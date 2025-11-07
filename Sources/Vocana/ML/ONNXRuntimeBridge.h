/*
 * ONNX Runtime C API Bridge for Swift
 * 
 * This header provides a minimal C bridge to ONNX Runtime's C API.
 * It allows Swift to call ONNX Runtime without depending on the full C++ API.
 *
 * Installation:
 * 1. Download ONNX Runtime from: https://github.com/microsoft/onnxruntime/releases
 * 2. Extract to Frameworks/onnxruntime/
 * 3. Link libonnxruntime.dylib in your build settings
 *
 * Usage from Swift:
 * See ONNXRuntimeWrapper.swift for Swift-friendly wrapper
 */

#ifndef ONNXRuntimeBridge_h
#define ONNXRuntimeBridge_h

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - Status Codes

typedef enum {
    ONNX_STATUS_OK = 0,
    ONNX_STATUS_ERROR = 1,
    ONNX_STATUS_INVALID_ARGUMENT = 2,
    ONNX_STATUS_NO_MODEL = 3,
    ONNX_STATUS_RUNTIME_EXCEPTION = 4
} ONNXStatus;

// MARK: - Opaque Types

typedef struct ONNXEnv ONNXEnv;
typedef struct ONNXSession ONNXSession;
typedef struct ONNXValue ONNXValue;
typedef struct ONNXSessionOptions ONNXSessionOptions;

// MARK: - Environment Management

/**
 * Create ONNX Runtime environment
 * @param log_level Logging level (0 = verbose, 4 = error)
 * @param env_name Name for the environment
 * @param out_env Output environment pointer
 * @return Status code
 */
ONNXStatus ONNXCreateEnv(int log_level, const char* env_name, ONNXEnv** out_env);

/**
 * Release environment
 */
void ONNXReleaseEnv(ONNXEnv* env);

// MARK: - Session Options

/**
 * Create session options
 */
ONNXStatus ONNXCreateSessionOptions(ONNXSessionOptions** out_options);

/**
 * Set number of intra-op threads
 */
ONNXStatus ONNXSetIntraOpNumThreads(ONNXSessionOptions* options, int num_threads);

/**
 * Set graph optimization level (0 = none, 1 = basic, 2 = extended, 3 = all)
 */
ONNXStatus ONNXSetGraphOptimizationLevel(ONNXSessionOptions* options, int level);

/**
 * Release session options
 */
void ONNXReleaseSessionOptions(ONNXSessionOptions* options);

// MARK: - Session Management

/**
 * Create inference session from model file
 * @param env Environment
 * @param model_path Path to .onnx model file
 * @param options Session options
 * @param out_session Output session pointer
 * @return Status code
 */
ONNXStatus ONNXCreateSession(ONNXEnv* env, 
                              const char* model_path,
                              ONNXSessionOptions* options,
                              ONNXSession** out_session);

/**
 * Get number of inputs
 */
ONNXStatus ONNXSessionGetInputCount(ONNXSession* session, size_t* out_count);

/**
 * Get number of outputs
 */
ONNXStatus ONNXSessionGetOutputCount(ONNXSession* session, size_t* out_count);

/**
 * Get input name by index
 */
ONNXStatus ONNXSessionGetInputName(ONNXSession* session, 
                                    size_t index,
                                    char* out_name,
                                    size_t name_len);

/**
 * Get output name by index
 */
ONNXStatus ONNXSessionGetOutputName(ONNXSession* session,
                                     size_t index,
                                     char* out_name,
                                     size_t name_len);

/**
 * Release session
 */
void ONNXReleaseSession(ONNXSession* session);

// MARK: - Tensor/Value Management

/**
 * Create tensor from float array
 * @param data Float array data
 * @param data_count Number of elements
 * @param shape Tensor shape
 * @param shape_count Number of dimensions
 * @param out_value Output value pointer
 * @return Status code
 */
ONNXStatus ONNXCreateTensorFloat(const float* data,
                                  size_t data_count,
                                  const int64_t* shape,
                                  size_t shape_count,
                                  ONNXValue** out_value);

/**
 * Get tensor data as float array
 */
ONNXStatus ONNXGetTensorFloatData(ONNXValue* value,
                                   float* out_data,
                                   size_t data_count);

/**
 * Get tensor shape
 */
ONNXStatus ONNXGetTensorShape(ONNXValue* value,
                               int64_t* out_shape,
                               size_t* out_shape_count);

/**
 * Release value
 */
void ONNXReleaseValue(ONNXValue* value);

// MARK: - Inference

/**
 * Run inference
 * @param session Inference session
 * @param input_names Array of input names
 * @param inputs Array of input values
 * @param input_count Number of inputs
 * @param output_names Array of output names
 * @param output_count Number of outputs
 * @param out_outputs Output values (allocated by ONNX Runtime)
 * @return Status code
 */
ONNXStatus ONNXSessionRun(ONNXSession* session,
                          const char* const* input_names,
                          const ONNXValue* const* inputs,
                          size_t input_count,
                          const char* const* output_names,
                          size_t output_count,
                          ONNXValue** out_outputs);

// MARK: - Error Handling

/**
 * Get last error message
 */
const char* ONNXGetLastErrorMessage(void);

#ifdef __cplusplus
}
#endif

#endif /* ONNXRuntimeBridge_h */

/*
 * Implementation Notes:
 * 
 * This bridge will be implemented in one of two ways:
 * 
 * 1. Direct ONNX Runtime C API (when library is available):
 *    - Include <onnxruntime_c_api.h>
 *    - Wrap OrtApi functions
 *    - Handle OrtStatus properly
 * 
 * 2. Mock implementation (for development without library):
 *    - Return mock data matching expected shapes
 *    - Log calls for debugging
 *    - Useful for testing pipeline without models
 * 
 * To switch between implementations, see ONNXRuntimeBridge.c
 */
