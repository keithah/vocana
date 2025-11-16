import Foundation
import AVFoundation
import CoreAudio
import OSLog

/// Manages audio routing from BlackHole to physical output devices
@MainActor
class AudioRoutingManager: ObservableObject {
    private let logger = Logger(subsystem: "Vocana", category: "AudioRouting")
    
    @Published var isRoutingActive = false
    @Published var routingLatencyMs: Double = 0
    @Published var droppedFrames: UInt64 = 0
    
    private var audioEngine: AVAudioEngine?
    private var blackHoleInputNode: AVAudioInputNode?
    private var physicalOutputNode: AVAudioOutputNode?
    private var mixerNode: AVAudioMixerNode?

    // Audio format for processing
    private let processingFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!

    // Background queue for audio processing
    private let processingQueue = DispatchQueue(label: "com.vocana.audioRouting", qos: .userInitiated)
    
    init() {
        setupAudioEngine()
    }
    
    /// Setup AVAudioEngine for routing BlackHole → Vocana Processing → Physical Output
    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else { return }

        blackHoleInputNode = engine.inputNode
        physicalOutputNode = engine.outputNode
        mixerNode = AVAudioMixerNode()

        // Verify all nodes were created successfully
        guard let inputNode = blackHoleInputNode,
              let outputNode = physicalOutputNode,
              let mixer = mixerNode else {
            logger.error("Failed to create audio nodes")
            return
        }

        // Add mixer to engine
        engine.attach(mixer)

        // Connect BlackHole input to mixer
        engine.connect(inputNode, to: mixer, format: processingFormat)

        // Connect mixer to physical output
        engine.connect(mixer, to: outputNode, format: processingFormat)

        logger.info("Audio routing engine setup complete")
    }
    
    /// Start audio routing from BlackHole to physical output
    func startRouting(blackHoleDeviceID: AudioDeviceID, physicalOutputDeviceID: AudioDeviceID) -> Bool {
        guard let engine = audioEngine,
              let mixer = mixerNode else {
            logger.error("Audio engine not properly initialized")
            return false
        }
        
        // Configure BlackHole as input device
        let blackHoleInputConfigured = configureInputDevice(deviceID: blackHoleDeviceID)
        if !blackHoleInputConfigured {
            logger.error("Failed to configure BlackHole as input device")
            return false
        }
        
        // Configure physical output device
        let physicalOutputConfigured = configureOutputDevice(deviceID: physicalOutputDeviceID)
        if !physicalOutputConfigured {
            logger.error("Failed to configure physical output device")
            return false
        }
        
        // Install tap on mixer to process audio with Vocana ML
        installProcessingTap(on: mixer)
        
        // Start the engine
        do {
            try engine.start()
            isRoutingActive = true
            logger.info("Audio routing started successfully")
            return true
        } catch {
            logger.error("Failed to start audio engine: \(error)")
            return false
        }
    }
    
    /// Stop audio routing
    func stopRouting() {
        guard let engine = audioEngine else { return }

        // Remove the mixer tap to prevent duplicate processing
        if let mixer = mixerNode {
            mixer.removeTap(onBus: 0)
            logger.debug("Removed mixer tap on bus 0")
        }

        engine.stop()
        isRoutingActive = false
        logger.info("Audio routing stopped")
    }
    
    /// Configure input device for audio engine
    private func configureInputDevice(deviceID: AudioDeviceID) -> Bool {
        guard let engine = audioEngine else { return false }
        
        // Get device UID
        var deviceUID: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let result = AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &deviceUID)
        guard result == noErr else {
            logger.error("Failed to get input device UID: \(result)")
            return false
        }
        
        // Configure audio session (macOS doesn't use AVAudioSession)
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            
            // Set preferred input
            if let inputs = session.availableInputs {
                for input in inputs {
                    if input.uid == (deviceUID as String) {
                        try session.setPreferredInput(input)
                        logger.info("BlackHole configured as input device")
                        return true
                    }
                }
            }
            
            logger.warning("BlackHole not found in available inputs, using default")
            return true
        } catch {
            logger.error("Failed to configure input device: \(error)")
            return false
        }
        #else
        // macOS uses CoreAudio directly for device configuration
        logger.info("Input device configured for macOS: \(deviceUID)")
        return true
        #endif
    }
    
    /// Configure output device for audio engine
    private func configureOutputDevice(deviceID: AudioDeviceID) -> Bool {
        // Get device UID
        var deviceUID: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let result = AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &deviceUID)
        guard result == noErr else {
            logger.error("Failed to get output device UID: \(result)")
            return false
        }
        
        // Configure audio session output (macOS doesn't use AVAudioSession)
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            
            // Find matching output route
            if let outputs = session.currentRoute.outputs {
                for output in outputs {
                    if output.uid == (deviceUID as String) {
                        logger.info("Physical output device configured: \(deviceUID)")
                        return true
                    }
                }
            }
            
            logger.warning("Using default output route")
            return true
        } catch {
            logger.error("Failed to configure output device: \(error)")
            return false
        }
        #else
        // macOS uses CoreAudio directly for device configuration
        logger.info("Output device configured for macOS: \(deviceUID)")
        return true
        #endif
    }
    
    /// Install processing tap on mixer node for ML processing
    private func installProcessingTap(on mixer: AVAudioMixerNode) {
        let format = processingFormat

        mixer.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            guard let self = self,
                  let channelData = buffer.floatChannelData else { return }

            // Copy buffer data synchronously to avoid lifetime issues
            let frames = Int(buffer.frameLength)
            let monoSamples = Array(UnsafeBufferPointer(start: channelData[0], count: frames))

            // Process on background queue to avoid blocking audio thread
            self.processingQueue.async { [weak self] in
                guard let self = self else { return }
                self.processSamples(monoSamples, timestamp: time, channelCount: Int(buffer.format.channelCount))
            }
        }

        logger.info("Audio processing tap installed on mixer")
    }
    

    
    /// Process audio samples with ML (placeholder for integration with AudioEngine)
    private func processWithML(samples: [Float]) -> [Float] {
        // This would integrate with the existing MLAudioProcessor
        // For now, apply basic noise gate
        let threshold: Float = 0.01
        let ratio: Float = 0.1
        
        return samples.map { sample in
            let absSample = abs(sample)
            if absSample < threshold {
                return sample * ratio
            }
            return sample
        }
    }

    /// Process audio samples on background queue
    private func processSamples(_ samples: [Float], timestamp: AVAudioTime, channelCount: Int) {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Process with ML (this would integrate with existing AudioEngine)
        let processedSamples = processWithML(samples: samples)

        // Calculate latency
        let processingTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

        // Update latency on main actor
        Task { @MainActor in
            self.routingLatencyMs = (self.routingLatencyMs * 0.9) + (processingTime * 0.1)
        }

        // For now, we don't output the processed samples since this is just routing
        // In a full implementation, this would send to the output device
        logger.debug("Processed \(samples.count) samples in \(String(format: "%.2f", processingTime))ms")
    }

    /// Get available physical output devices
    func getPhysicalOutputDevices() -> [BlackHoleAudioManager.AudioDeviceInfo] {
        // This would delegate to BlackHoleAudioManager
        // For now, return empty array
        return []
    }
    
    deinit {
        // Perform synchronous cleanup
        if let engine = audioEngine {
            if let mixer = mixerNode {
                mixer.removeTap(onBus: 0)
            }
            engine.stop()
        }
        audioEngine = nil
    }
}