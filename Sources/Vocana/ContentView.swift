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
    @ObservedObject var coordinator: AudioCoordinator
    @State private var showSettingsWindow = false
    
    // Expose coordinator for AppDelegate access
    var audioCoordinator: AudioCoordinator { coordinator }
    
    // Default initializer for SwiftUI Preview
    init() {
        self.coordinator = AudioCoordinator()
    }
    
    // Initializer for AppDelegate
    init(coordinator: AudioCoordinator) {
        self.coordinator = coordinator
    }
    
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
            AudioVisualizerView(audioEngine: coordinator.audioEngine)
            
            // Sensitivity control with visual feedback
            SensitivityControlView(sensitivity: $coordinator.settings.sensitivity)
            
            Divider()
            
             // Settings button - opens settings window
             SettingsButtonView {
                 showSettingsWindow = true
             }
            
            Spacer()
        }
        .padding()
        .frame(width: AppConstants.popoverWidth, height: AppConstants.popoverHeight)
        .onAppear {
            coordinator.startAudioProcessing()
        }
        .onDisappear {
            coordinator.stopAudioProcessing()
        }
         .overlay(
             // MEDIUM FIX: Use hidden Button with keyboardShortcut for proper keyboard handling
             // This allows ⌥⌘N to toggle the noise cancellation
             Button {
                 coordinator.settings.isEnabled.toggle()
             } label: {
                 EmptyView()
             }
             .keyboardShortcut("n", modifiers: [.command, .option])
             .opacity(0)
             .accessibilityHidden(true)
         )
         .sheet(isPresented: $showSettingsWindow) {
             SettingsWindow(isPresented: $showSettingsWindow, settings: coordinator.settings)
         }
    }
}

#Preview {
    ContentView()
}