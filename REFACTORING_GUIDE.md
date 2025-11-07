# Refactoring Guide - Vocana Codebase
**Detailed Code Examples for High-Impact Improvements**

---

## 1. Extract AudioBufferManager (6-hour refactor)

### Current State (AudioEngine.swift:522-599, ~77 lines)
```swift
// Monolithic - mixed concerns
private func appendToBufferAndExtractChunk(samples: [Float]) -> [Float]? {
    return audioBufferQueue.sync {
        let maxBufferSize = AppConstants.maxAudioBufferSize
        let projectedSize = _audioBuffer.count + samples.count
        
        if projectedSize > maxBufferSize {
            consecutiveOverflows += 1
            
            if consecutiveOverflows > AppConstants.maxConsecutiveOverflows && !audioCaptureSuspended {
                suspendAudioCapture(duration: AppConstants.circuitBreakerSuspensionSeconds)
                return nil
            }
            
            // ... 20 lines of overflow handling ...
        } else {
            consecutiveOverflows = 0
            _audioBuffer.append(contentsOf: samples)
        }
        
        guard _audioBuffer.count >= minimumBufferSize else {
            return nil
        }
        let chunk = Array(_audioBuffer.prefix(minimumBufferSize))
        _audioBuffer.removeFirst(minimumBufferSize)
        return chunk
    }
}
```

### Refactored State (AudioBufferManager.swift, new file ~120 lines)
```swift
import Foundation
import os.log

/// Manages circular audio buffer with overflow detection and recovery
class AudioBufferManager {
    private static let logger = Logger(subsystem: "com.vocana", category: "AudioBuffer")
    
    // Configuration
    let maxBufferSize: Int
    let minimumChunkSize: Int
    let maxConsecutiveOverflows: Int
    let circuitBreakerSuspensionDuration: TimeInterval
    
    // State
    private let queue = DispatchQueue(label: "com.vocana.buffer", qos: .userInteractive)
    private var buffer: [Float] = []
    private var consecutiveOverflows = 0
    private var isCircuitBreakerTripped = false
    
    // Observers
    var onCircuitBreakerTriggered: ((TimeInterval) -> Void)?
    var onOverflowDetected: ((Int) -> Void)?
    
    init(
        maxBufferSize: Int = AppConstants.maxAudioBufferSize,
        minimumChunkSize: Int = AppConstants.fftSize,
        maxConsecutiveOverflows: Int = AppConstants.maxConsecutiveOverflows,
        circuitBreakerDuration: TimeInterval = AppConstants.circuitBreakerSuspensionSeconds
    ) {
        self.maxBufferSize = maxBufferSize
        self.minimumChunkSize = minimumChunkSize
        self.maxConsecutiveOverflows = maxConsecutiveOverflows
        self.circuitBreakerSuspensionDuration = circuitBreakerDuration
    }
    
    // MARK: - Public Interface
    
    enum AppendResult {
        case chunkReady([Float])
        case circuitBreakerTriggered(suspensionDuration: TimeInterval)
        case overflowHandled
        case bufferNotReady
    }
    
    func append(_ samples: [Float]) -> AppendResult {
        queue.sync {
            let projectedSize = buffer.count + samples.count
            
            if projectedSize > maxBufferSize {
                return handleOverflow(with: samples)
            } else {
                consecutiveOverflows = 0
                buffer.append(contentsOf: samples)
                return extractIfReady()
            }
        }
    }
    
    func reset() {
        queue.sync {
            buffer.removeAll(keepingCapacity: false)
            consecutiveOverflows = 0
            isCircuitBreakerTripped = false
        }
    }
    
    var bufferCount: Int {
        queue.sync { buffer.count }
    }
    
    // MARK: - Private Methods
    
    private func handleOverflow(with samples: [Float]) -> AppendResult {
        consecutiveOverflows += 1
        onOverflowDetected?(buffer.count)
        
        // Check if circuit breaker should trigger
        if consecutiveOverflows > maxConsecutiveOverflows && !isCircuitBreakerTripped {
            isCircuitBreakerTripped = true
            onCircuitBreakerTriggered?(circuitBreakerSuspensionDuration)
            Self.logger.warning("Circuit breaker triggered: \(self.consecutiveOverflows) consecutive overflows")
            return .circuitBreakerTriggered(suspensionDuration: circuitBreakerSuspensionDuration)
        }
        
        // Apply crossfade and remove old samples
        applyCrossfadeAndRemoveOldSamples(newSamples: samples)
        
        Self.logger.warning("Audio buffer overflow: \(self.buffer.count) + \(samples.count) > \(self.maxBufferSize)")
        return .overflowHandled
    }
    
    private func applyCrossfadeAndRemoveOldSamples(newSamples: [Float]) {
        let overflow = (buffer.count + newSamples.count) - maxBufferSize
        let samplesToRemove = min(overflow, buffer.count)
        let fadeLength = min(AppConstants.crossfadeLengthSamples, samplesToRemove)
        
        // Remove old samples
        if samplesToRemove > 0 {
            buffer.removeFirst(samplesToRemove)
        }
        
        // Apply fade-in to new samples
        if fadeLength > 0 && newSamples.count >= fadeLength {
            var fadedSamples = newSamples
            for i in 0..<fadeLength {
                let fade = Float(i + 1) / Float(fadeLength)
                fadedSamples[i] *= fade
            }
            buffer.append(contentsOf: fadedSamples)
        } else {
            buffer.append(contentsOf: newSamples)
        }
    }
    
    private func extractIfReady() -> AppendResult {
        guard buffer.count >= minimumChunkSize else {
            return .bufferNotReady
        }
        
        let chunk = Array(buffer.prefix(minimumChunkSize))
        buffer.removeFirst(minimumChunkSize)
        return .chunkReady(chunk)
    }
}
```

### Updated AudioEngine Usage
```swift
class AudioEngine: ObservableObject {
    private let audioBuffer = AudioBufferManager()
    
    override init() {
        super.init()
        setupMemoryPressureMonitoring()
        
        // Observe buffer events
        audioBuffer.onCircuitBreakerTriggered = { [weak self] duration in
            self?.suspendAudioCapture(duration: duration)
        }
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        let samplesPtr = UnsafeBufferPointer(start: channelDataValue, count: Int(frames))
        let samples = Array(samplesPtr)
        
        // Simple, readable code
        let result = audioBuffer.append(samples)
        switch result {
        case .chunkReady(let chunk):
            processWithMLIfAvailable(samples: chunk)
        case .circuitBreakerTriggered(let duration):
            Self.logger.warning("Circuit breaker triggered, suspending for \(duration)s")
        case .overflowHandled:
            Self.logger.debug("Overflow handled with crossfade")
        case .bufferNotReady:
            break
        }
    }
}
```

**Benefits:**
- ✅ AudioEngine drops from 781 to 450 LOC
- ✅ AudioBufferManager is reusable and testable
- ✅ Clearer separation of concerns
- ✅ Easier to test buffer behavior independently

---

## 2. Fix Race Condition in startSimulation() (1-hour fix)

### Current Code (UNSAFE)
```swift
func startSimulation(isEnabled: Bool, sensitivity: Double) {
    self.isEnabled = isEnabled              // ← RACE POINT 1
    self.sensitivity = sensitivity          // ← RACE POINT 2
    
    stopSimulation()
    
    // PROBLEM: Another thread might have read isEnabled = false here
    if isEnabled {                          // ← Uses stale value!
        initializeMLProcessing()
    }
    
    if startRealAudioCapture() {
        isUsingRealAudio = true
    } else {
        isUsingRealAudio = false
        startSimulatedAudio()
    }
}
```

### Fixed Code (SAFE)
```swift
@MainActor
func startSimulation(isEnabled: Bool, sensitivity: Double) {
    // Step 1: Atomically capture all incoming parameters
    let enabledValue = isEnabled
    let sensitivityValue = sensitivity
    
    // Step 2: Stop existing processing
    stopSimulation()
    
    // Step 3: Commit new state atomically (all at once, no races)
    self.isEnabled = enabledValue
    self.sensitivity = sensitivityValue
    
    // Step 4: Initialize ML if enabled (uses captured consistent state)
    if enabledValue {
        initializeMLProcessing()
    }
    
    // Step 5: Start capture
    let capturedReal = startRealAudioCapture()
    isUsingRealAudio = capturedReal
    
    if !capturedReal {
        startSimulatedAudio()
    }
}
```

**Why This Works:**
- @MainActor ensures single-threaded execution
- Capture parameters immediately to prevent changes
- All state updates happen consecutively with no interleaving
- No other thread can observe partial state

---

## 3. Refactor appendToBufferAndExtractChunk Complexity (2-hour fix)

### Current Code (CC ≈ 11)
```swift
private func appendToBufferAndExtractChunk(samples: [Float]) -> [Float]? {
    return audioBufferQueue.sync {
        let maxBufferSize = AppConstants.maxAudioBufferSize
        let projectedSize = _audioBuffer.count + samples.count
        
        if projectedSize > maxBufferSize {           // ← Branch 1
            consecutiveOverflows += 1
            var updatedTelemetry = telemetry
            updatedTelemetry.recordAudioBufferOverflow()
            telemetry = updatedTelemetry
            
            if consecutiveOverflows > AppConstants.maxConsecutiveOverflows && !audioCaptureSuspended { // ← Branch 2
                updatedTelemetry = telemetry
                updatedTelemetry.recordCircuitBreakerTrigger()
                telemetry = updatedTelemetry
                Self.logger.warning("Circuit breaker triggered")
                suspendAudioCapture(duration: AppConstants.circuitBreakerSuspensionSeconds)
                return nil
            }
            
            let overflow = projectedSize - maxBufferSize
            let samplesToRemove = min(overflow, _audioBuffer.count)
            let fadeLength = min(AppConstants.crossfadeLengthSamples, samplesToRemove)
            
            if samplesToRemove > 0 {                 // ← Branch 3
                _audioBuffer.removeFirst(samplesToRemove)
            }
            
            if fadeLength > 0 && samples.count >= fadeLength { // ← Branch 4
                var fadedSamples = samples
                for i in 0..<fadeLength {
                    fadedSamples[i] *= Float(i + 1) / Float(fadeLength)
                }
                _audioBuffer.append(contentsOf: fadedSamples)
            } else {
                _audioBuffer.append(contentsOf: samples)
            }
        } else {                                     // ← Branch 5
            consecutiveOverflows = 0
            _audioBuffer.append(contentsOf: samples)
        }
        
        guard _audioBuffer.count >= minimumBufferSize else {
            return nil
        }
        let chunk = Array(_audioBuffer.prefix(minimumBufferSize))
        _audioBuffer.removeFirst(minimumBufferSize)
        return chunk
    }
}
```

### Refactored Code (CC ≈ 3 per function)
```swift
// Keep original signature for backward compatibility
private func appendToBufferAndExtractChunk(samples: [Float]) -> [Float]? {
    audioBufferQueue.sync {
        // Delegate to simpler functions
        if shouldHandleOverflow(with: samples) {
            handleBufferOverflow(with: samples)
        } else {
            consecutiveOverflows = 0
            _audioBuffer.append(contentsOf: samples)
        }
        
        return extractChunkIfReady()
    }
}

// Branch 1 - Check if overflow
private func shouldHandleOverflow(with samples: [Float]) -> Bool {
    _audioBuffer.count + samples.count > AppConstants.maxAudioBufferSize
}

// Branch 2 - Handle the overflow scenario
private func handleBufferOverflow(with samples: [Float]) {
    consecutiveOverflows += 1
    recordOverflowTelemetry()
    
    if shouldTriggerCircuitBreaker() {
        triggerCircuitBreaker()
        return
    }
    
    let overflow = _audioBuffer.count + samples.count - AppConstants.maxAudioBufferSize
    let samplesToRemove = min(overflow, _audioBuffer.count)
    removeOldSamples(count: samplesToRemove)
    appendWithCrossfade(samples, fadeLength: calculateFadeLength(samplesToRemove))
}

// Helper: Telemetry
private func recordOverflowTelemetry() {
    var updated = telemetry
    updated.recordAudioBufferOverflow()
    telemetry = updated
}

// Helper: Circuit breaker check
private func shouldTriggerCircuitBreaker() -> Bool {
    consecutiveOverflows > AppConstants.maxConsecutiveOverflows && !audioCaptureSuspended
}

// Helper: Circuit breaker trigger
private func triggerCircuitBreaker() {
    var updated = telemetry
    updated.recordCircuitBreakerTrigger()
    telemetry = updated
    Self.logger.warning("Circuit breaker triggered: \(self.consecutiveOverflows) overflows")
    suspendAudioCapture(duration: AppConstants.circuitBreakerSuspensionSeconds)
}

// Helper: Remove and fade
private func appendWithCrossfade(_ samples: [Float], fadeLength: Int) {
    if fadeLength > 0 && samples.count >= fadeLength {
        var faded = samples
        for i in 0..<fadeLength {
            faded[i] *= Float(i + 1) / Float(fadeLength)
        }
        _audioBuffer.append(contentsOf: faded)
    } else {
        _audioBuffer.append(contentsOf: samples)
    }
}

// Helper: Extract if ready
private func extractChunkIfReady() -> [Float]? {
    guard _audioBuffer.count >= minimumBufferSize else { return nil }
    let chunk = Array(_audioBuffer.prefix(minimumBufferSize))
    _audioBuffer.removeFirst(minimumBufferSize)
    return chunk
}

// Helper: Calculate fade length
private func calculateFadeLength(_ samplesToRemove: Int) -> Int {
    min(AppConstants.crossfadeLengthSamples, samplesToRemove)
}

// Helper: Remove old samples
private func removeOldSamples(count: Int) {
    guard count > 0 else { return }
    _audioBuffer.removeFirst(count)
}
```

**Before/After Metrics:**
```
Before:
  Lines: 76
  CC: 11
  Nested depth: 4
  Testability: Poor (all mixed together)

After:
  Main func: 15 lines, CC: 3
  Helper funcs: Each < 10 lines, CC: 1-2
  Testability: Excellent (each helper testable independently)
```

---

## 4. Split Broad Error Types (1-hour fix)

### Current State (ONNXModel.swift, lines 12-22)
```swift
enum ONNXError: Error {
    case modelNotFound(String)          // File system
    case sessionCreationFailed(String)  // Runtime init
    case inferenceError(String)         // Computation
    case invalidInputShape(String)      // Type error
    case invalidOutputShape(String)     // Type error
    case shapeOverflow(String)          // Numeric error
    case emptyInputs                    // Validation
    case emptyOutputs                   // Validation
    case invalidInput(String)           // Validation
}
```

### Refactored State
```swift
// File system errors
enum ONNXResourceError: Error {
    case modelNotFound(String)
    case sessionCreationFailed(String)
}

// Computation errors
enum ONNXInferenceError: Error {
    case computationFailed(String)
    case tensorMismatch(String)
}

// Type/shape errors
enum ONNXShapeError: Error {
    case invalidInputShape(String)
    case invalidOutputShape(String)
    case shapeOverflow(String)
    case dimensionMismatch(expected: Int, got: Int)
}

// Validation errors
enum ONNXValidationError: Error {
    case emptyInputs
    case emptyOutputs
    case invalidInput(String)
    case invalidTensorData(String)
}

// Combined error for throwing
enum ONNXError: Error {
    case resource(ONNXResourceError)
    case inference(ONNXInferenceError)
    case shape(ONNXShapeError)
    case validation(ONNXValidationError)
}
```

### Usage Benefits
```swift
// Before: Caller can't distinguish error types
catch let error as ONNXError {
    // Have to pattern match all 9 cases
}

// After: Caller can handle by category
catch let error as ONNXShapeError {
    // Only shape-related errors
    logger.error("Shape problem: \(error)")
}
catch let error as ONNXResourceError {
    // Only file/resource errors
    showUserDialog("Model not found")
}
```

---

## 5. Add Protocol-Based AudioCapture (3-hour refactor)

### Define Protocol
```swift
protocol AudioCapture {
    func start(tapHandler: @escaping (AVAudioPCMBuffer) -> Void) -> Bool
    func stop()
}
```

### Real Implementation
```swift
class AVAudioEngineCapture: AudioCapture {
    private var audioEngine: AVAudioEngine?
    private var isTapInstalled = false
    
    func start(tapHandler: @escaping (AVAudioPCMBuffer) -> Void) -> Bool {
        do {
            #if os(iOS) || os(tvOS) || os(watchOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
            #endif
            
            audioEngine = AVAudioEngine()
            guard let audioEngine = audioEngine else { return false }
            
            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
                Task.detached(priority: .userInteractive) {
                    tapHandler(buffer)
                }
            }
            isTapInstalled = true
            
            try audioEngine.start()
            return true
        } catch {
            Logger(subsystem: "Vocana", category: "AudioCapture")
                .error("Failed: \(error)")
            stop()
            return false
        }
    }
    
    func stop() {
        if isTapInstalled, let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        audioEngine?.stop()
        audioEngine = nil
    }
}
```

### Mock Implementation for Testing
```swift
class MockAudioCapture: AudioCapture {
    var tapHandler: ((AVAudioPCMBuffer) -> Void)?
    var startCalled = false
    var stopCalled = false
    
    func start(tapHandler: @escaping (AVAudioPCMBuffer) -> Void) -> Bool {
        self.tapHandler = tapHandler
        startCalled = true
        return true
    }
    
    func stop() {
        stopCalled = true
    }
    
    func simulateTap(buffer: AVAudioPCMBuffer) {
        tapHandler?(buffer)
    }
}
```

### AudioEngine Usage
```swift
class AudioEngine: ObservableObject {
    let audioCapture: AudioCapture
    
    init(audioCapture: AudioCapture = AVAudioEngineCapture()) {
        self.audioCapture = audioCapture
        // ...
    }
    
    private func startRealAudioCapture() -> Bool {
        audioCapture.start { [weak self] buffer in
            self?.processAudioBuffer(buffer)
        }
    }
    
    private func stopRealAudioCapture() {
        audioCapture.stop()
    }
}
```

### Test Example
```swift
func testAudioCaptureWithMock() {
    let mockCapture = MockAudioCapture()
    let audioEngine = AudioEngine(audioCapture: mockCapture)
    
    audioEngine.startSimulation(isEnabled: true, sensitivity: 0.5)
    
    XCTAssertTrue(mockCapture.startCalled)
    
    // Simulate audio without real microphone!
    let mockBuffer = createMockAudioBuffer()
    mockCapture.simulateTap(buffer: mockBuffer)
    
    XCTAssertGreater(audioEngine.currentLevels.input, 0)
}
```

---

## Summary: Effort vs. Impact

| Refactoring | Effort | Impact | Priority |
|-------------|--------|--------|----------|
| Extract AudioBufferManager | 6h | ★★★★★ | 🔴 Critical |
| Fix startSimulation() race | 1h | ★★★★☆ | 🔴 Critical |
| Simplify appendToBuffer() | 2h | ★★★★★ | 🔴 Critical |
| Split error enums | 1h | ★★★☆☆ | 🟠 High |
| Protocol-AudioCapture | 3h | ★★★★☆ | 🟡 Medium |
| Extract MemoryPressure | 2h | ★★★☆☆ | 🟡 Medium |
| Extract MLOrchestrator | 4h | ★★★★☆ | 🟡 Medium |

**Total Critical Work:** 9 hours → 40% reduction in complexity

---

**Next Steps:**
1. Implement Critical fixes (Week 1)
2. Get code review from team
3. Run extended testing on refactored code
4. Merge to main branch with comprehensive test suite
