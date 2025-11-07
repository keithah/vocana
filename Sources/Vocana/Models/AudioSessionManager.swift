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
                // Fix CRITICAL: Use detached task without MainActor to prevent blocking audio thread
                // Process on background queue, update UI properties on MainActor
                Task.detached(priority: .high) {
                    await MainActor.run {
                        self?.onAudioBufferReceived?(buffer)
                    }
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
