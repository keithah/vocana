//
//  AudioRoutingView.swift
//  Vocana
//
//  Audio routing interface for VocanaVirtualDevice integration
//

import SwiftUI
import AVFoundation
import CoreAudio

struct AudioRoutingView: View {
    @StateObject private var virtualAudioManager = VirtualAudioManager()
    @State private var isRoutingEnabled = false
    @State private var originalInputDeviceID: AudioDeviceID?
    @State private var originalOutputDeviceID: AudioDeviceID?
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Audio Routing")
                .font(.headline)
                .padding(.top)
            
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "waveform.path.ecg")
                        .foregroundColor(.blue)
                    Text("VocanaVirtualDevice Status")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                
                if let inputDevice = virtualAudioManager.inputDevice {
                    HStack {
                        Text("Input:")
                            .foregroundColor(.secondary)
                        Text(inputDevice.deviceName)
                            .foregroundColor(.primary)
                    }
                } else {
                    HStack {
                        Text("Input:")
                            .foregroundColor(.secondary)
                        Text("Not Found")
                            .foregroundColor(.red)
                    }
                }
                
                if let outputDevice = virtualAudioManager.outputDevice {
                    HStack {
                        Text("Output:")
                            .foregroundColor(.secondary)
                        Text(outputDevice.deviceName)
                            .foregroundColor(.primary)
                    }
                } else {
                    HStack {
                        Text("Output:")
                            .foregroundColor(.secondary)
                        Text("Not Found")
                            .foregroundColor(.red)
                    }
                }
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)
            
            Toggle("Enable Audio Routing", isOn: $isRoutingEnabled)
                .padding(.horizontal)
                .onChange(of: isRoutingEnabled) { enabled in
                    if enabled {
                        startRouting()
                    } else {
                        stopRouting()
                    }
                }
            
            Spacer()
        }
        .onAppear {
            virtualAudioManager.createVirtualDevices()
        }
    }
    
    private func startRouting() {
        // Save current default audio devices before switching
        saveCurrentDefaultDevices()

        // Create virtual devices
        let success = virtualAudioManager.createVirtualDevices()
        if success {
            // Enable noise cancellation on both input and output
            virtualAudioManager.enableInputNoiseCancellation(true)
            virtualAudioManager.enableOutputNoiseCancellation(true)

            // Set up audio routing through HAL plugin
            setupAudioRouting()
        }
    }

    private func stopRouting() {
        // Disable noise cancellation
        virtualAudioManager.enableInputNoiseCancellation(false)
        virtualAudioManager.enableOutputNoiseCancellation(false)

        // Destroy virtual devices
        virtualAudioManager.destroyVirtualDevices()

        // Restore original default audio devices
        restoreDefaultDevices()
    }

    private func saveCurrentDefaultDevices() {
        // Get current default input device
        var inputDeviceID: AudioDeviceID = 0
        var inputSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var inputPropertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let inputStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &inputPropertyAddress,
            0,
            nil,
            &inputSize,
            &inputDeviceID
        )

        if inputStatus == noErr {
            originalInputDeviceID = inputDeviceID
        }

        // Get current default output device
        var outputDeviceID: AudioDeviceID = 0
        var outputSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var outputPropertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let outputStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &outputPropertyAddress,
            0,
            nil,
            &outputSize,
            &outputDeviceID
        )

        if outputStatus == noErr {
            originalOutputDeviceID = outputDeviceID
        }
    }

    private func restoreDefaultDevices() {
        // Restore original input device
        if var inputDeviceID = originalInputDeviceID {
            var inputPropertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            AudioObjectSetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &inputPropertyAddress,
                0,
                nil,
                UInt32(MemoryLayout<AudioDeviceID>.size),
                &inputDeviceID
            )
        }

        // Restore original output device
        if var outputDeviceID = originalOutputDeviceID {
            var outputPropertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            AudioObjectSetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &outputPropertyAddress,
                0,
                nil,
                UInt32(MemoryLayout<AudioDeviceID>.size),
                &outputDeviceID
            )
        }

        // Clear saved device IDs
        originalInputDeviceID = nil
        originalOutputDeviceID = nil
    }

    private func setupAudioRouting() {
        // Configure Core Audio to route through Vocana virtual devices
        // This sets up the audio pipeline: Input Device -> HAL Plugin -> ML Processing -> Output Device

        guard let inputDevice = virtualAudioManager.inputDevice,
              let outputDevice = virtualAudioManager.outputDevice else {
            return
        }

        // Set default input device to Vocana Virtual Microphone
        setDefaultAudioDevice(deviceID: inputDevice.deviceID, isInput: true)

        // Set default output device to Vocana Virtual Speaker
        setDefaultAudioDevice(deviceID: outputDevice.deviceID, isInput: false)

        // The HAL plugin will now handle audio routing and processing
        // Audio flows: Physical Input -> HAL Plugin -> XPC -> ML Processing -> HAL Plugin -> Physical Output
    }

    private func setDefaultAudioDevice(deviceID: UInt32, isInput: Bool) {
        // Set the default audio device using Core Audio
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: isInput ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceIDToSet = deviceID
        let result = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &deviceIDToSet
        )

        if result == noErr {
            print("Successfully set default \(isInput ? "input" : "output") device to Vocana Virtual Device")
        } else {
            print("Failed to set default \(isInput ? "input" : "output") device: \(result)")
        }
    }
}

#Preview {
    AudioRoutingView()
}