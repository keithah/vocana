import Foundation
import os.log

/// Manages audio buffer lifecycle and chunk extraction
/// Responsibility: Buffer management, thread-safe append/extract operations, overflow handling
/// Isolated from level calculation, audio capture, and ML processing
class AudioBufferManager {
    private static let logger = Logger(subsystem: "Vocana", category: "AudioBufferManager")
    
    private let minimumBufferSize = 960  // FFT size for DeepFilterNet
    private let audioBufferQueue = DispatchQueue(label: "com.vocana.audiobuffer", qos: .userInteractive)
    private nonisolated(unsafe) var _audioBuffer: [Float] = []
    
    // Telemetry tracking (passed in from AudioEngine)
    var recordBufferOverflow: () -> Void = {}
    var recordCircuitBreakerTrigger: () -> Void = {}
    var recordCircuitBreakerSuspension: (TimeInterval) -> Void = { _ in }
    
    // Overflow tracking
    private var consecutiveOverflows = 0
    private var audioCaptureSuspended = false
    
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
            let (projectedSize, overflowed) = _audioBuffer.count.addingReportingOverflow(samples.count)
            
            // Handle overflow by treating as buffer overflow
            if overflowed || projectedSize > maxBufferSize {
                // Fix HIGH: Circuit breaker for sustained buffer overflows
                consecutiveOverflows += 1
                recordBufferOverflow()
                
                if consecutiveOverflows > AppConstants.maxConsecutiveOverflows && !audioCaptureSuspended {
                    recordCircuitBreakerTrigger()
                    audioCaptureSuspended = true
                    Self.logger.warning("Circuit breaker triggered: \(self.consecutiveOverflows) consecutive overflows")
                    Self.logger.info("Suspending audio capture for \(AppConstants.circuitBreakerSuspensionSeconds)s to allow ML to catch up")
                    
                    // Schedule resumption
                    let suspensionDuration = AppConstants.circuitBreakerSuspensionSeconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + suspensionDuration) {
                        self.audioCaptureSuspended = false
                        Self.logger.info("Resuming audio capture after circuit breaker suspension")
                    }
                    
                    onCircuitBreakerTriggered(suspensionDuration)
                    return nil // Skip this buffer append to help recovery
                }
                
                // Fix CRITICAL: Implement smoothing to prevent audio discontinuities
                Self.logger.warning("Audio buffer overflow \(self.consecutiveOverflows): \(self._audioBuffer.count) + \(samples.count) > \(maxBufferSize)")
                Self.logger.info("Applying crossfade to maintain audio continuity")
                
                // Fix CRITICAL: Calculate overflow and prevent crash when exceeding buffer size
                let overflow = projectedSize - maxBufferSize
                let samplesToRemove = min(overflow, _audioBuffer.count)
                
                // Apply crossfade to prevent clicks/pops when dropping audio
                let fadeLength = min(AppConstants.crossfadeLengthSamples, samplesToRemove)
                
                // Remove old samples first
                if samplesToRemove > 0 {
                    _audioBuffer.removeFirst(samplesToRemove)
                }
                
                // Apply fade-in to new samples if needed
                if fadeLength > 0 && samples.count >= fadeLength {
                    var fadedSamples = samples
                    for i in 0..<fadeLength {
                        let fade = Float(i + 1) / Float(fadeLength)
                        fadedSamples[i] *= fade
                    }
                    _audioBuffer.append(contentsOf: fadedSamples)
                } else {
                    _audioBuffer.append(contentsOf: samples)
                }
            } else {
                // Reset overflow counter on successful append
                consecutiveOverflows = 0
                _audioBuffer.append(contentsOf: samples)
            }
            
            // Check if we have enough samples for a chunk
            guard _audioBuffer.count >= minimumBufferSize else {
                return nil
            }
            
            // Extract chunk and remove from buffer
            let chunk = Array(_audioBuffer.prefix(minimumBufferSize))
            _audioBuffer.removeFirst(minimumBufferSize)
            return chunk
        }
    }
    
    /// Clear audio buffers (for cleanup/reset)
    func clearAudioBuffers() {
        audioBufferQueue.sync {
            _audioBuffer.removeAll()
            consecutiveOverflows = 0
        }
    }
    
    /// Get current buffer size (for debugging/monitoring)
    /// - Returns: Number of samples currently in buffer
    func getCurrentBufferSize() -> Int {
        return audioBufferQueue.sync { _audioBuffer.count }
    }
    
    /// Check if buffer is ready for extraction
    /// - Returns: true if buffer has minimum samples
    func hasEnoughSamples() -> Bool {
        return audioBufferQueue.sync { _audioBuffer.count >= minimumBufferSize }
    }
}
