# ONNX Runtime Setup Guide

This guide explains how to integrate ONNX Runtime with Vocana for real DeepFilterNet3 inference.

## Current Status

✅ **Mock Implementation**: Fully functional pipeline with simulated ONNX inference  
⬜ **Native Implementation**: Ready for ONNX Runtime integration (follow steps below)

## Quick Start (Mock Mode)

The project currently runs in **mock mode** by default, which allows full development and testing without ONNX Runtime:

```swift
// This works out of the box
let denoiser = try DeepFilterNet(modelsDirectory: "Resources/Models")
let enhanced = try denoiser.process(audio: audioSamples)
```

Mock mode:
- Returns realistic output shapes
- Fast execution (~2-5ms)
- Perfect for pipeline development and testing
- No external dependencies

## Installing ONNX Runtime (Native Mode)

To use real DeepFilterNet3 models with actual noise cancellation:

### Step 1: Download ONNX Runtime

```bash
cd /path/to/Vocana

# Download ONNX Runtime (Universal binary for macOS)
curl -L https://github.com/microsoft/onnxruntime/releases/download/v1.23.2/onnxruntime-osx-universal2-1.23.2.tgz \
  -o onnxruntime.tgz

# Extract
tar -xzf onnxruntime.tgz

# Move to Frameworks directory
mkdir -p Frameworks/onnxruntime
mv onnxruntime-osx-universal2-1.23.2/* Frameworks/onnxruntime/

# Verify installation
ls -lh Frameworks/onnxruntime/lib/libonnxruntime.dylib
```

### Step 2: Update Package.swift

Add linker settings to link against ONNX Runtime:

```swift
// In Package.swift
targets: [
    .executableTarget(
        name: "Vocana",
        dependencies: [],
        linkerSettings: [
            .unsafeFlags(["-L", "Frameworks/onnxruntime/lib"]),
            .linkedLibrary("onnxruntime")
        ]
    ),
    // ... rest of targets
]
```

### Step 3: Implement Native ONNX Runtime Bridge

The C bridge header is already created at `Sources/Vocana/ML/ONNXRuntimeBridge.h`.

Create the implementation file `Sources/Vocana/ML/ONNXRuntimeBridge.c`:

```c
#include "ONNXRuntimeBridge.h"
#include <onnxruntime_c_api.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Global ONNX Runtime API
static const OrtApi* g_ort_api = NULL;

// Initialize API
static void ensure_api_initialized() {
    if (g_ort_api == NULL) {
        g_ort_api = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    }
}

// Create environment
ONNXStatus ONNXCreateEnv(int log_level, const char* env_name, ONNXEnv** out_env) {
    ensure_api_initialized();
    
    OrtEnv* env = NULL;
    OrtStatus* status = g_ort_api->CreateEnv(
        (OrtLoggingLevel)log_level,
        env_name,
        &env
    );
    
    if (status != NULL) {
        g_ort_api->ReleaseStatus(status);
        return ONNX_STATUS_ERROR;
    }
    
    *out_env = (ONNXEnv*)env;
    return ONNX_STATUS_OK;
}

// ... implement other functions
```

See the header file for complete function signatures.

### Step 4: Complete NativeInferenceSession

Update `Sources/Vocana/ML/ONNXRuntimeWrapper.swift`:

```swift
class NativeInferenceSession: InferenceSession {
    private var env: OpaquePointer?
    private var session: OpaquePointer?
    private let modelPath: String
    
    var inputNames: [String] = []
    var outputNames: [String] = []
    
    init(modelPath: String, options: SessionOptions) throws {
        self.modelPath = modelPath
        
        // Create environment
        var envPtr: OpaquePointer?
        let status = ONNXCreateEnv(2, "Vocana", &envPtr)
        guard status == ONNX_STATUS_OK else {
            throw ONNXError.runtimeError("Failed to create ONNX environment")
        }
        self.env = envPtr
        
        // Create session
        var sessionOptions: OpaquePointer?
        ONNXCreateSessionOptions(&sessionOptions)
        ONNXSetIntraOpNumThreads(sessionOptions, Int32(options.intraOpNumThreads))
        ONNXSetGraphOptimizationLevel(sessionOptions, Int32(options.graphOptimizationLevel.rawValue))
        
        var sessionPtr: OpaquePointer?
        ONNXCreateSession(envPtr, modelPath, sessionOptions, &sessionPtr)
        self.session = sessionPtr
        
        // Query input/output names
        var inputCount: size_t = 0
        ONNXSessionGetInputCount(sessionPtr, &inputCount)
        // ... populate inputNames and outputNames
    }
    
    func run(inputs: [String: TensorData]) throws -> [String: TensorData] {
        // Convert inputs to OrtValue
        // Call ONNXSessionRun
        // Convert outputs back to TensorData
        // See implementation details in ONNXRuntimeBridge.h
    }
}
```

### Step 5: Enable Native Mode

Once implementation is complete:

```swift
// Use native ONNX Runtime
let model = try ONNXModel(modelPath: "enc.onnx", useNative: true)

// Or at the DeepFilterNet level
let denoiser = try DeepFilterNet(
    modelsDirectory: "Resources/Models",
    useNative: true
)
```

The wrapper will automatically:
- Detect if ONNX Runtime library is available
- Fall back to mock mode if not found
- Log which mode is being used

## Verification

Test that ONNX Runtime is working:

```bash
# Build
swift build

# Run tests
swift test

# Check for native mode messages
# Expected output:
# ✓ ONNX Runtime native library detected
# ✓ Loaded ONNX model: enc
```

## Performance Targets

| Mode | Latency | Memory | CPU | Accuracy |
|------|---------|--------|-----|----------|
| Mock | 2-5ms | 100MB | <5% | N/A (simulated) |
| Native (CPU) | <15ms | 200-300MB | 10-20% | Full DeepFilterNet3 |
| Native (CoreML) | <10ms | 250-350MB | 5-10% | Full DeepFilterNet3 |

## Optimization Options

### 1. CoreML Execution Provider (macOS GPU Acceleration)

```swift
// TODO: Add CoreML provider when creating session
// This will use Apple Neural Engine on M1/M2/M3
```

### 2. Memory Optimization

```swift
let options = SessionOptions(
    intraOpNumThreads: 4,
    graphOptimizationLevel: .all,
    enableCPUMemArena: true,    // Faster allocation
    enableMemPattern: true       // Reduce memory fragmentation
)
```

### 3. Session Reuse

```swift
// DON'T: Create new session for each inference
for audio in audioChunks {
    let model = try ONNXModel(...)  // ❌ Expensive!
    _ = try model.infer(...)
}

// DO: Reuse session
let model = try ONNXModel(...)
for audio in audioChunks {
    _ = try model.infer(...)        // ✅ Fast!
}
```

## Troubleshooting

### Library Not Found

```
⚠️  ONNX Runtime not found - using mock implementation
```

**Solution**: Verify `Frameworks/onnxruntime/lib/libonnxruntime.dylib` exists

### Linker Errors

```
Undefined symbols for architecture arm64:
  "_ONNXCreateEnv"
```

**Solution**: 
1. Check Package.swift has correct linker settings
2. Ensure ONNXRuntimeBridge.c is compiled
3. Verify library path is correct

### Runtime Errors

```
dyld: Library not loaded: @rpath/libonnxruntime.dylib
```

**Solution**: Add runtime library path:

```bash
export DYLD_LIBRARY_PATH=Frameworks/onnxruntime/lib:$DYLD_LIBRARY_PATH
swift run
```

Or set in Xcode: Build Settings → Runpath Search Paths → Add `@executable_path/../Frameworks/onnxruntime/lib`

## Alternative: CocoaPods (iOS/macOS)

For iOS deployment, use CocoaPods:

```ruby
# Podfile
platform :ios, '14.0'

target 'Vocana' do
  use_frameworks!
  pod 'onnxruntime-objc', '~> 1.23.0'
end
```

Then use the Objective-C wrapper instead of C API.

## Next Steps

1. ✅ Mock implementation working
2. ⬜ Implement NativeInferenceSession
3. ⬜ Test with real models
4. ⬜ Benchmark performance
5. ⬜ Optimize for real-time use
6. ⬜ Add CoreML provider

## Resources

- [ONNX Runtime Documentation](https://onnxruntime.ai/docs/)
- [C API Reference](https://onnxruntime.ai/docs/api/c/)
- [macOS Integration Guide](https://onnxruntime.ai/docs/tutorials/mobile/)
- [DeepFilterNet3 Paper](https://arxiv.org/abs/2305.08227)

## Status

**Current**: Mock implementation fully functional ✅  
**Next**: Implement native ONNX Runtime bridge  
**Timeline**: Day 4-5 of implementation plan
