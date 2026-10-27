import AppKit
import SwiftUI
import UpdatyMeCore

/// Rechte Detailspalte (Basis): Version, Herkunft, Pfad, Metadaten, Log-Platzhalter.
struct InspectorView: View {
    let item: InstalledItem?
    var remote: RemoteVersion?
    /// Grund, warum die neueste Version nicht ermittelt werden konnte.
    var lookupError: String?
    var logLines: [InventoryModel.LogLine] = []
    var updateState: InventoryModel.UpdateState?
    /// Letzter Update-Lauf dieses Eintrags (auch aus früheren Sitzungen).
    var lastRun: UpdateRun?
    var isPinnedInApp = false
    var onTogglePin: () -> Void = {}
    /// Gesetzt, wenn „In Homebrew übernehmen“ möglich ist.
    var onAdopt: (() -> Void)?
    var isFavorite = false
    var onToggleFavorite: () -> Void = {}

    var body: some View {
        if let item {
            Form {
                Section {
                    HStack(spacing: 12) {
                        ItemIcon(item: item, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.title3.weight(.semibold))
                            Text(item.kind.title)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        FavoriteButton(isFavorite: isFavorite, action: onToggleFavorite)
                            .imageScale(.large)
                    }
                    .padding(.vertical, 4)
                }

                Section("Version") {
                    LabeledContent("Installed", value: item.installedVersion.isEmpty ? "–" : item.installedVersion)
                    LabeledContent("Latest", value: item.latestVersion ?? "–")
                    LabeledContent("Status") {
                        StatusChip(status: item.status, isMajor: item.isMajorUpdate)
                    }
                    if let newerLine = remote?.newerReleaseLine {
                        LabeledContent("Newer release line") {
                            Text(verbatim: newerLine)
                        }
                    }
                    if let endOfLife = remote?.endOfLife {
                        LabeledContent(endOfLife < Date() ? "Support ended" : "Support ends") {
                            Text(endOfLife, format: .dateTime.year().month().day())
                                .foregroundStyle(endOfLife < Date() ? .red : .secondary)
                        }
                    }
                    if let configError = configErrorText(for: item) {
                        Label {
                            Text(configError)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        }
                        .font(.callout)
                    }
                    if let remote {
                        LabeledContent("Checked via") {
                            Text(remote.source)
                        }
                        LabeledContent("Checked") {
                            Text(remote.fetchedAt, format: .relative(presentation: .named))
                        }
                        if let url = remote.releaseNotesURL {
                            Link(destination: url) {
                                Label("Release Notes", systemImage: "doc.text")
                            }
                        }
                    }
                    if let lookupError {
                        Label {
                            Text("Latest version could not be determined: \(lookupError)")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        }
                        .font(.callout)
                    } else if item.status == .unknown, configErrorText(for: item) == nil {
                        Text(unknownExplanation(for: item))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Origin") {
                    LabeledContent("Source", value: item.source.title)
                    LabeledContent("Detected via", value: item.ecosystem.title)
                    LabeledContent("Update") { Text(item.updateCapability.title) }
                    if item.isPinnedInBrew {
                        Label("Pinned in Homebrew. Unpin with “brew unpin” in Terminal.", systemImage: "pin.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Toggle(isOn: Binding(get: { isPinnedInApp }, set: { _ in onTogglePin() })) {
                            Label("Pinned", systemImage: "pin")
                        }
                        .help("Pinned items are skipped by “Update All”.")
                    }
                    if let onAdopt {
                        Button("Adopt into Homebrew…", systemImage: "mug", action: onAdopt)
                    }
                    if item.source == .sparkle, let path = item.installPath {
                        Button("Open App", systemImage: "arrow.up.forward.app") { AppActions.openApp(at: path) }
                            .help("The app’s own updater checks for the update")
                    }
                    if item.source == .mas, let url = AppActions.appStoreURL(remote) {
                        Link(destination: url) {
                            Label("Open in App Store", systemImage: "bag")
                        }
                    }
                }

                if let path = item.installPath {
                    Section("Path") {
                        Text(path)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                        if FileManager.default.fileExists(atPath: path) {
                            Button("Show in Finder", systemImage: "folder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            }
                        }
                    }
                }

                if !visibleMetadata(item).isEmpty {
                    Section("Details") {
                        ForEach(visibleMetadata(item), id: \.key) { key, value in
                            LabeledContent {
                                Text(value)
                                    .textSelection(.enabled)
                                    .multilineTextAlignment(.trailing)
                            } label: {
                                Text(verbatim: key)
                            }
                        }
                    }
                }

                Section("Log") {
                    if case .failed(let message)? = updateState {
                        Label {
                            Text("Update failed: \(message)")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        }
                    } else if let lastRun, logLines.isEmpty {
                        UpdateRunSummary(run: lastRun)
                    }
                    if !logLines.isEmpty {
                        UpdateLogView(lines: logLines)
                    } else if let log = lastRun?.log, !log.isEmpty {
                        DisclosureGroup("Output") {
                            UpdateLogView(lines: log.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                                .map { InventoryModel.LogLine(id: $0.offset, text: String($0.element), isError: false) })
                        }
                    } else if lastRun == nil {
                        Text("No update runs yet.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("No Selection", systemImage: "sidebar.trailing")
        }
    }

    /// Fehler aus `tools.json` (Code + Detail aus dem Kern), übersetzt.
    private func configErrorText(for item: InstalledItem) -> String? {
        let detail = item.metadata[ConfiguredToolsEcosystem.errorDetailKey] ?? ""
        switch item.metadata[ConfiguredToolsEcosystem.errorKey].flatMap(ConfiguredToolsEcosystem.ConfigError.init(rawValue:)) {
        case .commandNotFound?: return String(localized: "Command not found: \(detail)")
        case .invalidPattern?: return String(localized: "Invalid version pattern: \(detail)")
        case .versionNotFound?: return String(localized: "No version found in the output of \(detail)")
        case nil: return nil
        }
    }

    /// Interne Schlüssel (Fehlercodes, Quellbeschreibung, Muster) sind an anderer Stelle übersetzt dargestellt.
    private static let internalMetadataKeys: Set<String> = [
        ConfiguredToolsEcosystem.errorKey, ConfiguredToolsEcosystem.errorDetailKey, ConfiguredToolsEcosystem.latestKey,
        BrewEcosystem.latestVersionPatternKey,
    ]

    private func visibleMetadata(_ item: InstalledItem) -> [(key: String, value: String)] {
        item.metadata.filter { !Self.internalMetadataKeys.contains($0.key) }.sorted { $0.key < $1.key }
    }

    /// Warum der Status unbekannt ist – ehrlich statt falsch „aktuell“.
    private func unknownExplanation(for item: InstalledItem) -> LocalizedStringKey {
        if item.source == .system && item.ecosystem == .python {
            return "Provided by Xcode or the Command Line Tools."
        }
        if item.source == .system && item.kind != .os {
            return "Updated together with macOS."
        }
        if remote == nil {
            return "No source for the latest version is known."
        }
        return "The versions cannot be compared reliably."
    }
}
