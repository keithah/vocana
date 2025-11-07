# Vocana Development Guide

## Project Setup

### System Requirements

- **macOS**: 12.0 or later (Apple Silicon only)
- **Xcode**: 15.0 or later
- **Swift**: 5.9 or later
- **CPU**: Apple Silicon (M1, M2, M3, M4, etc.)

### Building the Project

#### Using Swift Package Manager

```bash
# Build the executable
swift build

# Run the app
swift build && open .build/debug/Vocana

# Run tests
swift test

# Build with optimizations
swift build -c release
```

#### Using Xcode

```bash
# Generate Xcode project (if needed)
swift package generate-xcodeproj

# Or open with Xcode
xed .
```

### Project Structure

```
Vocana/
├── Sources/Vocana/
│   ├── VocanaApp.swift           # Main app entry point with AppDelegate
│   ├── ContentView.swift          # Menu bar popup UI
│   ├── Components/                # Reusable SwiftUI components
│   │   ├── AudioLevelsView.swift
│   │   ├── HeaderView.swift
│   │   ├── PowerToggleView.swift
│   │   ├── ProgressBar.swift
│   │   ├── SensitivityControlView.swift
│   │   └── SettingsButtonView.swift
│   ├── Models/                    # Data models and core logic
│   │   ├── AppConstants.swift
│   │   ├── AppSettings.swift
│   │   ├── AudioEngine.swift
│   │   ├── AudioSessionManager.swift
│   │   ├── AudioBufferManager.swift
│   │   ├── AudioLevelController.swift
│   │   └── MLAudioProcessor.swift
│   └── ML/                        # Machine learning models and processing
│       ├── DeepFilterNet.swift
│       ├── ONNXModel.swift
│       ├── SignalProcessing.swift
│       ├── SpectralFeatures.swift
│       └── ERBFeatures.swift
├── Tests/VocanaTests/             # Unit and integration tests
├── Resources/Models/              # ML model files
└── Package.swift                  # Swift Package manifest
```

## Architecture

### Core Components

#### 1. Audio Engine (`AudioEngine.swift`)
- Manages audio capture, processing, and playback
- Handles real-time audio buffering with circular buffers
- Implements circuit breaker pattern for memory protection
- Provides audio level monitoring for UI updates

#### 2. ML Audio Processor (`MLAudioProcessor.swift`)
- Applies DeepFilterNet for real-time noise cancellation
- Manages ONNX model inference
- Handles audio feature extraction (Spectral and ERB)
- Ensures thread-safe ML processing

#### 3. Signal Processing (`SignalProcessing.swift`)
- Implements STFT (Short-Time Fourier Transform) for audio analysis
- Applies Hann windowing with COLA (Constant Overlap-Add) reconstruction
- Provides crossfading for smooth audio transitions

#### 4. App Delegate (`VocanaApp.swift`)
- Creates and manages menu bar status item
- Handles popover for menu bar popup
- Manages app lifecycle and cleanup

### Threading Model

- **MainActor**: UI updates and AppDelegate methods
- **audioProcessingQueue**: Real-time audio processing (userInteractive priority)
- **mlProcessingQueue**: ML inference (userInteractive priority)
- **CircuitBreakerQueue**: Memory monitoring and protective actions

## Development Workflow

### Adding New Features

1. Create new files in appropriate folder (Components, Models, ML, etc.)
2. Follow existing naming conventions
3. Add appropriate documentation
4. Write unit tests
5. Test on real Apple Silicon hardware when possible

### Testing

```bash
# Run all tests
swift test

# Run specific test
swift test VocanaTests.AudioEngineTests

# Run tests with verbose output
swift test --verbose
```

### Code Style

- Follow [Swift API Design Guidelines](https://swift.org/documentation/api-design-guidelines/)
- Use `@MainActor` annotation for UI code
- Document public APIs with comments
- Use clear, descriptive variable names

## Performance Considerations

### Audio Processing Latency
- Target: 0.62ms latency
- Current: Achieved with optimized QoS and buffer sizes

### Memory Usage
- Menu bar UI: <50MB
- ML models: ~150MB (loaded on demand)
- Audio buffers: ~500KB (1 second at 48kHz)

### CPU Usage
- Idle: <0.5%
- Active noise cancellation: <15%
- UI updates: <2%

## Debugging

### Audio Issues
- Check `AudioEngine.startSimulation()` for test audio generation
- Monitor `audioEngine.currentLevels` in ContentView
- Verify audio session category in `AudioSessionManager`

### ML Issues
- Check `MLAudioProcessor.loadModels()` for model loading errors
- Monitor `DeepFilterNet.inferenceTime` for performance
- Verify ONNX model files in `Resources/Models/`

### Memory Issues
- Monitor `AudioBufferManager.currentBufferSize`
- Check circuit breaker triggers: `audioEngine.maxConsecutiveOverflows`
- Watch for ML model loading failures

## Next Steps

### Issue #7: Menu Bar Interface Implementation
- Enhance visual design
- Add real-time audio level visualization
- Implement keyboard shortcuts

### Issue #8: Settings and Preferences Interface
- Create settings window
- Implement tabbed preferences
- Add persistence with UserDefaults

### Issue #9: App Lifecycle and System Integration
- Add launch at startup support
- Implement system integration features
- Add accessibility support

## Resources

- [Apple Silicon Optimization Guide](https://developer.apple.com/documentation/accelerate)
- [Core Audio Documentation](https://developer.apple.com/documentation/coreaudio)
- [SwiftUI Documentation](https://developer.apple.com/documentation/swiftui)
- [ONNX Runtime Swift](https://onnx.ai/)
