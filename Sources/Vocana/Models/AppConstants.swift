import SwiftUI

struct AppConstants {
    // UI Dimensions
    static let popoverWidth: CGFloat = 300
    static let popoverHeight: CGFloat = 400
    static let progressBarHeight: CGFloat = 4
    static let cornerRadius: CGFloat = 2
    
    // Audio Simulation
    static let audioUpdateInterval: TimeInterval = 0.1
    static let inputLevelRange: ClosedRange<Double> = 0.2...0.8
    static let outputLevelRange: ClosedRange<Double> = 0.1...0.4
    static let levelDecayRate: Float = 0.9
    static let minimumLevelThreshold: Float = 0.01
    
    // Sensitivity
    static let sensitivityRange: ClosedRange<Double> = 0...1
    
    // Audio Processing
    static let sampleRate: Int = 48000 // Standard high-quality audio sampling rate
    
    // Buffer size of 1 second provides good balance between latency and robustness
    // Allows for ~2 seconds of processing latency before audio starts dropping
    static let maxAudioBufferSize: Int = 48000  // 1 second at 48kHz
    
    // Empirically tuned factor to bring RMS values (typically 0.01-0.1) to UI range (0-1)
    // Based on testing with typical microphone input levels
    static let rmsAmplificationFactor: Float = 10.0
    
    // ~35 minutes at 48kHz with 480 hop size - prevents DoS attacks via memory exhaustion
    // Calculated as: (35 * 60 * 48000) / 480 = 105,000 frames, rounded to 100,000
    static let maxSpectralFrames: Int = 100_000
    
    // 1 hour maximum audio length to prevent DoS attacks while allowing legitimate long recordings
    // At 48kHz with 32-bit float samples: 1 hour = ~172MB of audio data
    static let maxAudioProcessingSeconds: Int = 3600
    
    // Maximum memory allowed for ERB filterbank generation to prevent abuse
    // 500MB allows for very large models while preventing DoS attacks
    static let maxFilterbankMemoryMB: Int = 500
    
    // Duration in seconds to suspend audio capture when circuit breaker triggers
    // 150ms allows ML pipeline to catch up with minimal audio interruption
    static let circuitBreakerSuspensionSeconds: Double = 0.15
    
    // Default Log-SNR value for DeepFilterNet when no ML output is available
    // -10dB represents moderate noise suppression as a safe fallback
    static let defaultLSNRValue: Float = -10.0
    
    // Maximum amplification applied to processed audio (20dB) to prevent clipping
    // Corresponds to 10x voltage gain, balancing enhancement with distortion prevention
    static let maxProcessingGain: Float = 10.0
    
    // DeepFilterNet Configuration - matches original Python implementation
    static let fftSize: Int = 960      // 20ms frames at 48kHz, power-of-2 for efficient FFT
    static let hopSize: Int = 480      // 50% overlap for good time resolution and COLA reconstruction
    static let erbBands: Int = 32      // ERB bands covering 50Hz-20kHz for perceptual modeling
    static let dfBands: Int = 96       // Deep filtering applied to first 96 bins (0-4.8kHz where most speech energy is)
    static let dfOrder: Int = 5        // 5-tap FIR filter order - balances complexity vs quality
    
    // Audio Processing Constants
    static let crossfadeLengthSamples: Int = 480  // 10ms crossfade at 48kHz to prevent audio artifacts
    static let maxConsecutiveOverflows: Int = 10   // Circuit breaker threshold for sustained buffer overflows
    static let memoryPressureRecoveryDelaySeconds: Double = 30.0  // Timeout for forced memory pressure recovery
    static let memoryPressureCheckDelaySeconds: Double = 5.0     // Delay before checking memory pressure recovery
    
    // Audio Processing Constants
    // Human hearing starts ~20Hz but microphones/speakers below 50Hz add mostly noise
    // Also avoids low-frequency rumble and wind noise in real-world recordings
    static let minFrequency: Float = 50.0
    
     // Small positive value prevents log(0) in ERB calculations while being close to silence
    // Chosen to be well below typical speech/noise levels (>0.01) but above numerical precision issues
    static let defaultTensorValue: Float = 0.1
    
    // STFT Window Validation Constants
    // Minimum peak amplitude for Hann window to ensure COLA (Constant Overlap-Add) property
    // For vDSP_HANN_DENORM with 50% overlap, peak ~1.0, so 0.5 threshold ensures healthy windows
    // This prevents reconstruction artifacts that occur with amplitude too low
    static let minWindowPeakAmplitude: Float = 0.5
    
    // Reflection padding safety threshold
    // FFT size must be at least 2x smaller than maxAudioBufferSize to allow proper reflection padding
    // This prevents insufficient padding that could cause processing artifacts
    static let minBufferForReflectionRatio: Int = 2
    
    // Audio Input Validation Constants
    // Maximum absolute amplitude allowed in audio samples (prevents DoS via extreme values)
    // Typical audio is -1.0 to 1.0, values beyond this indicate either clipping or attack
    static let maxAudioAmplitude: Float = 2.0
    
    // Minimum audio amplitude threshold to process (below this is silence)
    // Prevents unnecessary ML processing on barely-audible content
    static let minAudioAmplitudeForProcessing: Float = 0.0001
    
    // Maximum RMS level allowed (corresponds to ~1.5x clipping prevention headroom)
    // Prevents processing of distorted/clipped audio that would give poor results
    static let maxRMSLevel: Float = 0.95
    
    // Accessibility
    static let accessibilityDescription = "Vocana"
    
    // Colors
    struct Colors {
        static let inputLevel = Color.blue
        static let outputLevel = Color.green
        static let backgroundOpacity = 0.3
    }
    
    // Fonts
    struct Fonts {
        static let title = Font.title2
        static let headline = Font.headline
        static let subheadline = Font.subheadline
        static let caption = Font.caption
    }
}