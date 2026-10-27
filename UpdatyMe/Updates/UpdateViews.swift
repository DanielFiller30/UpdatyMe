import AppKit
import SwiftUI
import UpdatyMeCore

/// Aktion je Zeile: Update-Knopf, Warte-/Fortschrittsanzeige oder Ergebnis.
struct UpdateActionView: View {
    let item: InstalledItem
    let model: InventoryModel
    let flow: UpdateFlow

    var body: some View {
        switch model.updateStates[item.id] {
        case .queued?:
            HStack(spacing: 4) {
                Text("Waiting").foregroundStyle(.secondary)
                Button {
                    Task { await model.cancelQueuedUpdate(item.id) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove from Queue")
                .accessibilityLabel("Remove from Queue")
            }
        case .running?:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                if model.removalJobs.contains(item.id) {
                    Text("Removing…").foregroundStyle(.secondary)
                } else {
                    Text("Updating…").foregroundStyle(.secondary)
                }
            }
        case .succeeded?:
            Label(model.removalJobs.contains(item.id) ? "Removed" : "Updated", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.brandGreen)
        case .failed(let message)?:
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .help(message)
        case nil:
            if model.pendingLatest.contains(item.id) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking…").foregroundStyle(.secondary)
                }
                .help("Software Update is still checking; this can take about a minute.")
            } else if item.canUpdateAutomatically {
                Button("Update") { flow.requestUpdate(item) }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .foregroundStyle(.updateOrange)
            } else if item.status == .outdated, item.updateCapability == .openSettings {
                Button("Open Settings") { SystemSettings.openSoftwareUpdate() }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .foregroundStyle(.updateOrange)
            } else if item.status == .outdated, item.source == .mas, let url = AppActions.appStoreURL(model.remotes[item.id]) {
                Button("Open in App Store") { NSWorkspace.shared.open(url) }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .foregroundStyle(.updateOrange)
            } else if let guide = RuntimeGuide.guide(for: item) {
                HStack(spacing: 6) {
                    if guide.canRunUpdate {
                        Button("Update") { flow.requestRuntimeScript(item, action: .update) }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                            .foregroundStyle(.updateOrange)
                    }
                    if let line = newerNodeLine {
                        Button("Install \(line)") { flow.requestRuntimeInstall(item, version: line, setDefault: false) }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                            .foregroundStyle(.updateOrange)
                            .help("Install the newest Node.js \(line).x")
                    }
                    RuntimeGuideButton(item: item, guide: guide, flow: flow, suggestedLine: newerNodeLine)
                }
            } else if item.status == .outdated, item.source == .sparkle, let path = item.installPath {
                Button("Open App") { AppActions.openApp(at: path) }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .foregroundStyle(.updateOrange)
                    .help("The app’s own updater checks for the update")
            }
        }
    }
}

extension UpdateActionView {
    /// Neuere Node-Hauptlinie, die per Manager installierbar und noch nicht installiert ist.
    var newerNodeLine: String? {
        guard item.ecosystem == .node, item.status != .outdated,
              let line = model.remotes[item.id]?.newerReleaseLine,
              RuntimeGuide.supportsCustomVersion(item), item.source != .asdf else { return nil }
        let installed = model.items.contains {
            $0.ecosystem == .node && $0.source == item.source && $0.installedVersion.split(separator: ".").first.map(String.init) == line
        }
        return installed ? nil : line
    }
}

/// Aktionen ohne eigene Update-Ausführung: App Store öffnen (kein `mas`), Sparkle-App öffnen.
enum AppActions {
    /// Seite der App im App Store (aus der iTunes-Lookup-Antwort).
    static func appStoreURL(_ remote: RemoteVersion?) -> URL? {
        guard let remote, remote.source == AppStoreLatestProvider.source else { return nil }
        return remote.releaseNotesURL
    }

    /// Startet die App; deren eigener Sparkle-Updater prüft dann (je nach App-Einstellung). Kein stilles Fremd-Update.
    static func openApp(at path: String) {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
    }
}

enum SystemSettings {
    static func openSoftwareUpdate() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Bestätigung für „Alle aktualisieren“ mit Liste; Major-Updates sind markiert.
struct UpdateAllSheet: View {
    let items: [InstalledItem]
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Update \(items.count) Items?")
                .font(.title3.weight(.semibold))
            if items.contains(where: \.isMajorUpdate) {
                Label("Includes major updates, which can contain breaking changes.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            Text("Homebrew may also update dependent packages.")
                .foregroundStyle(.secondary)
            List(items) { item in
                HStack {
                    ItemIcon(item: item)
                    Text(item.name)
                    Spacer()
                    Text(verbatim: "\(item.installedVersion) → \(item.latestVersion ?? "–")")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if item.isMajorUpdate {
                        MajorBadge()
                    }
                }
            }
            .frame(minHeight: 160)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Update All", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Live-Log eines Updates.
struct UpdateLogView: View {
    let lines: [InventoryModel.LogLine]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(lines) { line in
                        Text(line.text)
                            .font(.caption.monospaced())
                            .foregroundStyle(line.isError ? .red : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .textSelection(.enabled)
            }
            .frame(minHeight: 80, maxHeight: 240)
            .onChange(of: lines.count) {
                if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}
