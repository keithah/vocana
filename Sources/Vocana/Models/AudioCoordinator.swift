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
        // HIGH FIX: Fix race condition by merging publishers with debouncing
        // This prevents multiple simultaneous calls to updateAudioSettings()
        // when isEnabled and sensitivity change at nearly the same time
        Publishers.Merge(
            settings.$isEnabled.map { _ in () },
            settings.objectWillChange
        )
        .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
        .sink { [weak self] in
            self?.updateAudioSettings()
        }
        .store(in: &cancellables)
    }
    
    /// Update audio engine settings with error handling
    private func updateAudioSettings() {
        audioEngine.startSimulation(
            isEnabled: settings.isEnabled,
            sensitivity: settings.sensitivity
        )
        errorMessage = nil
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