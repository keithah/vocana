import Foundation

class AppSettings: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "isEnabled")
        }
    }
    
    @Published var sensitivity: Double {
        didSet {
            UserDefaults.standard.set(sensitivity, forKey: "sensitivity")
        }
    }
    
    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
        }
    }
    
    @Published var showInMenuBar: Bool {
        didSet {
            UserDefaults.standard.set(showInMenuBar, forKey: "showInMenuBar")
        }
    }
    
    init() {
        self.isEnabled = UserDefaults.standard.object(forKey: "isEnabled") as? Bool ?? false
        self.sensitivity = UserDefaults.standard.object(forKey: "sensitivity") as? Double ?? 0.5
        self.launchAtLogin = UserDefaults.standard.object(forKey: "launchAtLogin") as? Bool ?? false
        self.showInMenuBar = UserDefaults.standard.object(forKey: "showInMenuBar") as? Bool ?? true
    }
    
    func resetToDefaults() {
        isEnabled = false
        sensitivity = 0.5
        launchAtLogin = false
        showInMenuBar = true
    }
}