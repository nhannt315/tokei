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
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Claim a dedicated Control Center slot. Without an autosaveName the item
        // lands in the shared "Item-N" pool, where a stale hidden flag left by any
        // previously removed status item keeps it invisible forever.
        item.autosaveName = "TokeiStatusItem"
        item.isVisible = true
        // Left-click toggles the popover; right-click opens Refresh/Quit menu.
        item.button?.action = #selector(statusItemClicked)
        item.button?.target = self
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        // Configure the visible button BEFORE building the popover content, so a
        // slow/faulting popover init can never leave the item blank.
        renderLabel()

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: UsagePopoverView(state: state) { [weak self] in self?.showMainWindow() })

        // Poll the label off AppState. A plain timer avoids re-arming Observation
        // tracking on the status item, which flickered the icon on each update.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderLabel() }
        }

        applyAppearance()
        NotificationCenter.default.addObserver(forName: AppearanceMode.didChange,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAppearance() }
        }

    }

    /// Apply the user's light/dark/system choice to every app surface. The
    /// status-item icon is intentionally left alone: it's a template image that
    /// follows the menu bar, not the app's chosen appearance.
    func applyAppearance() {
        let a = AppearanceMode.current.nsAppearance
        NSApp.appearance = a
        popover.appearance = a       // NSPopover does NOT inherit NSApp.appearance
        mainWindow?.appearance = a
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

    /// Left-click toggles the popover; right-click pops a small menu so the app
    /// stays quittable (the redesigned popover has no Quit button).
    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.close()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: loc("Open Tokei…"), action: #selector(showMainWindow), keyEquivalent: "o")
        menu.addItem(withTitle: loc("Refresh"), action: #selector(refreshNow), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: loc("Quit Tokei"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // Attaching to the item shows the menu on this click, then clears it so
        // the next left-click still toggles the popover rather than re-opening it.
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func refreshNow() {
        Task { await state.refresh(userInitiated: true) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Show the main window (Overview / Analytics / Settings). SwiftUI's
    /// `WindowGroup`/`Settings` scenes don't surface reliably from an
    /// `.accessory` app on recent macOS, so we own a plain `NSWindow`. The app
    /// promotes to `.regular` while it is open so the window can take focus, and
    /// drops back to `.accessory` on close to leave no lingering Dock icon.
    @objc func showMainWindow() {
        popover.close()
        NSApp.setActivationPolicy(.regular)

        if mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 500),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false)
            window.title = "Tokei"
            window.contentViewController = NSHostingController(rootView: MainWindowView(state: state))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            mainWindow = window
            applyAppearance()   // window created lazily → apply the current choice now
        }

        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === mainWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct TokeiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The app is driven entirely by the AppDelegate's NSStatusItem + NSWindow;
        // this empty settings scene just satisfies the App protocol.
        Settings { EmptyView() }
    }
}
