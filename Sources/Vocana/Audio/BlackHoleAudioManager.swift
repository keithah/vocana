import Foundation
import AVFoundation
import CoreAudio

/// Manages BlackHole virtual audio device detection and routing
@MainActor
class BlackHoleAudioManager: ObservableObject {
    private let logger = Logger(subsystem: "Vocana", category: "BlackHoleAudio")
    
    @Published var isBlackHoleAvailable = false
    @Published var blackHoleDeviceID: AudioDeviceID?
    @Published var availableInputDevices: [AudioDeviceInfo] = []
    @Published var availableOutputDevices: [AudioDeviceInfo] = []
    
    struct AudioDeviceInfo: Identifiable {
        let id: AudioDeviceID
        let name: String
        let uid: String
        let isInput: Bool
        let isOutput: Bool
    }
    
    init() {
        refreshAudioDevices()
    }
    
    /// Refresh the list of available audio devices
    func refreshAudioDevices() {
        var devices = [AudioDeviceInfo]()
        var blackHoleFound = false
        
        // Get all audio devices
        var deviceList: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var result = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            0,
            nil,
            &size
        )
        
        guard result == noErr else {
            logger.error("Failed to get device list size: \(result)")
            return
        }
        
        let deviceCount = Int(size) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: deviceCount)
        
        result = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            0,
            nil,
            &size,
            &deviceIDs
        )
        
        guard result == noErr else {
            logger.error("Failed to get device list: \(result)")
            return
        }
        
        // Process each device
        for deviceID in deviceIDs {
            var deviceInfo = getDeviceInfo(deviceID: deviceID)
            
            // Check if this is BlackHole
            if deviceInfo.name.contains("BlackHole") {
                blackHoleFound = true
                blackHoleDeviceID = deviceID
                isBlackHoleAvailable = true
                logger.info("BlackHole device found: \(deviceInfo.name) (ID: \(deviceID))")
            }
            
            devices.append(deviceInfo)
        }
        
        // Separate input and output devices
        availableInputDevices = devices.filter { $0.isInput }
        availableOutputDevices = devices.filter { $0.isOutput }
        
        if !blackHoleFound {
            isBlackHoleAvailable = false
            blackHoleDeviceID = nil
            logger.warning("BlackHole device not found")
        }
    }
    
    /// Get detailed information about an audio device
    private func getDeviceInfo(deviceID: AudioDeviceID) -> AudioDeviceInfo {
        var deviceName: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var deviceUID: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        
        // Get device name
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &deviceName)
        
        // Get device UID
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &deviceUID)
        
        // Check input/output capabilities
        var inputStreams: UInt32 = 0
        var streamSize = UInt32(MemoryLayout<UInt32>.size)
        var inputStreamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &inputStreamAddress, 0, nil, &streamSize, &inputStreams)
        
        var outputStreams: UInt32 = 0
        var outputStreamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &outputStreamAddress, 0, nil, &streamSize, &outputStreams)
        
        return AudioDeviceInfo(
            id: deviceID,
            name: deviceName as String,
            uid: deviceUID as String,
            isInput: inputStreams > 0,
            isOutput: outputStreams > 0
        )
    }
    
    /// Set BlackHole as default output device
    func setBlackHoleAsDefaultOutput() -> Bool {
        guard let deviceID = blackHoleDeviceID else {
            logger.error("BlackHole device not available")
            return false
        }
        
        var outputDeviceID = deviceID
        var result = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &outputDeviceID
        )
        
        if result == noErr {
            logger.info("BlackHole set as default output device")
            return true
        } else {
            logger.error("Failed to set BlackHole as default output: \(result)")
            return false
        }
    }
    
    /// Set BlackHole as default input device
    func setBlackHoleAsDefaultInput() -> Bool {
        guard let deviceID = blackHoleDeviceID else {
            logger.error("BlackHole device not available")
            return false
        }
        
        var inputDeviceID = deviceID
        var result = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &inputDeviceID
        )
        
        if result == noErr {
            logger.info("BlackHole set as default input device")
            return true
        } else {
            logger.error("Failed to set BlackHole as default input: \(result)")
            return false
        }
    }
    
    /// Get current default output device
    func getCurrentDefaultOutputDevice() -> AudioDeviceInfo? {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        let result = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            0,
            nil,
            &size,
            &deviceID
        )
        
        guard result == noErr else { return nil }
        return getDeviceInfo(deviceID: deviceID)
    }
    
    /// Get current default input device
    func getCurrentDefaultInputDevice() -> AudioDeviceInfo? {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        let result = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            0,
            nil,
            &size,
            &deviceID
        )
        
        guard result == noErr else { return nil }
        return getDeviceInfo(deviceID: deviceID)
    }
}