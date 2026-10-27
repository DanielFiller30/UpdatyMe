import SwiftUI
import UpdatyMeCore

/// Einfache Diagnoseansicht („Wo wurde was gefunden?“), eigenes Fenster. Ausbau in Phase 8.
struct DiagnosticsView: View {
    @State private var model = DiagnosticsModel()
    @State private var confirmsClearCaches = false

    var body: some View {
        List {
            Section("Tools") {
                ForEach(model.tools) { tool in
                    LabeledContent {
                        VStack(alignment: .trailing) {
                            if let path = tool.path {
                                Text(path.path)
                            } else {
                                Text("not found").foregroundStyle(.secondary)
                            }
                            if let version = tool.version {
                                Text(version).foregroundStyle(.secondary)
                            }
                        }
                        .textSelection(.enabled)
                    } label: {
                        Label(tool.name, systemImage: tool.path == nil ? "xmark.circle" : "checkmark.circle.fill")
                    }
                }
            }

            if let environment = model.environment {
                Section("Source") {
                    Text(sourceDescription(environment.source))
                }

                Section("Version Managers") {
                    if environment.versionManagers.isEmpty {
                        Text("None detected").foregroundStyle(.secondary)
                    }
                    ForEach(environment.versionManagers) { manager in
                        LabeledContent {
                            Text(manager.root.path)
                        } label: {
                            Text(verbatim: manager.kind.rawValue)
                        }
                    }
                }

                Section("Resolved PATH") {
                    ForEach(environment.searchPath, id: \.self) { Text($0).textSelection(.enabled) }
                }

                Section("PATH of the App Process") {
                    Text(model.processPath).textSelection(.enabled)
                }

                Section("Notes") {
                    ForEach(environment.notes, id: \.self) { Text($0.text) }
                }
            }

            if !model.locations.isEmpty {
                Section("Storage Locations") {
                    ForEach(model.locations) { location in
                        LocationRow(location: location)
                    }
                }
                Section {
                    Button("Clear Caches", systemImage: "trash") {
                        confirmsClearCaches = true
                    }
                    .confirmationDialog("Clear Caches?", isPresented: $confirmsClearCaches) {
                        Button("Clear Caches", role: .destructive) { model.clearCaches() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Cached web responses and command results will be deleted. The next check queries all sources again.")
                    }
                    Text("Removes cached web responses and command results. Inventory, favorites, pins and history are kept. The next check queries all sources again.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("Caches")
                }
            }
        }
        .overlay {
            if model.environment == nil {
                ProgressView("Resolving environment…")
            }
        }
        .navigationTitle("Diagnostics")
        .toolbar {
            Button("Resolve Again", systemImage: "arrow.clockwise") {
                Task { await model.load(forceRefresh: true) }
            }
            .disabled(model.isLoading)
        }
        .task { await model.load() }
    }

    private func sourceDescription(_ source: ResolvedEnvironment.Source) -> String {
        switch source {
        case .loginShell: String(localized: "Login shell (zsh -l -i)")
        case .fallback(let reason): String(localized: "Fallback: \(reason.text)")
        }
    }
}

#Preview {
    DiagnosticsView()
}

/// Ein Speicherort mit Pfad, Größe und „Im Finder zeigen“.
private struct LocationRow: View {
    let location: DiagnosticsModel.Location

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if let size = location.size {
                    Text(size, format: .byteCount(style: .file))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if location.exists, let url = location.url {
                    Button("Show in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let url = location.url {
                    Text(url.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if !location.exists {
                        Text(location.kind == .toolsConfiguration ? "Not created yet" : "Does not exist")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text("not found").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var title: LocalizedStringKey {
        switch location.kind {
        case .store: "Inventory database"
        case .httpCache: "Web cache"
        case .commandCache: "Command cache"
        case .toolsConfiguration: "Tool configuration (tools.json)"
        case .homebrew: "Homebrew"
        }
    }
}
