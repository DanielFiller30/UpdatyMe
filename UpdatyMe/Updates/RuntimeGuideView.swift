import AppKit
import SwiftUI
import UpdatyMeCore

/// ⓘ für Runtimes: zeigt Befehle zum Aktualisieren bzw. Setzen als Standard (nur anzeigen und kopieren).
struct RuntimeGuideButton: View {
    let item: InstalledItem
    let guide: RuntimeGuide
    var flow: UpdateFlow?
    var suggestedLine: String?

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .help("Commands for updating \(item.name)")
        .accessibilityLabel("Commands for updating \(item.name)")
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            RuntimeGuideView(item: item, guide: guide, flow: flow, suggestedLine: suggestedLine) { isPresented = false }
        }
    }
}

struct RuntimeGuideView: View {
    let item: InstalledItem
    let guide: RuntimeGuide
    var flow: UpdateFlow?
    var suggestedLine: String?
    var dismiss: () -> Void = {}

    @State private var customVersion = ""
    @State private var setAsDefault = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(item.name) \(item.installedVersion)")
                    .font(.headline)
                if item.status == .outdated, let latest = item.latestVersion {
                    Text("Newest version: \(latest)")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(guide.steps, id: \.self) { step in
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(for: step.purpose))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .top) {
                        Text(step.command)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        CopyButton(text: step.command)
                    }
                    .padding(8)
                    .background(.background.secondary, in: .rect(cornerRadius: 6))
                }
            }

            ForEach(guide.notes, id: \.self) { note in
                Text(text(for: note))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if let url = guide.downloadURL {
                    Link(destination: url) {
                        Label("Download Page", systemImage: "arrow.down.circle")
                    }
                }
                Spacer()
                if guide.steps.count > 1 {
                    Button("Copy All") { Clipboard.copy(guide.script) }
                }
            }

            if let flow, RuntimeGuide.supportsCustomVersion(item) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Install a specific version")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let line = suggestedLine {
                        Button("Install newest \(line).x") {
                            dismiss()
                            flow.requestRuntimeInstall(item, version: line, setDefault: setAsDefault)
                        }
                    }
                    HStack {
                        TextField("Version", text: $customVersion, prompt: Text("e.g. 22.11.0"))
                            .textFieldStyle(.roundedBorder)
                            .font(.callout.monospaced())
                            .onSubmit(installCustomVersion)
                        Button("Install…", action: installCustomVersion)
                            .disabled(!RuntimeGuide.isValidVersion(trimmedVersion))
                    }
                    Toggle("Set as default", isOn: $setAsDefault)
                        .toggleStyle(.checkbox)
                }
            }

            if let flow {
                HStack {
                    if guide.canRunUpdate {
                        Button("Run Update…", systemImage: "arrow.triangle.2.circlepath") {
                            dismiss()
                            flow.requestRuntimeScript(item, action: .update)
                        }
                    }
                    Spacer()
                    if guide.uninstall != nil {
                        Button("Uninstall…", systemImage: "trash", role: .destructive) {
                            dismiss()
                            flow.requestRuntimeScript(item, action: .uninstall)
                        }
                    }
                }
                Text("UpdatyMe runs these commands only after you confirm. You can also paste them into Terminal.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("UpdatyMe does not run these commands. Paste them into Terminal.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(width: 400)
    }

    private var trimmedVersion: String { customVersion.trimmingCharacters(in: .whitespaces) }

    private func installCustomVersion() {
        guard let flow, RuntimeGuide.isValidVersion(trimmedVersion) else { return }
        dismiss()
        flow.requestRuntimeInstall(item, version: trimmedVersion, setDefault: setAsDefault)
    }

    private func title(for purpose: RuntimeGuide.Step.Purpose) -> LocalizedStringKey {
        switch purpose {
        case .installLatest: "Install newest version"
        case .setDefault: "Set as default"
        case .list: "Show installed versions"
        case .update: "Update"
        case .uninstall: "Uninstall"
        }
    }

    private func text(for note: RuntimeGuide.Note) -> LocalizedStringKey {
        switch note {
        case .providedByDeveloperTools: "This Python comes with Xcode or the Command Line Tools and is updated together with them."
        case .asdfVersion: "Requires asdf 0.16 or later. Older versions use “asdf global” instead of “asdf set --home”."
        case .javaHomeInProfile: "Add the JAVA_HOME line to your shell profile (e.g. ~/.zshrc) to make it the default."
        case .manualInstallation: "Installed without a version manager. Download the new version from the vendor."
        }
    }
}

private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            Clipboard.copy(text)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("Copy")
        .accessibilityLabel("Copy")
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
