import Foundation
import ServiceManagement

/// Helper for managing launch at login functionality
///
/// Uses SMAppService (available in macOS 13+) to register the app
/// for launch at login with proper entitlements.
///
/// Features:
/// - Enable/disable launch at login
/// - Check current status
/// - Handle permissions gracefully
/// - Fallback for older macOS versions
///
/// Usage:
/// ```swift
/// LaunchAtLoginHelper.setLaunchAtLogin(true) { success in
///     print("Launch at login enabled: \(success)")
/// }
/// ```
enum LaunchAtLoginHelper {
    /// Enable or disable launch at login
    /// - Parameters:
    ///   - enabled: Whether to enable launch at login
    ///   - completion: Completion handler with success status
    static func setLaunchAtLogin(_ enabled: Bool, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                // Ensure completion is called on main thread
                DispatchQueue.main.async {
                    completion(isLaunchAtLoginEnabled())
                }
            }
            
            do {
                if #available(macOS 13.0, *) {
                    if enabled {
                        try SMAppService.mainApp.register()
                        os_log("Launch at login enabled", log: .default, type: .info)
                    } else {
                        try SMAppService.mainApp.unregister()
                        os_log("Launch at login disabled", log: .default, type: .info)
                    }
                } else {
                    // Fallback for older macOS versions
                    setLaunchAtLoginLegacy(enabled)
                    os_log("Launch at login set (legacy method)", log: .default, type: .info)
                }
            } catch {
                os_log("Failed to set launch at login: %{public}@", log: .default, type: .error, error.localizedDescription)
            }
        }
    }
    
    /// Check if launch at login is currently enabled
    /// - Returns: True if app will launch at login
    static func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            return status == .enabled
        } else {
            return isLaunchAtLoginEnabledLegacy()
        }
    }
    
    // MARK: - Legacy Support (macOS 12 and earlier)
    
    /// Legacy method using LaunchServices (for macOS 12 and earlier)
    private static func setLaunchAtLoginLegacy(_ enabled: Bool) {
        guard let appPath = Bundle.main.bundlePath as NSString? else {
            os_log("Failed to get app bundle path", log: .default, type: .error)
            return
        }
        
        let launchAgentPlist = NSHomeDirectory() + "/Library/LaunchAgents/com.vocana.app.plist"
        let launchAgentDir = NSHomeDirectory() + "/Library/LaunchAgents"
        
        let fileManager = FileManager.default
        
        // Ensure LaunchAgents directory exists
        try? fileManager.createDirectory(atPath: launchAgentDir, withIntermediateDirectories: true, attributes: nil)
        
        if enabled {
            // Create launch agent plist
            let plistDict: [String: Any] = [
                "Label": "com.vocana.app",
                "ProgramArguments": [appPath],
                "RunAtLoad": true,
                "StartInterval": 60,
                "StandardOutPath": NSHomeDirectory() + "/Library/Logs/Vocana.log",
                "StandardErrorPath": NSHomeDirectory() + "/Library/Logs/Vocana.log"
            ]
            
            if let plistData = try? PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0) {
                try? plistData.write(to: URL(fileURLWithPath: launchAgentPlist), options: .atomic)
                os_log("Created launch agent plist", log: .default, type: .info)
            }
        } else {
            // Remove launch agent plist
            try? fileManager.removeItem(atPath: launchAgentPlist)
            os_log("Removed launch agent plist", log: .default, type: .info)
        }
    }
    
    /// Check legacy launch at login status (for macOS 12 and earlier)
    private static func isLaunchAtLoginEnabledLegacy() -> Bool {
        let launchAgentPlist = NSHomeDirectory() + "/Library/LaunchAgents/com.vocana.app.plist"
        return FileManager.default.fileExists(atPath: launchAgentPlist)
    }
}

// MARK: - OSLog Extension

import os

extension OSLog {
    static let `default` = OSLog(subsystem: "com.vocana.app", category: "launch")
}
