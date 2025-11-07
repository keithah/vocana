# PR #34 Recommended Code Fixes

This document provides specific code fixes for all critical and high-priority issues.

---

## CRITICAL-001: Synchronous Queue Call in Audio Hot Path

### Current Code (AudioEngine.swift:156-164)
```swift
bufferManager.recordBufferOverflow = { [weak self] in
    guard let self = self else { return }
    self.telemetryQueue.sync {
        self.telemetrySnapshot.recordAudioBufferOverflow()
        Task { @MainActor in
            self.telemetry = self.telemetrySnapshot
            self.updatePerformanceStatus()
        }
    }
}
```

### Problem
- Synchronous blocking in audio hot path
- 47+ times per second at 48kHz
- Even 100µs blocks cause dropout risk

### Fix
Replace sync with async and debounce:

```swift
private var telemetryUpdateWorkItem: DispatchWorkItem?

private func setupComponentCallbacks() {
    bufferManager.recordBufferOverflow = { [weak self] in
        guard let self = self else { return }
        self.scheduleTelemetryUpdate {
            self.telemetrySnapshot.recordAudioBufferOverflow()
        }
    }
    
    bufferManager.recordCircuitBreakerTrigger = { [weak self] in
        guard let self = self else { return }
        self.scheduleTelemetryUpdate {
            self.telemetrySnapshot.recordCircuitBreakerTrigger()
        }
    }
    
    mlProcessor.recordLatency = { [weak self] latency in
        guard let self = self else { return }
        // Update latency immediately (non-blocking)
        Task { @MainActor in
            self.processingLatencyMs = latency
        }
        self.scheduleTelemetryUpdate {
            self.telemetrySnapshot.recordLatency(latency)
        }
    }
    
    // ... rest of callbacks
}

private func scheduleTelemetryUpdate(_ update: @escaping () -> Void) {
    // Cancel previous work item if not yet executed
    telemetryUpdateWorkItem?.cancel()
    
    let workItem = DispatchWorkItem { [weak self] in
        guard let self = self else { return }
        self.telemetryQueue.sync {
            update()
            Task { @MainActor in
                self.telemetry = self.telemetrySnapshot
                self.updatePerformanceStatus()
            }
        }
    }
    
    // Debounce: execute after 50ms if no new updates
    telemetryUpdateWorkItem = workItem
    self.telemetryQueue.asyncAfter(deadline: .now() + .milliseconds(50), execute: workItem)
}
```

### Benefits
- Non-blocking telemetry updates
- Batched updates (max 20 times/sec instead of 47+)
- No audio dropout risk
- Reduced CPU load from Task allocation

---

## HIGH-001: MainActor Task Creation Inside Queue Sync Block

### Current Code (AudioEngine.swift:156-164)
```swift
bufferManager.recordBufferOverflow = { [weak self] in
    guard let self = self else { return }
    self.telemetryQueue.sync {
        self.telemetrySnapshot.recordAudioBufferOverflow()
        Task { @MainActor in  // DEADLOCK RISK
            self.telemetry = self.telemetrySnapshot
            self.updatePerformanceStatus()
        }
    }
}
```

### Problem
- Spawning MainActor task inside sync block
- If main thread blocked: deadlock
- Sync block holds lock while waiting for MainActor

### Fix (Primary Solution)
Use the debouncing approach from CRITICAL-001, which moves the Task outside sync.

### Alternative Quick Fix (if keeping sync)
```swift
bufferManager.recordBufferOverflow = { [weak self] in
    guard let self = self else { return }
    let snapshot: ProductionTelemetry
    self.telemetryQueue.sync {
        self.telemetrySnapshot.recordAudioBufferOverflow()
        snapshot = self.telemetrySnapshot
    }
    // Task spawned OUTSIDE sync block
    Task { @MainActor in
        self.telemetry = snapshot
        self.updatePerformanceStatus()
    }
}
```

### Why This Fixes It
- MainActor task not created while holding queue lock
- No risk of deadlock
- Main thread can be blocked without affecting queue

---

## HIGH-002: Undocumented Thread Safety Contract for Callbacks

### Current Code (AudioBufferManager.swift:24-26)
```swift
var recordBufferOverflow: () -> Void = {}
var recordCircuitBreakerTrigger: () -> Void = {}
var recordCircuitBreakerSuspension: (TimeInterval) -> Void = { _ in }
```

### Problem
- No documentation about threading
- Called from `audioBufferQueue`, not MainActor
- Users could misuse and create race conditions

### Fix
Add comprehensive documentation:

```swift
/// Callback invoked when audio buffer overflows.
///
/// - Important: This callback is invoked from `audioBufferQueue`, which runs at `.userInitiated` QoS.
///   **Do NOT perform blocking operations** (e.g., file I/O, network requests, locks).
///   **Do NOT directly update UI or call @MainActor methods** - use Task { @MainActor in ... } instead.
///   Keep processing minimal - the audio processing thread is waiting.
///
/// - Thread Safety: You MUST NOT hold locks or dispatch to other queues without .async.
///   For UI updates, use: Task { @MainActor in self.updateUI() }
///
/// - Performance: This callback is in the audio hot path. Avoid allocations, use weak self.
///
/// Example:
/// ```
/// manager.recordBufferOverflow = { [weak self] in
///     // Bad: self.someUIUpdate() - WILL CRASH
///     // Bad: someDispatchQueue.sync {} - DEADLOCK RISK
///     // Good: Task { @MainActor in self?.updateUI() }
///     Task { @MainActor [weak self] in
///         self?.bufferHealthMessage = "Overflow detected"
///     }
/// }
/// ```
var recordBufferOverflow: () -> Void = {}

/// Callback invoked when circuit breaker is triggered.
/// See recordBufferOverflow documentation for threading requirements.
var recordCircuitBreakerTrigger: () -> Void = {}

/// Callback invoked when audio capture is suspended by circuit breaker.
/// Parameter: duration - TimeInterval for suspension (e.g., 0.15 seconds)
/// See recordBufferOverflow documentation for threading requirements.
var recordCircuitBreakerSuspension: (TimeInterval) -> Void = { _ in }
```

---

## HIGH-003: MLAudioProcessor isMLProcessingActive Not Synchronized

### Current Code (MLAudioProcessor.swift)
```swift
@MainActor
class MLAudioProcessor {
    private let mlStateQueue = DispatchQueue(label: "com.vocana.mlstate", qos: .userInitiated)
    private var mlProcessingSuspendedDueToMemory = false
    
    var isMLProcessingActive = false  // Written from multiple contexts
    
    // Line 74: within MainActor.run
    await MainActor.run { [weak self] in
        self.denoiser = denoiser
        self.isMLProcessingActive = true  // OK - on MainActor
    }
    
    // Line 139: direct write
    func processAudioWithML(...) -> [Float]? {
        // ...
        catch {
            isMLProcessingActive = false  // NO PROTECTION
        }
    }
}
```

### Problem
- `isMLProcessingActive` written without consistent protection
- Race condition with `mlProcessingSuspendedDueToMemory`
- Inconsistent state management

### Fix
Ensure all state writes are protected:

```swift
@MainActor
class MLAudioProcessor {
    private static let logger = Logger(subsystem: "Vocana", category: "MLAudioProcessor")
    
    private var denoiser: DeepFilterNet?
    private var mlInitializationTask: Task<Void, Never>?
    
    // ML state management - protected by mlStateQueue
    private let mlStateQueue = DispatchQueue(label: "com.vocana.mlstate", qos: .userInitiated)
    
    private var mlProcessingSuspendedDueToMemory = false
    private var _isMLProcessingActive = false
    
    // Public accessor (on MainActor)
    var isMLProcessingActive: Bool {
        mlStateQueue.sync { _isMLProcessingActive }
    }
    
    private func setMLProcessingActive(_ active: Bool) {
        mlStateQueue.sync {
            _isMLProcessingActive = active
        }
    }
    
    func initializeMLProcessing() {
        mlInitializationTask?.cancel()
        
        mlInitializationTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            do {
                guard !Task.isCancelled else { return }
                
                let modelsPath = self.findModelsDirectory()
                guard !Task.isCancelled else { return }
                
                let denoiser = try DeepFilterNet(modelsDirectory: modelsPath)
                let wasCancelled = Task.isCancelled
                
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    
                    let canActivateML = self.mlStateQueue.sync {
                        !self.mlProcessingSuspendedDueToMemory
                    }
                    
                    guard !wasCancelled && canActivateML else {
                        return
                    }
                    
                    self.denoiser = denoiser
                    self.setMLProcessingActive(true)
                    Self.logger.info("DeepFilterNet ML processing enabled")
                }
            } catch {
                guard !Task.isCancelled else { return }
                
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    Self.logger.error("Could not initialize ML processing: \(error.localizedDescription)")
                    self.denoiser = nil
                    self.setMLProcessingActive(false)
                }
            }
        }
    }
    
    func processAudioWithML(chunk: [Float], sensitivity: Double) -> [Float]? {
        let canProcess = mlStateQueue.sync {
            _isMLProcessingActive && !mlProcessingSuspendedDueToMemory
        }
        guard canProcess, let capturedDenoiser = denoiser else {
            return nil
        }
        
        do {
            let startTime = CFAbsoluteTimeGetCurrent()
            let enhanced = try capturedDenoiser.process(audio: chunk)
            let endTime = CFAbsoluteTimeGetCurrent()
            
            let latencyMs = (endTime - startTime) * 1000.0
            recordLatency(latencyMs)
            
            if latencyMs > 1.0 {
                Self.logger.warning("Latency SLA violation: \(String(format: "%.2f", latencyMs))ms > 1.0ms")
            }
            
            return enhanced
        } catch {
            Self.logger.error("ML processing error: \(error.localizedDescription)")
            recordFailure()
            
            setMLProcessingActive(false)
            denoiser = nil
            return nil
        }
    }
}
```

### Key Changes
- Private `_isMLProcessingActive` backing var
- Public accessor uses `mlStateQueue.sync`
- All writes go through `setMLProcessingActive()`
- Consistent protection everywhere

---

## HIGH-004: Integer Overflow Vulnerability in Buffer Size Calculation

### Current Code (AudioBufferManager.swift:40-44)
```swift
func appendToBufferAndExtractChunk(
    samples: [Float],
    onCircuitBreakerTriggered: @escaping (TimeInterval) -> Void
) -> [Float]? {
    return audioBufferQueue.sync {
        let maxBufferSize = AppConstants.maxAudioBufferSize
        
        // Check for overflow without validating input first
        let (projectedSize, overflowed) = bufferState.audioBuffer.count
            .addingReportingOverflow(samples.count)
        
        if overflowed || projectedSize > maxBufferSize {
            // Handle overflow...
        }
    }
}
```

### Problem
- `samples.count` not validated before overflow check
- Extremely large `samples` could bypass checks
- Should validate input before arithmetic

### Fix
Add input validation before overflow check:

```swift
func appendToBufferAndExtractChunk(
    samples: [Float],
    onCircuitBreakerTriggered: @escaping (TimeInterval) -> Void
) -> [Float]? {
    return audioBufferQueue.sync {
        let maxBufferSize = AppConstants.maxAudioBufferSize
        
        // Fix HIGH-004: Validate input size before arithmetic operations
        guard samples.count > 0 else {
            return nil  // Empty sample buffer
        }
        
        guard samples.count <= maxBufferSize else {
            // Samples array itself exceeds max buffer size
            Self.logger.warning("Sample array exceeds max buffer size: \(samples.count) > \(maxBufferSize)")
            recordBufferOverflow()
            return nil
        }
        
        // Now safe to check for overflow
        let (projectedSize, overflowed) = bufferState.audioBuffer.count
            .addingReportingOverflow(samples.count)
        
        if overflowed || projectedSize > maxBufferSize {
            // Handle overflow...
            bufferState.consecutiveOverflows += 1
            recordBufferOverflow()
            
            if bufferState.consecutiveOverflows > AppConstants.maxConsecutiveOverflows 
                && !bufferState.audioCaptureSuspended {
                recordCircuitBreakerTrigger()
                bufferState.audioCaptureSuspended = true
                // ... rest of handling
            }
            // ... overflow handling continues
        } else {
            bufferState.consecutiveOverflows = 0
            bufferState.audioBuffer.append(contentsOf: samples)
        }
        
        // Check if we have enough samples for a chunk
        guard bufferState.audioBuffer.count >= minimumBufferSize else {
            return nil
        }
        
        let chunk = Array(bufferState.audioBuffer.prefix(minimumBufferSize))
        bufferState.audioBuffer.removeFirst(minimumBufferSize)
        return chunk
    }
}
```

### Benefits
- Input validation before arithmetic
- Prevents resource exhaustion attacks
- Clear error logging for debugging
- Safe bounds on all operations

---

## MEDIUM-002: Remove Unused Method

### Current Code (AudioSessionManager.swift:130-137)
```swift
/// Suspend audio capture (circuit breaker)
/// - Parameter duration: How long to suspend for
func suspendAudioCapture(duration: TimeInterval) {
    audioCaptureSuspensionTimer?.invalidate()
    audioCaptureSuspensionTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
        Task { @MainActor in
            self?.resumeAudioCapture()
        }
    }
}
```

### Problem
- Never called in the codebase
- AudioEngine handles suspension differently (lines 183-187)
- Creates API confusion

### Fix: Option 1 - Remove It
Simply delete the `suspendAudioCapture()` and `resumeAudioCapture()` methods.

### Fix: Option 2 - Integrate It
If you want to keep it for future use, document why:

```swift
/// Suspend audio capture temporarily (not currently used - for future circuit breaker enhancement).
/// - Parameter duration: How long to suspend audio capture
/// - Note: Currently, circuit breaker suspension is handled by AudioEngine directly.
///   This method is available if we need to decouple that responsibility.
@available(*, deprecated, message: "Use AudioEngine's circuit breaker instead")
func suspendAudioCapture(duration: TimeInterval) {
    // ... implementation
}
```

### Recommendation
**Remove it** - AudioEngine already handles suspension, and this creates confusion about responsibility.

---

## MEDIUM-003: Document MainActor + Queue Hybrid Model

### Current Code (MLAudioProcessor.swift:7)
```swift
@MainActor
class MLAudioProcessor {
    private let mlStateQueue = DispatchQueue(label: "com.vocana.mlstate", qos: .userInitiated)
    // No explanation of why both are used
}
```

### Fix
Add comprehensive documentation:

```swift
/// ML audio processor using DeepFilterNet for audio denoising.
///
/// ## Threading Model
/// This class is isolated to MainActor, but uses an internal DispatchQueue for specific state synchronization.
///
/// **Why the hybrid approach?**
/// - All public methods must be called on MainActor (enforced by compiler)
/// - Internal state `mlProcessingSuspendedDueToMemory` needs fast, lock-free updates from performance-sensitive paths
/// - The `mlStateQueue` protects only this specific state, allowing concurrent reads without MainActor context switch
/// - This hybrid approach optimizes the common case (checking if ML is suspended) without context switching overhead
///
/// **Threading Guarantees:**
/// - All public properties and methods: MainActor only
/// - State reads via mlStateQueue: Thread-safe from any thread
/// - State writes: Always go through setMLProcessingActive() or via sync queue
///
/// ## Usage Example
/// ```swift
/// // On MainActor
/// processor.initializeMLProcessing()
///
/// // Can check from any thread efficiently
/// let isSuspended = processor.isMemoryPressureSuspended()
/// ```
@MainActor
class MLAudioProcessor {
    private static let logger = Logger(subsystem: "Vocana", category: "MLAudioProcessor")
    
    private var denoiser: DeepFilterNet?
    private var mlInitializationTask: Task<Void, Never>?
    
    /// Internal queue for lock-free state synchronization
    /// Only protects mlProcessingSuspendedDueToMemory for minimal contention
    private let mlStateQueue = DispatchQueue(label: "com.vocana.mlstate", qos: .userInitiated)
    private var mlProcessingSuspendedDueToMemory = false
    
    // ... rest of class
}
```

---

## MEDIUM-005: Extract Concerns from processAudioBuffer

### Current Code (AudioEngine.swift:277-302)
```swift
private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
    // Fix HIGH: Skip processing if audio capture is suspended
    guard !audioCaptureSuspended else { return }
    
    guard let channelData = buffer.floatChannelData else { return }
    let channelDataValue = channelData.pointee
    let frames = buffer.frameLength
    
    let capturedEnabled = isEnabled
    let capturedSensitivity = sensitivity
    
    let samplesPtr = UnsafeBufferPointer(start: channelDataValue, count: Int(frames))
    
    let inputLevel = levelController.calculateRMSFromPointer(samplesPtr)
    
    if capturedEnabled {
        let samples = Array(samplesPtr)
        let outputLevel = processWithMLIfAvailable(samples: samples, sensitivity: capturedSensitivity)
        currentLevels = AudioLevels(input: inputLevel, output: outputLevel)
    } else {
        currentLevels = levelController.applyDecay()
    }
}
```

### Problem
- Handles: suspension check, pointer extraction, level calculation, ML coordination
- 26 lines with multiple concerns
- Hard to test individual concerns

### Fix
Extract into focused methods:

```swift
private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
    // Step 1: Guard against suspension
    guard !audioCaptureSuspended else { return }
    
    // Step 2: Extract samples safely
    guard let samplesPtr = extractAudioSamples(from: buffer) else { return }
    
    // Step 3: Capture state atomically
    let (enabled, sensitivity) = captureAudioState()
    
    // Step 4: Calculate and process levels
    let inputLevel = levelController.calculateRMSFromPointer(samplesPtr)
    
    if enabled {
        let samples = Array(samplesPtr)
        let outputLevel = processWithMLIfAvailable(samples: samples, sensitivity: sensitivity)
        currentLevels = AudioLevels(input: inputLevel, output: outputLevel)
    } else {
        currentLevels = levelController.applyDecay()
    }
}

/// Extract audio samples from buffer safely
private func extractAudioSamples(from buffer: AVAudioPCMBuffer) -> UnsafeBufferPointer<Float>? {
    guard let channelData = buffer.floatChannelData else { return nil }
    let channelDataValue = channelData.pointee
    let frames = buffer.frameLength
    return UnsafeBufferPointer(start: channelDataValue, count: Int(frames))
}

/// Capture audio enabled state and sensitivity atomically
private func captureAudioState() -> (enabled: Bool, sensitivity: Double) {
    return (isEnabled, sensitivity)
}
```

### Benefits
- Each method has single responsibility
- Easier to test individually
- Easier to modify without affecting others
- Better code reusability

---

## Summary of Fixes

| Issue | File | Complexity | Effort |
|-------|------|-----------|--------|
| CRITICAL-001 | AudioEngine.swift | High | 1-2 hrs |
| HIGH-001 | AudioEngine.swift | Medium | 1 hr |
| HIGH-002 | AudioBufferManager.swift | Low | 30 min |
| HIGH-003 | MLAudioProcessor.swift | High | 1-2 hrs |
| HIGH-004 | AudioBufferManager.swift | Low | 30 min |
| MEDIUM-002 | AudioSessionManager.swift | Minimal | 5 min |
| MEDIUM-003 | MLAudioProcessor.swift | Low | 30 min |
| MEDIUM-005 | AudioEngine.swift | Medium | 1 hr |

**Total Estimated Time**: 6-8 hours for critical/high issues

---

## Testing Recommendations After Fixes

1. **Unit Tests**: Verify individual fix correctness
2. **Integration Tests**: Verify components still work together
3. **Performance Tests**: Measure telemetry callback latency
4. **Concurrency Tests**: Rapid buffer arrivals with main thread load
5. **ThreadSanitizer**: Run with race detection enabled
6. **Memory Tests**: Verify no task leaks, no memory growth

---

Generated: November 7, 2025
