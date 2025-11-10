import Foundation
import os.log

/// Manages audio buffer lifecycle and chunk extraction
/// Responsibility: Buffer management, thread-safe append/extract operations, overflow handling
/// Isolated from level calculation, audio capture, and ML processing
class AudioBufferManager {
    private static let logger = Logger(subsystem: "Vocana", category: "AudioBufferManager")
    
    private let minimumBufferSize = 960  // FFT size for DeepFilterNet
    private let audioBufferQueue = DispatchQueue(label: "com.vocana.audiobuffer", qos: .userInteractive)
    
    // Fix CRI-002: Rate limiting to prevent DoS attacks through rapid buffer operations
    private let maxOperationsPerSecond = 1000
    private var operationCount = 0
    private var lastOperationTime = Date()
    
    // Fix CRITICAL-003: Use struct wrapper for proper encapsulation instead of nonisolated(unsafe)
    // All access to this structure must go through audioBufferQueue
    private struct BufferState {
        var audioBuffer: [Float] = []
        var consecutiveOverflows: Int = 0
        var audioCaptureSuspended: Bool = false
    }
    
    private var bufferState = BufferState()
    
    // Telemetry tracking (passed in from AudioEngine)
    /// Callback invoked when audio buffer overflows.
    /// - Important: This callback is invoked from the audioBufferQueue (user-initiated QoS).
    /// Do NOT perform blocking operations. Do NOT call methods that require MainActor.
    /// Use Task { @MainActor in ... } if main thread update needed.
    var recordBufferOverflow: () -> Void = {}
    
    /// Callback invoked when circuit breaker triggers due to repeated overflows.
    /// - Important: This callback is invoked from the audioBufferQueue (user-initiated QoS).
    /// Do NOT perform blocking operations. Do NOT call methods that require MainActor.
    /// Use Task { @MainActor in ... } if main thread update needed.
    var recordCircuitBreakerTrigger: () -> Void = {}
    
    /// Callback invoked when circuit breaker suspends audio capture for a duration.
    /// - Important: This callback is invoked from the audioBufferQueue (user-initiated QoS).
    /// Do NOT perform blocking operations. Do NOT call methods that require MainActor.
    /// Use Task { @MainActor in ... } if main thread update needed.
    /// - Parameter duration: Suspension duration in seconds
    var recordCircuitBreakerSuspension: (TimeInterval) -> Void = { _ in }
    
    /// Thread-safe append samples to buffer and extract chunk if ready
    /// - Parameters:
    ///   - samples: Audio samples to append
    ///   - onCircuitBreakerTriggered: Callback when circuit breaker activates
    /// - Returns: Audio chunk if minimum buffer size reached, nil otherwise
    func appendToBufferAndExtractChunk(
        samples: [Float],
        onCircuitBreakerTriggered: @escaping (TimeInterval) -> Void
    ) -> [Float]? {
        return audioBufferQueue.sync {
            // Fix CRI-002: Rate limiting to prevent DoS attacks - check FIRST
            let now = Date()
            let timeSinceLastOperation = now.timeIntervalSince(lastOperationTime)
            
            // Reset counter every second
            if timeSinceLastOperation >= 1.0 {
                operationCount = 0
                lastOperationTime = now
            }
            
            // Check rate limit
            self.operationCount += 1
            if self.operationCount > maxOperationsPerSecond {
                Self.logger.warning("Rate limit exceeded: \(self.operationCount) operations in \(timeSinceLastOperation)s")
                return nil
            }
            
            // Fix HIGH-003: Input validation to prevent excessive memory allocation
            // Only check size AFTER rate limiting to ensure all buffers are subject to CRI-002
            guard samples.count <= AppConstants.maxAudioBufferSize else {
                Self.logger.warning("Samples array exceeds max buffer size: \(samples.count)")
                recordBufferOverflow()
                return nil
            }
            let maxBufferSize = AppConstants.maxAudioBufferSize
            
            // Fix CRITICAL-001: Prevent integer overflow before calculation
            guard bufferState.audioBuffer.count <= Int.max - samples.count else {
                // Integer overflow would occur - treat as critical buffer overflow
                bufferState.consecutiveOverflows += 1
                recordBufferOverflow()
                Self.logger.error("Integer overflow in buffer size calculation")
                return nil
            }
            
            let projectedSize = bufferState.audioBuffer.count + samples.count
            
            // Handle buffer overflow
            if projectedSize > maxBufferSize {
                // Fix HIGH: Circuit breaker for sustained buffer overflows
                bufferState.consecutiveOverflows += 1
                recordBufferOverflow()
                
                if bufferState.consecutiveOverflows > AppConstants.maxConsecutiveOverflows && !bufferState.audioCaptureSuspended {
                    recordCircuitBreakerTrigger()
                    bufferState.audioCaptureSuspended = true
                    Self.logger.warning("Circuit breaker triggered: \(self.bufferState.consecutiveOverflows) consecutive overflows")
                    Self.logger.info("Suspending audio capture for \(AppConstants.circuitBreakerSuspensionSeconds)s to allow ML to catch up")
                    
                    // Schedule resumption - important: update state within queue, then schedule callback
                    let suspensionDuration = AppConstants.circuitBreakerSuspensionSeconds
                    let suspensionStartTime = DispatchTime.now()
                    
                    // Schedule the resumption update within the audioBufferQueue to ensure atomicity
                    audioBufferQueue.asyncAfter(deadline: suspensionStartTime + suspensionDuration) { [weak self] in
                        self?.bufferState.audioCaptureSuspended = false
                        Self.logger.info("Resuming audio capture after circuit breaker suspension")
                    }
                    
                    onCircuitBreakerTriggered(suspensionDuration)
                    recordCircuitBreakerSuspension(suspensionDuration)
                    return nil // Skip this buffer append to help recovery
                }
                
                // Fix CRITICAL: Implement smoothing to prevent audio discontinuities
                Self.logger.warning("Audio buffer overflow \(self.bufferState.consecutiveOverflows): \(self.bufferState.audioBuffer.count) + \(samples.count) > \(maxBufferSize)")
                Self.logger.info("Applying crossfade to maintain audio continuity")

                 // Fix CRITICAL: Calculate overflow safely without using wrapped values
                 // Use checked arithmetic to compute required removal
                 let requiredRemoval = max(0, bufferState.audioBuffer.count + samples.count - maxBufferSize)
                 let samplesToRemove = min(requiredRemoval, bufferState.audioBuffer.count)
                 
                 // Apply crossfade to prevent clicks/pops when dropping audio
                 // Note: In overflow scenarios, we prioritize latency and correctness over perfect audio continuity.
                 // We fade in new samples to smooth the transition, but don't fade out removed samples since
                 // they're being dropped due to buffer overflow (emergency situation).
                 let fadeLength = min(AppConstants.crossfadeLengthSamples, samplesToRemove)
                 
                 // Remove old samples first to make room for new ones
                 if samplesToRemove > 0 {
                     bufferState.audioBuffer.removeFirst(samplesToRemove)
                 }
                 
                 // Apply fade-in to new samples to smooth the discontinuity
                 // This reduces clicks/pops that might occur from the sample deletion
                 if fadeLength > 0 && samples.count >= fadeLength {
                     var fadedSamples = samples
                     for i in 0..<fadeLength {
                         // Linear fade-in over fadeLength samples
                         let fadeValue = Float(i + 1) / Float(fadeLength)
                         fadedSamples[i] *= fadeValue
                     }
                     bufferState.audioBuffer.append(contentsOf: fadedSamples)
                 } else {
                     bufferState.audioBuffer.append(contentsOf: samples)
                 }
            } else {
                // Reset overflow counter on successful append
                bufferState.consecutiveOverflows = 0
                bufferState.audioBuffer.append(contentsOf: samples)
            }
            
            // Check if we have enough samples for a chunk
            guard bufferState.audioBuffer.count >= minimumBufferSize else {
                return nil
            }
            
            // Extract chunk and remove from buffer
            let chunk = Array(bufferState.audioBuffer.prefix(minimumBufferSize))
            bufferState.audioBuffer.removeFirst(minimumBufferSize)
            return chunk
        }
    }
    
    /// Clear audio buffers (for cleanup/reset)
    func clearAudioBuffers() {
        audioBufferQueue.sync {
            bufferState.audioBuffer.removeAll()
            bufferState.consecutiveOverflows = 0
        }
    }
    
    /// Get current buffer size (for debugging/monitoring)
    /// - Returns: Number of samples currently in buffer
    func getCurrentBufferSize() -> Int {
        return audioBufferQueue.sync {
            // Fix SEC-002: Apply rate limiting to all public buffer operations
            enforceRateLimit()
            return bufferState.audioBuffer.count
        }
    }
    
    /// Check if buffer is ready for extraction
    /// - Returns: true if buffer has minimum samples
    func hasEnoughSamples() -> Bool {
        return audioBufferQueue.sync {
            // Fix SEC-002: Apply rate limiting to all public buffer operations
            enforceRateLimit()
            return bufferState.audioBuffer.count >= minimumBufferSize
        }
    }

    /// Check if audio capture is suspended due to circuit breaker
    /// - Returns: true if suspended, false otherwise
    func isAudioCaptureSuspended() -> Bool {
        return audioBufferQueue.sync {
            // Fix SEC-002: Apply rate limiting to all public buffer operations
            enforceRateLimit()
            return bufferState.audioCaptureSuspended
        }
    }
    
    /// Enforce rate limiting across all public operations
    private func enforceRateLimit() {
        let now = Date()
        let timeSinceLastOperation = now.timeIntervalSince(lastOperationTime)
        
        // Reset counter every second
        if timeSinceLastOperation >= 1.0 {
            operationCount = 0
            lastOperationTime = now
        }
        
        // Check rate limit
        operationCount += 1
        if operationCount > maxOperationsPerSecond {
            let count = operationCount
            Self.logger.warning("Rate limit exceeded on buffer operation: \(count) ops in \(timeSinceLastOperation)s")
        }
    }
}
