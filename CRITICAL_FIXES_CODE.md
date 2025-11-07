# Critical Security Fixes - Code Solutions

## Fix #1: Rust FFI Null Pointer Dereferences

### Problem Location
`libDF/src/capi.rs` - Multiple functions

### Current Vulnerable Code
```rust
pub unsafe extern "C" fn df_get_frame_length(st: *mut DFState) -> usize {
    let state = st.as_mut().expect("Invalid pointer");  // ← CRASH if NULL
    state.m.hop_size
}

pub unsafe extern "C" fn df_next_log_msg(st: *mut DFState) -> *mut c_char {
    let state = st.as_mut().expect("Invalid pointer");  // ← CRASH if NULL
    let msg = state.get_next_log_message();
    if let Some(msg) = msg {
        let c_msg = CString::new(msg).expect("Failed to convert log message to CString");
        c_msg.into_raw()
    } else {
        std::ptr::null_mut()
    }
}

pub unsafe extern "C" fn df_set_atten_lim(st: *mut DFState, lim_db: f32) {
    let state = st.as_mut().expect("Invalid pointer");  // ← CRASH if NULL
    state.m.set_atten_lim(lim_db)
}
```

### Fixed Code
```rust
pub unsafe extern "C" fn df_get_frame_length(st: *mut DFState) -> usize {
    match unsafe { st.as_ref() } {
        Some(state) => state.m.hop_size,
        None => {
            eprintln!("ERROR: NULL pointer passed to df_get_frame_length");
            0  // Return safe default
        }
    }
}

pub unsafe extern "C" fn df_next_log_msg(st: *mut DFState) -> *mut c_char {
    match unsafe { st.as_ref() } {
        Some(state) => {
            let msg = {
                // Use mut borrow in a scope to avoid lifetime issues
                let state_mut = st as *mut DFState;
                unsafe { state_mut.as_mut() }
                    .and_then(|s| s.get_next_log_message())
            };
            
            if let Some(msg) = msg {
                match CString::new(msg) {
                    Ok(c_msg) => c_msg.into_raw(),
                    Err(e) => {
                        eprintln!("ERROR: Failed to convert log message to CString: {}", e);
                        std::ptr::null_mut()
                    }
                }
            } else {
                std::ptr::null_mut()
            }
        }
        None => {
            eprintln!("ERROR: NULL pointer passed to df_next_log_msg");
            std::ptr::null_mut()
        }
    }
}

pub unsafe extern "C" fn df_set_atten_lim(st: *mut DFState, lim_db: f32) {
    match unsafe { st.as_mut() } {
        Some(state) => state.m.set_atten_lim(lim_db),
        None => {
            eprintln!("ERROR: NULL pointer passed to df_set_atten_lim");
        }
    }
}

pub unsafe extern "C" fn df_set_post_filter_beta(st: *mut DFState, beta: f32) {
    match unsafe { st.as_mut() } {
        Some(state) => state.m.set_pf_beta(beta),
        None => {
            eprintln!("ERROR: NULL pointer passed to df_set_post_filter_beta");
        }
    }
}

pub unsafe extern "C" fn df_process_frame(
    st: *mut DFState,
    input: *mut c_float,
    output: *mut c_float,
) -> c_float {
    match unsafe { st.as_mut() } {
        Some(state) => {
            // Validate input and output pointers
            if input.is_null() || output.is_null() {
                eprintln!("ERROR: NULL input or output pointer to df_process_frame");
                return -1.0;  // Return error code
            }
            
            let input = unsafe { ArrayView2::from_shape_ptr((1, state.m.hop_size), input) };
            let output = unsafe { ArrayViewMut2::from_shape_ptr((1, state.m.hop_size), output) };
            
            state.m.process(input, output).unwrap_or(-1.0)
        }
        None => {
            eprintln!("ERROR: NULL pointer passed to df_process_frame");
            -1.0
        }
    }
}

pub unsafe extern "C" fn df_process_frame_raw(
    st: *mut DFState,
    input: *mut c_float,
    out_gains_p: *mut *mut c_float,
    out_coefs_p: *mut *mut c_float,
) -> c_float {
    match unsafe { st.as_mut() } {
        Some(state) => {
            // Validate all pointers
            if input.is_null() || out_gains_p.is_null() || out_coefs_p.is_null() {
                eprintln!("ERROR: NULL pointer passed to df_process_frame_raw");
                return -1.0;
            }
            
            let input = unsafe { ArrayView2::from_shape_ptr((1, state.m.n_freqs), input) };
            
            if let Err(e) = state.m.set_spec_buffer(input) {
                eprintln!("ERROR: Failed to set input spectrum: {}", e);
                return -1.0;
            }
            
            match state.m.process_raw() {
                Ok((lsnr, gains, coefs)) => {
                    unsafe {
                        let mut out_gains = ArrayViewMut2::from_shape_ptr((1, state.m.nb_erb), *out_gains_p);
                        let mut out_coefs = ArrayViewMut4::from_shape_ptr((1, state.m.df_order, state.m.nb_df, 2), *out_coefs_p);
                        
                        if let Some(gains) = gains {
                            out_gains.assign(&gains.to_array_view().unwrap());
                        } else {
                            *out_gains_p = std::ptr::null_mut();
                        }
                        if let Some(coefs) = coefs {
                            out_coefs.assign(&coefs.to_array_view().unwrap());
                        } else {
                            *out_coefs_p = std::ptr::null_mut();
                        }
                    }
                    lsnr
                }
                Err(e) => {
                    eprintln!("ERROR: Failed to process DF spectral frame: {}", e);
                    -1.0
                }
            }
        }
        None => {
            eprintln!("ERROR: NULL pointer passed to df_process_frame_raw");
            -1.0
        }
    }
}
```

### Testing
```rust
#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_null_pointer_handling() {
        // Test that NULL pointer doesn't crash
        unsafe {
            let result = df_get_frame_length(std::ptr::null_mut());
            assert_eq!(result, 0);  // Should return safe default
            
            let msg = df_next_log_msg(std::ptr::null_mut());
            assert!(msg.is_null());
            
            df_set_atten_lim(std::ptr::null_mut(), 1.0);  // Should not crash
            df_process_frame(std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut());
        }
    }
}
```

---

## Fix #2: Memory Leak in df_coef_size and df_gain_size

### Problem Location
`libDF/src/capi.rs:222-246`

### Current Vulnerable Code
```rust
pub unsafe extern "C" fn df_coef_size(st: *const DFState) -> DynArray {
    let state = st.as_ref().expect("Invalid pointer");
    let mut shape = vec![
        state.m.ch as u32,
        state.m.df_order as u32,
        state.m.n_freqs as u32,
        2,
    ];
    let ret = DynArray {
        array: shape.as_mut_ptr(),
        length: shape.len() as u32,
    };
    std::mem::forget(shape);  // ← LEAK: Never deallocated
    ret
}
```

### Fixed Code - Option A: Caller Frees
```rust
// Add a header to track metadata
#[repr(C)]
pub struct DynArrayOwned {
    array: *mut u32,
    length: u32,
    capacity: u32,  // Track original capacity for freeing
}

pub unsafe extern "C" fn df_coef_size(st: *const DFState) -> DynArrayOwned {
    match unsafe { st.as_ref() } {
        Some(state) => {
            let mut shape = vec![
                state.m.ch as u32,
                state.m.df_order as u32,
                state.m.n_freqs as u32,
                2,
            ];
            let capacity = shape.capacity() as u32;
            let length = shape.len() as u32;
            let array = shape.as_mut_ptr();
            std::mem::forget(shape);  // Caller responsible for freeing
            
            DynArrayOwned {
                array,
                length,
                capacity,
            }
        }
        None => {
            eprintln!("ERROR: NULL pointer passed to df_coef_size");
            DynArrayOwned {
                array: std::ptr::null_mut(),
                length: 0,
                capacity: 0,
            }
        }
    }
}

pub unsafe extern "C" fn df_gain_size(st: *const DFState) -> DynArrayOwned {
    match unsafe { st.as_ref() } {
        Some(state) => {
            let mut shape = vec![state.m.ch as u32, state.m.nb_erb as u32];
            let capacity = shape.capacity() as u32;
            let length = shape.len() as u32;
            let array = shape.as_mut_ptr();
            std::mem::forget(shape);
            
            DynArrayOwned {
                array,
                length,
                capacity,
            }
        }
        None => {
            eprintln!("ERROR: NULL pointer passed to df_gain_size");
            DynArrayOwned {
                array: std::ptr::null_mut(),
                length: 0,
                capacity: 0,
            }
        }
    }
}

// Must be called to free memory
#[no_mangle]
pub unsafe extern "C" fn df_free_array(arr: DynArrayOwned) {
    if !arr.array.is_null() && arr.capacity > 0 {
        let _ = Vec::from_raw_parts(arr.array, arr.length as usize, arr.capacity as usize);
    }
}
```

### Fixed Code - Option B: Return Copies (Safer)
```rust
#[repr(C)]
pub struct DynArray {
    array: [u32; 4],
    length: u32,
}

pub unsafe extern "C" fn df_coef_size(st: *const DFState) -> DynArray {
    match unsafe { st.as_ref() } {
        Some(state) => {
            DynArray {
                array: [
                    state.m.ch as u32,
                    state.m.df_order as u32,
                    state.m.n_freqs as u32,
                    2,
                ],
                length: 4,
            }
        }
        None => {
            eprintln!("ERROR: NULL pointer passed to df_coef_size");
            DynArray {
                array: [0, 0, 0, 0],
                length: 0,
            }
        }
    }
}

pub unsafe extern "C" fn df_gain_size(st: *const DFState) -> DynArray {
    match unsafe { st.as_ref() } {
        Some(state) => {
            DynArray {
                array: [state.m.ch as u32, state.m.nb_erb as u32, 0, 0],
                length: 2,
            }
        }
        None => {
            eprintln!("ERROR: NULL pointer passed to df_gain_size");
            DynArray {
                array: [0, 0, 0, 0],
                length: 0,
            }
        }
    }
}
```

---

## Fix #3: Path Traversal Validation

### Problem Location
`Sources/Vocana/ML/ONNXModel.swift:169-217`

### Current Code with Weaknesses
```swift
private static func sanitizeModelPath(_ path: String) throws -> String {
    let url = URL(fileURLWithPath: path)
    let resolvedURL = url.standardizedFileURL
    let resolvedPath = resolvedURL.path
    
    var allowedDirectories: [URL] = []
    let currentDir = FileManager.default.currentDirectoryPath
    allowedDirectories.append(URL(fileURLWithPath: currentDir).appendingPathComponent("Models"))
    
    // Vulnerability: Component checking can be fooled
    let resolvedComponents = resolvedURL.pathComponents
    let allowedComponents = allowedDirectories.map { $0.pathComponents }
    
    let isPathAllowed = allowedComponents.contains { allowedComp in
        resolvedComponents.starts(with: allowedComp)
    }
    
    guard isPathAllowed else {
        throw ONNXError.modelNotFound("Model path not in allowed directories: \(resolvedPath)")
    }
    
    guard resolvedPath.lowercased().hasSuffix(".onnx") else {
        throw ONNXError.modelNotFound("Model file must have .onnx extension: \(resolvedPath)")
    }
    
    return resolvedPath
}
```

### Fully Fixed Code
```swift
private static func sanitizeModelPath(_ path: String) throws -> String {
    let fm = FileManager.default
    
    // Step 1: Validate path is not empty
    guard !path.isEmpty else {
        throw ONNXError.modelNotFound("Model path cannot be empty")
    }
    
    // Step 2: Resolve to absolute path
    let url = URL(fileURLWithPath: path).standardizedFileURL
    var resolvedPath = url.path
    
    // Step 3: Resolve symlinks (critical for preventing symlink attacks)
    do {
        // Check if path exists first
        if fm.fileExists(atPath: resolvedPath) {
            // Resolve any symlinks to get canonical path
            let attributes = try fm.attributesOfItem(atPath: resolvedPath)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                if let target = try fm.destinationOfSymbolicLink(atPath: resolvedPath) {
                    resolvedPath = target
                }
            }
        }
    } catch {
        Self.logger.warning("Could not resolve symlinks for \(resolvedPath): \(error)")
        // Continue with unresolved path
    }
    
    // Step 4: Build whitelist of allowed base directories
    var allowedPaths: Set<String> = []
    
    // Add Bundle resources Models directory
    if let resourcePath = Bundle.main.resourcePath {
        let bundleModelsPath = (resourcePath as NSString).appendingPathComponent("Models")
        allowedPaths.insert(self.canonicalPath(bundleModelsPath))
    }
    
    // Add Documents Models directory
    if let documentsPath = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
        let docsModelsPath = documentsPath.appendingPathComponent("Models").path
        allowedPaths.insert(self.canonicalPath(docsModelsPath))
    }
    
    // Add temp Models directory
    let tempModelsPath = fm.temporaryDirectory.appendingPathComponent("Models").path
    allowedPaths.insert(self.canonicalPath(tempModelsPath))
    
    // Step 5: Check if resolved path is within allowed directories
    // Using full path comparison to prevent component prefix attacks
    let isAllowed = allowedPaths.contains { allowedPath in
        // Exact match or is subdirectory of allowed path
        resolvedPath == allowedPath || 
        (resolvedPath.hasPrefix(allowedPath + "/") && 
         !resolvedPath.contains("/../"))  // Additional check for ../ bypass
    }
    
    guard isAllowed else {
        Self.logger.error("SECURITY: Path traversal attempt blocked: \(resolvedPath)")
        throw ONNXError.modelNotFound("Model path not in allowed directories")
    }
    
    // Step 6: Verify file extension (must be .onnx)
    guard resolvedPath.lowercased().hasSuffix(".onnx") else {
        throw ONNXError.modelNotFound("Model file must have .onnx extension")
    }
    
    // Step 7: Ensure file exists and is readable (prevents TOCTOU to some degree)
    guard fm.isReadableFile(atPath: resolvedPath) else {
        throw ONNXError.modelNotFound("Model file not readable or does not exist: \(resolvedPath)")
    }
    
    Self.logger.info("✓ Model path validated: \(resolvedPath)")
    return resolvedPath
}

/// Helper to get canonical path (resolve . and .. components)
private static func canonicalPath(_ path: String) -> String {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    return url.path
}
```

### Integration with Init
```swift
init(modelPath: String, useNative: Bool = false) throws {
    // FIX: Use improved path sanitization
    let sanitizedPath = try Self.sanitizeModelPath(modelPath)
    
    self.modelPath = sanitizedPath
    self.modelName = URL(fileURLWithPath: sanitizedPath).deletingPathExtension().lastPathComponent
    
    // Verify model exists (redundant but explicit)
    guard FileManager.default.fileExists(atPath: sanitizedPath) else {
        throw ONNXError.modelNotFound(sanitizedPath)
    }
    
    // Create ONNX Runtime session
    let runtime = ONNXRuntimeWrapper(mode: useNative ? .automatic : .mock)
    let options = SessionOptions(
        intraOpNumThreads: ProcessInfo.processInfo.activeProcessorCount,
        graphOptimizationLevel: .all
    )
    
    do {
        self.session = try runtime.createSession(modelPath: sanitizedPath, options: options)
        Self.logger.info("✓ Loaded ONNX model: \(self.modelName)")
    } catch {
        throw ONNXError.sessionCreationFailed(error.localizedDescription)
    }
}
```

---

## Fix #4: Integer Overflow in Buffer Sizing

### Problem Location
`Sources/Vocana/Models/AudioEngine.swift:540`

### Current Vulnerable Code
```swift
private func appendToBufferAndExtractChunk(samples: [Float]) -> [Float]? {
    return audioBufferQueue.sync {
        let maxBufferSize = AppConstants.maxAudioBufferSize
        let projectedSize = _audioBuffer.count + samples.count  // ← OVERFLOW RISK
        
        if projectedSize > maxBufferSize {
            // Handle overflow
        }
    }
}
```

### Fixed Code
```swift
private func appendToBufferAndExtractChunk(samples: [Float]) -> [Float]? {
    return audioBufferQueue.sync {
        let maxBufferSize = AppConstants.maxAudioBufferSize
        
        // FIX: Use safe addition with overflow checking
        let (projectedSize, overflowed) = _audioBuffer.count.addingReportingOverflow(samples.count)
        
        // Handle overflow or size exceeded
        if overflowed || projectedSize > maxBufferSize {
            if overflowed {
                Self.logger.error("SECURITY: Integer overflow detected in buffer size calculation")
            }
            
            // Circuit breaker for sustained buffer overflows
            consecutiveOverflows += 1
            var updatedTelemetry = telemetry
            updatedTelemetry.recordAudioBufferOverflow()
            telemetry = updatedTelemetry
            
            if consecutiveOverflows > AppConstants.maxConsecutiveOverflows && !audioCaptureSuspended {
                updatedTelemetry = telemetry
                updatedTelemetry.recordCircuitBreakerTrigger()
                telemetry = updatedTelemetry
                Self.logger.warning("Circuit breaker triggered: \(self.consecutiveOverflows) consecutive overflows")
                Self.logger.info("Suspending audio capture for \(AppConstants.circuitBreakerSuspensionSeconds)s to allow ML to catch up")
                suspendAudioCapture(duration: AppConstants.circuitBreakerSuspensionSeconds)
                return nil // Skip this buffer append to help recovery
            }
            
            Self.logger.warning("Audio buffer overflow \(self.consecutiveOverflows): \(self._audioBuffer.count) + \(samples.count) would exceed \(maxBufferSize)")
            Self.logger.info("Applying crossfade to maintain audio continuity")
            
            // FIX: Safe calculation of how much to remove
            guard !overflowed else {
                // If overflow, just clear buffer to be safe
                _audioBuffer.removeAll(keepingCapacity: false)
                Self.logger.warning("Cleared audio buffer due to overflow condition")
                _audioBuffer.append(contentsOf: samples)
                
                guard _audioBuffer.count >= minimumBufferSize else {
                    return nil
                }
                let chunk = Array(_audioBuffer.prefix(minimumBufferSize))
                _audioBuffer.removeFirst(minimumBufferSize)
                return chunk
            }
            
            // Calculate how many samples need to be removed
            // projectedSize is safe (no overflow) but exceeds maxBufferSize
            let overflow = projectedSize - maxBufferSize
            let samplesToRemove = min(overflow, _audioBuffer.count)
            
            // Apply crossfade to prevent clicks/pops when dropping audio
            let fadeLength = min(AppConstants.crossfadeLengthSamples, samplesToRemove)
            
            // Remove old samples first
            if samplesToRemove > 0 {
                _audioBuffer.removeFirst(samplesToRemove)
            }
            
            // Apply fade-in to new samples if needed
            if fadeLength > 0 && samples.count >= fadeLength {
                var fadedSamples = samples
                for i in 0..<fadeLength {
                    let fade = Float(i + 1) / Float(fadeLength)
                    fadedSamples[i] *= fade
                }
                _audioBuffer.append(contentsOf: fadedSamples)
            } else {
                _audioBuffer.append(contentsOf: samples)
            }
        } else {
            // Reset overflow counter on successful append
            consecutiveOverflows = 0
            _audioBuffer.append(contentsOf: samples)
        }
        
        guard _audioBuffer.count >= minimumBufferSize else {
            return nil
        }
        let chunk = Array(_audioBuffer.prefix(minimumBufferSize))
        _audioBuffer.removeFirst(minimumBufferSize)
        return chunk
    }
}
```

---

## Fix #5: Sensitivity Input Validation

### Problem Location
`Sources/Vocana/Models/AppSettings.swift:46-52`

### Current Code
```swift
var sensitivity: Double {
    get { _sensitivityValue }
    set {
        let clamped = max(Validation.min, min(Validation.max, newValue))
        _sensitivityValue = clamped
        objectWillChange.send()
    }
}
```

### Fixed Code
```swift
var sensitivity: Double {
    get { _sensitivityValue }
    set {
        // FIX: Validate input is a valid number
        guard newValue.isFinite else {
            Self.logger.warning("Attempted to set invalid sensitivity: \(newValue)")
            // Silently reject invalid input, keep current value
            return
        }
        
        // Then clamp to valid range
        let clamped = max(Validation.min, min(Validation.max, newValue))
        
        // Only trigger update if value actually changed
        if clamped != _sensitivityValue {
            _sensitivityValue = clamped
            objectWillChange.send()
            
            // Log unusual values for monitoring
            if clamped != newValue {
                Self.logger.debug("Sensitivity clamped from \(newValue) to \(clamped)")
            }
        }
    }
}
```

### Add Validation to Init
```swift
init() {
    self.isEnabled = UserDefaults.standard.object(forKey: Keys.isEnabled) as? Bool ?? Defaults.isEnabled
    
    // Load and validate sensitivity
    let loadedSensitivity = UserDefaults.standard.object(forKey: Keys.sensitivity) as? Double ?? Defaults.sensitivity
    
    // FIX: Validate loaded value
    guard loadedSensitivity.isFinite else {
        Self.logger.warning("Invalid sensitivity loaded from UserDefaults: \(loadedSensitivity), using default")
        self._sensitivityValue = Defaults.sensitivity
        UserDefaults.standard.set(Defaults.sensitivity, forKey: Keys.sensitivity)
        return
    }
    
    let clampedSensitivity = max(Validation.min, min(Validation.max, loadedSensitivity))
    self._sensitivityValue = clampedSensitivity
    
    // Write back clamped value if it differs from loaded value
    if clampedSensitivity != loadedSensitivity {
        UserDefaults.standard.set(clampedSensitivity, forKey: Keys.sensitivity)
    }
    
    self.launchAtLogin = UserDefaults.standard.object(forKey: Keys.launchAtLogin) as? Bool ?? Defaults.launchAtLogin
    self.showInMenuBar = UserDefaults.standard.object(forKey: Keys.showInMenuBar) as? Bool ?? Defaults.showInMenuBar
}
```

---

## Testing All Fixes

```swift
// Test file: VocanaSecurityTests.swift

import XCTest
@testable import Vocana

class VocanaSecurityTests: XCTestCase {
    
    // Test Fix #3: Path Traversal
    func testPathTraversalPrevention() {
        let testCases = [
            ("../../../etc/passwd", false),           // Directory traversal
            ("/etc/passwd", false),                   // Absolute path
            ("Models/../../passwd", false),           // Mixed traversal
            ("Models/enc.onnx", true),                // Valid relative
            ("Models/sub/enc.onnx", true),            // Valid subdir
            ("Models/enc.txt", false),                // Wrong extension
            ("", false),                              // Empty
        ]
        
        for (path, shouldSucceed) in testCases {
            do {
                _ = try ONNXModel.sanitizeModelPath(path)
                if !shouldSucceed {
                    XCTFail("Should have rejected path: \(path)")
                }
            } catch {
                if shouldSucceed {
                    XCTFail("Should have accepted path: \(path), error: \(error)")
                }
            }
        }
    }
    
    // Test Fix #4: Integer Overflow
    func testBufferOverflowPrevention() {
        let audioEngine = AudioEngine()
        
        // Create samples that would overflow if unchecked
        let samples = [Float](repeating: 1.0, count: Int.max / 2)
        let chunk = audioEngine.appendToBufferAndExtractChunk(samples: samples)
        
        // Should not crash, should return nil or handle gracefully
        XCTAssertNil(chunk)
    }
    
    // Test Fix #5: Sensitivity Validation
    func testSensitivityValidation() {
        let settings = AppSettings()
        
        // Test NaN rejection
        let initialValue = settings.sensitivity
        settings.sensitivity = Double.nan
        XCTAssertEqual(settings.sensitivity, initialValue, "NaN should be rejected")
        
        // Test Infinity rejection
        settings.sensitivity = Double.infinity
        XCTAssertEqual(settings.sensitivity, initialValue, "Infinity should be rejected")
        
        // Test clamping
        settings.sensitivity = 10.0  // Beyond max
        XCTAssertEqual(settings.sensitivity, 1.0, "Should clamp to max")
        
        // Test valid range
        settings.sensitivity = 0.5
        XCTAssertEqual(settings.sensitivity, 0.5, "Should accept valid value")
    }
}
```

---

## Deployment Checklist

- [ ] Review all code changes with security lead
- [ ] Run all unit tests
- [ ] Enable AddressSanitizer and ThreadSanitizer
- [ ] Perform manual testing with edge cases
- [ ] Code review by peer
- [ ] Update documentation
- [ ] Create release notes highlighting security fixes
- [ ] Deploy to staging
- [ ] Final validation in staging
- [ ] Deploy to production with monitoring
- [ ] Monitor error logs for any issues

---

## Validation Commands

```bash
# Rust: Check for unsafe code
cargo clippy --all-targets --all-features -- -W clippy::undocumented_unsafe_blocks

# Swift: Build with sanitizers
swift build -Xswiftc -sanitize=thread -Xswiftc -sanitize-coverage=func

# Run tests
swift test

# Check for deprecated APIs
swift build 2>&1 | grep -i deprecated
```

