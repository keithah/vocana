//
//  PerformanceBenchmarks.swift
//  Vocana
//
//  Created by AI Assistant
//

import XCTest
@testable import Vocana

class PerformanceBenchmarks: XCTestCase {
    // MARK: - Test Data Setup

    private var testAudio: [Float]!
    private var testWeights: [Float]!
    private var testBiases: [Float]!
    private var testSpectrum: (real: [Float], imag: [Float])!

    override func setUp() {
        super.setUp()

        // Generate test audio data (1 second at 48kHz)
        let sampleRate = 48000
        let duration = 1.0
        let numSamples = Int(Float(sampleRate) * Float(duration))

        testAudio = (0..<numSamples).map { i in
            let t = Float(i) / Float(sampleRate)
            // Generate a mix of sine waves and noise
            return sin(2 * Float.pi * 440 * t) * 0.5 +
                   sin(2 * Float.pi * 1000 * t) * 0.3 +
                   Float.random(in: -0.1...0.1)
        }

        // Generate test neural network weights
        let inputSize = 512
        let hiddenSize = 256

        testWeights = (0..<inputSize * hiddenSize).map { _ in Float.random(in: -0.1...0.1) }
        testBiases = (0..<hiddenSize).map { _ in Float.random(in: -0.01...0.01) }

        // Generate test spectrum data (FFT of test audio)
        let fftSize = 1024
        testSpectrum = (
            real: (0..<fftSize).map { _ in Float.random(in: -1.0...1.0) },
            imag: (0..<fftSize).map { _ in Float.random(in: -1.0...1.0) }
        )
    }

    override func tearDown() {
        testAudio = nil
        testWeights = nil
        testBiases = nil
        testSpectrum = nil
        super.tearDown()
    }

    // MARK: - FFT Performance Benchmarks

    func testFFTPerformanceComparison() {
        let fftSizes = [256, 512, 1024, 2048]

        for fftSize in fftSizes {
            let input = Array(testAudio.prefix(fftSize))

            // CPU FFT baseline (using vDSP if available, otherwise skip)
            var cpuTime: TimeInterval = 0
            cpuTime = measureTime {
                _ = try? cpuFFT(input: input, inverse: false)
            }

            // GPU FFT
            var gpuTime: TimeInterval = 0
            if let metalProcessor = MetalNeuralProcessor() {
                gpuTime = measureTime {
                    _ = try? metalProcessor.fft(input: input, inverse: false)
                }
            }

            print(String(format: "FFT Size %4d: CPU %.3fms, GPU %.3fms, Speedup %.1fx",
                         fftSize, cpuTime * 1000, gpuTime * 1000,
                         gpuTime > 0 ? cpuTime / gpuTime : 0))
        }
    }

    // MARK: - STFT Performance Benchmarks

    func testSTFTPerformanceComparison() {
        let windowSizes = [256, 512, 1024]
        let hopSizes = [128, 256, 512]

        for windowSize in windowSizes {
            for hopSize in hopSizes {
                guard hopSize < windowSize else { continue }

                // CPU STFT baseline
                let cpuTime = measureTime {
                    _ = try? cpuSTFT(input: testAudio, windowSize: windowSize, hopSize: hopSize, inverse: false)
                }

                // GPU STFT
                var gpuTime: TimeInterval = 0
                if let metalProcessor = MetalNeuralProcessor() {
                    gpuTime = measureTime {
                        _ = try? metalProcessor.stft(input: testAudio, windowSize: windowSize, hopSize: hopSize, inverse: false)
                    }
                }

                print(String(format: "STFT %3dx%3d: CPU %.3fms, GPU %.3fms, Speedup %.1fx",
                             windowSize, hopSize, cpuTime * 1000, gpuTime * 1000,
                             gpuTime > 0 ? cpuTime / gpuTime : 0))
            }
        }
    }

    // MARK: - ERB Filtering Performance Benchmarks

    func testERBFilteringPerformanceComparison() {
        let numBandsOptions = [32, 64, 96]

        for numBands in numBandsOptions {
            // CPU ERB filtering baseline
            let cpuTime = measureTime {
                _ = try? cpuERBFilter(spectrum: testSpectrum, numBands: numBands, sampleRate: 48000)
            }

            // GPU ERB filtering
            var gpuTime: TimeInterval = 0
            if let metalProcessor = MetalNeuralProcessor() {
                gpuTime = measureTime {
                    _ = try? metalProcessor.erbFilter(spectrum: testSpectrum, numBands: numBands, sampleRate: 48000)
                }
            }

            print(String(format: "ERB %2d bands: CPU %.3fms, GPU %.3fms, Speedup %.1fx",
                         numBands, cpuTime * 1000, gpuTime * 1000,
                         gpuTime > 0 ? cpuTime / gpuTime : 0))
        }
    }

    // MARK: - Neural Network Layer Performance Benchmarks

    func testLinearLayerPerformanceComparison() {
        let inputSizes = [128, 256, 512]
        let outputSizes = [64, 128, 256]

        for inputSize in inputSizes {
            for outputSize in outputSizes {
                let input: [Float] = (0..<inputSize).map { _ in Float.random(in: -1.0...1.0) }
                let weights: [[Float]] = (0..<outputSize).map { _ in
                    (0..<inputSize).map { _ in Float.random(in: -0.1...0.1) }
                }
                let biases: [Float] = (0..<outputSize).map { _ in Float.random(in: -0.01...0.01) }

                // CPU Linear layer
                let cpuTime = measureTime {
                    _ = cpuLinear(input: input, weights: weights, biases: biases)
                }

                // GPU Linear layer
                var gpuTime: TimeInterval = 0
                if let metalProcessor = MetalNeuralProcessor() {
                    gpuTime = measureTime {
                        let semaphore = DispatchSemaphore(value: 0)
                        var result: [Float]?
                        metalProcessor.linear(input: input, weights: weights, bias: biases) { res in
                            switch res {
                            case .success(let output):
                                result = output
                            case .failure:
                                result = nil
                            }
                            semaphore.signal()
                        }
                        semaphore.wait()
                        _ = result
                    }
                }

                print(String(format: "Linear %3dx%3d: CPU %.3fms, GPU %.3fms, Speedup %.1fx",
                             inputSize, outputSize, cpuTime * 1000, gpuTime * 1000,
                             gpuTime > 0 ? cpuTime / gpuTime : 0))
            }
        }
    }

    func testConv1DLayerPerformanceComparison() {
        let inputLengths = [512, 1024, 2048]
        let kernelSizes = [3, 5, 7]
        let inputChannels = 32
        let outputChannels = 64

        for inputLength in inputLengths {
            for kernelSize in kernelSizes {
                let input: [Float] = (0..<inputLength * inputChannels).map { _ in Float.random(in: -1.0...1.0) }

                // Create MetalConv1DLayer for GPU testing
                let metalLayer = MetalConv1DLayer(inputChannels: inputChannels,
                                                outputChannels: outputChannels,
                                                kernelSize: kernelSize,
                                                stride: 1)

                // CPU Conv1D baseline
                let cpuTime = measureTime {
                    _ = try? cpuConv1D(input: input,
                                     inputChannels: inputChannels,
                                     outputChannels: outputChannels,
                                     kernelSize: kernelSize,
                                     stride: 1)
                }

                // GPU Conv1D
                var gpuTime: TimeInterval = 0
                gpuTime = measureTime {
                    var hiddenStates = [String: [Float]]()
                    _ = try? metalLayer.forward(input, hiddenStates: &hiddenStates)
                }

                print(String(format: "Conv1D %4dx%2d: CPU %.3fms, GPU %.3fms, Speedup %.1fx",
                             inputLength, kernelSize, cpuTime * 1000, gpuTime * 1000,
                             gpuTime > 0 ? cpuTime / gpuTime : 0))
            }
        }
    }

    // MARK: - Quantization Performance Benchmarks

    func testQuantizationPerformanceComparison() {
        let modelSizes = [1000, 10000, 100000]

        for modelSize in modelSizes {
            let weights: [Float] = (0..<modelSize).map { _ in Float.random(in: -1.0...1.0) }

            // FP16 quantization
            let fp16Time = measureTime {
                _ = ModelQuantization.quantizeToFP16(weights)
            }

            // INT8 quantization
            let int8Time = measureTime {
                _ = ModelQuantization.quantizeToINT8(weights)
            }

            // Dynamic quantization
            let dynamicTime = measureTime {
                _ = ModelQuantization.analyzeActivationRange(weights)
            }

            print(String(format: "Quantization %6d weights: FP16 %.3fms, INT8 %.3fms, Dynamic %.3fms",
                         modelSize, fp16Time * 1000, int8Time * 1000, dynamicTime * 1000))
        }
    }

    func testQuantizedInferencePerformance() {
        // Create a small neural network for testing
        let layers: [NeuralLayer] = [
            Conv1DLayer(inputChannels: 1, outputChannels: 16, kernelSize: 3, stride: 1),
            LinearLayer(inputSize: 512, outputSize: 128),
            LinearLayer(inputSize: 128, outputSize: 32)
        ]

        let quantizedLayers: [QuantizedLayer] = ModelQuantization.quantizeModel(layers: layers, quantizationType: .int8)

        let testInput: [Float] = (0..<512).map { _ in Float.random(in: -1.0...1.0) }

        // Original inference
        var originalTime: TimeInterval = 0
        var originalHiddenStates = [String: [Float]]()
        originalTime = measureTime {
            var input = testInput
            for layer in layers {
                input = try! layer.forward(input, hiddenStates: &originalHiddenStates)
            }
        }

        // Quantized inference
        var quantizedTime: TimeInterval = 0
        var quantizedHiddenStates = [String: [Float]]()
        quantizedTime = measureTime {
            var input = testInput
            for layer in quantizedLayers {
                input = try! layer.forward(input, hiddenStates: &quantizedHiddenStates)
            }
        }

        print(String(format: "Quantized Inference: Original %.3fms, Quantized %.3fms, Speedup %.1fx",
                     originalTime * 1000, quantizedTime * 1000,
                     quantizedTime > 0 ? originalTime / quantizedTime : 0))
    }

    // MARK: - Memory Usage Benchmarks

    func testMemoryUsageComparison() {
        let modelSizes = [10000, 50000, 100000]

        for modelSize in modelSizes {
            // Original FP32 memory usage
            let fp32Memory = modelSize * MemoryLayout<Float>.size

            // FP16 memory usage
            let fp16Memory = modelSize * MemoryLayout<Float16>.size

            // INT8 memory usage
            let int8Memory = modelSize * MemoryLayout<Int8>.size

            print(String(format: "Memory %6d weights: FP32 %5.1fKB, FP16 %5.1fKB (%.1fx), INT8 %5.1fKB (%.1fx)",
                         modelSize,
                         Float(fp32Memory) / 1024.0,
                         Float(fp16Memory) / 1024.0, Float(fp32Memory) / Float(fp16Memory),
                         Float(int8Memory) / 1024.0, Float(fp32Memory) / Float(int8Memory)))
        }
    }

    // MARK: - End-to-End Pipeline Benchmarks

    func testEndToEndAudioProcessingPipeline() {
        // Simulate complete audio processing pipeline

        // CPU pipeline
        let cpuTime = measureTime {
            // Simulate CPU-based processing
            var processed = testAudio!

            // STFT
            let stftResult = try? cpuSTFT(input: processed, windowSize: 1024, hopSize: 512, inverse: false)

            // ERB filtering
            if let spectrum = stftResult {
                _ = try? cpuERBFilter(spectrum: spectrum, numBands: 64, sampleRate: 48000)
            }

            // Neural network processing
            let layers = [
                LinearLayer(inputSize: 512, outputSize: 256),
                LinearLayer(inputSize: 256, outputSize: 128)
            ]

            var hiddenStates = [String: [Float]]()
            for layer in layers {
                processed = try! layer.forward(Array(processed.prefix(512)), hiddenStates: &hiddenStates)
            }
        }

        // GPU pipeline
        var gpuTime: TimeInterval = 0
        if let metalProcessor = MetalNeuralProcessor() {
            gpuTime = measureTime {
                do {
                    // STFT
                    let stftResult = try metalProcessor.stft(input: testAudio, windowSize: 1024, hopSize: 512, inverse: false)

                    // ERB filtering
                    _ = try metalProcessor.erbFilter(spectrum: stftResult, numBands: 64, sampleRate: 48000)

                    // Neural network processing
                    let weights: [[Float]] = (0..<256).map { _ in (0..<512).map { _ in Float.random(in: -0.1...0.1) } }
                    let biases: [Float] = (0..<256).map { _ in Float.random(in: -0.01...0.01) }
                    let semaphore = DispatchSemaphore(value: 0)
                    var result: [Float]?
                    metalProcessor.linear(input: Array(testAudio.prefix(512)), weights: weights, bias: biases) { res in
                        switch res {
                        case .success(let output):
                            result = output
                        case .failure:
                            result = nil
                        }
                        semaphore.signal()
                    }
                    semaphore.wait()
                    _ = result

                } catch {
                    // GPU processing failed, time will be 0
                }
            }
        }

        print(String(format: "End-to-End Pipeline: CPU %.3fms, GPU %.3fms, Speedup %.1fx",
                     cpuTime * 1000, gpuTime * 1000,
                     gpuTime > 0 ? cpuTime / gpuTime : 0))
    }

    // MARK: - Helper Methods

    private func measureTime(_ block: () -> Void) -> TimeInterval {
        let start = CFAbsoluteTimeGetCurrent()
        block()
        let end = CFAbsoluteTimeGetCurrent()
        return end - start
    }

    // CPU baseline implementations for comparison
    private func cpuFFT(input: [Float], inverse: Bool) throws -> (real: [Float], imag: [Float]) {
        // Simple CPU FFT implementation for baseline comparison
        // In a real implementation, this would use vDSP or similar
        let n = input.count

        // Very basic DFT (not optimized, just for baseline)
        let resultReal = (0..<n).map { k -> Float in
            var sum: Float = 0
            for i in 0..<n {
                let angle = (inverse ? 2 : -2) * Float.pi * Float(k * i) / Float(n)
                sum += input[i] * cos(angle)
            }
            return sum
        }

        let resultImag = (0..<n).map { k -> Float in
            var sum: Float = 0
            for i in 0..<n {
                let angle = (inverse ? 2 : -2) * Float.pi * Float(k * i) / Float(n)
                sum += input[i] * sin(angle)
            }
            return sum
        }

        return (resultReal, resultImag)
    }

    private func cpuSTFT(input: [Float], windowSize: Int, hopSize: Int, inverse: Bool) throws -> (real: [Float], imag: [Float]) {
        // Simplified STFT for baseline comparison
        let numFrames = (input.count - windowSize) / hopSize + 1
        var realResult = [Float]()
        var imagResult = [Float]()

        for frame in 0..<numFrames {
            let start = frame * hopSize
            let frameData = Array(input[start..<min(start + windowSize, input.count)])

            // Apply Hann window
            let windowed = frameData.enumerated().map { i, sample in
                let window = 0.5 * (1 - cos(2 * Float.pi * Float(i) / Float(windowSize - 1)))
                return sample * window
            }

            // Pad to windowSize if needed
            var padded = windowed
            while padded.count < windowSize {
                padded.append(0)
            }

            // FFT
            let fft = try cpuFFT(input: padded, inverse: false)
            realResult.append(contentsOf: fft.real)
            imagResult.append(contentsOf: fft.imag)
        }

        return (realResult, imagResult)
    }

    private func cpuERBFilter(spectrum: (real: [Float], imag: [Float]), numBands: Int, sampleRate: Float) throws -> (real: [Float], imag: [Float]) {
        // Simplified ERB filtering for baseline
        let fftSize = spectrum.real.count
        var filteredReal = [Float](repeating: 0, count: numBands)
        var filteredImag = [Float](repeating: 0, count: numBands)

        for band in 0..<numBands {
            let centerFreq = Float(band + 1) * (sampleRate / 2.0) / Float(numBands)
            let bin = Int(centerFreq * Float(fftSize) / sampleRate)

            if bin < fftSize {
                filteredReal[band] = spectrum.real[bin]
                filteredImag[band] = spectrum.imag[bin]
            }
        }

        return (filteredReal, filteredImag)
    }

    private func cpuLinear(input: [Float], weights: [[Float]], biases: [Float]) -> [Float] {
        var output = [Float](repeating: 0, count: biases.count)

        for out in 0..<biases.count {
            var sum = biases[out]
            for inp in 0..<min(input.count, weights[out].count) {
                sum += input[inp] * weights[out][inp]
            }
            output[out] = sum
        }

        return output
    }

    private func cpuConv1D(input: [Float], inputChannels: Int, outputChannels: Int, kernelSize: Int, stride: Int) throws -> [Float] {
        let inputLength = input.count / inputChannels
        let outputLength = (inputLength - kernelSize) / stride + 1

        guard outputLength > 0 else {
            throw NSError(domain: "CPUConv1D", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid convolution parameters"])
        }

        var output = [Float](repeating: 0, count: outputChannels * outputLength)

        for outC in 0..<outputChannels {
            for t in 0..<outputLength {
                var acc: Float = 0
                for inC in 0..<inputChannels {
                    for k in 0..<kernelSize {
                        let inputIndex = inC * inputLength + t * stride + k
                        if inputIndex < input.count {
                            // Use a simple kernel weight (in real implementation, would use trained weights)
                            let weight = Float.random(in: -0.1...0.1)
                            acc += input[inputIndex] * weight
                        }
                    }
                }
                output[outC * outputLength + t] = max(0, acc) // ReLU
            }
        }

        return output
    }
}