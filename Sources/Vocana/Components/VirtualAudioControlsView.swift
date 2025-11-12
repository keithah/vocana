//
//  VirtualAudioControlsView.swift
//  Vocana Virtual Audio Controls View
//
//  Created by Vocana Team.
//  Copyright © 2025 Vocana. All rights reserved.
//

import SwiftUI

struct VirtualAudioControlsView: View {
    @StateObject private var virtualAudioManager = VirtualAudioManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Virtual Audio Devices")
                .font(.headline)
                .foregroundColor(.primary)

            if virtualAudioManager.areDevicesAvailable {
                VStack(spacing: 12) {
                    // Input Device Controls
                    if let inputDevice = virtualAudioManager.inputDevice {
                        DeviceControlView(
                            device: inputDevice,
                            title: "Microphone",
                            iconName: "mic.fill",
                            isNoiseCancellationEnabled: virtualAudioManager.isInputNoiseCancellationEnabled,
                            toggleAction: { enabled in
                                virtualAudioManager.enableInputNoiseCancellation(enabled)
                            }
                        )
                    }

                    // Output Device Controls
                    if let outputDevice = virtualAudioManager.outputDevice {
                        DeviceControlView(
                            device: outputDevice,
                            title: "Speaker",
                            iconName: "speaker.wave.2.fill",
                            isNoiseCancellationEnabled: virtualAudioManager.isOutputNoiseCancellationEnabled,
                            toggleAction: { enabled in
                                virtualAudioManager.enableOutputNoiseCancellation(enabled)
                            }
                        )
                    }

                    // Application Detection
                    ApplicationDetectionView()
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)

                    Text("Virtual Audio Devices Not Available")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Text("Install Vocana HAL plugin to enable virtual audio device support")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding()
            }
        }
        .padding()
        .background(Color(.windowBackgroundColor).opacity(0.5))
        .cornerRadius(8)
        .onAppear {
            // Refresh device state when view appears
            virtualAudioManager.createVirtualDevices()
        }
    }
}

struct DeviceControlView: View {
    let device: VocanaAudioDevice
    let title: String
    let iconName: String
    let isNoiseCancellationEnabled: Bool
    let toggleAction: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: iconName)
                    .foregroundColor(.blue)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text(device.deviceName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Toggle("Noise Cancellation", isOn: Binding(
                get: { isNoiseCancellationEnabled },
                set: { toggleAction($0) }
            ))
            .toggleStyle(SwitchToggleStyle())
        }
        .padding(12)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(6)
    }
}

struct ApplicationDetectionView: View {
    @StateObject private var virtualAudioManager = VirtualAudioManager.shared
    @State private var isMonitoring = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "app.badge.checkmark")
                    .foregroundColor(.green)
                Text("Application Detection")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Button(action: {
                    if isMonitoring {
                        virtualAudioManager.stopApplicationMonitoring()
                    } else {
                        virtualAudioManager.startApplicationMonitoring()
                    }
                    isMonitoring.toggle()
                }) {
                    Text(isMonitoring ? "Stop" : "Start")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(isMonitoring ? Color.red.opacity(0.2) : Color.green.opacity(0.2))
                        .foregroundColor(isMonitoring ? .red : .green)
                        .cornerRadius(4)
                }
            }

            if !virtualAudioManager.activeConferencingApps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Active Apps:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ForEach(virtualAudioManager.activeConferencingApps, id: \.self) { app in
                        Text("• \(app)")
                            .font(.caption)
                            .foregroundColor(.primary)
                    }
                }
            } else {
                Text("No active conferencing apps detected")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(6)
    }
}

struct VirtualAudioControlsView_Previews: PreviewProvider {
    static var previews: some View {
        VirtualAudioControlsView()
            .frame(width: 400, height: 300)
    }
}