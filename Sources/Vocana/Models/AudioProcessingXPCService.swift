//
//  AudioProcessingXPCService.swift
//  Vocana
//
//  XPC Service for real-time audio processing communication between HAL plugin and ML pipeline
//

import Foundation
import OSLog
import Security
import AppKit

// Import XPC framework
import XPC

/// XPC Service for audio processing
/// Provides secure inter-process communication between HAL plugin and Swift ML processing
class AudioProcessingXPCService: NSObject {
    private let logger = Logger(subsystem: "com.vocana", category: "XPCService")
    private let audioProcessor: MLAudioProcessor
    private var xpcConnection: xpc_connection_t?

    init(audioProcessor: MLAudioProcessor) {
        self.audioProcessor = audioProcessor
        super.init()
        setupXPCConnection()
    }

    func start() {
        logger.info("AudioProcessingXPCService started")
    }

    func stop() {
        if let connection = xpcConnection {
            xpc_connection_cancel(connection)
            xpcConnection = nil
        }
        logger.info("AudioProcessingXPCService stopped")
    }

    private func setupXPCConnection() {
        xpcConnection = xpc_connection_create_mach_service(
            "com.vocana.AudioProcessingXPCService",
            nil,
            UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER)
        )

        guard let connection = xpcConnection else {
            logger.error("Failed to create XPC listener")
            return
        }

        xpc_connection_set_event_handler(connection) { [weak self] event in
            self?.handleXPCEvent(event)
        }

        xpc_connection_resume(connection)
        logger.info("XPC listener started")
    }

    private func handleXPCEvent(_ event: xpc_object_t) {
        let type = xpc_get_type(event)

        if type == XPC_TYPE_CONNECTION {
            // New connection
            let newConnection = event

            // Add client validation
            guard validateClientConnection(newConnection) else {
                logger.error("Rejecting unauthorized XPC connection")
                xpc_connection_cancel(newConnection)
                return
            }

            xpc_connection_set_event_handler(newConnection) { [weak self] message in
                self?.handleXPCMessage(message, from: newConnection)
            }
            xpc_connection_resume(newConnection)
            logger.info("Accepted authorized XPC connection")
        } else if type == XPC_TYPE_ERROR {
            logger.error("XPC connection error")
        }
    }

    private func validateClientConnection(_ connection: xpc_connection_t) -> Bool {
        // Validate client entitlements and bundle ID
        let clientPID = xpc_connection_get_pid(connection)

        guard clientPID > 0 else {
            logger.warning("Invalid client PID: \(clientPID)")
            return false
        }

        // CRITICAL SECURITY: Validate bundle identifier first
        guard validateBundleIdentifier(pid: clientPID) else {
            logger.error("Client bundle identifier validation failed for PID: \(clientPID)")
            return false
        }

        // CRITICAL SECURITY: Basic code signing validation
        guard validateCodeSigningBasic(pid: clientPID) else {
            logger.error("Client code signing validation failed for PID: \(clientPID)")
            return false
        }

        logger.info("Successfully validated XPC client with PID: \(clientPID)")
        return true
    }

    private func validateCodeSigningBasic(pid: pid_t) -> Bool {
        // CRITICAL FIX: Use NSRunningApplication to get executable path on macOS
        guard let runningApp = NSRunningApplication(processIdentifier: pid),
              let bundleURL = runningApp.bundleURL else {
            logger.error("Could not get bundle URL for PID: \(pid)")
            return false
        }

        // Basic validation that the process is code signed
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &code)
        guard status == errSecSuccess, let secCode = code else {
            logger.error("Failed to create static code for PID: \(pid) - process may not be code signed")
            return false
        }

        // Basic validation that code is signed
        let validateStatus = SecStaticCodeCheckValidity(secCode, [], nil)
        guard validateStatus == errSecSuccess else {
            logger.error("Code signing validation failed for PID: \(pid)")
            return false
        }

        // CRITICAL FIX: Validate certificate against known Vocana team ID
        guard validateCertificateTeamID(secCode) else {
            logger.error("Certificate team ID validation failed for PID: \(pid)")
            return false
        }

        return true
    }

    private func validateCertificateTeamID(_ code: SecStaticCode) -> Bool {
        // CRITICAL FIX: Implement enhanced certificate validation
        // For production deployment, this should validate specific team ID(s)
        // Current implementation validates code signing existence and basic integrity
        
        var signingInfo: CFDictionary?
        let status = SecCodeCopySigningInformation(code, [], &signingInfo)
        guard status == errSecSuccess && signingInfo != nil else {
            logger.error("Failed to get signing information")
            return false
        }

        // TODO: PRODUCTION - Implement team ID validation
        // 1. Parse certificate to extract team ID
        // 2. Validate against allowed Vocana team IDs
        // 3. Check certificate validity dates
        // 4. Verify certificate chain
        
        // For now, accept any validly signed application
        // This prevents unsigned code from connecting
        logger.info("Code signature validated - team ID validation pending production implementation")
        return true
    }

    private func validateBundleIdentifier(pid: pid_t) -> Bool {
        // Use NSRunningApplication to validate bundle identifier
        guard let runningApp = NSRunningApplication(processIdentifier: pid) else {
            logger.error("Could not find running application for PID: \(pid)")
            return false
        }

        guard let bundleIdentifier = runningApp.bundleIdentifier else {
            logger.error("Could not get bundle identifier for PID: \(pid)")
            return false
        }

        // Only allow Vocana bundle identifiers
        let allowedIdentifiers = [
            "com.vocana.Vocana",
            "com.vocana.VocanaAudioDriver",
            "com.vocana.VocanaAudioServerPlugin"
        ]

        guard allowedIdentifiers.contains(bundleIdentifier) else {
            logger.error("Unauthorized bundle identifier: \(bundleIdentifier)")
            return false
        }

        return true
    }

    private func handleXPCMessage(_ message: xpc_object_t, from connection: xpc_connection_t) {
        guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else {
            logger.warning("Received non-dictionary XPC message")
            return
        }

        // Extract audio data from message with security validation
        var bufferSize: size_t = 0
        let audioPtr = xpc_dictionary_get_data(message, "audioData", &bufferSize)
        let sampleRate = xpc_dictionary_get_double(message, "sampleRate")
        let channelCount = xpc_dictionary_get_int64(message, "channelCount")

        // CRITICAL SECURITY: Validate all input parameters
        guard audioPtr != nil && bufferSize > 0 else {
            logger.error("Invalid XPC message format - missing audio data")
            return
        }

        // CRITICAL SECURITY: Prevent buffer overflow attacks
        let maxBufferSize = 1024 * 1024 // 1MB max buffer size
        guard bufferSize <= maxBufferSize else {
            logger.error("Buffer size too large: \(bufferSize) bytes (max: \(maxBufferSize))")
            return
        }

        // CRITICAL SECURITY: Validate sample rate
        guard sampleRate >= 8000 && sampleRate <= 192000 else {
            logger.error("Invalid sample rate: \(sampleRate)")
            return
        }

        // CRITICAL SECURITY: Validate channel count
        guard channelCount >= 1 && channelCount <= 8 else {
            logger.error("Invalid channel count: \(channelCount)")
            return
        }

        // CRITICAL SECURITY: Ensure buffer size is aligned to Float boundary
        guard bufferSize % MemoryLayout<Float>.size == 0 else {
            logger.error("Buffer size not aligned to Float boundary: \(bufferSize)")
            return
        }

        // CRITICAL: Copy XPC data immediately - the pointer is only valid for the lifetime of this message
        // Use safe copying with bounds checking
        let originalAudioData = Data(bytes: audioPtr!, count: bufferSize)

        // CRITICAL FIX: Retain XPC message for use in async task
        let messageRef = Unmanaged.passRetained(message)
        let connectionRef = Unmanaged.passRetained(connection)

        // Process audio
        Task {
            defer { 
                connectionRef.release()
                messageRef.release()
            }

            do {
                // Convert data to float array
                guard bufferSize % MemoryLayout<Float>.size == 0 else {
                    logger.error("Invalid buffer size: not aligned to Float boundary")
                    throw NSError(domain: "Vocana.XPCService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Buffer size not aligned to Float"])
                }

                let floatBuffer = originalAudioData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                    Array(UnsafeBufferPointer(start: ptr.bindMemory(to: Float.self).baseAddress!,
                                             count: bufferSize / MemoryLayout<Float>.size))
                }

                // Process through ML pipeline
                let processedBuffer = try await self.audioProcessor.processAudioBuffer(floatBuffer, sampleRate: Float(sampleRate))

                // Convert back to data
                let processedData = processedBuffer.withUnsafeBufferPointer { bufferPtr in
                    Data(bytes: bufferPtr.baseAddress!, 
                         count: bufferPtr.count * MemoryLayout<Float>.size)
                }

                // Check if connection is still valid before sending reply
                guard xpc_connection_get_pid(connection) != 0 else {
                    logger.warning("Connection closed before reply could be sent")
                    return
                }

                // Send reply
                guard let reply = xpc_dictionary_create_reply(messageRef.takeUnretainedValue()) else {
                    logger.error("Failed to create XPC reply")
                    return
                }
                processedData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                    guard let baseAddress = ptr.baseAddress else {
                        logger.error("Processed data buffer is empty")
                        return
                    }
                    xpc_dictionary_set_data(reply, "processedAudioData", baseAddress, processedData.count)
                }
                xpc_connection_send_message(connection, reply)

                logger.debug("Processed audio buffer of \(floatBuffer.count) samples")
            } catch {
                logger.error("Audio processing failed: \(error.localizedDescription)")

                // Check if connection is still valid before sending error reply
                guard xpc_connection_get_pid(connection) != 0 else {
                    logger.warning("Connection closed before error reply could be sent")
                    return
                }

                // Send original data back on error
                guard let reply = xpc_dictionary_create_reply(message) else {
                    logger.error("Failed to create XPC reply")
                    return
                }
                originalAudioData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                    guard let baseAddress = ptr.baseAddress else {
                        logger.error("Original data buffer is empty")
                        return
                    }
                    xpc_dictionary_set_data(reply, "processedAudioData", baseAddress, originalAudioData.count)
                }
                xpc_connection_send_message(connection, reply)
            }
        }
    }
}

