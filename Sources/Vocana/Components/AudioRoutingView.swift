//
//  AudioRoutingView.swift
//  Vocana
//
//  Audio routing interface for VocanaVirtualDevice integration
//

import SwiftUI
import AVFoundation

struct AudioRoutingView: View {
    @StateObject private var virtualAudioManager = VirtualAudioManager()
    @State private var isRoutingEnabled = false
    
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
        virtualAudioManager.enableVirtualDevices(true)
    }
    
    private func stopRouting() {
        virtualAudioManager.enableVirtualDevices(false)
    }
}

#Preview {
    AudioRoutingView()
}