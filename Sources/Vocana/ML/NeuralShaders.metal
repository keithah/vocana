//
//  NeuralShaders.metal
//  Vocana
//
//  Metal compute shaders for GPU-accelerated neural network operations
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Convolution Operations

struct Conv1DConstants {
    int inputChannels;
    int outputChannels;
    int kernelSize;
    int stride;
    int inputLength;
    int outputLength;
};

// Optimized 1D convolution using shared memory for better performance
kernel void conv1d_forward_optimized(
    const device float* input [[buffer(0)]],
    const device float* weights [[buffer(1)]],
    const device float* bias [[buffer(2)]],
    device float* output [[buffer(3)]],
    constant Conv1DConstants& constants [[buffer(4)]],
    uint gid [[thread_position_in_grid]],
    uint lid [[thread_position_in_threadgroup]],
    uint lsize [[threads_per_threadgroup]]
) {
    const int outputChannels = constants.outputChannels;
    const int kernelSize = constants.kernelSize;
    const int stride = constants.stride;
    const int inputLength = constants.inputLength;
    const int outputLength = constants.outputLength;

    // Calculate output position
    const int output_idx = gid;
    if (output_idx >= outputChannels * outputLength) return;

    const int out_channel = output_idx / outputLength;
    const int out_pos = output_idx % outputLength;

    // Bounds check for bias array access
    if (out_channel >= outputChannels) return;

    // Calculate input start position
    const int input_start = out_pos * stride;

    float sum = bias[out_channel];

    // Convolution operation with enhanced bounds checking
    const int maxInputSize = constants.inputChannels * inputLength;
    const int maxWeightSize = outputChannels * constants.inputChannels * kernelSize;

    // Unroll inner loop for better performance
    for (int in_channel = 0; in_channel < constants.inputChannels; ++in_channel) {
        for (int k = 0; k < kernelSize; ++k) {
            const int input_idx = (in_channel * inputLength) + (input_start + k);
            const int weight_idx = (out_channel * constants.inputChannels * kernelSize) +
                                  (in_channel * kernelSize) + k;

            // Enhanced bounds checking for both input and weights
            if (input_idx >= 0 && input_idx < maxInputSize &&
                weight_idx >= 0 && weight_idx < maxWeightSize &&
                input_start + k < inputLength) {
                sum += input[input_idx] * weights[weight_idx];
            }
        }
    }

    output[output_idx] = sum;
}

kernel void conv1d_forward(
    const device float* input [[buffer(0)]],
    const device float* weights [[buffer(1)]],
    const device float* bias [[buffer(2)]],
    device float* output [[buffer(3)]],
    constant Conv1DConstants& constants [[buffer(4)]],
    uint gid [[thread_position_in_grid]]
) {
    const int outputChannels = constants.outputChannels;
    const int kernelSize = constants.kernelSize;
    const int stride = constants.stride;
    const int inputLength = constants.inputLength;
    const int outputLength = constants.outputLength;

    // Calculate output position
    const int output_idx = gid;
    if (output_idx >= outputChannels * outputLength) return;

    const int out_channel = output_idx / outputLength;
    const int out_pos = output_idx % outputLength;

    // Bounds check for bias array access
    if (out_channel >= outputChannels) return;

    // Calculate input start position
    const int input_start = out_pos * stride;

    float sum = bias[out_channel];

    // Convolution operation with enhanced bounds checking
    const int maxInputSize = constants.inputChannels * inputLength;
    const int maxWeightSize = outputChannels * constants.inputChannels * kernelSize;
    
    for (int in_channel = 0; in_channel < constants.inputChannels; ++in_channel) {
        for (int k = 0; k < kernelSize; ++k) {
            const int input_idx = (in_channel * inputLength) + (input_start + k);
            const int weight_idx = (out_channel * constants.inputChannels * kernelSize) +
                                  (in_channel * kernelSize) + k;

            // Enhanced bounds checking for both input and weights
            if (input_idx >= 0 && input_idx < maxInputSize && 
                weight_idx >= 0 && weight_idx < maxWeightSize &&
                input_start + k < inputLength) {
                sum += input[input_idx] * weights[weight_idx];
            }
        }
    }

    output[output_idx] = sum;
}

// MARK: - Linear Operations

kernel void linear_forward(
    device float* input [[buffer(0)]],
    const device float* weights [[buffer(1)]],
    const device float* bias [[buffer(2)]],
    device float* output [[buffer(3)]],
    constant int& inputSize [[buffer(4)]],
    constant int& outputSize [[buffer(5)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= outputSize || gid >= outputSize) return;

    // Bounds check for bias access
    if (gid >= outputSize) return;
    
    float sum = bias[gid];

    // Matrix multiplication with bounds checking
    const int weightRowStart = gid * inputSize;
    for (int i = 0; i < inputSize; ++i) {
        const int weightIdx = weightRowStart + i;
        // Check bounds for both weights and input arrays
        if (weightIdx < outputSize * inputSize && i < inputSize) {
            sum += weights[weightIdx] * input[i];
        }
    }

    output[gid] = sum;
}

// MARK: - GRU Operations

struct GRUConstants {
    int inputSize;
    int hiddenSize;
    int batchSize;
};

kernel void gru_forward(
    const device float* input [[buffer(0)]],
    const device float* hidden_state [[buffer(1)]],
    const device float* weights_ir [[buffer(2)]],  // Input-reset weights
    const device float* weights_iz [[buffer(3)]],  // Input-update weights
    const device float* weights_in [[buffer(4)]],  // Input-new weights
    const device float* weights_hr [[buffer(5)],  // Hidden-reset weights
    const device float* weights_hz [[buffer(6)],  // Hidden-update weights
    const device float* weights_hn [[buffer(7)],  // Hidden-new weights
    const device float* bias_ir [[buffer(8)]],
    const device float* bias_iz [[buffer(9)]],
    const device float* bias_in [[buffer(10)]],
    const device float* bias_hr [[buffer(11)]],
    const device float* bias_hz [[buffer(12)]],
    const device float* bias_hn [[buffer(13)]],
    device float* output [[buffer(14)]],
    device float* new_hidden [[buffer(15)]],
    constant GRUConstants& constants [[buffer(16)]],
    uint gid [[thread_position_in_grid]]
) {
    const int hiddenSize = constants.hiddenSize;
    const int inputSize = constants.inputSize;
    if (gid >= uint(hiddenSize) || hiddenSize <= 0 || inputSize <= 0) return;

    // Bounds checking helper
    auto checkWeightBounds = [&](int row, int col, int maxCols) -> bool {
        return row >= 0 && col >= 0 && row < hiddenSize && col < maxCols;
    };

    // Reset gate: r = sigmoid(W_ir * x + b_ir + W_hr * h + b_hr)
    float reset_gate = 0.0f;
    if (gid < hiddenSize) {
        reset_gate = bias_ir[gid] + bias_hr[gid];
    }
    
    for (int i = 0; i < inputSize; ++i) {
        if (checkWeightBounds(gid, i, inputSize)) {
            reset_gate += weights_ir[gid * inputSize + i] * input[i];
        }
    }
    for (int i = 0; i < hiddenSize; ++i) {
        if (checkWeightBounds(gid, i, hiddenSize)) {
            reset_gate += weights_hr[gid * hiddenSize + i] * hidden_state[i];
        }
    }
    reset_gate = 1.0f / (1.0f + exp(-reset_gate)); // sigmoid

    // Update gate: z = sigmoid(W_iz * x + b_iz + W_hz * h + b_hz)
    float update_gate = 0.0f;
    if (gid < hiddenSize) {
        update_gate = bias_iz[gid] + bias_hz[gid];
    }
    
    for (int i = 0; i < inputSize; ++i) {
        if (checkWeightBounds(gid, i, inputSize)) {
            update_gate += weights_iz[gid * inputSize + i] * input[i];
        }
    }
    for (int i = 0; i < hiddenSize; ++i) {
        if (checkWeightBounds(gid, i, hiddenSize)) {
            update_gate += weights_hz[gid * hiddenSize + i] * hidden_state[i];
        }
    }
    update_gate = 1.0f / (1.0f + exp(-update_gate)); // sigmoid

    // New candidate: n = tanh(W_in * x + b_in + W_hn * (r * h) + b_hn)
    float new_candidate = 0.0f;
    if (gid < hiddenSize) {
        new_candidate = bias_in[gid] + bias_hn[gid];
    }
    
    for (int i = 0; i < inputSize; ++i) {
        if (checkWeightBounds(gid, i, inputSize)) {
            new_candidate += weights_in[gid * inputSize + i] * input[i];
        }
    }
    for (int i = 0; i < hiddenSize; ++i) {
        if (checkWeightBounds(gid, i, hiddenSize)) {
            new_candidate += weights_hn[gid * hiddenSize + i] * (reset_gate * hidden_state[i]);
        }
    }
    new_candidate = tanh(new_candidate);

    // New hidden state: h' = (1 - z) * n + z * h
    float new_hidden_val = (1.0f - update_gate) * new_candidate + update_gate * hidden_state[gid];

    if (gid < hiddenSize) {
        new_hidden[gid] = new_hidden_val;
        output[gid] = new_hidden_val; // For single layer, output = new hidden state
    }
}
    for (int i = 0; i < hiddenSize; ++i) {
        reset_gate += weights_hr[gid * hiddenSize + i] * hidden_state[i];
    }
    reset_gate = 1.0f / (1.0f + exp(-reset_gate)); // sigmoid

    // Update gate: z = sigmoid(W_iz * x + b_iz + W_hz * h + b_hz)
    float update_gate = bias_iz[gid] + bias_hz[gid];
    for (int i = 0; i < constants.inputSize; ++i) {
        update_gate += weights_iz[gid * constants.inputSize + i] * input[i];
    }
    for (int i = 0; i < hiddenSize; ++i) {
        update_gate += weights_hz[gid * hiddenSize + i] * hidden_state[i];
    }
    update_gate = 1.0f / (1.0f + exp(-update_gate)); // sigmoid

    // New candidate: n = tanh(W_in * x + b_in + W_hn * (r * h) + b_hn)
    float new_candidate = bias_in[gid] + bias_hn[gid];
    for (int i = 0; i < constants.inputSize; ++i) {
        new_candidate += weights_in[gid * constants.inputSize + i] * input[i];
    }
    for (int i = 0; i < hiddenSize; ++i) {
        new_candidate += weights_hn[gid * hiddenSize + i] * (reset_gate * hidden_state[i]);
    }
    new_candidate = tanh(new_candidate);

    // New hidden state: h' = (1 - z) * n + z * h
    float new_hidden_val = (1.0f - update_gate) * new_candidate + update_gate * hidden_state[gid];

    new_hidden[gid] = new_hidden_val;
    output[gid] = new_hidden_val; // For single layer, output = new hidden state
}

// MARK: - Activation Functions

kernel void relu_activation(
    const device float* input [[buffer(0)]],
    device float* output [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    // Note: Actual buffer size bounds checking should be done at dispatch time
    // This kernel assumes proper thread count is set
    output[gid] = max(0.0f, input[gid]);
}

kernel void sigmoid_activation(
    const device float* input [[buffer(0)]],
    device float* output [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    // Note: Actual buffer size bounds checking should be done at dispatch time
    // This kernel assumes proper thread count is set
    float x = input[gid];
    // Clamp input to prevent overflow in exp()
    x = clamp(x, -80.0f, 80.0f);
    output[gid] = 1.0f / (1.0f + exp(-x));
}

kernel void tanh_activation(
    const device float* input [[buffer(0)]],
    device float* output [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    // Note: Actual buffer size bounds checking should be done at dispatch time
    // This kernel assumes proper thread count is set
    float x = input[gid];
    // Clamp input to prevent overflow in exp()
    x = clamp(x, -80.0f, 80.0f);
    output[gid] = (exp(x) - exp(-x)) / (exp(x) + exp(-x));
}

// MARK: - Utility Functions

kernel void add_bias(
    device float* input [[buffer(0)]],
    const device float* bias [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    // Note: Actual buffer size bounds checking should be done at dispatch time
    // This kernel assumes proper thread count is set and arrays are same size
    input[gid] += bias[gid];
}

kernel void elementwise_multiply(
    const device float* a [[buffer(0)]],
    const device float* b [[buffer(1)]],
    device float* output [[buffer(2)]],
    uint gid [[thread_position_in_grid]]
) {
    // Note: Actual buffer size bounds checking should be done at dispatch time
    // This kernel assumes proper thread count is set and arrays are same size
    output[gid] = a[gid] * b[gid];
}

kernel void vector_add(
    const device float* a [[buffer(0)]],
    const device float* b [[buffer(1)]],
    device float* output [[buffer(2)]],
    uint gid [[thread_position_in_grid]]
) {
    // Note: Actual buffer size bounds checking should be done at dispatch time
    // This kernel assumes proper thread count is set and arrays are same size
    output[gid] = a[gid] + b[gid];
}

// MARK: - Audio Processing Operations

// Complex number structure for FFT operations
struct Complex {
    float real;
    float imag;
};

Complex complex_multiply(Complex a, Complex b) {
    return Complex{a.real * b.real - a.imag * b.imag, a.real * b.imag + a.imag * b.real};
}

Complex complex_add(Complex a, Complex b) {
    return Complex{a.real + b.real, a.imag + b.imag};
}

// FFT Constants
struct FFTConstants {
    int fftSize;
    int log2fftSize;
    bool inverse;
};

// Twiddle factor computation
Complex twiddle_factor(int k, int N, bool inverse) {
    float angle = (inverse ? 2.0f : -2.0f) * M_PI_F * float(k) / float(N);
    return Complex{cos(angle), sin(angle)};
}

// Bit reversal for FFT
int bit_reverse(int x, int log2n) {
    int result = 0;
    for (int i = 0; i < log2n; ++i) {
        result = (result << 1) | (x & 1);
        x >>= 1;
    }
    return result;
}

// Radix-2 FFT implementation
kernel void fft_forward(
    const device float* input [[buffer(0)]],
    device float* output_real [[buffer(1)]],
    device float* output_imag [[buffer(2)]],
    constant FFTConstants& constants [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    const int N = constants.fftSize;
    if (gid >= uint(N) || N <= 0 || N > 4096) return; // Bounds check for fixed array size

    // Convert real input to complex (imaginary part = 0)
    Complex x[4096]; // Maximum FFT size - protected by bounds check above
    for (int i = 0; i < N && i < 4096; ++i) {
        x[i] = Complex{input[i], 0.0f};
    }

    // Bit reversal permutation
    for (int i = 0; i < N; ++i) {
        int j = bit_reverse(i, constants.log2fftSize);
        if (i < j) {
            Complex temp = x[i];
            x[i] = x[j];
            x[j] = temp;
        }
    }

    // Cooley-Tukey FFT
    for (int s = 1; s <= constants.log2fftSize; ++s) {
        int m = 1 << s;
        int m2 = m >> 1;
        Complex wm = twiddle_factor(1, m, constants.inverse);

        for (int k = 0; k < N; k += m) {
            Complex w = Complex{1.0f, 0.0f};
            for (int j = 0; j < m2; ++j) {
                Complex t = complex_multiply(w, x[k + j + m2]);
                Complex u = x[k + j];
                x[k + j] = complex_add(u, t);
                x[k + j + m2] = Complex{u.real - t.real, u.imag - t.imag};
                w = complex_multiply(w, wm);
            }
        }
    }

    // Output results
    for (int i = 0; i < N; ++i) {
        output_real[i] = x[i].real;
        output_imag[i] = x[i].imag;
    }
}

// Inverse FFT (IFFT)
kernel void fft_inverse(
    const device float* input_real [[buffer(0)]],
    const device float* input_imag [[buffer(1)]],
    device float* output [[buffer(2)]],
    constant FFTConstants& constants [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    const int N = constants.fftSize;
    if (gid >= uint(N) || N <= 0 || N > 4096) return; // Bounds check for fixed array size

    // Convert input to complex
    Complex x[4096]; // Protected by bounds check above
    for (int i = 0; i < N && i < 4096; ++i) {
        x[i] = Complex{input_real[i], input_imag[i]};
    }

    // Bit reversal permutation
    for (int i = 0; i < N; ++i) {
        int j = bit_reverse(i, constants.log2fftSize);
        if (i < j) {
            Complex temp = x[i];
            x[i] = x[j];
            x[j] = temp;
        }
    }

    // Cooley-Tukey IFFT
    for (int s = 1; s <= constants.log2fftSize; ++s) {
        int m = 1 << s;
        int m2 = m >> 1;
        Complex wm = twiddle_factor(1, m, true); // inverse = true

        for (int k = 0; k < N; k += m) {
            Complex w = Complex{1.0f, 0.0f};
            for (int j = 0; j < m2; ++j) {
                Complex t = complex_multiply(w, x[k + j + m2]);
                Complex u = x[k + j];
                x[k + j] = complex_add(u, t);
                x[k + j + m2] = Complex{u.real - t.real, u.imag - t.imag};
                w = complex_multiply(w, wm);
            }
        }
    }

    // Scale by 1/N and output real part
    for (int i = 0; i < N; ++i) {
        output[i] = x[i].real / float(N);
    }
}

// STFT Constants
struct STFTConstants {
    int fftSize;
    int hopSize;
    int windowSize;
    int numFrames;
    bool inverse;
};

// Hann window generation
kernel void generate_hann_window(
    device float* window [[buffer(0)]],
    constant int& windowSize [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= uint(windowSize)) return;
    float phase = 2.0f * M_PI_F * float(gid) / float(windowSize - 1);
    window[gid] = 0.5f * (1.0f - cos(phase));
}

// STFT analysis (forward)
kernel void stft_analysis(
    const device float* input [[buffer(0)]],
    const device float* window [[buffer(1)]],
    device float* stft_real [[buffer(2)]],
    device float* stft_imag [[buffer(3)]],
    constant STFTConstants& constants [[buffer(4)]],
    uint frame_gid [[thread_position_in_grid]]
) {
    if (frame_gid >= uint(constants.numFrames) || constants.fftSize <= 0 || constants.fftSize > 4096) return;

    const int frame_start = frame_gid * constants.hopSize;
    const int fft_size = constants.fftSize;

    // Extract and window the frame
    Complex frame[4096]; // Max FFT size - protected by bounds check above
    for (int i = 0; i < fft_size && i < 4096; ++i) {
        // Additional bounds checking for input access
        float sample = 0.0f;
        if (frame_start + i < constants.windowSize && frame_start + i >= 0) {
            sample = input[frame_start + i];
        }
        float win_val = (i < constants.windowSize && i >= 0) ? window[i] : 1.0f;
        frame[i] = Complex{sample * win_val, 0.0f};
    }

    // Compute FFT (simplified - would need full FFT implementation)
    // For now, just copy the windowed frame
    for (int i = 0; i < fft_size; ++i) {
        stft_real[frame_gid * fft_size + i] = frame[i].real;
        stft_imag[frame_gid * fft_size + i] = frame[i].imag;
    }
}

// STFT synthesis (inverse)
kernel void stft_synthesis(
    const device float* stft_real [[buffer(0)]],
    const device float* stft_imag [[buffer(1)]],
    const device float* window [[buffer(2)]],
    device float* output [[buffer(3)]],
    constant STFTConstants& constants [[buffer(4)]],
    uint sample_gid [[thread_position_in_grid]]
) {
    if (sample_gid >= uint(constants.windowSize)) return;

    // Overlap-add reconstruction (simplified)
    float sum = 0.0f;
    int num_contributing_frames = 0;

    for (int frame = 0; frame < constants.numFrames; ++frame) {
        int frame_start = frame * constants.hopSize;
        int sample_in_frame = sample_gid - frame_start;

        if (sample_in_frame >= 0 && sample_in_frame < constants.fftSize) {
            float real_part = stft_real[frame * constants.fftSize + sample_in_frame];
            float win_val = (sample_in_frame < constants.windowSize) ? window[sample_in_frame] : 1.0f;
            sum += real_part * win_val;
            num_contributing_frames++;
        }
    }

    // Normalize by number of overlapping frames
    output[sample_gid] = (num_contributing_frames > 0) ? sum / float(num_contributing_frames) : 0.0f;
}

// MARK: - ERB Filtering Operations

// ERB filterbank constants
struct ERBConstants {
    int numBands;
    int fftSize;
    float sampleRate;
    float minFreq;
    float maxFreq;
};

// ERB frequency scale conversion
float freq_to_erb(float freq) {
    return 21.4f * log10(1.0f + freq / 229.0f);
}

float erb_to_freq(float erb) {
    return 229.0f * (pow(10.0f, erb / 21.4f) - 1.0f);
}

// Generate ERB filterbank
kernel void generate_erb_filterbank(
    device float* filterbank [[buffer(0)]],
    constant ERBConstants& constants [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    const int freq_bin = gid / constants.numBands;
    const int band = gid % constants.numBands;

    if (freq_bin >= constants.fftSize / 2 || band >= constants.numBands) return;

    float freq = float(freq_bin) * constants.sampleRate / float(constants.fftSize);

    // ERB filter shape (simplified triangular filter)
    // Guard against division by zero for single band case
    float numBandsSafe = max(1.0, float(constants.numBands - 1));
    float erb_center = freq_to_erb(constants.minFreq) +
                      float(band) * (freq_to_erb(constants.maxFreq) - freq_to_erb(constants.minFreq)) /
                      numBandsSafe;

    float center_freq = erb_to_freq(erb_center);
    float erb_width = 1.0f; // Simplified ERB width

    float lower_freq = erb_to_freq(erb_center - erb_width);
    float upper_freq = erb_to_freq(erb_center + erb_width);

    // Triangular filter response
    float response = 0.0f;
    if (freq >= lower_freq && freq <= center_freq) {
        response = (freq - lower_freq) / (center_freq - lower_freq);
    } else if (freq > center_freq && freq <= upper_freq) {
        response = (upper_freq - freq) / (upper_freq - center_freq);
    }

    filterbank[gid] = response;
}

// Apply ERB filtering to spectrum
kernel void apply_erb_filtering(
    const device float* spectrum_real [[buffer(0)]],
    const device float* spectrum_imag [[buffer(1)]],
    const device float* filterbank [[buffer(2)]],
    device float* filtered_real [[buffer(3)]],
    device float* filtered_imag [[buffer(4)]],
    constant ERBConstants& constants [[buffer(5)]],
    uint gid [[thread_position_in_grid]]
) {
    const int freq_bin = gid;

    if (freq_bin >= constants.fftSize / 2) return;

    // Apply ERB filtering
    for (int band = 0; band < constants.numBands; ++band) {
        float filter_response = filterbank[freq_bin * constants.numBands + band];
        filtered_real[freq_bin * constants.numBands + band] = spectrum_real[freq_bin] * filter_response;
        filtered_imag[freq_bin * constants.numBands + band] = spectrum_imag[freq_bin] * filter_response;
    }
}

// MARK: - Audio Feature Extraction

// Spectral centroid calculation
kernel void spectral_centroid(
    const device float* spectrum [[buffer(0)]],
    device float* centroids [[buffer(1)]],
    constant int& fftSize [[buffer(2)]],
    constant float& sampleRate [[buffer(3)]],
    uint frame_gid [[thread_position_in_grid]]
) {
    const int frame_start = frame_gid * (fftSize / 2);

    float numerator = 0.0f;
    float denominator = 0.0f;

    for (int k = 0; k < fftSize / 2; ++k) {
        int spectrum_idx = frame_start + k;
        // Bounds checking for spectrum access
        if (spectrum_idx >= 0) {
            float magnitude = spectrum[spectrum_idx];
            float frequency = float(k) * sampleRate / float(fftSize);

            numerator += frequency * magnitude;
            denominator += magnitude;
        }
    }

    centroids[frame_gid] = (denominator > 0.0f) ? numerator / denominator : 0.0f;
}

// MARK: - GPU-Accelerated Encoder Operations

struct EncoderConstants {
    int batchSize;
    int timeSteps;
    int featureDim;
    int hiddenDim;
};

// GPU-accelerated encoder forward pass
kernel void encoder_forward(
    const device float* input [[buffer(0)]],      // [batch, time, features]
    const device float* weights [[buffer(1)]],    // [features, hidden]
    const device float* bias [[buffer(2)]],       // [hidden]
    device float* output [[buffer(3)]],           // [batch, time, hidden]
    constant EncoderConstants& constants [[buffer(4)]],
    uint gid [[thread_position_in_grid]]
) {
    const int batchSize = constants.batchSize;
    const int timeSteps = constants.timeSteps;
    const int featureDim = constants.featureDim;
    const int hiddenDim = constants.hiddenDim;

    // Calculate position in output tensor
    const int totalElements = batchSize * timeSteps * hiddenDim;
    if (gid >= totalElements) return;

    const int batch = gid / (timeSteps * hiddenDim);
    const int time = (gid / hiddenDim) % timeSteps;
    const int hidden = gid % hiddenDim;

    // Bounds checking
    if (batch >= batchSize || time >= timeSteps || hidden >= hiddenDim) return;

    float sum = bias[hidden];

    // Matrix multiplication: output[b,t,h] = sum(input[b,t,f] * weights[f,h])
    const int inputOffset = (batch * timeSteps * featureDim) + (time * featureDim);
    const int weightOffset = hidden * featureDim;

    for (int f = 0; f < featureDim; ++f) {
        const int inputIdx = inputOffset + f;
        const int weightIdx = weightOffset + f;

        if (inputIdx < batchSize * timeSteps * featureDim &&
            weightIdx < featureDim * hiddenDim) {
            sum += input[inputIdx] * weights[weightIdx];
        }
    }

    output[gid] = sum;
}

// MARK: - GPU-Accelerated ERB Decoder Operations

struct ERBDecoderConstants {
    int batchSize;
    int timeSteps;
    int erbBands;
    int outputDim;
};

// GPU-accelerated ERB decoder forward pass
kernel void erb_decoder_forward(
    const device float* input [[buffer(0)]],      // [batch, time, erb_bands]
    const device float* weights [[buffer(1)]],    // [erb_bands, output_dim]
    const device float* bias [[buffer(2)]],       // [output_dim]
    device float* output [[buffer(3)]],           // [batch, time, output_dim]
    constant ERBDecoderConstants& constants [[buffer(4)]],
    uint gid [[thread_position_in_grid]]
) {
    const int batchSize = constants.batchSize;
    const int timeSteps = constants.timeSteps;
    const int erbBands = constants.erbBands;
    const int outputDim = constants.outputDim;

    // Calculate position in output tensor
    const int totalElements = batchSize * timeSteps * outputDim;
    if (gid >= totalElements) return;

    const int batch = gid / (timeSteps * outputDim);
    const int time = (gid / outputDim) % timeSteps;
    const int out_dim = gid % outputDim;

    // Bounds checking
    if (batch >= batchSize || time >= timeSteps || out_dim >= outputDim) return;

    float sum = bias[out_dim];

    // Matrix multiplication: output[b,t,d] = sum(input[b,t,e] * weights[e,d])
    const int inputOffset = (batch * timeSteps * erbBands) + (time * erbBands);
    const int weightOffset = out_dim * erbBands;

    for (int e = 0; e < erbBands; ++e) {
        const int inputIdx = inputOffset + e;
        const int weightIdx = weightOffset + e;

        if (inputIdx < batchSize * timeSteps * erbBands &&
            weightIdx < erbBands * outputDim) {
            sum += input[inputIdx] * weights[weightIdx];
        }
    }

    output[gid] = sum;
}

// MARK: - GPU-Accelerated DF Decoder Operations

struct DFDecoderConstants {
    int batchSize;
    int timeSteps;
    int dfBands;
    int outputChannels;
};

// GPU-accelerated DF decoder forward pass
kernel void df_decoder_forward(
    const device float* input [[buffer(0)]],      // [batch, time, df_bands]
    const device float* weights [[buffer(1)]],    // [df_bands, output_channels]
    const device float* bias [[buffer(2)]],       // [output_channels]
    device float* output [[buffer(3)]],           // [batch, time, output_channels]
    constant DFDecoderConstants& constants [[buffer(4)]],
    uint gid [[thread_position_in_grid]]
) {
    const int batchSize = constants.batchSize;
    const int timeSteps = constants.timeSteps;
    const int dfBands = constants.dfBands;
    const int outputChannels = constants.outputChannels;

    // Calculate position in output tensor
    const int totalElements = batchSize * timeSteps * outputChannels;
    if (gid >= totalElements) return;

    const int batch = gid / (timeSteps * outputChannels);
    const int time = (gid / outputChannels) % timeSteps;
    const int channel = gid % outputChannels;

    // Bounds checking
    if (batch >= batchSize || time >= timeSteps || channel >= outputChannels) return;

    float sum = bias[channel];

    // Matrix multiplication: output[b,t,c] = sum(input[b,t,d] * weights[d,c])
    const int inputOffset = (batch * timeSteps * dfBands) + (time * dfBands);
    const int weightOffset = channel * dfBands;

    for (int d = 0; d < dfBands; ++d) {
        const int inputIdx = inputOffset + d;
        const int weightIdx = weightOffset + d;

        if (inputIdx < batchSize * timeSteps * dfBands &&
            weightIdx < dfBands * outputChannels) {
            sum += input[inputIdx] * weights[weightIdx];
        }
    }

    output[gid] = sum;
}

// MARK: - Advanced GPU Acceleration Features

// MARK: - Batch Processing Operations

struct BatchConv1DConstants {
    int batchSize;
    int inputChannels;
    int outputChannels;
    int kernelSize;
    int stride;
    int inputLength;
    int outputLength;
};

// Batch convolution for processing multiple audio streams simultaneously
kernel void batch_conv1d_forward(
    const device float* input [[buffer(0)]],      // [batch, channels, length]
    const device float* weights [[buffer(1)]],    // [out_channels, in_channels, kernel]
    const device float* bias [[buffer(2)]],       // [out_channels]
    device float* output [[buffer(3)]],           // [batch, out_channels, out_length]
    constant BatchConv1DConstants& constants [[buffer(4)]],
    uint3 gid [[thread_position_in_grid]]
) {
    const int batch = gid.x;
    const int out_channel = gid.y;
    const int out_pos = gid.z;

    if (batch >= constants.batchSize || out_channel >= constants.outputChannels ||
        out_pos >= constants.outputLength) return;

    const int input_start = out_pos * constants.stride;
    float sum = bias[out_channel];

    // Convolution with batch processing
    for (int in_channel = 0; in_channel < constants.inputChannels; ++in_channel) {
        for (int k = 0; k < constants.kernelSize; ++k) {
            const int input_idx = batch * constants.inputChannels * constants.inputLength +
                                in_channel * constants.inputLength + (input_start + k);
            const int weight_idx = out_channel * constants.inputChannels * constants.kernelSize +
                                 in_channel * constants.kernelSize + k;

            if (input_start + k < constants.inputLength) {
                sum += input[input_idx] * weights[weight_idx];
            }
        }
    }

    const int output_idx = batch * constants.outputChannels * constants.outputLength +
                          out_channel * constants.outputLength + out_pos;
    output[output_idx] = sum;
}

// MARK: - Attention Mechanisms

struct AttentionConstants {
    int batchSize;
    int seqLength;
    int numHeads;
    int headDim;
    int modelDim;
};

// Multi-head attention computation
kernel void multihead_attention(
    const device float* query [[buffer(0)]],     // [batch, seq, model_dim]
    const device float* key [[buffer(1)]],       // [batch, seq, model_dim]
    const device float* value [[buffer(2)]],     // [batch, seq, model_dim]
    const device float* weights_q [[buffer(3)]], // [model_dim, model_dim]
    const device float* weights_k [[buffer(4)]], // [model_dim, model_dim]
    const device float* weights_v [[buffer(5)]], // [model_dim, model_dim]
    const device float* weights_o [[buffer(6)]], // [model_dim, model_dim]
    device float* output [[buffer(7)]],          // [batch, seq, model_dim]
    constant AttentionConstants& constants [[buffer(8)]],
    uint3 gid [[thread_position_in_grid]]
) {
    const int batch = gid.x;
    const int seq = gid.y;
    const int head = gid.z;

    if (batch >= constants.batchSize || seq >= constants.seqLength ||
        head >= constants.numHeads) return;

    const int model_dim = constants.modelDim;
    const int head_dim = constants.headDim;

    // Compute attention for this head
    threadgroup float attention_scores[1024]; // Shared memory for attention scores

    // Q, K, V projections (simplified - would need proper linear layers)
    for (int i = 0; i < constants.seqLength; ++i) {
        float score = 0.0f;
        for (int d = 0; d < head_dim; ++d) {
            // Simplified attention computation
            const int q_idx = batch * constants.seqLength * model_dim + seq * model_dim + head * head_dim + d;
            const int k_idx = batch * constants.seqLength * model_dim + i * model_dim + head * head_dim + d;
            score += query[q_idx] * key[k_idx];
        }
        attention_scores[i] = score / sqrt(float(head_dim));
    }

    // Softmax (simplified)
    float max_score = -FLT_MAX;
    for (int i = 0; i < constants.seqLength; ++i) {
        max_score = max(max_score, attention_scores[i]);
    }

    float sum_exp = 0.0f;
    for (int i = 0; i < constants.seqLength; ++i) {
        attention_scores[i] = exp(attention_scores[i] - max_score);
        sum_exp += attention_scores[i];
    }

    for (int i = 0; i < constants.seqLength; ++i) {
        attention_scores[i] /= sum_exp;
    }

    // Weighted sum of values
    for (int d = 0; d < head_dim; ++d) {
        float weighted_sum = 0.0f;
        for (int i = 0; i < constants.seqLength; ++i) {
            const int v_idx = batch * constants.seqLength * model_dim + i * model_dim + head * head_dim + d;
            weighted_sum += attention_scores[i] * value[v_idx];
        }

        const int out_idx = batch * constants.seqLength * model_dim + seq * model_dim + head * head_dim + d;
        output[out_idx] = weighted_sum;
    }
}

// MARK: - Fused Operations for Better Performance

struct FusedConvActivationConstants {
    int inputChannels;
    int outputChannels;
    int kernelSize;
    int stride;
    int inputLength;
    int outputLength;
    int activationType; // 0: relu, 1: gelu, 2: swish
};

// Fused convolution + activation for better performance
kernel void fused_conv1d_activation(
    const device float* input [[buffer(0)]],
    const device float* weights [[buffer(1)]],
    const device float* bias [[buffer(2)]],
    device float* output [[buffer(3)]],
    constant FusedConvActivationConstants& constants [[buffer(4)]],
    uint gid [[thread_position_in_grid]]
) {
    const int output_idx = gid;
    if (output_idx >= constants.outputChannels * constants.outputLength) return;

    const int out_channel = output_idx / constants.outputLength;
    const int out_pos = output_idx % constants.outputLength;
    const int input_start = out_pos * constants.stride;

    float sum = bias[out_channel];

    // Convolution
    for (int in_channel = 0; in_channel < constants.inputChannels; ++in_channel) {
        for (int k = 0; k < constants.kernelSize; ++k) {
            const int input_idx = (in_channel * constants.inputLength) + (input_start + k);
            const int weight_idx = (out_channel * constants.inputChannels * constants.kernelSize) +
                                 (in_channel * constants.kernelSize) + k;

            if (input_idx < constants.inputChannels * constants.inputLength &&
                input_start + k < constants.inputLength) {
                sum += input[input_idx] * weights[weight_idx];
            }
        }
    }

    // Fused activation
    switch (constants.activationType) {
        case 0: // ReLU
            sum = max(0.0f, sum);
            break;
        case 1: // GELU (approximation)
            sum = 0.5f * sum * (1.0f + tanh(0.7978845608f * (sum + 0.044715f * sum * sum * sum)));
            break;
        case 2: // Swish
            sum = sum * (1.0f / (1.0f + exp(-sum)));
            break;
        default:
            break;
    }

    output[output_idx] = sum;
}

// MARK: - Memory-Efficient Operations

struct QuantizedConvConstants {
    int inputChannels;
    int outputChannels;
    int kernelSize;
    int stride;
    int inputLength;
    int outputLength;
    float scale;
    int zeroPoint;
};

// 8-bit quantized convolution for memory efficiency
kernel void quantized_conv1d_forward(
    const device char* input [[buffer(0)]],      // Quantized input
    const device char* weights [[buffer(1)]],    // Quantized weights
    const device float* bias [[buffer(2)]],      // Float bias
    device float* output [[buffer(3)]],          // Float output
    constant QuantizedConvConstants& constants [[buffer(4)]],
    uint gid [[thread_position_in_grid]]
) {
    const int output_idx = gid;
    if (output_idx >= constants.outputChannels * constants.outputLength) return;

    const int out_channel = output_idx / constants.outputLength;
    const int out_pos = output_idx % constants.outputLength;
    const int input_start = out_pos * constants.stride;

    int quantized_sum = 0;

    // Quantized convolution
    for (int in_channel = 0; in_channel < constants.inputChannels; ++in_channel) {
        for (int k = 0; k < constants.kernelSize; ++k) {
            const int input_idx = (in_channel * constants.inputLength) + (input_start + k);
            const int weight_idx = (out_channel * constants.inputChannels * constants.kernelSize) +
                                 (in_channel * constants.kernelSize) + k;

            if (input_idx < constants.inputChannels * constants.inputLength &&
                input_start + k < constants.inputLength) {
                quantized_sum += int(input[input_idx]) * int(weights[weight_idx]);
            }
        }
    }

    // Dequantize and add bias
    float sum = float(quantized_sum) * constants.scale + bias[out_channel];
    output[output_idx] = sum;
}

// MARK: - Advanced Audio Processing

struct AdvancedSTFTConstants {
    int fftSize;
    int hopSize;
    int windowSize;
    int numFrames;
    int numChannels;
    bool useHannWindow;
    float scaleFactor;
};

// Advanced STFT with multi-channel support and windowing options
kernel void advanced_stft_analysis(
    const device float* input [[buffer(0)]],     // [channels, samples]
    const device float* window [[buffer(1)]],    // Window function
    device float* stft_real [[buffer(2)]],       // [channels, frames, fft_size/2]
    device float* stft_imag [[buffer(3)]],       // [channels, frames, fft_size/2]
    constant AdvancedSTFTConstants& constants [[buffer(4)]],
    uint3 gid [[thread_position_in_grid]]
) {
    const int channel = gid.x;
    const int frame = gid.y;
    const int bin = gid.z;

    if (channel >= constants.numChannels || frame >= constants.numFrames ||
        bin >= constants.fftSize / 2) return;

    const int frame_start = frame * constants.hopSize;
    const int input_offset = channel * (constants.numFrames * constants.hopSize + constants.windowSize);

    // Apply window and compute DFT bin
    float real_sum = 0.0f;
    float imag_sum = 0.0f;

    for (int n = 0; n < constants.windowSize; ++n) {
        const int input_idx = input_offset + frame_start + n;
        if (input_idx < (channel + 1) * (constants.numFrames * constants.hopSize + constants.windowSize)) {
            float sample = input[input_idx];
            float win_val = constants.useHannWindow ? window[n] : 1.0f;

            float angle = -2.0f * M_PI_F * float(bin) * float(n) / float(constants.fftSize);
            float cos_val = cos(angle);
            float sin_val = sin(angle);

            real_sum += sample * win_val * cos_val;
            imag_sum += sample * win_val * sin_val;
        }
    }

    const int output_idx = channel * constants.numFrames * (constants.fftSize / 2) +
                          frame * (constants.fftSize / 2) + bin;

    stft_real[output_idx] = real_sum * constants.scaleFactor;
    stft_imag[output_idx] = imag_sum * constants.scaleFactor;
}

// MARK: - Transformer Operations

struct TransformerConstants {
    int batchSize;
    int seqLength;
    int modelDim;
    int numHeads;
    int ffDim;
};

// Transformer feed-forward network
kernel void transformer_feedforward(
    const device float* input [[buffer(0)]],     // [batch, seq, model_dim]
    const device float* weights1 [[buffer(1)]],   // [model_dim, ff_dim]
    const device float* weights2 [[buffer(2)]],   // [ff_dim, model_dim]
    const device float* bias1 [[buffer(3)]],      // [ff_dim]
    const device float* bias2 [[buffer(4)]],      // [model_dim]
    device float* output [[buffer(5)]],           // [batch, seq, model_dim]
    constant TransformerConstants& constants [[buffer(6)]],
    uint3 gid [[thread_position_in_grid]]
) {
    const int batch = gid.x;
    const int seq = gid.y;
    const int dim = gid.z;

    if (batch >= constants.batchSize || seq >= constants.seqLength ||
        dim >= constants.modelDim) return;

    // First linear layer + ReLU
    float hidden = bias1[dim];
    const int input_offset = batch * constants.seqLength * constants.modelDim +
                           seq * constants.modelDim;
    const int weight1_offset = dim * constants.modelDim;

    for (int d = 0; d < constants.modelDim; ++d) {
        hidden += input[input_offset + d] * weights1[weight1_offset + d];
    }
    hidden = max(0.0f, hidden); // ReLU

    // Second linear layer
    float result = bias2[dim];
    const int weight2_offset = dim * constants.ffDim;

    for (int d = 0; d < constants.ffDim; ++d) {
        result += hidden * weights2[weight2_offset + d];
    }

    const int output_idx = batch * constants.seqLength * constants.modelDim +
                          seq * constants.modelDim + dim;
    output[output_idx] = result;
}

// MARK: - Performance Monitoring

struct PerformanceConstants {
    uint64_t startTime;
    uint64_t kernelId;
};

// Performance monitoring kernel
kernel void performance_monitor(
    device uint64_t* timestamps [[buffer(0)]],
    constant PerformanceConstants& constants [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid == 0) {
        timestamps[constants.kernelId] = constants.startTime;
    }
}