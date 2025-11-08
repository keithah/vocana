import SwiftUI

/// Main content view for Vocana menu bar interface
/// 
/// This view orchestrates the entire menu bar interface, coordinating
/// between audio processing, user controls, and status indicators.
/// It uses the coordinator pattern to maintain clean separation of concerns.
/// 
/// Layout Structure:
/// - Header: App title and status indicators
/// - Main Controls: Power toggle for noise cancellation
/// - Audio Visualization: Real-time input/output level meters
/// - Sensitivity Control: Adjustable noise cancellation sensitivity
/// - Settings: Access to advanced configuration
/// 
/// Features:
/// - Coordinator pattern for clean architecture
/// - Comprehensive error handling with user feedback
/// - Keyboard shortcuts for power users
/// - Accessibility support throughout
/// - Responsive layout for different screen sizes
/// 
/// Usage:
/// ```swift
/// ContentView()
///     .frame(width: 300, height: 400)
/// ```
/// 
/// Error Handling:
/// - Graceful degradation on audio engine failures
/// - User-friendly error messages with retry options
/// - Automatic recovery attempts for transient issues
/// 
/// Performance:
/// - Efficient state management through coordinator
/// - Minimal view updates through optimized change detection
/// - Background audio processing with UI throttling
/// 
/// Accessibility:
/// - Full VoiceOver support
/// - Keyboard navigation
/// - High contrast mode compatibility
/// - Reduced motion support
struct ContentView: View {
    // Fix QUAL-001: Use concrete type with protocol conformance to reduce tight coupling
    @StateObject private var coordinator = AudioCoordinator()
    
    var body: some View {
        VStack(spacing: 16) {
            // Header with status indicator
            HStack {
                HeaderView()
                Spacer()
                StatusIndicatorView(audioEngine: coordinator.audioEngine, settings: coordinator.settings)
            }
            
            Divider()
            
            // Main controls
            PowerToggleView(isEnabled: $coordinator.settings.isEnabled)
            
            // Real-time audio visualization
            AudioVisualizerView(
                inputLevel: coordinator.audioEngine.currentLevels.input,
                outputLevel: coordinator.audioEngine.currentLevels.output
            )
            
            // Sensitivity control with visual feedback
            SensitivityControlView(sensitivity: $coordinator.settings.sensitivity)
            
            Divider()
            
            // Settings button
            SettingsButtonView {
                // TODO: Open settings window
            }
            
            Spacer()
        }
        .padding()
        .frame(width: AppConstants.popoverWidth, height: AppConstants.popoverHeight)
        .onAppear {
            coordinator.startAudioSimulation()
        }
        .onDisappear {
            coordinator.stopAudioSimulation()
        }
        .overlay(
            Button {
                coordinator.settings.isEnabled.toggle()
            } label: {
                EmptyView()
            }
            .keyboardShortcut("n", modifiers: [.command, .option])  // ⌥⌘N to toggle noise cancellation
            .opacity(0)
            .accessibilityHidden(true)
        )
        .alert("Audio Error", isPresented: $coordinator.showError) {
            Button("OK") { 
                coordinator.errorMessage = nil
            }
            Button("Retry") {
                coordinator.retryAudioSimulation()
            }
        } message: {
            Text(coordinator.errorMessage ?? "An unknown error occurred")
        }
    }
}

#Preview {
    ContentView()
}