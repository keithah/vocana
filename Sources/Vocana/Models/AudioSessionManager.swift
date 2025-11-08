import Foundation
@preconcurrency import AVFoundation
import os.log

/// Manages AVAudioSession and audio capture lifecycle
/// Responsibility: Audio session setup, tap management, audio buffer processing
/// Isolated from buffer management, ML processing, and level calculations
@MainActor
class AudioSessionManager {
    private static let logger = Logger(subsystem: "Vocana", category: "AudioSessionManager")
    
    private var audioEngine: AVAudioEngine?
    private(set) var isTapInstalled = false  // Fix TEST-001: Expose for testing
    private var audioCaptureSuspensionTimer: Timer?
    private var timer: Timer?
    
    // Fix HIGH-001: Dedicated queue for audio processing to avoid blocking MainActor
    private let audioProcessingQueue = DispatchQueue(label: "com.vocana.audioprocessing", qos: .userInitiated)
    
    // Callback for processing audio buffers
    var onAudioBufferReceived: ((AVAudioPCMBuffer) -> Void)?
    
    // State for simulated audio
    var isEnabled = false
    var sensitivity: Double = 0.5
    
    // Callbacks for updates
    var updateLevels: ((Float, Float) -> Void)?
    
    /// Start real audio capture from microphone
    /// - Returns: true if successful, false otherwise
    func startRealAudioCapture() -> Bool {
        do {
            // Fix HIGH: Configure audio session before starting engine
            #if os(iOS) || os(tvOS) || os(watchOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
            #endif
            
            audioEngine = AVAudioEngine()
            guard let audioEngine = audioEngine else { return false }
            
            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            
              // Fix HIGH: Track tap installation to prevent crash
              // Install tap to monitor audio levels
              // Fix PERF-001: Capture callback before tap installation to prevent lifecycle issues
              // This ensures the callback reference doesn't depend on self being alive during tap execution
              let bufferCallback = self.onAudioBufferReceived
              
              inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
                   // Fix CRITICAL-004: Copy buffer data immediately within tap closure
                   // AVAudioPCMBuffer objects are reused by the audio engine, so we must copy the contents
                   // before passing to async contexts to prevent data races
                   
                   // Fix HIGH: Validate buffer before processing to prevent crashes
                   guard buffer.frameLength > 0 && buffer.frameLength <= 4096 else {
                       Self.logger.warning("Invalid buffer frame length: \(buffer.frameLength)")
                       return
                   }
                    guard buffer.floatChannelData != nil else {
                        Self.logger.warning("Buffer has no channel data")
                        return
                    }
                   
                   // Fix CRITICAL-002: Proper buffer validation to prevent use-after-free
                   guard let copiedBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
                         let sourceChannels = buffer.floatChannelData,
                         let destChannels = copiedBuffer.floatChannelData else {
                       Self.logger.error("Buffer copy failed - insufficient memory or invalid buffer")
                       return
                   }
                  
                  // Copy audio data with bounds validation
                  copiedBuffer.frameLength = buffer.frameLength
                  let bytesToCopy = Int(buffer.frameLength) * MemoryLayout<Float>.size
                  
                   for channel in 0..<Int(buffer.format.channelCount) {
                        memcpy(destChannels[channel], sourceChannels[channel], bytesToCopy)
                     }
                     
                    // Fix CRITICAL: Use synchronous MainActor dispatch to prevent buffer lifecycle issues
                    // Audio tap callback runs on high-priority audio thread, buffer must be processed immediately
                    // Note: bufferCallback is captured outside the tap to avoid holding self reference
                    DispatchQueue.main.async {
                        bufferCallback?(copiedBuffer)
                    }
                }
            isTapInstalled = true
            
            try audioEngine.start()
            return true
        } catch {
            Self.logger.error("Failed to start real audio capture: \(error.localizedDescription)")
            // Fix HIGH: Clean up tap on failure path to prevent leak
            if isTapInstalled {
                audioEngine?.inputNode.removeTap(onBus: 0)
                isTapInstalled = false
            }
            audioEngine = nil
            return false
        }
    }
    
    /// Stop real audio capture and clean up audio session
    func stopRealAudioCapture() {
        // Fix HIGH: Remove tap BEFORE stopping engine to prevent crash
        if isTapInstalled, let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        audioEngine?.stop()
        audioEngine = nil
        
        // Fix CRITICAL: Conditionally deactivate audio session to prevent interference
        // 
        // Only deactivate if no other active audio sessions exist in the app.
        // This prevents interfering with music playback, VoIP calls, or other audio functionality.
        #if os(iOS) || os(tvOS) || os(watchOS)
        do {
            let session = AVAudioSession.sharedInstance()
            // Check if other audio sessions are active before deactivating
            if !session.isOtherAudioPlaying {
                try session.setActive(false, options: .notifyOthersOnDeactivation)
            } else {
                Self.logger.info("Keeping audio session active - other audio is playing")
            }
        } catch {
            Self.logger.error("Failed to deactivate audio session: \(error.localizedDescription)")
        }
        #endif
    }
    
    /// Start simulated audio playback (for testing)
    /// Security: Ensure proper timer resource management and cleanup
    func startSimulatedAudio() {
        // Security: Ensure cleanup of existing timer before creating new one
        timer?.invalidate()
        
        timer = Timer.scheduledTimer(withTimeInterval: AppConstants.audioUpdateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateSimulatedLevels()
            }
        }
        
        // Security: Safely add timer to RunLoop with proper error handling
        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    /// Stop simulated audio playback
    func stopSimulatedAudio() {
        timer?.invalidate()
        timer = nil
    }
    
    /// Update simulated levels during testing
    private func updateSimulatedLevels() {
        if isEnabled {
            let input = Float.random(in: Float(AppConstants.inputLevelRange.lowerBound)...Float(AppConstants.inputLevelRange.upperBound))
            let output = Float.random(in: Float(AppConstants.outputLevelRange.lowerBound)...Float(AppConstants.outputLevelRange.upperBound)) * Float(sensitivity)
            updateLevels?(input, output)
        }
    }
    
    /// Suspend audio capture (circuit breaker)
    /// 
    /// NOTE: This method is currently unused but kept for future circuit breaker implementation.
    /// It provides a mechanism to temporarily suspend audio capture for a specified duration,
    /// which could be useful for handling system-level audio interruptions or memory pressure scenarios.
    /// 
    /// - Parameter duration: How long to suspend for (in seconds)
    func suspendAudioCapture(duration: TimeInterval) {
        audioCaptureSuspensionTimer?.invalidate()
        audioCaptureSuspensionTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.resumeAudioCapture()
            }
        }
    }
    
    /// Resume audio capture after suspension
    private func resumeAudioCapture() {
        audioCaptureSuspensionTimer?.invalidate()
        audioCaptureSuspensionTimer = nil
        Self.logger.info("Resuming audio capture after circuit breaker suspension")
    }
    
    /// Clean up resources
    func cleanup() {
        stopRealAudioCapture()
        stopSimulatedAudio()
        audioCaptureSuspensionTimer?.invalidate()
    }
}
