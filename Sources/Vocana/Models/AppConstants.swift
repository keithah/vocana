import SwiftUI

struct AppConstants {
    // UI Dimensions
    // 300px width provides optimal balance between content visibility and screen space usage
    // Fits comfortably on smallest MacBook Air (11") while maintaining readability
    static let popoverWidth: CGFloat = 300
    
    // 400px height accommodates all controls without scrolling on minimum window size
    // Includes header, main controls, audio visualization, sensitivity, and settings
    static let popoverHeight: CGFloat = 400
    
    // 4px height provides visible progress indication without overwhelming the UI
    // Standard for macOS progress bars and level indicators
    static let progressBarHeight: CGFloat = 4
    
    // 2px radius matches macOS design language for small UI elements
    // Provides subtle rounding without appearing overly rounded
    static let cornerRadius: CGFloat = 2
    
    // Audio Simulation
    // 0.1 second (100ms) interval provides smooth 10fps animation
    // Balances visual responsiveness with CPU usage and battery life
    static let audioUpdateInterval: TimeInterval = 0.1
    
    // Input range 20-80% simulates typical microphone input with headroom
    // 20% minimum prevents empty visualization during quiet passages
    // 80% maximum leaves headroom for unexpected loud sounds
    static let inputLevelRange: ClosedRange<Double> = 0.2...0.8
    
    // Output range 10-40% simulates processed audio with noise reduction
    // Lower range reflects typical noise reduction reducing overall level
    // 10% minimum ensures visibility even with heavy noise reduction
    static let outputLevelRange: ClosedRange<Double> = 0.1...0.4
    
    // 0.9 decay rate provides smooth exponential decay over ~1 second
    // Formula: level * 0.9^n where n is number of update intervals
    // At 10fps, reaches ~37% after 1 second (0.9^10)
    static let levelDecayRate: Float = 0.9
    
    // 0.01 (1%) threshold prevents flicker from near-zero audio levels
    // Below this level, audio is effectively silence for UI purposes
    // Matches typical noise floor of consumer microphones
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
     // 50ms provides better user experience while allowing ML pipeline to catch up
     static let circuitBreakerSuspensionSeconds: Double = 0.05
    
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
    
    // Audio Level UI Constants
    // 70% threshold chosen based on audio engineering best practices:
    // - Below 70%: Healthy signal level with headroom
    // - Above 70%: Risk of clipping, user should lower input gain
    static let levelWarningThreshold: Float = 0.7  
    
    // 0.3 smoothing factor provides responsive yet stable visualization:
    // - Higher values (0.5+) would be too jittery for voice
    // - Lower values (0.1-) would feel sluggish and unresponsive
    // - 0.3 gives ~130ms response time at 60fps update rate
    static let audioLevelSmoothingFactor: Float = 0.3
    
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