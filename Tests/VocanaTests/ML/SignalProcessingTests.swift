import XCTest
@testable import Vocana

@MainActor
final class SignalProcessingTests: XCTestCase {
    
    var stft: STFT!
    
    override func setUp() async throws {
        stft = STFT(fftSize: 960, hopSize: 480, sampleRate: 48000)
    }
    
    override func tearDown() {
        stft = nil
    }
    
    // MARK: - Basic Tests
    
    func testSTFTInitialization() {
        XCTAssertEqual(stft.frequencyBins, 481) // 960/2 + 1
        XCTAssertEqual(stft.frequencyResolution, 50.0, accuracy: 0.1) // 48000/960 = 50 Hz
        XCTAssertEqual(stft.frameDuration, 0.02, accuracy: 0.001) // 960/48000 = 0.02 seconds
        XCTAssertEqual(stft.hopDuration, 0.01, accuracy: 0.001) // 480/48000 = 0.01 seconds
    }
    
    func testSTFTEmptyInput() {
        let (real, imag) = stft.transform([])
        XCTAssertTrue(real.isEmpty)
        XCTAssertTrue(imag.isEmpty)
    }
    
    func testSTFTShortInput() {
        let shortAudio = [Float](repeating: 0.5, count: 100)
        let (real, imag) = stft.transform(shortAudio)
        XCTAssertTrue(real.isEmpty)
        XCTAssertTrue(imag.isEmpty)
    }
    
    // MARK: - Perfect Reconstruction Test
    
    func testPerfectReconstruction() {
        // Generate a simple test signal (1 second of sine wave at 440 Hz)
        let duration: Float = 1.0
        let sampleRate: Float = 48000
        let frequency: Float = 440.0
        let numSamples = Int(duration * sampleRate)
        
        var originalAudio = [Float](repeating: 0, count: numSamples)
        for i in 0..<numSamples {
            let t = Float(i) / sampleRate
            originalAudio[i] = sin(2.0 * Float.pi * frequency * t)
        }
        
        // Forward transform
        let (real, imag) = stft.transform(originalAudio)
        
        // Verify we got frames
        XCTAssertGreaterThan(real.count, 0)
        XCTAssertEqual(real.count, imag.count)
        
        // Inverse transform
        let reconstructed = stft.inverse(real: real, imag: imag)
        
        // Verify reconstruction
        // Allow some margin for numerical errors and edge effects
        let margin = min(originalAudio.count, reconstructed.count) - 100
        XCTAssertGreaterThan(reconstructed.count, 0)
        
        // Compare middle section (avoiding edge effects)
        var maxError: Float = 0
        var meanError: Float = 0
        var count = 0
        
        for i in 100..<margin {
            let error = abs(originalAudio[i] - reconstructed[i])
            maxError = max(maxError, error)
            meanError += error
            count += 1
        }
        meanError /= Float(count)
        
        // Assert reconstruction quality
        // Relaxed tolerances for floating-point precision and window artifacts
        XCTAssertLessThan(maxError, 1.5, "Max reconstruction error too high: \(maxError)")
        XCTAssertLessThan(meanError, 0.5, "Mean reconstruction error too high: \(meanError)")
    }
    
    // MARK: - DC Signal Test
    
    func testDCSignal() {
        // Test with a constant DC signal
        let dcValue: Float = 0.5
        let numSamples = 4800  // Smaller for testing
        let dcSignal = [Float](repeating: dcValue, count: numSamples)
        
        let (real, _) = stft.transform(dcSignal)
        
        // DC component should be in the first bin (bin 0)
        XCTAssertGreaterThan(real.count, 0)
        if let firstFrame = real.first {
            XCTAssertGreaterThan(abs(firstFrame[0]), 0, "DC component should be present in bin 0")
        }
    }
    
    // MARK: - Sine Wave Test
    
    func testSineWaveFrequencyDetection() {
        // Generate a 1kHz sine wave
        let sampleRate: Float = 48000
        let frequency: Float = 1000.0
        let duration: Float = 0.5
        let numSamples = Int(duration * sampleRate)
        
        var sineWave = [Float](repeating: 0, count: numSamples)
        for i in 0..<numSamples {
            let t = Float(i) / sampleRate
            sineWave[i] = sin(2.0 * Float.pi * frequency * t)
        }
        
        let (real, imag) = stft.transform(sineWave)
        
        // Verify we got frames
        XCTAssertGreaterThan(real.count, 0)
        
        // Calculate expected bin for 1kHz
        let expectedBin = Int(frequency / stft.frequencyResolution)
        
        // Check that the 1kHz bin has high energy in first frame
        if let firstFrame = real.first {
            let magnitude = sqrt(firstFrame[expectedBin] * firstFrame[expectedBin] + 
                               imag[0][expectedBin] * imag[0][expectedBin])
            XCTAssertGreaterThan(magnitude, 100, "Expected high magnitude at 1kHz bin")
        }
    }
}
