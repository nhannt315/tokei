import SwiftUI

@main
struct TokeiApp: App {
    @State private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            UsagePopoverView(state: state)
        } label: {
            MenuBarLabel(state: state)
        }
        .menuBarExtraStyle(.window)
    }
}
