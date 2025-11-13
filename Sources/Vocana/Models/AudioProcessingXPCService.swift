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

    private func handleXPCEvent(_ event: xpc_object_t) {
        let type = xpc_get_type(event)

        if type == XPC_TYPE_CONNECTION {
            // New connection
            let newConnection = event
            xpc_connection_set_event_handler(newConnection) { [weak self] message in
                self?.handleXPCMessage(message, from: newConnection)
            }
            xpc_connection_resume(newConnection)
            logger.info("Accepted new XPC connection")
        } else if type == XPC_TYPE_ERROR {
            logger.error("XPC connection error")
        }
    }

    private func handleXPCMessage(_ message: xpc_object_t, from connection: xpc_connection_t) {
        guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else {
            logger.warning("Received non-dictionary XPC message")
            return
        }

        // Extract audio data from message
        var bufferSize: size_t = 0
        let audioPtr = xpc_dictionary_get_data(message, "audioData", &bufferSize)
        let sampleRate = xpc_dictionary_get_double(message, "sampleRate")
        _ = xpc_dictionary_get_int64(message, "channelCount") // channelCount not used in processing

        guard audioPtr != nil && bufferSize > 0 else {
            logger.error("Invalid XPC message format - missing audio data")
            return
        }

        // Process audio
        Task {
            do {
                // Convert data to float array
                guard let audioPtr = audioPtr else {
                    logger.error("Audio data is nil")
                    return
                }

                let floatBuffer = audioPtr.withMemoryRebound(to: Float.self, capacity: bufferSize / MemoryLayout<Float>.size) { floatPtr in
                    Array(UnsafeBufferPointer(start: floatPtr, count: bufferSize / MemoryLayout<Float>.size))
                }

                // Process through ML pipeline
                let processedBuffer = try await self.audioProcessor.processAudioBuffer(floatBuffer, sampleRate: Float(sampleRate))

                // Convert back to data
                let processedData = processedBuffer.withUnsafeBufferPointer { bufferPtr in
                    Data(buffer: bufferPtr)
                }

                // Send reply
                guard let reply = xpc_dictionary_create_reply(message) else {
                    logger.error("Failed to create XPC reply")
                    return
                }
                processedData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                    xpc_dictionary_set_data(reply, "processedAudioData", ptr.baseAddress!, processedData.count)
                }
                xpc_connection_send_message(connection, reply)

                logger.debug("Processed audio buffer of \(floatBuffer.count) samples")
            } catch {
                logger.error("Audio processing failed: \(error.localizedDescription)")

                // Send original data back on error
                guard let reply = xpc_dictionary_create_reply(message) else {
                    logger.error("Failed to create XPC reply")
                    return
                }
                xpc_dictionary_set_data(reply, "processedAudioData", audioPtr!, bufferSize)
                xpc_connection_send_message(connection, reply)
            }
        }
    }
}

