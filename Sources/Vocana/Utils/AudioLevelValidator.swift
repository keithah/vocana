import Foundation
import os.log

/// Utility for validating and sanitizing float audio level values
/// Ensures all values are safe for display and processing
struct AudioLevelValidator {
    private static let logger = Logger(subsystem: "Vocana", category: "AudioLevelValidator")
    
    /// Validate and clamp an audio level value to safe range
    /// - Checks for NaN, Infinity, denormal numbers
    /// - Clamps to valid range [0.0, 1.0] for display
    /// - Logs warnings for out-of-range values to assist debugging
    /// 
    /// Parameter Notes:
    /// - Expected range: [0.0, 1.0] representing 0-100% audio level
    /// - Values outside [-10.0, 10.0] indicate potential data corruption
    /// - NaN/Infinity indicate processing errors upstream
    /// 
    /// - Parameter value: The level value to validate
    /// - Returns: A safe value between 0.0 and 1.0, or 0.0 if invalid
    static func validateAudioLevel(_ value: Float) -> Float {
        // Security: Check for NaN and Infinity
        guard value.isFinite else {
            Self.logger.warning("Received non-finite audio level: \(value). Returning 0.0")
            return 0.0
        }
        
        // Security: Reject extreme values (audio levels should be reasonable)
        // Range [-10.0, 10.0] provides 10x headroom beyond normalized [0.0, 1.0] range
        // Values outside this suggest data corruption or malformed input
        guard value >= -10.0 && value <= 10.0 else {
            Self.logger.warning("Audio level \(value) exceeds safe range [-10.0, 10.0]. Returning 0.0")
            return 0.0
        }
        
        // Security: Check for subnormal numbers that could cause performance issues
        guard value.isNormal || value == 0.0 else {
            Self.logger.debug("Received subnormal audio level: \(value). Normalizing to 0.0")
            return 0.0
        }
        
        // Log warnings if value is outside normalized range (helps detect upstream issues)
        if (value < 0.0 || value > 1.0) && value.isFinite && (value.isNormal || value == 0.0) {
            Self.logger.debug("Audio level \(value) outside normalized range [0.0, 1.0]. Clamping.")
        }
        
        // Clamp to valid UI range [0.0, 1.0]
        return max(0.0, min(1.0, value))
    }
}
