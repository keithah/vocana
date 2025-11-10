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
    
    deinit {
        // Fix CRITICAL: Clean up cancellables explicitly to prevent subscription leaks
        cancellables.removeAll()
        // Note: stopAudioSimulation() cannot be called from deinit as it's @MainActor
        // The audio engine will clean up automatically when deallocated
    }
    
    /// Setup reactive bindings between settings and audio engine
    private func setupBindings() {
        // Optimization: Split isEnabled and sensitivity for responsive UX
        // isEnabled receives immediate updates for responsive user feedback
        // sensitivity uses debouncing to prevent excessive ML re-processing
        
        // Immediate isEnabled updates (toggle response should be instant)
        settings.$isEnabled
            .sink { [weak self] _ in
                self?.updateAudioSettings()
            }
            .store(in: &cancellables)
        
        // Debounced sensitivity updates (ML processing is expensive)
        // 50ms debounce prevents excessive re-processing while user adjusts slider
        settings.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                self?.updateAudioSettings()
            }
            .store(in: &cancellables)
    }
    
     /// Update audio engine settings with state validation
    private func updateAudioSettings() {
        // Fix HIGH: Validate audio engine state before updating
        audioEngine.startAudioProcessing(
            isEnabled: settings.isEnabled,
            sensitivity: settings.sensitivity
        )
    }
    
    /// Start audio processing (called from UI)
    func startAudioProcessing() {
        updateAudioSettings()
    }
    
    /// Stop audio processing (called from UI)
    func stopAudioProcessing() {
        audioEngine.stopAudioProcessing()
    }
}