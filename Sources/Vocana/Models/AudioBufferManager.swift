import Foundation
import os.log

/// Manages audio buffer lifecycle and chunk extraction
/// Responsibility: Buffer management, thread-safe append/extract operations, overflow handling
/// Isolated from level calculation, audio capture, and ML processing
class AudioBufferManager {
    private static let logger = Logger(subsystem: "Vocana", category: "AudioBufferManager")
    
    private let minimumBufferSize = 960  // FFT size for DeepFilterNet
    private let audioBufferQueue = DispatchQueue(label: "com.vocana.audiobuffer", qos: .userInteractive)
    
    // Fix CRITICAL-003: Use struct wrapper for proper encapsulation instead of nonisolated(unsafe)
    // All access to this structure must go through audioBufferQueue
    private struct BufferState {
        var audioBuffer: [Float] = []
        var consecutiveOverflows: Int = 0
        var audioCaptureSuspended: Bool = false
    }
    
    private var bufferState = BufferState()
    
    // Telemetry tracking (passed in from AudioEngine)
    var recordBufferOverflow: () -> Void = {}
    var recordCircuitBreakerTrigger: () -> Void = {}
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
            let maxBufferSize = AppConstants.maxAudioBufferSize
            
            // Fix CRITICAL: Safe integer overflow checking for buffer size calculation
            let (projectedSize, overflowed) = bufferState.audioBuffer.count.addingReportingOverflow(samples.count)
            
            // Handle overflow by treating as buffer overflow
            if overflowed || projectedSize > maxBufferSize {
                // Fix HIGH: Circuit breaker for sustained buffer overflows
                bufferState.consecutiveOverflows += 1
                recordBufferOverflow()
                
                if bufferState.consecutiveOverflows > AppConstants.maxConsecutiveOverflows && !bufferState.audioCaptureSuspended {
                    recordCircuitBreakerTrigger()
                    bufferState.audioCaptureSuspended = true
                    Self.logger.warning("Circuit breaker triggered: \(self.bufferState.consecutiveOverflows) consecutive overflows")
                    Self.logger.info("Suspending audio capture for \(AppConstants.circuitBreakerSuspensionSeconds)s to allow ML to catch up")
                    
                    // Schedule resumption
                    let suspensionDuration = AppConstants.circuitBreakerSuspensionSeconds
                    onCircuitBreakerTriggered(suspensionDuration)
                    return nil // Skip this buffer append to help recovery
                }
                
                // Fix CRITICAL: Implement smoothing to prevent audio discontinuities
                Self.logger.warning("Audio buffer overflow \(self.bufferState.consecutiveOverflows): \(self.bufferState.audioBuffer.count) + \(samples.count) > \(maxBufferSize)")
                Self.logger.info("Applying crossfade to maintain audio continuity")
                
                // Fix CRITICAL: Calculate overflow and prevent crash when exceeding buffer size
                let overflow = projectedSize - maxBufferSize
                let samplesToRemove = min(overflow, bufferState.audioBuffer.count)
                
                // Apply crossfade to prevent clicks/pops when dropping audio
                let fadeLength = min(AppConstants.crossfadeLengthSamples, samplesToRemove)
                
                // Remove old samples first
                if samplesToRemove > 0 {
                    bufferState.audioBuffer.removeFirst(samplesToRemove)
                }
                
                // Apply fade-in to new samples if needed
                if fadeLength > 0 && samples.count >= fadeLength {
                    var fadedSamples = samples
                    for i in 0..<fadeLength {
                        let fade = Float(i + 1) / Float(fadeLength)
                        fadedSamples[i] *= fade
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
        return audioBufferQueue.sync { bufferState.audioBuffer.count }
    }
    
    /// Check if buffer is ready for extraction
    /// - Returns: true if buffer has minimum samples
    func hasEnoughSamples() -> Bool {
        return audioBufferQueue.sync { bufferState.audioBuffer.count >= minimumBufferSize }
    }
}
