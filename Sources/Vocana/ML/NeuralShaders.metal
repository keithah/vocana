//
//  NeuralShaders.metal
//  Vocana
//
//  Metal compute shaders for GPU-accelerated neural network operations
//

#include <metal_stdlib>
using namespace metal;

// Maximum FFT size supported by GPU kernels
constant int MAX_FFT_SIZE = 4096;

// MARK: - Convolution Operations

struct Conv1DConstants {
    int inputChannels;
    int outputChannels;
    int kernelSize;
    int stride;
    int inputLength;
    int outputLength;
};

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

    // Calculate input start position
    const int input_start = out_pos * stride;

    float sum = bias[out_channel];

    // Convolution operation
    for (int in_channel = 0; in_channel < constants.inputChannels; ++in_channel) {
        for (int k = 0; k < kernelSize; ++k) {
            const int input_idx = (in_channel * inputLength) + (input_start + k);
            const int weight_idx = (out_channel * constants.inputChannels * kernelSize) +
                                  (in_channel * kernelSize) + k;

            if (input_idx < constants.inputChannels * inputLength) {
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
    if (gid >= outputSize) return;

    float sum = bias[gid];

    // Matrix multiplication: output[gid] = weights[gid * inputSize + i] * input[i]
    for (int i = 0; i < inputSize; ++i) {
        sum += weights[gid * inputSize + i] * input[i];
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
    const device float* weights_hr [[buffer(5)]],  // Hidden-reset weights
    const device float* weights_hz [[buffer(6)]],  // Hidden-update weights
    const device float* weights_hn [[buffer(7)]],  // Hidden-new weights
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
    if (gid >= hiddenSize) return;

    // Reset gate: r = sigmoid(W_ir * x + b_ir + W_hr * h + b_hr)
    float reset_gate = bias_ir[gid] + bias_hr[gid];
    for (int i = 0; i < constants.inputSize; ++i) {
        reset_gate += weights_ir[gid * constants.inputSize + i] * input[i];
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
    output[gid] = max(0.0f, input[gid]);
}

kernel void sigmoid_activation(
    const device float* input [[buffer(0)]],
    device float* output [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    output[gid] = 1.0f / (1.0f + exp(-input[gid]));
}

kernel void tanh_activation(
    const device float* input [[buffer(0)]],
    device float* output [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    float x = input[gid];
    output[gid] = (exp(x) - exp(-x)) / (exp(x) + exp(-x));
}

// MARK: - Utility Functions

kernel void add_bias(
    device float* input [[buffer(0)]],
    const device float* bias [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    input[gid] += bias[gid];
}

kernel void elementwise_multiply(
    const device float* a [[buffer(0)]],
    const device float* b [[buffer(1)]],
    device float* output [[buffer(2)]],
    uint gid [[thread_position_in_grid]]
) {
    output[gid] = a[gid] * b[gid];
}

kernel void vector_add(
    const device float* a [[buffer(0)]],
    const device float* b [[buffer(1)]],
    device float* output [[buffer(2)]],
    uint gid [[thread_position_in_grid]]
) {
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
    if (gid >= uint(N)) return;

    // CRITICAL SECURITY: Prevent stack buffer overflow - validate FFT size
    if (N > MAX_FFT_SIZE) return;
    
    // Convert real input to complex (imaginary part = 0)
    // Use device memory instead of stack to prevent overflow
    device Complex* x = reinterpret_cast<device Complex*>(output + N); // Use output buffer as temporary storage
    for (int i = 0; i < N; ++i) {
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
    if (gid >= uint(N)) return;

    // Convert input to complex
    Complex x[MAX_FFT_SIZE];
    for (int i = 0; i < N; ++i) {
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
    
    // CRITICAL SECURITY: Prevent division by zero
    if (windowSize <= 1) {
        window[gid] = 1.0f; // For window size 0 or 1, use full amplitude
        return;
    }
    
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
    if (frame_gid >= uint(constants.numFrames)) return;

    const int frame_start = frame_gid * constants.hopSize;
    const int fft_size = constants.fftSize;

    // Extract and window the frame
    Complex frame[MAX_FFT_SIZE]; // Max FFT size
    for (int i = 0; i < fft_size; ++i) {
        float sample = (frame_start + i < constants.windowSize) ? input[frame_start + i] : 0.0f;
        float win_val = (i < constants.windowSize) ? window[i] : 1.0f;
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
    float erb_center = freq_to_erb(constants.minFreq) +
                      float(band) * (freq_to_erb(constants.maxFreq) - freq_to_erb(constants.minFreq)) /
                      float(constants.numBands - 1);

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
        float magnitude = spectrum[frame_start + k];
        float frequency = float(k) * sampleRate / float(fftSize);

        numerator += frequency * magnitude;
        denominator += magnitude;
    }

    centroids[frame_gid] = (denominator > 0.0f) ? numerator / denominator : 0.0f;
}

// Spectral flux calculation
kernel void spectral_flux(
    const device float* current_spectrum [[buffer(0)]],
    const device float* previous_spectrum [[buffer(1)]],
    device float* flux [[buffer(2)]],
    constant int& fftSize [[buffer(3)]],
    uint frame_gid [[thread_position_in_grid]]
) {
    const int frame_start = frame_gid * (fftSize / 2);

    float sum = 0.0f;
    for (int k = 0; k < fftSize / 2; ++k) {
        float diff = current_spectrum[frame_start + k] - previous_spectrum[frame_start + k];
        sum += max(diff, 0.0f); // Half-wave rectification
    }

    flux[frame_gid] = sum;
}