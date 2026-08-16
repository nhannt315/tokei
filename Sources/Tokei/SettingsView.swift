import SwiftUI

struct SettingsView: View {
    @AppStorage(PercentageMode.defaultsKey) private var mode = PercentageMode.remaining.rawValue

    var body: some View {
        Form {
            Picker("Show percentage as", selection: $mode) {
                ForEach(PercentageMode.allCases, id: \.rawValue) { m in
                    Text(m.label).tag(m.rawValue)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(20)
        .frame(width: 340)
    }
}
