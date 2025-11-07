# DeepFilterNet Quick Reference Card

## One-Page Overview for Developers

---

## What is DeepFilterNet?

**Purpose**: State-of-the-art real-time speech enhancement for full-band audio (48kHz)  
**Method**: Two-stage deep filtering (ERB-scale + periodic components)  
**Status**: Production-ready, actively maintained (3.5k⭐ on GitHub)

---

## Key Specifications

| Aspect | Value |
|--------|-------|
| **Model Size** | 2.5M params (~3MB) |
| **Input Format** | 48kHz mono, float32/int16 |
| **Frame Size** | 480 samples (10ms) |
| **Latency** | ~20ms total (10ms model + STFT) |
| **Quality** | PESQ 3.4-3.5 (excellent) |
| **Speed (CPU)** | 25x real-time (RTF 0.04) |

---

## Apple Silicon Performance

```
M1:  50-100x real-time | 10-15ms | 0.1-0.3W
M2:  100-200x real-time | 5-10ms  | 0.05-0.2W
M3:  100-200x real-time | 5-10ms  | 0.05-0.2W
M4:  140-330x real-time | 3-7ms   | 0.03-0.15W
```

---

## Conversion Quick Start

### 1. Install Dependencies
```bash
pip install coremltools>=8.0 torch deepfilternet
```

### 2. Convert Model
```python
import coremltools as ct
from DeepFilterNet import DeepFilterNet

# Load & trace
model = DeepFilterNet.from_pretrained('DeepFilterNet2')
traced = torch.jit.trace(model, torch.randn(1, 1, 480))

# Convert
mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="audio", shape=(1,1,480))],
    compute_precision=ct.precision.FLOAT16,
    minimum_deployment_target=ct.target.macOS13
)

mlmodel.save("DeepFilterNet2.mlpackage")
```

### 3. Validate
```python
# Check accuracy
psnr = validate_conversion(model, mlmodel)
assert psnr > 60  # Should be > 60 dB
```

---

## Integration (Swift)

```swift
import CoreML

class NoiseReducer {
    let model: DeepFilterNet2_FP16
    
    init() throws {
        model = try DeepFilterNet2_FP16()
    }
    
    func process(_ audio: [Float]) throws -> [Float] {
        let input = try MLMultiArray(audio, shape: [1,1,480])
        let output = try model.prediction(audio_input: input)
        return output.audio_output.toArray()
    }
}
```

---

## Optimization Options

| Method | Impact | Trade-off |
|--------|--------|-----------|
| **FP16** | Size -50%, Speed +20% | PESQ -0.01 ✅ |
| **INT8** | Size -73%, Speed +35% | PESQ -0.2 ⚠️ |
| **Prune 30%** | Size -30%, Speed +15% | PESQ -0.05 ✅ |

**Recommendation**: Start with FP16 (best quality/speed balance)

---

## Common Issues & Solutions

### Issue: Low ANE Utilization
**Solution**: Use channels-first format (B, C, 1, S), replace Linear with Conv2d

### Issue: Stateful Processing
**Solution**: Expose hidden states as inputs/outputs or use stateful models (macOS 14+)

### Issue: Complex Numbers
**Solution**: Decompose into real/imaginary operations

### Issue: First Inference Slow
**Solution**: Pre-warm model at app launch with dummy input

---

## Quality Metrics

```
Target vs Expected:
PESQ:  > 3.0  →  3.4-3.5  ✅
STOI:  > 0.85 →  0.90-0.93 ✅
SNR:   > 10dB →  12-18dB  ✅
```

---

## Performance Checklist

Before deploying:
- [ ] PSNR > 60 dB (conversion accuracy)
- [ ] Latency < 15ms on M1
- [ ] ANE utilization > 85%
- [ ] Memory < 10 MB
- [ ] PESQ > 3.0 on test set

---

## Troubleshooting

### Conversion Fails
1. Check coremltools version (need >= 8.0)
2. Verify model is in eval() mode
3. Use simpler example input for tracing

### Low Quality
1. Validate conversion with PSNR
2. Check for numerical precision issues
3. Test on diverse audio samples

### Slow Performance
1. Profile with Xcode Instruments
2. Check compute unit distribution
3. Verify ANE is being used

---

## Useful Commands

```bash
# Profile model
xcrun xctrace record --template 'Core ML' --launch YourApp

# Check model info
python -c "import coremltools as ct; m=ct.models.MLModel('model.mlpackage'); print(m)"

# Benchmark
python scripts/benchmark_latency.py model.mlpackage
```

---

## Resources

| Resource | Link |
|----------|------|
| **Full Report** | [deepfilternet_research_report.md](./deepfilternet_research_report.md) |
| **Summary** | [deepfilternet_summary.md](./deepfilternet_summary.md) |
| **GitHub** | [github.com/Rikorose/DeepFilterNet](https://github.com/Rikorose/DeepFilterNet) |
| **Papers** | [arXiv:2205.05474](https://arxiv.org/abs/2205.05474) |
| **Core ML** | [coremltools.readme.io](https://coremltools.readme.io/) |

---

## Decision Matrix

| Criteria | DeepFilterNet2 | Alternative |
|----------|----------------|-------------|
| Quality | ⭐⭐⭐⭐⭐ | RNNoise ⭐⭐⭐ |
| Speed | ⭐⭐⭐⭐ | RNNoise ⭐⭐⭐⭐⭐ |
| Size | ⭐⭐⭐⭐ | RNNoise ⭐⭐⭐⭐⭐ |
| ANE Support | ⭐⭐⭐⭐⭐ | RNNoise ⭐⭐⭐ |
| Full-band | ✅ | ❌ |
| Maintenance | ✅ | ⚠️ |

**Verdict**: DeepFilterNet2 best for Vocana's needs

---

## Quick Decision

**Should I use DeepFilterNet?**

✅ YES if you need:
- High-quality noise reduction
- Full-band audio (48kHz)
- Real-time processing
- On-device deployment
- Active support

❌ NO if you need:
- Smallest possible model (use RNNoise)
- Ultra-low latency (< 5ms)
- 16kHz audio (narrowband)

---

**Version**: 1.0 | **Date**: Nov 6, 2025 | **Issue**: #5
