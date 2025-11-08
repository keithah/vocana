import Foundation
import Combine

/// Coordinator pattern implementation to reduce tight coupling between UI and AudioEngine
/// Manages the relationship between user settings and audio processing state
@MainActor
class AudioCoordinator: ObservableObject {
    @Published var audioEngine = AudioEngine()
    @Published var settings = AppSettings()
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        setupBindings()
    }
    
    /// Setup reactive bindings between settings and audio engine
    private func setupBindings() {
        // Use merge with objectWillChange for deterministic updates
        // objectWillChange fires for all property changes including sensitivity (computed property)
        // Debounce prevents multiple rapid updates when isEnabled and sensitivity change together
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
    
    /// Update audio engine settings
    private func updateAudioSettings() {
        audioEngine.startSimulation(
            isEnabled: settings.isEnabled,
            sensitivity: settings.sensitivity
        )
    }
    
    /// Start audio simulation (called from UI)
    func startAudioSimulation() {
        updateAudioSettings()
    }
    
    /// Stop audio simulation (called from UI)
    func stopAudioSimulation() {
        audioEngine.stopSimulation()
    }
}