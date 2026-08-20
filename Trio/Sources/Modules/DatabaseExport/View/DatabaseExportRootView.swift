import SwiftUI
import Swinject

extension DatabaseExport {
    struct RootView: BaseView {
        let resolver: Resolver
        @StateObject var state = StateModel()

        @State private var showShareSheet = false
        @State private var showExportError = false
        @State private var exportErrorMessage = ""
        @State private var exportedFileURL: URL?

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            List {
                Section(
                    header: Text("Database Export"),
                    footer: Text(
                        "This creates a ZIP archive containing the full Trio database and your configuration files, including your personal health data (glucose, insulin, carbs, and therapy settings). Credentials stored in the keychain are not included. Only share this archive with people you trust."
                    ),
                    content: {
                        Text(
                            "Export a complete snapshot of Trio's data for troubleshooting, migration, or analysis."
                        )
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    }
                ).listRowBackground(Color.chart)

                Section {
                    Button(action: {
                        Task {
                            let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
                            impactHeavy.impactOccurred()

                            switch await state.exportDatabase() {
                            case let .success(fileURL):
                                if FileManager.default.fileExists(atPath: fileURL.path),
                                   let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                                   (attributes[.size] as? Int ?? 0) > 0
                                {
                                    exportedFileURL = fileURL
                                    showShareSheet = true
                                } else {
                                    exportErrorMessage = String(localized: "Export file is empty or could not be found")
                                    showExportError = true
                                }
                            case let .failure(error):
                                exportErrorMessage = error.localizedDescription
                                showExportError = true
                            }
                        }
                    }, label: {
                        if state.isExporting {
                            HStack {
                                ProgressView().padding(.trailing, 10)
                                Text("Exporting...")
                            }
                        } else {
                            Text("Export Database")
                        }
                    })
                        .disabled(state.isExporting)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .tint(.white)
                }.listRowBackground(
                    state.isExporting ? Color(.systemGray4) : Color(.systemBlue)
                )
            }
            .listSectionSpacing(sectionSpacing)
            .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
            .navigationTitle("Export Database")
            .navigationBarTitleDisplayMode(.automatic)
            .sheet(isPresented: $showShareSheet) {
                if let fileURL = exportedFileURL {
                    ShareSheet(activityItems: [fileURL])
                }
            }
            .alert("Export Error", isPresented: $showExportError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportErrorMessage)
            }
        }
    }
}
