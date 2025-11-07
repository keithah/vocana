import XCTest
@testable import Vocana

final class FeatureExtractionTests: XCTestCase {
    
    var erbFeatures: ERBFeatures!
    var spectralFeatures: SpectralFeatures!
    var stft: STFT!
    
    override func setUp() {
        erbFeatures = ERBFeatures(numBands: 32, sampleRate: 48000, fftSize: 960)
        spectralFeatures = SpectralFeatures(dfBands: 96, sampleRate: 48000, fftSize: 960)
        stft = STFT(fftSize: 960, hopSize: 480, sampleRate: 48000)
    }
    
    override func tearDown() {
        erbFeatures = nil
        spectralFeatures = nil
        stft = nil
    }
    
    // MARK: - ERB Features Tests
    
    func testERBFilterbankGeneration() {
        // Verify filterbank properties
        let centers = erbFeatures.centerFrequencies
        
        XCTAssertEqual(centers.count, 32, "Should have 32 ERB bands")
        XCTAssertGreaterThan(centers.first ?? 0, 0, "First center should be > 0")
        XCTAssertLessThan(centers.last ?? 0, 24000, "Last center should be < Nyquist")
        
        // Verify centers are monotonically increasing
        for i in 1..<centers.count {
            XCTAssertGreaterThan(centers[i], centers[i-1], "Centers should be monotonically increasing")
        }
    }
    
    func testERBFeatureExtraction() {
        // Generate test signal
        let duration: Float = 0.5
        let sampleRate: Float = 48000
        let frequency: Float = 1000.0
        let numSamples = Int(duration * sampleRate)
        
        var testSignal = [Float](repeating: 0, count: numSamples)
        for i in 0..<numSamples {
            let t = Float(i) / sampleRate
            testSignal[i] = sin(2.0 * Float.pi * frequency * t)
        }
        
        // Compute STFT
        let (real, imag) = stft.transform(testSignal)
        
        // Extract ERB features
        let features = erbFeatures.extract(spectrogramReal: real, spectrogramImag: imag)
        
        // Verify output shape
        XCTAssertGreaterThan(features.count, 0, "Should have frames")
        if let firstFrame = features.first {
            XCTAssertEqual(firstFrame.count, 32, "Should have 32 bands")
        }
        
        // Verify features are non-negative (energy-based)
        for frame in features {
            for value in frame {
                XCTAssertGreaterThanOrEqual(value, 0, "ERB features should be non-negative")
            }
        }
    }
    
    func testERBNormalization() {
        // Create simple test features
        let testFeatures = [
            [1.0, 2.0, 3.0, 4.0] as [Float],
            [2.0, 3.0, 4.0, 5.0] as [Float]
        ]
        
        let normalized = erbFeatures.normalize(testFeatures, alpha: 1.0)
        
        // Verify output shape
        XCTAssertEqual(normalized.count, testFeatures.count)
        XCTAssertEqual(normalized[0].count, testFeatures[0].count)
        
        // Verify normalization properties (mean should be ~0, std should be ~1 before alpha)
        for frame in normalized {
            let mean = frame.reduce(0, +) / Float(frame.count)
            XCTAssertLessThan(abs(mean), 0.1, "Normalized mean should be near 0")
        }
    }
    
    // MARK: - Spectral Features Tests
    
    func testSpectralFeatureExtraction() throws {
        // Generate test signal
        let duration: Float = 0.5
        let sampleRate: Float = 48000
        let frequency: Float = 440.0
        let numSamples = Int(duration * sampleRate)
        
        var testSignal = [Float](repeating: 0, count: numSamples)
        for i in 0..<numSamples {
            let t = Float(i) / sampleRate
            testSignal[i] = sin(2.0 * Float.pi * frequency * t)
        }
        
        // Compute STFT
        let (real, imag) = stft.transform(testSignal)
        
        // Extract spectral features
        let features = try spectralFeatures.extract(spectrogramReal: real, spectrogramImag: imag)
        
        // Verify output shape: [numFrames, 2, 96]
        XCTAssertGreaterThan(features.count, 0, "Should have frames")
        if let firstFrame = features.first {
            XCTAssertEqual(firstFrame.count, 2, "Should have 2 channels (real, imag)")
            XCTAssertEqual(firstFrame[0].count, 96, "Real channel should have 96 bins")
            XCTAssertEqual(firstFrame[1].count, 96, "Imag channel should have 96 bins")
        }
    }
    
    func testSpectralFeatureFrequencyRange() {
        let range = spectralFeatures.frequencyRange
        
        XCTAssertEqual(range.min, 0, "Min frequency should be 0")
        
        // Max frequency = (sampleRate / fftSize) * dfBands = (48000 / 960) * 96 = 4800 Hz
        let expectedMax: Float = 4800.0
        XCTAssertEqual(range.max, expectedMax, accuracy: 1.0)
    }
    
    func testSpectralFeatureNormalization() {
        // Create test spectral features [numFrames, 2, dfBands]
        let realChannel = Array(repeating: Float(1.0), count: 96)
        let imagChannel = Array(repeating: Float(0.5), count: 96)
        let testFeatures = [[realChannel, imagChannel]]
        
        let normalized = spectralFeatures.normalize(testFeatures, alpha: 1.0)
        
        // Verify output shape
        XCTAssertEqual(normalized.count, 1)
        XCTAssertEqual(normalized[0].count, 2)
        XCTAssertEqual(normalized[0][0].count, 96)
        XCTAssertEqual(normalized[0][1].count, 96)
        
        // Verify normalization occurred (values should change)
        XCTAssertNotEqual(normalized[0][0][0], realChannel[0])
    }
    
    // MARK: - Integration Tests
    
    func testFullFeatureExtractionPipeline() throws {
        // Generate test signal (440 Hz sine wave)
        let duration: Float = 1.0
        let sampleRate: Float = 48000
        let frequency: Float = 440.0
        let numSamples = Int(duration * sampleRate)
        
        var testSignal = [Float](repeating: 0, count: numSamples)
        for i in 0..<numSamples {
            let t = Float(i) / sampleRate
            testSignal[i] = sin(2.0 * Float.pi * frequency * t)
        }
        
        // Step 1: STFT
        let (real, imag) = stft.transform(testSignal)
        XCTAssertGreaterThan(real.count, 0)
        
        // Step 2: ERB features
        let erbFeats = erbFeatures.extract(spectrogramReal: real, spectrogramImag: imag)
        let normalizedErb = erbFeatures.normalize(erbFeats)
        
        XCTAssertEqual(erbFeats.count, real.count, "ERB features should match number of frames")
        XCTAssertEqual(normalizedErb.count, erbFeats.count)
        
        // Step 3: Spectral features
        let specFeats = try spectralFeatures.extract(spectrogramReal: real, spectrogramImag: imag)
        let normalizedSpec = spectralFeatures.normalize(specFeats)
        
        XCTAssertEqual(specFeats.count, real.count, "Spectral features should match number of frames")
        XCTAssertEqual(normalizedSpec.count, specFeats.count)
        
        // Verify we have the right shapes for ONNX input
        // ERB: [numFrames, 32]
        // Spec: [numFrames, 2, 96]
        if let firstErb = normalizedErb.first {
            XCTAssertEqual(firstErb.count, 32)
        }
        if let firstSpec = normalizedSpec.first {
            XCTAssertEqual(firstSpec.count, 2)
            XCTAssertEqual(firstSpec[0].count, 96)
        }
    }
}
