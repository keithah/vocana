import SwiftUI
import AppKit
import AVFoundation

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
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    
    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try setupMenuBar()
            
            // Hide main window since we're a menu bar app
            if let window = NSApplication.shared.windows.first {
                window.close()
            }
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
        return .terminateNow
    }
    
    @MainActor
    private func setupMenuBar() throws {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        guard let button = statusItem?.button else {
            throw VocanaError.statusBarButtonFailure
        }
        
        button.image = NSImage(systemSymbolName: "waveform.and.mic", accessibilityDescription: "Vocana")
        button.action = #selector(menuBarClicked)
        button.target = self
        
        setupPopover()
    }
    
    @MainActor
    private func setupPopover() {
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 300, height: 400)
        popover?.behavior = .transient
        
        let contentView = ContentView()
        popover?.contentViewController = NSHostingController(rootView: contentView)
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