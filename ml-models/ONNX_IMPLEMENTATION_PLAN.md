# ONNX/DeepFilterNet Implementation Plan

## Overview
Implement DeepFilterNet3 noise cancellation using ONNX Runtime with Swift-based signal processing.

**Timeline:** 5 days  
**Branch:** feature/onnx-deepfilternet  
**Issue:** #21

---

## Phase 1: Signal Processing (Days 1-2)

### Task 1.1: STFT Implementation (Day 1 Morning)
**File:** `Sources/Vocana/ML/SignalProcessing.swift`

**Requirements:**
- Sample rate: 48kHz
- FFT size: 960
- Hop size: 480 (50% overlap)
- Window: Hann window
- Output: Complex spectrogram [C, T, F]

**Implementation:**
```swift
import Accelerate

class STFT {
    private let fftSize: Int = 960
    private let hopSize: Int = 480
    private var fftSetup: vDSP_DFT_Setup?
    private var window: [Float]
    
    func transform(_ audio: [Float]) -> DSPSplitComplex
    func inverse(_ spectrogram: DSPSplitComplex) -> [Float]
}
```

**Reference:** `libdf` STFT implementation in Rust

**Testing:**
- Unit test with sine wave
- Compare against known FFT results
- Verify perfect reconstruction (STFT → ISTFT)

---

### Task 1.2: ERB Feature Extraction (Day 1 Afternoon)
**File:** `Sources/Vocana/ML/ERBFeatures.swift`

**Requirements:**
- ERB bands: 32
- ERB filterbank from libdf
- Unit normalization with alpha
- Output shape: [1, 1, T, 32]

**Implementation:**
```swift
class ERBFeatures {
    private let numBands: Int = 32
    private var erbFilterbank: [[Float]]
    
    func extract(spectrogram: DSPSplitComplex) -> [Float]
    func normalize(_ features: [Float], alpha: Float) -> [Float]
}
```

**Reference:** `libdf erb()` and `erb_norm()` functions

**Testing:**
- Test filterbank generation
- Test against known ERB values
- Verify output shape

---

### Task 1.3: Spectral Features (Day 2 Morning)
**File:** `Sources/Vocana/ML/SpectralFeatures.swift`

**Requirements:**
- DF bands: 96 (first 96 frequency bins)
- Unit normalization
- Real/imaginary to 2-channel format
- Output shape: [1, 2, T, 96]

**Implementation:**
```swift
class SpectralFeatures {
    private let dfBands: Int = 96
    
    func extract(spectrogram: DSPSplitComplex) -> [[Float]]
    func toRealImagFormat(_ spec: DSPSplitComplex) -> [[Float]]
}
```

**Testing:**
- Verify first 96 bins extracted
- Test real/imag format conversion
- Validate output shape

---

### Task 1.4: Integration & Testing (Day 2 Afternoon)
**File:** `Tests/VocanaTests/SignalProcessingTests.swift`

**Tests:**
- STFT perfect reconstruction
- ERB features match reference
- Spectral features correct shape
- End-to-end: Audio → Features → Audio

---

## Phase 2: ONNX Runtime Integration (Days 3-4)

### Task 2.1: ONNX Runtime Setup (Day 3 Morning)
**Dependencies:**
- ONNX Runtime C API (via SPM or manual integration)
- Model files bundled in Resources/

**File:** `Package.swift`
```swift
.package(url: "https://github.com/microsoft/onnxruntime-swift", .branch("main"))
```

**Model Files:**
- Copy `ml-models/pretrained/tmp/export/*.onnx` to `Resources/Models/`
- enc.onnx (encoder)
- erb_dec.onnx (ERB decoder)
- df_dec.onnx (deep filtering decoder)

---

### Task 2.2: ONNX Model Wrapper (Day 3 Afternoon)
**File:** `Sources/Vocana/ML/ONNXModel.swift`

**Requirements:**
- Load ONNX models from bundle
- Create inference sessions
- Run inference with input tensors
- Return output tensors

**Implementation:**
```swift
import onnxruntime_objc

class ONNXModel {
    private var session: ORTSession?
    
    init(modelPath: String) throws
    func infer(inputs: [String: ORTValue]) throws -> [String: ORTValue]
    deinit
}
```

**Testing:**
- Test model loading
- Test inference with dummy data
- Verify output shapes match expectations

---

### Task 2.3: DeepFilterNet Pipeline (Day 4)
**File:** `Sources/Vocana/ML/DeepFilterNet.swift`

**Requirements:**
- Orchestrate 3-model inference
- Apply deep filtering
- Handle state management

**Pipeline:**
```
Audio [T]
  ↓
STFT → Complex Spectrogram [C, T, F]
  ↓
ERB Features [1, 1, T, 32]  +  Spectral Features [1, 2, T, 96]
  ↓
Encoder (enc.onnx)
  ↓
States: e0, e1, e2, e3, emb, c0, lsnr
  ↓                              ↓
ERB Decoder (erb_dec.onnx)    DF Decoder (df_dec.onnx)
  ↓                              ↓
Mask [1, 1, T, F]             Coefs [T, 96, 10]
  ↓
Apply Filtering (mask * spec, coefs)
  ↓
ISTFT → Enhanced Audio [T]
```

**Implementation:**
```swift
class DeepFilterNet {
    private let stft: STFT
    private let erbFeatures: ERBFeatures
    private let specFeatures: SpectralFeatures
    private let encoder: ONNXModel
    private let erbDecoder: ONNXModel
    private let dfDecoder: ONNXModel
    
    func process(audio: [Float]) -> [Float]
}
```

---

## Phase 3: Real-time Integration (Day 4-5)

### Task 3.1: AudioEngine Integration (Day 4 Evening)
**File:** `Sources/Vocana/Models/AudioEngine.swift`

**Changes:**
- Replace simulation with DeepFilterNet
- Process audio buffers in real-time
- Handle buffering (accumulate to frame size)

**Implementation:**
```swift
class AudioEngine {
    private var denoiser: DeepFilterNet?
    private var audioBuffer: [Float] = []
    private let frameSize = 480 // 10ms at 48kHz
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        // Accumulate samples
        audioBuffer.append(contentsOf: samples)
        
        // Process when we have enough
        if audioBuffer.count >= frameSize {
            let frame = Array(audioBuffer[..<frameSize])
            let enhanced = denoiser?.process(audio: frame)
            audioBuffer.removeFirst(frameSize)
            
            // Update UI with levels
        }
    }
}
```

---

### Task 3.2: Performance Optimization (Day 5 Morning)
**Focus Areas:**
- Minimize allocations (reuse buffers)
- Profile with Instruments
- Optimize ONNX session config
- Measure latency

**Targets:**
- Latency: <15ms
- CPU: <10%
- Memory: <200MB

---

### Task 3.3: UI Updates (Day 5 Afternoon)
**File:** `Sources/Vocana/ContentView.swift`

**Changes:**
- Show "ML Processing Active" status
- Display processing latency
- Add quality indicator

---

## Phase 4: Testing & Polish (Day 5 Evening)

### Task 4.1: End-to-End Testing
- Test with various noise types
- Benchmark on different hardware
- Stress test with long sessions

### Task 4.2: Error Handling
- Model loading failures
- ONNX runtime errors
- Memory pressure handling

---

## File Structure

```
Sources/Vocana/ML/
├── SignalProcessing.swift     # STFT/ISTFT
├── ERBFeatures.swift          # ERB extraction
├── SpectralFeatures.swift     # Spectral features
├── ONNXModel.swift            # ONNX wrapper
├── DeepFilterNet.swift        # Main pipeline
└── DeepFiltering.swift        # Coefficient application

Resources/Models/
├── enc.onnx
├── erb_dec.onnx
└── df_dec.onnx

Tests/VocanaTests/ML/
├── SignalProcessingTests.swift
├── ERBFeaturesTests.swift
├── ONNXModelTests.swift
└── DeepFilterNetTests.swift
```

---

## Dependencies

**Swift Packages:**
- ONNX Runtime Swift (if available) OR manual C API integration

**System Frameworks:**
- Accelerate (vDSP for FFT)
- AVFoundation (audio I/O)
- Foundation

---

## Success Criteria

- [ ] STFT/ISTFT perfect reconstruction (<0.001 error)
- [ ] ERB features match libdf reference
- [ ] All 3 ONNX models load successfully
- [ ] Multi-model inference pipeline works
- [ ] Real-time processing <15ms latency
- [ ] Noise reduction quality >80% (subjective)
- [ ] All tests passing
- [ ] No memory leaks
- [ ] Works on M1/M2/M3/M4

---

## References

- DeepFilterNet paper: https://arxiv.org/abs/2305.08227
- libdf implementation: `ml-models/DeepFilterNet/libDF/`
- ONNX models: `ml-models/pretrained/tmp/export/`
- Config: `ml-models/pretrained/DeepFilterNet3/config.ini`

---

## Next Steps

1. ✅ Create this plan
2. ⬜ Start Day 1: STFT implementation
3. ⬜ Daily progress updates in Issue #21
4. ⬜ Code reviews after each phase
5. ⬜ Ship when all criteria met

Let's build! 🚀
