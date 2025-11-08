import Foundation

/// Utility for validating and sanitizing float audio level values
/// Ensures all values are safe for display and processing
struct AudioLevelValidator {
    /// Validate and clamp an audio level value to safe range
    /// - Checks for NaN, Infinity, denormal numbers
    /// - Clamps to valid range [0.0, 1.0] for display
    /// - Parameter value: The level value to validate
    /// - Returns: A safe value between 0.0 and 1.0, or 0.0 if invalid
    static func validateAudioLevel(_ value: Float) -> Float {
        // Security: Check for NaN and Infinity
        guard value.isFinite else {
            return 0.0
        }
        
        // Security: Reject extreme values (audio levels should be reasonable)
        guard value >= -10.0 && value <= 10.0 else {
            return 0.0
        }
        
        // Security: Check for subnormal numbers that could cause performance issues
        guard value.isNormal || value == 0.0 else {
            return 0.0
        }
        
        // Clamp to valid UI range [0.0, 1.0]
        return max(0.0, min(1.0, value))
    }
}
