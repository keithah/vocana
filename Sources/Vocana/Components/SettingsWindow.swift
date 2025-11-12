//
//  SettingsWindow.swift
//  Vocana Settings Window
//
//  Created by Vocana Team.
//  Copyright © 2025 Vocana. All rights reserved.
//

import SwiftUI

#if os(macOS)
class SettingsWindow: NSWindow {
    init(audioEngine: AudioEngine, settings: AppSettings) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        self.title = "Vocana Settings"
        self.center()

        let contentView = SettingsContentView(audioEngine: audioEngine, settings: settings)
        let hostingView = NSHostingView(rootView: contentView)
        self.contentView = hostingView

        // Set minimum size
        self.minSize = NSSize(width: 400, height: 500)
    }
}

struct SettingsContentView: View {
    @ObservedObject var audioEngine: AudioEngine
    @ObservedObject var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("Vocana Settings")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text("Configure audio processing and virtual devices")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)

                Divider()

                // Audio Settings
                GroupBox(label: Text("Audio Processing").font(.headline)) {
                    VStack(alignment: .leading, spacing: 16) {
                        // Power toggle
                        HStack {
                            Text("Enable Audio Processing")
                            Spacer()
                            Toggle("", isOn: $settings.isEnabled)
                                .labelsHidden()
                        }

                        // Sensitivity control
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Sensitivity: \(String(format: "%.1f", settings.sensitivity))")
                            Slider(value: $settings.sensitivity, in: 0.0...1.0, step: 0.1)
                                .accentColor(.blue)
                        }
                    }
                    .padding()
                }
                .padding(.horizontal)

                // Performance Settings
                GroupBox(label: Text("Performance").font(.headline)) {
                    VStack(alignment: .leading, spacing: 16) {
                        // Memory pressure level
                        HStack {
                            Text("Memory Pressure")
                            Spacer()
                            Text(audioEngine.memoryPressureLevel.description)
                                .foregroundColor(memoryPressureColor)
                        }

                        // Processing latency
                        HStack {
                            Text("Processing Latency")
                            Spacer()
                            Text(String(format: "%.1f ms", audioEngine.processingLatencyMs))
                        }

                        // Buffer health
                        HStack {
                            Text("Buffer Health")
                            Spacer()
                            Text(audioEngine.bufferHealthMessage)
                                .foregroundColor(bufferHealthColor)
                        }
                    }
                    .padding()
                }
                .padding(.horizontal)

                // Virtual Audio Devices
                VirtualAudioControlsView()
                    .padding(.horizontal)

                // About Section
                GroupBox(label: Text("About").font(.headline)) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Vocana v1.0.0")
                            .font(.headline)

                        Text("Real-time audio noise cancellation using machine learning")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        HStack {
                            Text("Total Frames Processed:")
                            Spacer()
                            Text("\(audioEngine.telemetry.totalFramesProcessed)")
                        }

                        HStack {
                            Text("ML Processing Failures:")
                            Spacer()
                            Text("\(audioEngine.telemetry.mlProcessingFailures)")
                        }
                    }
                    .padding()
                }
                .padding(.horizontal)

                Spacer(minLength: 20)
            }
            .padding(.vertical)
        }
    }

    private var memoryPressureColor: Color {
        switch audioEngine.memoryPressureLevel {
        case .normal: return .green
        case .warning: return .yellow
        case .urgent: return .orange
        case .critical: return .red
        }
    }

    private var bufferHealthColor: Color {
        if audioEngine.telemetry.circuitBreakerTriggers > 0 {
            return .red
        } else if audioEngine.telemetry.audioBufferOverflows > 5 {
            return .orange
        } else {
            return .green
        }
    }
}

extension MemoryPressureLevel {
    var description: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .urgent: return "Urgent"
        case .critical: return "Critical"
        }
    }
}

#endif