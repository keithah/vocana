import XCTest
@testable import Vocana

/// Performance regression tests to detect latency and throughput degradation
final class PerformanceRegressionTests: XCTestCase {
    
    // MARK: - STFT Performance
    
    func testSTFTTransformLatency() {
        let stft = try! STFT(fftSize: 960, hopSize: 480, sampleRate: 48000)
        let testAudio = [Float](repeating: 0.1, count: 4800)  // 100ms of audio
        
        let startTime = CFAbsoluteTimeGetCurrent()
        let _ = stft.transform(testAudio)
        let endTime = CFAbsoluteTimeGetCurrent()
        
        let latencyMs = (endTime - startTime) * 1000.0
        
        // STFT should complete in < 10ms for 100ms of audio (reasonable for vDSP operations)
        XCTAssertLessThan(latencyMs, 10.0, "STFT transform latency \(String(format: "%.2f", latencyMs))ms exceeds 10ms target")
    }
    
    func testSTFTInverseTransformLatency() throws {
        let stft = try! STFT(fftSize: 960, hopSize: 480, sampleRate: 48000)
        let testAudio = [Float](repeating: 0.1, count: 4800)
        let spectrum = stft.transform(testAudio)
        
        let startTime = CFAbsoluteTimeGetCurrent()
        let _ = stft.inverse(real: spectrum.0, imag: spectrum.1)
        let endTime = CFAbsoluteTimeGetCurrent()
        
        let latencyMs = (endTime - startTime) * 1000.0
        
        // ISTFT should also complete in < 10ms
        XCTAssertLessThan(latencyMs, 10.0, "ISTFT latency \(String(format: "%.2f", latencyMs))ms exceeds 10ms target")
    }
    
    // MARK: - Feature Extraction Performance
    
    func testERBFeatureExtractionLatency() throws throws {
        let erbFeatures = ERBFeatures(numBands: 32, sampleRate: 48000, fftSize: 960)
        
        // Create test spectrogram (10 frames of 481 bins each)
        let spectrogramReal = [[Float]](repeating: [Float](repeating: 0.1, count: 481), count: 10)
        let spectrogramImag = [[Float]](repeating: [Float](repeating: 0.0, count: 481), count: 10)
        
        let startTime = CFAbsoluteTimeGetCurrent()
        let _ = erbFeatures.extract(spectrogramReal: spectrogramReal, spectrogramImag: spectrogramImag)
        let endTime = CFAbsoluteTimeGetCurrent()
        
        let latencyMs = (endTime - startTime) * 1000.0
        
        // Feature extraction should be fast (< 5ms for 10 frames)
        XCTAssertLessThan(latencyMs, 5.0, "ERB extraction latency \(String(format: "%.2f", latencyMs))ms exceeds 5ms target")
    }
    
    func testSpectralFeatureExtractionLatency() throws throws {
        let spectralFeatures = SpectralFeatures(sampleRate: 48000)
        
        // Create test spectrogram
        let spectrogramReal = [[Float]](repeating: [Float](repeating: 0.1, count: 481), count: 10)
        let spectrogramImag = [[Float]](repeating: [Float](repeating: 0.0, count: 481), count: 10)
        
        let startTime = CFAbsoluteTimeGetCurrent()
        let _ = try spectralFeatures.extract(spectrogramReal: spectrogramReal, spectrogramImag: spectrogramImag)
        let endTime = CFAbsoluteTimeGetCurrent()
        
        let latencyMs = (endTime - startTime) * 1000.0
        
        // Should also be fast (< 5ms)
        XCTAssertLessThan(latencyMs, 5.0, "Spectral extraction latency \(String(format: "%.2f", latencyMs))ms exceeds 5ms target")
    }
    
    // MARK: - Consistency Tests
    
    func testSTFTLatencyConsistency() throws {
        let stft = try! STFT(fftSize: 960, hopSize: 480, sampleRate: 48000)
        let testAudio = [Float](repeating: 0.1, count: 4800)
        
        var latencies: [Double] = []
        
        // Collect latencies from multiple runs
        for _ in 0..<5 {
            let startTime = CFAbsoluteTimeGetCurrent()
            let _ = stft.transform(testAudio)
            let endTime = CFAbsoluteTimeGetCurrent()
            latencies.append((endTime - startTime) * 1000.0)
        }
        
        let mean = latencies.reduce(0, +) / Double(latencies.count)
        let maxLatency = latencies.max() ?? 0
        
        // Max latency should not be more than 2x average (reasonable variance)
        XCTAssertLessThan(maxLatency, mean * 2.0, "STFT latency variance too high (max: \(String(format: "%.2f", maxLatency))ms, mean: \(String(format: "%.2f", mean))ms)")
    }
}
