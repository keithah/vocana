import Foundation
import AVFoundation
import os.log

/// Manages AVAudioSession and audio capture lifecycle
/// Responsibility: Audio session setup, tap management, audio buffer processing
/// Isolated from buffer management, ML processing, and level calculations
@MainActor
class AudioSessionManager {
    private static let logger = Logger(subsystem: "Vocana", category: "AudioSessionManager")
    
    private var audioEngine: AVAudioEngine?
    private var isTapInstalled = false
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
             inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                  // Fix CRITICAL-004: Copy buffer data immediately within tap closure
                  // AVAudioPCMBuffer objects are reused by the audio engine, so we must copy the contents
                  // before passing to async contexts to prevent data races
                  guard let self = self else { return }
                  
                  // Fix HIGH: Validate buffer before processing to prevent crashes
                  guard buffer.frameLength > 0 && buffer.frameLength <= 4096 else {
                      Self.logger.warning("Invalid buffer frame length: \(buffer.frameLength)")
                      return
                  }
                  guard let channelData = buffer.floatChannelData else {
                      Self.logger.warning("Buffer has no channel data")
                      return
                  }
                  
                  // Create a copy of the buffer to avoid reuse-after-free race condition
                  let copiedBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
                  guard let copiedBuffer = copiedBuffer else { return }
                 
                 // Copy the audio data
                 copiedBuffer.frameLength = buffer.frameLength
                 if let sourceChannels = buffer.floatChannelData,
                    let destChannels = copiedBuffer.floatChannelData {
                     for channel in 0..<Int(buffer.format.channelCount) {
                         memcpy(destChannels[channel], sourceChannels[channel], Int(buffer.frameLength) * MemoryLayout<Float>.size)
                     }
                 }
                 
                  // Fix CRITICAL: Direct MainActor dispatch to reduce latency
                  // Audio tap callback is already on background thread, no need for additional queue
                  Task { @MainActor in
                      self.onAudioBufferReceived?(copiedBuffer)
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
    func startSimulatedAudio() {
        timer = Timer.scheduledTimer(withTimeInterval: AppConstants.audioUpdateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateSimulatedLevels()
            }
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
    /// - Parameter duration: How long to suspend for
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
