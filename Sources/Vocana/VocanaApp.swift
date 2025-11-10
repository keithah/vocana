import SwiftUI
import AppKit
import Combine
@preconcurrency import AVFoundation
import OSLog

enum VocanaError: Int, Error {
    case statusBarButtonFailure = 1
    case setupPopoverFailure = 2
    
    var localizedDescription: String {
        switch self {
        case .statusBarButtonFailure:
            return "Failed to get status bar button"
        case .setupPopoverFailure:
            return "Failed to setup popover"
        }
    }
}

@main
struct VocanaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
        requestMicrophonePermission()
    }
    
    var body: some Scene {
        WindowGroup {
            EmptyView()
        }
        .windowStyle(.hiddenTitleBar)
    }
    
    private func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Microphone Access Denied"
                    alert.informativeText = "Vocana needs access to your microphone to function. Please enable it in System Settings > Privacy & Security > Microphone."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "Vocana", category: "AppDelegate")
    
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    private var systemEventMonitor: Any?
    private var appSettings: AppSettings?
    private var audioCoordinator: AudioCoordinator?
    private var iconManager: MenuBarIconManager?
    
    @MainActor
    private var audioEngine: AudioEngine? {
        return audioCoordinator?.audioEngine
    }
    
    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try setupMenuBar()
            setupSystemEventMonitoring()
            
            // Hide main window since we're a menu bar app
            if let window = NSApplication.shared.windows.first {
                window.close()
            }
            
            // Set up menu bar behavior
            updateMenuBarVisibility()
            
            // Register for system notifications
            registerSystemNotifications()
        } catch {
            handleError(error)
        }
    }
    
    private func handleError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Ensure proper resource cleanup before app termination
        Task { @MainActor in
            // Close popover and clean up UI resources
            popover?.close()
            popover = nil
            
            // Remove status bar item
            if let statusItem = statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
                self.statusItem = nil
            }
            
            // Unregister system event monitoring
            if let monitor = systemEventMonitor {
                NSEvent.removeMonitor(monitor)
            }
            
            // Unregister system notifications
            NotificationCenter.default.removeObserver(self)
            
            // Clean up Combine subscriptions
            iconManager?.cleanup()
            cancellables.removeAll()
            
            // Note: ContentView and AudioEngine will be cleaned up via deinit
            // when popover is deallocated, ensuring proper audio session cleanup
        }
        
        return .terminateNow
    }
    
    // MARK: - System Event Monitoring
    
    private func setupSystemEventMonitoring() {
        // Monitor keyboard events for app-wide shortcuts
        // This would be used for global hotkeys if implemented
    }
    
    private func registerSystemNotifications() {
        // Monitor for system sleep/wake
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        
        // Monitor for user session changes
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleUserSessionChange),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
    }
    
    @objc private func handleSystemSleep() {
        // Pause audio processing when system sleeps
        // Close popover to save memory
        if let popover = popover, popover.isShown {
            popover.performClose(nil)
        }
    }
    
    @objc private func handleSystemWake() {
        // Resume audio processing when system wakes
    }
    
    @objc private func handleUserSessionChange() {
        // Handle user session changes (switching users, session resume)
    }
    
    // MARK: - Menu Bar Management
    
    @MainActor
    private func updateMenuBarVisibility() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Initialize app settings on main thread
            if self.appSettings == nil {
                self.appSettings = AppSettings()
            }
            
            if let appSettings = self.appSettings, !appSettings.showInMenuBar {
                // Optionally hide from menu bar if user preference
                // This is typically not used, but available for advanced users
            }
        }
    }
    
    @MainActor
    private func setupMenuBar() throws {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        guard let button = statusItem?.button else {
            throw VocanaError.statusBarButtonFailure
        }
        
        // Icon will be set up by MenuBarIconManager after popover is created
        button.action = #selector(menuBarClicked)
        button.target = self
        
        setupPopover()
    }
    
    @MainActor
    private func setupMenuBarIconUpdates() {
        guard let audioEngine = audioEngine, let settings = audioCoordinator?.settings else { 
            Self.logger.error("setupMenuBarIconUpdates: No audio engine or settings available")
            return 
        }
        
        // Initialize icon manager
        iconManager = MenuBarIconManager()
        
        Self.logger.debug("Setting up consolidated menu bar icon updates...")
        
        // Consolidate multiple publishers into single update stream for performance
        Publishers.CombineLatest3(
            audioEngine.$isUsingRealAudio,
            audioEngine.$currentLevels,
            settings.$isEnabled
        )
        .debounce(for: .milliseconds(16), scheduler: DispatchQueue.main) // 60fps max
        .sink { [weak self] isUsingRealAudio, _, isEnabled in
            // Update icon manager state - UI will refresh automatically when state changes
            self?.iconManager?.updateState(isEnabled: isEnabled, isUsingRealAudio: isUsingRealAudio)
        }
        .store(in: &cancellables)
        
        // Initial setup - apply current state to button
        if let button = statusItem?.button {
            iconManager?.applyToButton(button)
        }
    }
    
    private var cancellables = Set<AnyCancellable>()
    
    @MainActor
    private func setupPopover() {
        popover = NSPopover()
        popover?.contentSize = NSSize(width: AppConstants.popoverWidth, height: AppConstants.popoverHeight)
        popover?.behavior = .transient
        
        // Create audio coordinator and content view
        audioCoordinator = AudioCoordinator()
        let contentView = ContentView(coordinator: audioCoordinator!)
        popover?.contentViewController = NSHostingController(rootView: contentView)
        
        // Setup menu bar icon updates AFTER audioCoordinator is created
        setupMenuBarIconUpdates()
    }
    
    @objc private func menuBarClicked() {
        guard let button = statusItem?.button else { return }
        guard let popover = popover else { return }
        
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        button.isHighlighted = popover.isShown
    }
}