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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var refreshTimer: Timer?

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
        popover.contentViewController = NSHostingController(rootView: UsagePopoverView(state: state))

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
}

@main
struct TokeiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
