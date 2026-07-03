import SwiftUI

struct SettingsView: View {
    @ObservedObject var gameManager: GameManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.05, green: 0.08, blue: 0.15)
                    .ignoresSafeArea()

                Form {
                    Section {
                        Toggle(isOn: $gameManager.jitEnabled) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("JIT Acceleration")
                                Text("Speeds up hot loops by caching decoded instructions. Auto-tunes for A-series chips.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .tint(Color(red: 0.4, green: 0.6, blue: 1.0))

                        if let jit = gameManager.jitStats {
                            LabeledContent("Loops Compiled", value: "\(jit.compiledLoops)")
                            LabeledContent("Back-Edges Tracked", value: "\(jit.trackedBackEdges)")
                            LabeledContent("Hot Threshold", value: "\(jit.hotThreshold) iterations")
                            LabeledContent("Detected A-Chip", value: jit.isAChip ? "Yes" : "No")
                        }
                    } header: {
                        Text("Performance")
                    } footer: {
                        Text("Disabling JIT falls back to pure instruction-by-instruction interpretation. Only useful for troubleshooting.")
                    }

                    Section("Library") {
                        LabeledContent("Games", value: "\(gameManager.games.count)")
                        LabeledContent("Favorites", value: "\(gameManager.favorites.count)")
                    }

                    Section("About") {
                        LabeledContent("Version", value: Bundle.main.appVersionString)
                        Link(destination: URL(string: "https://github.com/bward-dev1/cemu-ios-a-chip")!) {
                            Label("View on GitHub", systemImage: "arrow.up.right.square")
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
