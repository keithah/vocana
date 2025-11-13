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