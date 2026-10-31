import SwiftUI

struct ReportProblemAdvancedView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    @State private var autoSaveLogs = LogAutoSave.isEnabled

    var body: some View {
        List {
            Section(
                content: {
                    Toggle(isOn: $autoSaveLogs) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-save Logs")
                            Text("Automatically save a log export to this device's internal storage every 24 hours")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                },
                footer: {
                    Text(
                        "Saved shortly after midnight as a .zip file named after the day it covers, in the Files app under Trio › SavedLogs. Each file has the last 24 hours of logs, including glucose, insulin and carbs; passwords and serial numbers are removed. If Trio isn't running at midnight, the file is saved the next time it runs. Files stay on this device until you delete them."
                    )
                }
            )
            .listRowBackground(Color.chart)
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Advanced Options")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: autoSaveLogs) { _, enabled in
            LogAutoSave.setEnabled(enabled)
        }
    }
}
