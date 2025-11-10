import Foundation
import Vocana

print("Testing ML initialization...")

// Create an MLAudioProcessor instance
let processor = MLAudioProcessor()

// Set up callbacks
processor.recordSuccess = {
    print("✅ recordSuccess called - ML processing is working!")
}

processor.recordFailure = {
    print("❌ recordFailure called - ML processing failed")
}

processor.onMLProcessingReady = {
    print("🎉 ML processing is ready!")
}

// Initialize ML processing
processor.initializeMLProcessing()

// Wait a bit for async initialization
print("Waiting for ML initialization...")
sleep(3)

print("ML state: isMLProcessingActive = \(processor.isMLProcessingActive)")
print("Test completed.")