import XCTest
@testable import Vocana

@MainActor
final class AudioCoordinatorMemoryTests: XCTestCase {
    
    /// Test that AudioCoordinator properly deallocates without resource leaks
    func testAudioCoordinatorMemoryManagement() async throws {
        weak var weakCoordinator: AudioCoordinator?
        
        do {
            let coordinator = AudioCoordinator()
            weakCoordinator = coordinator
            
            // Start and stop audio simulation
            coordinator.startAudioSimulation()
            
            // Simulate some time passing
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            
            coordinator.stopAudioSimulation()
        }
        
        // Give cleanup time to complete
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        
        // Verify coordinator was deallocated
        XCTAssertNil(weakCoordinator, "AudioCoordinator should be deallocated after going out of scope")
    }
    
    /// Test that settings updates don't prevent deallocation
    func testAudioCoordinatorSettingsUpdatesDontLeakMemory() async throws {
        weak var weakCoordinator: AudioCoordinator?
        
        do {
            let coordinator = AudioCoordinator()
            weakCoordinator = coordinator
            
            // Simulate multiple settings changes
            coordinator.settings.isEnabled = true
            try await Task.sleep(nanoseconds: 50_000_000)
            
            coordinator.settings.isEnabled = false
            try await Task.sleep(nanoseconds: 50_000_000)
            
            coordinator.settings.sensitivity = 0.8
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        
        // Give cleanup time
        try await Task.sleep(nanoseconds: 200_000_000)
        
        XCTAssertNil(weakCoordinator, "AudioCoordinator should deallocate even after settings changes")
    }
    
    /// Test that stopping audio simulation allows cleanup
    func testAudioCoordinatorStopAllowsCleanup() async throws {
        weak var weakCoordinator: AudioCoordinator?
        
        do {
            let coordinator = AudioCoordinator()
            weakCoordinator = coordinator
            
            coordinator.startAudioSimulation()
            try await Task.sleep(nanoseconds: 100_000_000)
            
            // Explicitly stop - this is important for cleanup
            coordinator.stopAudioSimulation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        
        // Give cleanup time
        try await Task.sleep(nanoseconds: 200_000_000)
        
        XCTAssertNil(weakCoordinator, "Coordinator should deallocate after stop()")
    }
}
