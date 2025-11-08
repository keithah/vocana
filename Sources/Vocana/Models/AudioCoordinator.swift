import Foundation
import Combine

/// Coordinator pattern implementation to reduce tight coupling between UI and AudioEngine
/// Manages the relationship between user settings and audio processing state
@MainActor
class AudioCoordinator: ObservableObject {
    @Published var audioEngine = AudioEngine()
    @Published var settings = AppSettings()
    
    // Error handling state
    @Published var errorMessage: String?
    @Published var showError = false
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        setupBindings()
    }
    
    /// Setup reactive bindings between settings and audio engine
    private func setupBindings() {
        // React to enabled state changes
        settings.$isEnabled
            .sink { [weak self] _ in
                self?.updateAudioSettings()
            }
            .store(in: &cancellables)
        
        // React to sensitivity changes using objectWillChange
        settings.objectWillChange
            .sink { [weak self] _ in
                self?.updateAudioSettings()
            }
            .store(in: &cancellables)
    }
    
    /// Update audio engine settings with error handling
    private func updateAudioSettings() {
        do {
            audioEngine.startSimulation(
                isEnabled: settings.isEnabled,
                sensitivity: settings.sensitivity
            )
            errorMessage = nil
        } catch {
            errorMessage = "Failed to start audio processing: \(error.localizedDescription)"
            showError = true
        }
    }
    
    /// Start audio simulation (called from UI)
    func startAudioSimulation() {
        updateAudioSettings()
    }
    
    /// Stop audio simulation (called from UI)
    func stopAudioSimulation() {
        audioEngine.stopSimulation()
    }
    
    /// Handle error recovery
    func retryAudioSimulation() {
        errorMessage = nil
        showError = false
        updateAudioSettings()
    }
}