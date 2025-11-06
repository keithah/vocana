import SwiftUI
import AppKit
import AVFoundation

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
        // macOS handles microphone permissions through system prompts
        // We'll check and request permissions when needed
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    
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
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Error"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return .terminateNow
    }
    
    @MainActor
    private func setupMenuBar() throws {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        guard let button = statusItem?.button else {
            throw NSError(domain: "VocanaError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to get status bar button"])
        }
        
        button.image = NSImage(systemSymbolName: "waveform.and.mic", accessibilityDescription: "Vocana")
        button.action = #selector(menuBarClicked)
        button.target = self
        
        try setupPopover()
    }
    
    @MainActor
    private func setupPopover() throws {
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