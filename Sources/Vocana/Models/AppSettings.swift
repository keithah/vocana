import Foundation
import Combine
import OSLog

@MainActor
class AppSettings: ObservableObject {
    private static let logger = Logger(subsystem: "Vocana", category: "AppSettings")
    
    // MARK: - Constants
    
    private enum Keys {
        static let isEnabled = "isEnabled"
        static let sensitivity = "sensitivity"
        static let launchAtLogin = "launchAtLogin"
        static let showInMenuBar = "showInMenuBar"
    }
    
    private enum Defaults {
        static let isEnabled = false
        static let sensitivity: Double = {
            let value = 0.5
            assert(AppConstants.sensitivityRange.contains(value), "Default sensitivity must be within valid range")
            return value
        }()
        static let launchAtLogin = false
        static let showInMenuBar = true
    }
    
    private enum Validation {
        static let range = AppConstants.sensitivityRange
        static var min: Double { range.lowerBound }
        static var max: Double { range.upperBound }
    }
    
    // MARK: - Published Properties
    
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.isEnabled)
        }
    }
    
    private var _sensitivityValue: Double = Defaults.sensitivity {
        didSet {
            UserDefaults.standard.set(_sensitivityValue, forKey: Keys.sensitivity)
        }
    }
    
    var sensitivity: Double {
        get { _sensitivityValue }
        set {
            let clamped = max(Validation.min, min(Validation.max, newValue))
            _sensitivityValue = clamped
            objectWillChange.send()
        }
    }
    
    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin)
            // Update system launch at login setting with error handling
            LaunchAtLoginHelper.setLaunchAtLogin(launchAtLogin) { [weak self] success in
                DispatchQueue.main.async {
                    self?.handleLaunchAtLoginResult(success)
                }
            }
        }
    }
    
    // MARK: - Private Error Handling
    
    private func initializeLaunchAtLogin() {
        LaunchAtLoginHelper.setLaunchAtLogin(launchAtLogin) { [weak self] success in
            DispatchQueue.main.async {
                self?.handleLaunchAtLoginResult(success)
            }
        }
    }
    
    private func handleLaunchAtLoginResult(_ success: Bool) {
        if success {
            Self.logger.debug("Launch at login setting updated successfully")
        } else {
            Self.logger.error("Failed to update launch at login")
            // Consider reverting the setting or notifying user
            // For now, we'll log the error but keep the setting
        }
    }
    
    @Published var showInMenuBar: Bool {
        didSet {
            UserDefaults.standard.set(showInMenuBar, forKey: Keys.showInMenuBar)
        }
    }
    
    // MARK: - Initialization
    
    init() {
        self.isEnabled = UserDefaults.standard.object(forKey: Keys.isEnabled) as? Bool ?? Defaults.isEnabled
        
        // Load and validate sensitivity
        let loadedSensitivity = UserDefaults.standard.object(forKey: Keys.sensitivity) as? Double ?? Defaults.sensitivity
        let clampedSensitivity = max(Validation.min, min(Validation.max, loadedSensitivity))
        self._sensitivityValue = clampedSensitivity
        
        // Write back clamped value if it differs from loaded value
        if clampedSensitivity != loadedSensitivity {
            UserDefaults.standard.set(clampedSensitivity, forKey: Keys.sensitivity)
        }
        
        self.launchAtLogin = UserDefaults.standard.object(forKey: Keys.launchAtLogin) as? Bool ?? Defaults.launchAtLogin
        self.showInMenuBar = UserDefaults.standard.object(forKey: Keys.showInMenuBar) as? Bool ?? Defaults.showInMenuBar
        
        // Initialize launch at login with error handling
        initializeLaunchAtLogin()
    }
    
    // MARK: - Methods
    
    func resetToDefaults() {
        isEnabled = Defaults.isEnabled
        sensitivity = Defaults.sensitivity
        launchAtLogin = Defaults.launchAtLogin
        showInMenuBar = Defaults.showInMenuBar
    }
}