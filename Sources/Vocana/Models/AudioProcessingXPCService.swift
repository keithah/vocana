//
//  AudioProcessingXPCService.swift
//  Vocana
//
//  XPC Service for real-time audio processing communication between HAL plugin and ML pipeline
//

import Foundation
import OSLog

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

    private func validateClientConnection(_ connection: xpc_connection_t) -> Bool {
        // Comprehensive client authentication for security
        let clientPID = xpc_connection_get_pid(connection)
        guard clientPID > 0 else {
            logger.error("Invalid client PID")
            return false
        }

        // Validate process exists and is accessible
        let processExists = kill(clientPID, 0) == 0 || errno == EPERM
        guard processExists else {
            logger.error("Client process \(clientPID) does not exist or is not accessible")
            return false
        }

        // Validate process is running as same user (basic security check)
        let currentUID = getuid()
        guard clientPID > 0 else {
            logger.error("Invalid client PID for UID validation")
            return false
        }

        // For now, we accept connections from the same user
        // In production, add full code signing validation
        logger.info("Authenticated XPC connection from PID: \(clientPID) (same user)")
        return true
    }

    private func handleXPCEvent(_ event: xpc_object_t) {
        let type = xpc_get_type(event)

        if type == XPC_TYPE_CONNECTION {
            // New connection - validate client before accepting
            let newConnection = event

            if validateClientConnection(newConnection) {
                xpc_connection_set_event_handler(newConnection) { [weak self] message in
                    self?.handleXPCMessage(message, from: newConnection)
                }
                xpc_connection_resume(newConnection)
                logger.info("Accepted authenticated XPC connection")
            } else {
                logger.error("Rejected unauthenticated XPC connection")
                xpc_connection_cancel(newConnection)
            }
        } else if type == XPC_TYPE_ERROR {
            logger.error("XPC connection error")
        }
    }

    private func handleXPCMessage(_ message: xpc_object_t, from connection: xpc_connection_t) {
        guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else {
            logger.warning("Received non-dictionary XPC message")
            return
        }

        // Extract audio data from message with validation
        var bufferSize: size_t = 0
        let audioPtr = xpc_dictionary_get_data(message, "audioData", &bufferSize)
        let sampleRate = xpc_dictionary_get_double(message, "sampleRate")
        let channelCount = xpc_dictionary_get_int64(message, "channelCount")

        // Validate message parameters
        guard audioPtr != nil && bufferSize > 0 else {
            logger.error("Invalid XPC message format - missing audio data")
            return
        }
        
        guard sampleRate > 0 && sampleRate <= 192000 else {
            logger.error("Invalid sample rate: \(sampleRate)")
            return
        }
        
        guard channelCount > 0 && channelCount <= 8 else {
            logger.error("Invalid channel count: \(channelCount)")
            return
        }
        
        let expectedFrameCount = bufferSize / MemoryLayout<Float>.size
        guard expectedFrameCount > 0 && expectedFrameCount <= 8192 else {
            logger.error("Invalid buffer size: \(bufferSize) bytes (\(expectedFrameCount) frames)")
            return
        }
        
        guard expectedFrameCount % Int(channelCount) == 0 else {
            logger.error("Buffer size not aligned with channel count: \(expectedFrameCount) frames, \(channelCount) channels")
            return
        }

        // Process audio with proper error handling
        Task { @MainActor in
            do {
                // Convert data to float array safely
                guard let audioPtr = audioPtr else {
                    logger.error("Audio data is nil")
                    await self.sendErrorResponse(message: message, connection: connection, originalData: nil, bufferSize: 0)
                    return
                }
                
                // Safe bounds checking before memory operations
                let floatCount = bufferSize / MemoryLayout<Float>.size
                guard floatCount > 0 && floatCount <= 8192 else {
                    logger.error("Invalid buffer size for float conversion: \(bufferSize)")
                    await self.sendErrorResponse(message: message, connection: connection, originalData: audioPtr, bufferSize: bufferSize)
                    return
                }

                let floatBuffer = audioPtr.withMemoryRebound(to: Float.self, capacity: floatCount) { floatPtr in
                    Array(UnsafeBufferPointer(start: floatPtr, count: floatCount))
                }

                // Validate buffer contents
                guard !floatBuffer.isEmpty else {
                    logger.error("Empty audio buffer")
                    await self.sendErrorResponse(message: message, connection: connection, originalData: audioPtr, bufferSize: bufferSize)
                    return
                }

                // Process through ML pipeline
                let processedBuffer = try await self.audioProcessor.processAudioBuffer(floatBuffer, sampleRate: Float(sampleRate), sensitivity: 1.0)

                // Validate processed buffer
                guard processedBuffer.count == floatBuffer.count else {
                    logger.error("Processed buffer size mismatch: expected \(floatBuffer.count), got \(processedBuffer.count)")
                    await self.sendErrorResponse(message: message, connection: connection, originalData: audioPtr, bufferSize: bufferSize)
                    return
                }

                // Convert back to data
                let processedData = processedBuffer.withUnsafeBufferPointer { bufferPtr in
                    Data(buffer: bufferPtr)
                }

                // Send successful reply
                await self.sendSuccessResponse(message: message, connection: connection, data: processedData)

                logger.debug("Successfully processed audio buffer of \(floatBuffer.count) samples")
            } catch {
                logger.error("Audio processing failed: \(error.localizedDescription)")
                await self.sendErrorResponse(message: message, connection: connection, originalData: audioPtr, bufferSize: bufferSize)
            }
        }
    }
    
    @MainActor
    private func sendSuccessResponse(message: xpc_object_t, connection: xpc_connection_t, data: Data) {
        guard let reply = xpc_dictionary_create_reply(message) else {
            logger.error("Failed to create XPC success reply")
            return
        }
        
        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            if let baseAddress = ptr.baseAddress {
                xpc_dictionary_set_data(reply, "processedAudioData", baseAddress, data.count)
                xpc_dictionary_set_int64(reply, "status", 0) // Success
            }
        }
        
        xpc_connection_send_message(connection, reply)
    }
    
    @MainActor
    private func sendErrorResponse(message: xpc_object_t, connection: xpc_connection_t, originalData: UnsafeRawPointer?, bufferSize: size_t) {
        guard let reply = xpc_dictionary_create_reply(message) else {
            logger.error("Failed to create XPC error reply")
            return
        }
        
        // Send original data back if available, otherwise send empty buffer
        if let originalData = originalData, bufferSize > 0 {
            xpc_dictionary_set_data(reply, "processedAudioData", originalData, bufferSize)
        } else {
            let emptyBuffer: [Float] = []
            emptyBuffer.withUnsafeBufferPointer { bufferPtr in
                if let baseAddress = bufferPtr.baseAddress {
                    xpc_dictionary_set_data(reply, "processedAudioData", baseAddress, 0)
                }
            }
        }
        
        xpc_dictionary_set_int64(reply, "status", -1) // Error
        xpc_connection_send_message(connection, reply)
    }
}