import Foundation
import Vocana

// Simple test to check if ML models load
print("Testing ML model loading...")

do {
    let modelsPath = "Resources/Models"
    let encPath = "\(modelsPath)/enc.onnx"
    let erbDecPath = "\(modelsPath)/erb_dec.onnx"
    let dfDecPath = "\(modelsPath)/df_dec.onnx"

    let fileManager = FileManager.default

    if fileManager.fileExists(atPath: encPath) {
        print("✅ enc.onnx found")
    } else {
        print("❌ enc.onnx not found")
    }

    if fileManager.fileExists(atPath: erbDecPath) {
        print("✅ erb_dec.onnx found")
    } else {
        print("❌ erb_dec.onnx not found")
    }

    if fileManager.fileExists(atPath: dfDecPath) {
        print("✅ df_dec.onnx found")
    } else {
        print("❌ df_dec.onnx not found")
    }

    // Try to create ONNXModel instances
    print("Testing ONNXModel creation...")

    let runtime = ONNXRuntimeWrapper(mode: .automatic)
    print("Runtime mode: automatic")

    let encSession = try runtime.createSession(modelPath: encPath)
    print("✅ Encoder session created")

    let erbDecSession = try runtime.createSession(modelPath: erbDecPath)
    print("✅ ERB decoder session created")

    let dfDecSession = try runtime.createSession(modelPath: dfDecPath)
    print("✅ DF decoder session created")

    print("All ML models loaded successfully!")

} catch {
    print("❌ Error: \(error.localizedDescription)")
}