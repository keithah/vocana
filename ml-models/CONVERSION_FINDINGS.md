# DeepFilterNet Core ML Conversion Findings

## Summary

DeepFilterNet3 is a complex multi-stage model that **cannot be directly converted to Core ML** due to:

1. **Multi-model architecture**: The model is split into 3 ONNX models (encoder, erb_decoder, df_decoder)
2. **Custom preprocessing**: Requires Rust library (`libdf`) for STFT and ERB feature extraction
3. **Complex operations**: Uses deep filtering with custom operations not supported in Core ML

## Model Architecture

```
Raw Audio (48kHz)
    ↓
[libdf STFT + ERB extraction]
    ↓
feat_erb: [1, 1, S, 32]   # ERB features
feat_spec: [1, 2, S, 96]  # Spectral features
    ↓
[enc.onnx - Encoder]
    ↓
e0, e1, e2, e3, emb, c0, lsnr  # Intermediate states
    ↓                       ↓
[erb_dec.onnx]    [df_dec.onnx]
    ↓                       ↓
mask                   coefs (deep filtering)
    ↓                       ↓
[Apply mask & filtering]
    ↓
[libdf ISTFT]
    ↓
Enhanced Audio
```

## Model Parameters

- Sample rate: 48,000 Hz
- FFT size: 960
- Hop size: 480 (50% overlap)
- ERB bands: 32
- DF bands: 96
- Frame duration: 10ms (480 samples)
- Latency budget: ~15ms

## Options Moving Forward

### Option 1: ONNX Runtime (RECOMMENDED)
**Pros:**
- ✅ Models already available in ONNX format
- ✅ ONNX Runtime supports macOS
- ✅ Can implement STFT/ERB in Swift using Accelerate framework
- ✅ Good performance on Apple Silicon

**Cons:**
- ⚠️ Need to port Rust STFT/ERB code to Swift
- ⚠️ Multi-model inference pipeline more complex

**Estimated effort:** 3-5 days

### Option 2: Simpler Alternative Model
Use a different noise suppression model that:
- Is end-to-end (audio in → audio out)
- Has existing Core ML support
- Meets latency requirements (<15ms)

**Candidates:**
- RNNoise (classical approach, very lightweight)
- Facebook's Demucs (source separation, might be overkill)
- Custom lightweight U-Net model trained on noise reduction

**Estimated effort:** 2-7 days (depending on model quality requirements)

### Option 3: Use macOS Built-in Voice Processing
**Pros:**
- ✅ Zero implementation time
- ✅ Optimized by Apple
- ✅ System-level integration

**Cons:**
- ⚠️ Limited control over noise suppression aggressiveness
- ⚠️ May not be as effective as DeepFilterNet

**Estimated effort:** 1 day

## Recommendation

**Short-term (MVP):** Option 3 - Use macOS voice processing to validate the app concept
**Long-term (v1.0):** Option 1 - Implement ONNX Runtime with custom STFT/ERB

This allows us to:
1. Ship a working product quickly (1-2 days)
2. Validate the menu bar UX and settings
3. Test real-world latency and performance
4. Plan proper ML integration once we have users

## Next Steps

1. ✅ Document findings (this file)
2. ⬜ Implement macOS voice processing in AudioEngine
3. ⬜ Test latency and quality
4. ⬜ Create ONNX integration plan (separate issue)
5. ⬜ Implement Swift STFT/ERB for ONNX models (future)

## Files & Resources

- ONNX models: `ml-models/pretrained/tmp/export/*.onnx`
- PyTorch checkpoint: `ml-models/pretrained/DeepFilterNet3/checkpoints/model_120.ckpt.best`
- Config: `ml-models/pretrained/DeepFilterNet3/config.ini`
- DeepFilterNet repo: `ml-models/DeepFilterNet/`

## References

- [DeepFilterNet Paper](https://arxiv.org/abs/2305.08227)
- [ONNX Runtime macOS](https://onnxruntime.ai/docs/get-started/with-python.html)
- [Apple Accelerate vDSP](https://developer.apple.com/documentation/accelerate/vdsp)
- [AVAudioEngine Voice Processing](https://developer.apple.com/documentation/avfaudio/audio_engine/audio_units/using_voice_processing)
