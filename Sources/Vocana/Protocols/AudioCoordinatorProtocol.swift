import Foundation
import SwiftUI

/// Protocol defining interface for audio coordination
/// 
/// This protocol abstracts audio coordination functionality to reduce
/// tight coupling between UI components and audio processing implementation.
/// It enables better testability and maintainability by defining clear boundaries.
protocol AudioCoordinating: ObservableObject {
    /// Audio engine instance for processing
    var audioEngine: any AudioEngineProtocol { get }
    
    /// Settings for audio processing
    var settings: any AudioSettingsProtocol { get }
    
    /// Error state management
    var showError: Bool { get set }
    var errorMessage: String? { get set }
    
    /// Start audio processing simulation
    func startAudioSimulation()
    
    /// Stop audio processing simulation
    func stopAudioSimulation()
    
    /// Retry audio processing after error
    func retryAudioSimulation()
}

/// Protocol defining audio settings interface
/// 
/// This protocol provides a clean interface for audio settings,
/// enabling better separation of concerns and easier testing.
protocol AudioSettingsProtocol: ObservableObject {
    /// Whether noise cancellation is enabled
    var isEnabled: Bool { get set }
    
    /// Sensitivity level for noise cancellation (0.0 to 1.0)
    var sensitivity: Float { get set }
}

/// Protocol defining audio engine interface
/// 
/// This protocol abstracts audio engine functionality,
/// allowing for mock implementations and better testability.
protocol AudioEngineProtocol: ObservableObject {
    /// Current audio levels (input and output)
    var currentLevels: (input: Float, output: Float) { get }
    
    /// Whether audio processing is active
    var isProcessing: Bool { get }
    
    /// Start audio processing
    func start() throws
    
    /// Stop audio processing
    func stop()
    
    /// Reset audio processing state
    func reset()
}