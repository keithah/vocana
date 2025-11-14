import Foundation

/// Centralized error handling for Vocana application
/// Provides user-friendly error messages and proper error categorization
enum AudioAppError: LocalizedError, Equatable {
    case audioSessionFailed(String)
    case audioEngineInitializationFailed(String)
    case mlModelLoadFailed(String)
    case mlProcessingFailed(String)
    case memoryPressure(String)
    case bufferOverflow(String)
    case circuitBreakerTriggered(String)
    case virtualDeviceNotFound(String)
    case permissionDenied(String)
    case unknown(String)
    
    var errorDescription: String? {
        switch self {
        case .audioSessionFailed(let details):
            return "Audio session error: \(details)"
        case .audioEngineInitializationFailed(let details):
            return "Failed to initialize audio engine: \(details)"
        case .mlModelLoadFailed(let details):
            return "Failed to load ML models: \(details)"
        case .mlProcessingFailed(let details):
            return "Audio processing error: \(details)"
        case .memoryPressure(let details):
            return "System memory pressure: \(details)"
        case .bufferOverflow(let details):
            return "Audio buffer overflow: \(details)"
        case .circuitBreakerTriggered(let details):
            return "Audio processing paused: \(details)"
        case .virtualDeviceNotFound(let details):
            return "Virtual audio device not found: \(details)"
        case .permissionDenied(let details):
            return "Permission denied: \(details)"
        case .unknown(let details):
            return "Unexpected error: \(details)"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .audioSessionFailed:
            return "Please check your audio settings and restart the application"
        case .audioEngineInitializationFailed:
            return "Try restarting the application or checking your audio device connections"
        case .mlModelLoadFailed:
            return "Please ensure the ML models are properly installed and restart the application"
        case .mlProcessingFailed:
            return "Audio processing will continue with basic noise reduction"
        case .memoryPressure:
            return "Close other applications to free up memory"
        case .bufferOverflow:
            return "Audio processing will automatically recover"
        case .circuitBreakerTriggered:
            return "Audio processing will resume automatically"
        case .virtualDeviceNotFound:
            return "Please install the Vocana HAL plugin for virtual audio device support"
        case .permissionDenied:
            return "Please grant microphone access in System Preferences"
        case .unknown:
            return "Try restarting the application"
        }
    }
    
    var severity: ErrorSeverity {
        switch self {
        case .audioSessionFailed, .audioEngineInitializationFailed, .mlModelLoadFailed, .permissionDenied:
            return .critical
        case .mlProcessingFailed, .memoryPressure, .virtualDeviceNotFound:
            return .warning
        case .bufferOverflow, .circuitBreakerTriggered:
            return .info
        case .unknown:
            return .warning
        }
    }
}

/// Error severity levels for user notification
enum ErrorSeverity {
    case info
    case warning
    case critical
}

/// Centralized error handler for the application
@MainActor
class ErrorHandler: ObservableObject {
    static let shared = ErrorHandler()
    
    @Published var currentError: AudioAppError?
    @Published var showError = false
    
    private init() {}
    
    /// Handle an error with user notification
    /// - Parameter error: The error to handle
    func handle(_ error: Error) {
        let audioError = mapToAudioAppError(error)
        currentError = audioError
        showError = true
        
        // Log the error for debugging
        logError(audioError)
        
        // Auto-dismiss info-level errors after 3 seconds
        if audioError.severity == .info {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                if self?.currentError == audioError {
                    self?.dismissError()
                }
            }
        }
    }
    
    /// Dismiss the current error
    func dismissError() {
        currentError = nil
        showError = false
    }
    
    /// Map generic errors to AudioAppError
    private func mapToAudioAppError(_ error: Error) -> AudioAppError {
        if let audioError = error as? AudioAppError {
            return audioError
        }
        
        // Map AVFoundation errors
        if let avError = error as? AVAudioSession.ErrorCode {
            switch avError {
            case .cannotInterruptOthers, .cannotStartRecording, .cannotStartPlaying:
                return .audioSessionFailed(error.localizedDescription)
            case .insufficientPriority:
                return .audioSessionFailed("Insufficient audio priority")
            case .isBusy:
                return .audioSessionFailed("Audio session is busy")
            case .mediaServicesWereLost:
                return .audioSessionFailed("Media services were lost")
            case .mediaServicesWereReset:
                return .audioSessionFailed("Media services were reset")
            case .incompatibleCategory:
                return .audioSessionFailed("Incompatible audio category")
            case .isDisallowed:
                return .permissionDenied("Audio access is disallowed")
            default:
                return .audioSessionFailed(error.localizedDescription)
            }
        }
        
        // Map ML processing errors
        if let mlError = error as? MLAudioProcessor.MLAudioProcessorError {
            return .mlProcessingFailed(mlError.localizedDescription)
        }
        
        return .unknown(error.localizedDescription)
    }
    
    /// Log error for debugging
    private func logError(_ error: AudioAppError) {
        let osLog = OSLog(subsystem: "Vocana", category: "ErrorHandler")
        
        let logType: OSLogType
        switch error.severity {
        case .critical:
            logType = .fault
        case .warning:
            logType = .error
        case .info:
            logType = .info
        }
        
        os_log("%{public}@", log: osLog, type: logType, error.localizedDescription)
    }
}

/// Extension for easy error handling
extension ErrorHandler {
    /// Convenience method to handle common audio errors
    func handleAudioError(_ error: Error?, context: String = "") {
        guard let error = error else { return }
        
        let contextInfo = context.isEmpty ? "" : " (\(context))"
        let audioError = mapToAudioAppError(error)
        
        // Add context to error description if needed
        if !context.isEmpty {
            currentError = AudioAppError.unknown("\(audioError.localizedDescription)\(contextInfo)")
        } else {
            currentError = audioError
        }
        
        showError = true
        logError(currentError!)
    }
}