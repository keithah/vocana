import Foundation
import SwiftUI

/// Protocol for Audio Engine dependency injection
protocol AudioEngineProtocol: ObservableObject {
    var currentLevels: AudioLevels { get }
    var isUsingRealAudio: Bool { get }
    var isMLProcessingActive: Bool { get }
    var processingLatencyMs: Double { get }
    var hasPerformanceIssues: Bool { get }
    var bufferHealthMessage: String { get }
    
    func startSimulation(isEnabled: Bool, sensitivity: Double)
    func stopSimulation()
}

/// Protocol for App Settings dependency injection
protocol AppSettingsProtocol: ObservableObject {
    var isEnabled: Bool { get set }
    var sensitivity: Double { get set }
    var launchAtLogin: Bool { get set }
    var showInMenuBar: Bool { get set }
}

/// Factory for creating dependencies with proper lifecycle management
@MainActor
class DependencyFactory: ObservableObject {
    static let shared = DependencyFactory()
    
    private var audioEngine: AudioEngineProtocol?
    private var appSettings: AppSettingsProtocol?
    
    private init() {}
    
    func createAudioEngine() -> AudioEngineProtocol {
        if let existing = audioEngine {
            return existing
        }
        let new = AudioEngine()
        audioEngine = new
        return new
    }
    
    func createAppSettings() -> AppSettingsProtocol {
        if let existing = appSettings {
            return existing
        }
        let new = AppSettings()
        appSettings = new
        return new
    }
    
    func cleanup() {
        audioEngine = nil
        appSettings = nil
    }
}

/// ViewModel for ContentView with proper dependency injection
@MainActor
class ContentViewModel: ObservableObject {
    private let audioEngine: AudioEngineProtocol
    private let appSettings: AppSettingsProtocol
    
    @Published private(set) var showingAudioRouting = false
    
    init(audioEngine: AudioEngineProtocol, appSettings: AppSettingsProtocol) {
        self.audioEngine = audioEngine
        self.appSettings = appSettings
    }
    
    func openSettingsWindow() {
        #if os(macOS)
        let settingsWindow = SettingsWindow(audioEngine: audioEngine, settings: appSettings)
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        #endif
    }
    
    func showAudioRouting() {
        showingAudioRouting = true
    }
    
    func hideAudioRouting() {
        showingAudioRouting = false
    }
    
    // MARK: - Computed Properties for View
    
    var currentLevels: AudioLevels {
        audioEngine.currentLevels
    }
    
    var isUsingRealAudio: Bool {
        audioEngine.isUsingRealAudio
    }
    
    var isMLProcessingActive: Bool {
        audioEngine.isMLProcessingActive
    }
    
    var processingLatencyMs: Double {
        audioEngine.processingLatencyMs
    }
    
    var hasPerformanceIssues: Bool {
        audioEngine.hasPerformanceIssues
    }
    
    var bufferHealthMessage: String {
        audioEngine.bufferHealthMessage
    }
    
    var isEnabled: Bool {
        get { appSettings.isEnabled }
        set { 
            appSettings.isEnabled = newValue
            audioEngine.startSimulation(isEnabled: newValue, sensitivity: appSettings.sensitivity)
        }
    }
    
    var sensitivity: Double {
        get { appSettings.sensitivity }
        set { 
            appSettings.sensitivity = newValue
            audioEngine.startSimulation(isEnabled: appSettings.isEnabled, sensitivity: newValue)
        }
    }
}