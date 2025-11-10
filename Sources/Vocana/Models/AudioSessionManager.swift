import Foundation
@preconcurrency import AVFoundation
import os.log
import AppKit
import CoreMedia

/// Manages AVAudioSession and audio capture lifecycle
/// Responsibility: Audio session setup, tap management, audio buffer processing
/// Isolated from buffer management, ML processing, and level calculations
@MainActor
class AudioSessionManager: NSObject {
    private static let logger = Logger(subsystem: "Vocana", category: "AudioSessionManager")
    
    private var audioEngine: AVAudioEngine?
    private(set) var isTapInstalled = false  // Fix TEST-001: Expose for testing
    private var audioCaptureSuspensionTimer: Timer?
    private var timer: Timer?
    
    // AVCapture-based audio input (more reliable on macOS)
    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var audioInput: AVCaptureDeviceInput?
    private var captureQueue = DispatchQueue(label: "com.vocana.audio.capture", qos: .userInitiated)
    
    // Fix HIGH-001: Dedicated queue for audio processing to avoid blocking MainActor
    private let audioProcessingQueue = DispatchQueue(label: "com.vocana.audioprocessing", qos: .userInitiated)
    
    // Callback for processing audio buffers
    var onAudioBufferReceived: ((AVAudioPCMBuffer) -> Void)?
    
    // State for audio processing
    var isEnabled = false
    var sensitivity: Double = 0.5
    
    // Callbacks for updates
    var updateLevels: ((Float, Float) -> Void)?
    
    /// Start real audio capture from microphone
    /// - Returns: true if successful, false otherwise
    func startRealAudioCapture() -> Bool {
        print("🎤 AudioSessionManager.startRealAudioCapture - Starting...")
        
        // Check permissions first
        #if os(macOS)
        print("🎤 macOS detected - checking microphone permissions...")
        let permissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        print("🎤 Microphone permission status: \(permissionStatus.rawValue)")
        
        if permissionStatus == .denied {
            print("🎤 ❌ Microphone access denied - requesting permission...")
            requestMicrophonePermission()
            return false
        } else if permissionStatus == .restricted {
            print("🎤 ❌ Microphone access restricted")
            return false
        } else if permissionStatus == .notDetermined {
            print("🎤 ❓ Permission not determined - requesting permission...")
            requestMicrophonePermission()
            return false
        }
        
        // Check available input devices
        let inputDevices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone, .externalUnknown], mediaType: .audio, position: .unspecified).devices
        print("🎤 Available input devices: \(inputDevices.count)")
        for device in inputDevices {
            print("🎤   - \(device.localizedName)")
        }
        
        if inputDevices.isEmpty {
            print("🎤 ❌ No input devices found!")
            return false
        }
        #else
        // iOS/tvOS/watchOS - configure audio session
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
            print("🎤 Audio session configured successfully")
        } catch {
            print("🎤 ❌ Failed to configure audio session: \(error.localizedDescription)")
            return false
        }
        #endif
        
        // Try AVCapture approach first (more reliable on macOS)
        if startAVCaptureAudioInput() {
            return true
        }
        
        // Fallback to AVAudioEngine if AVCapture fails
        print("🎤 AVCapture failed, trying AVAudioEngine fallback...")
        return startAVAudioEngineInput()
    }
    
    /// Start audio input using AVCapture (more reliable on macOS)
    private func startAVCaptureAudioInput() -> Bool {
        print("🎤 Starting AVCapture audio input...")
        
        do {
            // Create capture session
            captureSession = AVCaptureSession()
            guard let captureSession = captureSession else {
                print("🎤 Failed to create capture session")
                return false
            }
            
            // Configure session
            captureSession.beginConfiguration()
            // No specific preset needed for audio-only capture
            
            // Find default audio device
            guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
                print("🎤 No default audio device found")
                captureSession.commitConfiguration()
                return false
            }
            
            print("🎤 Using audio device: \(audioDevice.localizedName)")
            
            // Create audio input
            audioInput = try AVCaptureDeviceInput(device: audioDevice)
            guard let audioInput = audioInput else {
                print("🎤 Failed to create audio input")
                captureSession.commitConfiguration()
                return false
            }
            
            // Add input to session
            if captureSession.canAddInput(audioInput) {
                captureSession.addInput(audioInput)
            } else {
                print("🎤 Cannot add audio input to session")
                captureSession.commitConfiguration()
                return false
            }
            
            // Create audio output
            audioOutput = AVCaptureAudioDataOutput()
            guard let audioOutput = audioOutput else {
                print("🎤 Failed to create audio output")
                captureSession.commitConfiguration()
                return false
            }
            
            // Set up sample buffer callback
            audioOutput.setSampleBufferDelegate(self, queue: captureQueue)
            
            // Add output to session
            if captureSession.canAddOutput(audioOutput) {
                captureSession.addOutput(audioOutput)
            } else {
                print("🎤 Cannot add audio output to session")
                captureSession.commitConfiguration()
                return false
            }
            
            captureSession.commitConfiguration()
            
            // Start session
            captureSession.startRunning()
            print("🎤 ✅ AVCapture session started successfully")
            
            // Verify session is running
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                print("🎤 Capture session running: \(captureSession.isRunning)")
            }
            
            return true
            
        } catch {
            print("🎤 ❌ Failed to start AVCapture audio input: \(error.localizedDescription)")
            cleanupAVCapture()
            return false
        }
    }
    
    /// Start audio input using AVAudioEngine (fallback)
    private func startAVAudioEngineInput() -> Bool {
        print("🎤 Starting AVAudioEngine fallback...")
        
        do {
            print("🎤 Creating AVAudioEngine...")
            audioEngine = AVAudioEngine()
            guard let audioEngine = audioEngine else { 
                print("🎤 Failed to create AVAudioEngine")
                return false 
            }
            
            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            print("🎤 Input format: \(inputFormat)")
            print("🎤 Sample rate: \(inputFormat.sampleRate)")
            print("🎤 Channels: \(inputFormat.channelCount)")
            
            // Create a standard format for audio input
            let standardFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)
            print("🎤 Using standard format: \(String(describing: standardFormat))")
            
            // Install tap
            let bufferCallback = self.onAudioBufferReceived
            
            inputNode.installTap(onBus: 0, bufferSize: 512, format: standardFormat) { buffer, _ in
                print("🎤 🎉 AVAudioEngine tap working! Buffer length: \(buffer.frameLength)")
                
                // Validate buffer
                guard buffer.frameLength > 0 && buffer.frameLength <= 8192 else {
                    Self.logger.warning("Invalid buffer frame length: \(buffer.frameLength)")
                    return
                }
                guard buffer.floatChannelData != nil else {
                    Self.logger.warning("Buffer has no channel data")
                    return
                }
                
                // Copy buffer
                guard let copiedBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
                      let sourceChannels = buffer.floatChannelData,
                      let destChannels = copiedBuffer.floatChannelData else {
                    Self.logger.error("Buffer copy failed")
                    return
                }
                
                copiedBuffer.frameLength = buffer.frameLength
                let bytesToCopy = Int(buffer.frameLength) * MemoryLayout<Float>.size
                
                for channel in 0..<Int(buffer.format.channelCount) {
                    memcpy(destChannels[channel], sourceChannels[channel], bytesToCopy)
                }
                
                // Call callback
                DispatchQueue.main.async {
                    bufferCallback?(copiedBuffer)
                }
            }
            
            isTapInstalled = true
            
            print("🎤 Starting audio engine...")
            try audioEngine.start()
            print("🎤 ✅ AVAudioEngine started successfully")
            print("🎤 Engine running: \(audioEngine.isRunning)")
            
            return true
            
        } catch {
            print("🎤 ❌ Failed to start AVAudioEngine: \(error.localizedDescription)")
            Self.logger.error("Failed to start AVAudioEngine: \(error.localizedDescription)")
            cleanupAVAudioEngine()
            return false
        }
    }
    
    /// Stop real audio capture and clean up audio session
    func stopRealAudioCapture() {
        print("🎤 Stopping real audio capture...")
        
        // Stop AVCapture first
        cleanupAVCapture()
        
        // Stop AVAudioEngine
        cleanupAVAudioEngine()
        
        // Deactivate audio session on iOS/tvOS/watchOS
        #if os(iOS) || os(tvOS) || os(watchOS)
        do {
            let session = AVAudioSession.sharedInstance()
            if !session.isOtherAudioPlaying {
                try session.setActive(false, options: .notifyOthersOnDeactivation)
            } else {
                Self.logger.info("Keeping audio session active - other audio is playing")
            }
        } catch {
            Self.logger.error("Failed to deactivate audio session: \(error.localizedDescription)")
        }
        #endif
        
        print("🎤 Real audio capture stopped")
    }
    
    /// Clean up AVCapture resources
    private func cleanupAVCapture() {
        if let session = captureSession {
            if session.isRunning {
                session.stopRunning()
            }
            captureSession = nil
        }
        audioOutput = nil
        audioInput = nil
    }
    
    /// Clean up AVAudioEngine resources
    private func cleanupAVAudioEngine() {
        if isTapInstalled, let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        audioEngine?.stop()
        audioEngine = nil
    }
    
    /// Update audio levels during processing
    private func updateAudioLevels() {
        if isEnabled {
            // Real audio levels are updated via the audio tap callback
            // This method is kept for potential future use
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
    
    /// Request microphone permission on macOS
    private func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                if granted {
                    print("🎤 ✅ Microphone permission granted")
                    // Try starting audio capture again
                    _ = self.startRealAudioCapture()
                } else {
                    print("🎤 ❌ Microphone permission denied")
                    self.showPermissionAlert()
                }
            }
        }
    }
    
    /// Show alert for microphone permission
    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Access Required"
        alert.informativeText = "Vocana needs access to your microphone to function. Please enable it in System Settings > Privacy & Security > Microphone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Open System Settings to microphone permissions
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }
    
    /// Try alternative audio input approach
    private func tryAlternativeAudioInput() {
        print("🎤 Trying alternative audio input...")
        
        // Try using a different buffer size and format
        guard audioEngine != nil else {
            print("🎤 No audio engine available")
            return
        }
        
        let inputNode = audioEngine!.inputNode
        
        // Remove existing tap if any
        if isTapInstalled {
            inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        
        // Try with a very simple format
        let simpleFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)
        
        inputNode.installTap(onBus: 0, bufferSize: 256, format: simpleFormat) { buffer, _ in
            print("🎤 🎉 ALTERNATIVE AUDIO TAP WORKING! Buffer length: \(buffer.frameLength)")
            
            // Call the original callback
            DispatchQueue.main.async {
                self.onAudioBufferReceived?(buffer)
            }
        }
        
        isTapInstalled = true
        print("🎤 Alternative tap installed")
    }
    
    /// Clean up resources
    func cleanup() {
        stopRealAudioCapture()
        audioCaptureSuspensionTimer?.invalidate()
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension AudioSessionManager: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        print("🎤 🎉 AVCapture audio data received! Sample buffer size: \(sampleBuffer.numSamples)")
        
        // Get number of samples
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else {
            print("🎤 No samples in buffer")
            return
        }
        
        // Get format description
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            print("🎤 Failed to get format description")
            return
        }
        
        // Get audio stream basic description
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            print("🎤 Failed to get audio stream basic description")
            return
        }
        
        let sampleRate = asbd.pointee.mSampleRate
        let channels = asbd.pointee.mChannelsPerFrame
        
        // Create AVAudioFormat
        guard let audioFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels) else {
            print("🎤 Failed to create audio format")
            return
        }
        
        // Create AVAudioPCMBuffer
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(numSamples)) else {
            print("🎤 Failed to create PCM buffer")
            return
        }
        
        // Copy sample data into AVAudioPCMBuffer
        pcmBuffer.frameLength = AVAudioFrameCount(numSamples)
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(numSamples),
            into: pcmBuffer.mutableAudioBufferList
        )
        
        guard copyStatus == noErr else {
            print("🎤 Failed to copy audio data: \(copyStatus)")
            return
        }
        
         // Calculate audio levels for UI updates
        guard let channelData = pcmBuffer.floatChannelData else { return }
        let samplesPtr = UnsafeBufferPointer(start: channelData.pointee, count: Int(pcmBuffer.frameLength))
        
        // Calculate RMS level
        var sum: Float = 0
        for sample in samplesPtr {
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(samplesPtr.count))
        
        // Call the callback with the converted buffer
        Task { @MainActor [weak self] in
            self?.onAudioBufferReceived?(pcmBuffer)
            // Update UI levels through callback
            self?.updateLevels?(rms, rms)  // Use same level for input/output for now
        }
    }
}
