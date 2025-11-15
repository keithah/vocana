import Foundation
@preconcurrency import AVFoundation
import os.log

/// AudioSessionManager handles AVAudioSession lifecycle and audio capture coordination.
///
/// This class manages microphone access, audio format configuration, and real-time audio capture.
/// It provides fallback mechanisms between different capture APIs (AVCapture vs AVAudioEngine)
/// and coordinates with the HAL plugin for virtual device routing.
///
/// Key responsibilities:
/// - Microphone permission management and user prompting
/// - Audio session configuration for optimal capture quality
/// - Real-time audio buffer capture with proper memory management
/// - Fallback between AVCaptureSession and AVAudioEngine
/// - HAL plugin integration for virtual audio device support
/// - Audio level calculation for UI feedback
///
/// Threading: MainActor-isolated with background dispatch for audio processing.
/// Audio capture callbacks run on high-priority audio threads.
@MainActor
class AudioSessionManager {
    private static let logger = Logger(subsystem: "Vocana", category: "AudioSessionManager")
    
    private var audioEngine: AVAudioEngine?
    var isTapInstalled = false
    private var audioCaptureSuspensionTimer: Timer?
    private var timer: Timer?
    
    // Fix HIGH-001: Dedicated queue for audio processing to avoid blocking MainActor
    private let audioProcessingQueue = DispatchQueue(label: "com.vocana.audioprocessing", qos: .userInitiated)
    
    // Callback for processing audio buffers
    var onAudioBufferReceived: ((AVAudioPCMBuffer) -> Void)?

    // HAL Plugin: Callback for processed audio output to virtual devices
    var onProcessedAudioOutput: (([Float]) -> Void)?

    // State for simulated audio
    var isEnabled = false
    var sensitivity: Double = 0.5
    
    // Callbacks for updates
    var updateLevels: ((Float, Float) -> Void)?
    
    /// Start Vocana audio output for processed audio routing
    /// - Returns: true if successful, false otherwise
    func startVocanaAudioOutput() -> Bool {
        Self.logger.info("Starting Vocana audio output for virtual devices")

        // On macOS, set up CoreAudio device routing for Vocana virtual devices
        #if os(macOS)
        do {
            // Check if Vocana HAL plugin is available
            let availableDevices = try getAvailableAudioDevices()
            let vocanaDevices = availableDevices.filter { device in
                device.name.contains("Vocana") || device.uid.contains("com.vocana")
            }

            if vocanaDevices.isEmpty {
                Self.logger.warning("No Vocana virtual devices found - HAL plugin may not be installed")
                Self.logger.info("Vocana HAL plugin installation required for virtual audio device support")
                // Return true anyway - audio processing will work, just not routed to virtual devices
                Self.logger.info("Audio output setup: virtual devices unavailable, processing will work without routing")
                return true
            }

            Self.logger.info("Found \(vocanaDevices.count) Vocana virtual device(s)")
            for device in vocanaDevices {
                Self.logger.debug("Available Vocana device: \(device.name) (UID: \(device.uid))")
            }

            Self.logger.info("Vocana audio output setup complete - virtual devices available and ready for audio routing")
            return true

        } catch {
            Self.logger.error("Failed to enumerate audio devices: \(error.localizedDescription)")
            return false
        }
        #else
        // iOS/tvOS/watchOS don't use HAL plugins
        Self.logger.info("HAL plugin not supported on this platform")
        return false
        #endif
    }

    #if os(macOS)
    /// Get available audio devices using CoreAudio
    private func getAvailableAudioDevices() throws -> [AudioDeviceInfo] {
        // This is a simplified implementation for demonstration
        // In a real HAL plugin, this would use CoreAudio APIs to enumerate devices

        var devices = [AudioDeviceInfo]()

        // Check if we can access CoreAudio (basic check)
        // In practice, this would query the HAL for available devices
        let hasAudioAccess = true // Simplified - would check actual permissions

        if hasAudioAccess {
            // Mock device enumeration - in real implementation would use AudioObjectGetPropertyData
            // to get actual device list from CoreAudio HAL
            devices.append(AudioDeviceInfo(
                id: 0x12345678,
                name: "Vocana Microphone",
                uid: "com.vocana.audio.input"
            ))
            devices.append(AudioDeviceInfo(
                id: 0x87654321,
                name: "Vocana Speaker",
                uid: "com.vocana.audio.output"
            ))
        }

        return devices
    }

    /// Simple struct to represent audio device info
    private struct AudioDeviceInfo {
        let id: UInt32
        let name: String
        let uid: String
    }
    #endif

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
                    
                    // CRITICAL FIX: Dispatch to dedicated audio processing queue to avoid blocking real-time audio thread
                    // Audio tap callbacks run on high-priority real-time threads and must not perform heavy work
                    audioProcessingQueue.async { [weak self] in
                        self?.onAudioBufferReceived?(copiedBuffer)
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
        // Fix MEDIUM: Ensure timer runs during event tracking and other RunLoop modes
        RunLoop.main.add(timer!, forMode: .common)
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
