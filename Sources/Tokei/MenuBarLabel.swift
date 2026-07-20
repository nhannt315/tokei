import SwiftUI

/// Menu bar label: SF Symbol + remaining-quota % (cost fallback). Template
/// rendering — symbol variant, not color, signals the warning state.
struct MenuBarLabel: View {
    let state: AppState

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: state.menuBarWarning ? "exclamationmark.triangle" : "gauge.with.needle")
            Text(state.menuBarText)
        }
        .task {
            // Menu-bar-only: no Dock icon when run via `swift run`
            // (the bundle also sets LSUIElement).
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }
}
