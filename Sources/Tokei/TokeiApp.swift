import AppKit
import Observation
import SwiftUI

/// Menu-bar app driven by an explicit AppKit NSStatusItem.
///
/// SwiftUI's `MenuBarExtra` does not guarantee strong retention of its
/// underlying status item on macOS 26: at launch the item is sometimes torn
/// down before the scene holds it, AppKit logs `StatusBar 0 terminating on
/// removal`, and the accessory app quits ~180ms in. Owning the NSStatusItem
/// here (strong property, lives as long as the delegate) sidesteps that gap.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let state = AppState()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var refreshTimer: Timer?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Claim a dedicated Control Center slot. Without an autosaveName the item
        // lands in the shared "Item-N" pool, where a stale hidden flag left by any
        // previously removed status item keeps it invisible forever.
        item.autosaveName = "TokeiStatusItem"
        item.isVisible = true
        item.button?.action = #selector(togglePopover)
        item.button?.target = self
        statusItem = item

        // Configure the visible button BEFORE building the popover content, so a
        // slow/faulting popover init can never leave the item blank.
        renderLabel()

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: UsagePopoverView(state: state) { [weak self] in self?.showSettings() })

        // Poll the label off AppState. A plain timer avoids re-arming Observation
        // tracking on the status item, which flickered the icon on each update.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderLabel() }
        }
    }

    private func renderLabel() {
        guard let button = statusItem?.button else { return }
        let symbol = state.menuBarWarning ? "exclamationmark.triangle" : "gauge.with.needle"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Tokei")
        image?.isTemplate = true          // adopt the menu bar's tint (light/dark)
        button.image = image
        button.imagePosition = .imageLeading
        button.title = " " + state.menuBarText
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.close()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Show a settings window. SwiftUI's `Settings` scene does not surface reliably
    /// from an `.accessory` app on macOS 26 (`showSettingsWindow:` promotes the app
    /// but opens no window), so we own a plain `NSWindow` hosting `SettingsView`.
    /// The app promotes to `.regular` while it is open so the window can take focus,
    /// and drops back to `.accessory` on close to leave no lingering Dock icon.
    @objc func showSettings() {
        popover.close()
        NSApp.setActivationPolicy(.regular)

        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false)
            window.title = "Settings"
            window.contentViewController = NSHostingController(rootView: SettingsView())
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct TokeiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { SettingsView() }
    }
}
