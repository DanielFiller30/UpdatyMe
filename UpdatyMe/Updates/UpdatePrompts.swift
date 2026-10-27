import SwiftUI
import UpdatyMeCore

extension View {
    /// Bestätigungsdialoge vor Updates, Übernahmen und Deinstallationen (`UpdateFlow.prompt`).
    func updatePrompts(flow: UpdateFlow) -> some View {
        modifier(UpdatePromptsModifier(flow: flow))
    }
}

private struct UpdatePromptsModifier: ViewModifier {
    let flow: UpdateFlow

    func body(content: Content) -> some View {
        content
        .sheet(isPresented: isPrompting { if case .all = $0 { true } else { false } }) {
            if case .all(let items)? = flow.prompt {
                UpdateAllSheet(items: items, onConfirm: flow.confirm, onCancel: flow.cancel)
            }
        }
        .alert(
            "Update?",
            isPresented: isPrompting { if case .single = $0 { true } else { false } },
            presenting: flow.prompt
        ) { _ in
            Button("Update") { flow.confirm() }
            Button("Cancel", role: .cancel) { flow.cancel() }
        } message: { prompt in
            if case .single(let item) = prompt {
                Text("\(item.name) will be updated from \(item.installedVersion) to \(item.latestVersion ?? "–"). Homebrew may also update dependent packages.")
            }
        }
        .alert(
            runtimeAlertTitle,
            isPresented: isPrompting { if case .runtime = $0 { true } else { false } },
            presenting: flow.prompt
        ) { prompt in
            if case .runtime(_, let action, _) = prompt {
                Button(action == .uninstall ? "Uninstall" : action == .install ? "Install" : "Run Update",
                       role: action == .uninstall ? .destructive : nil) { flow.confirm() }
            }
            Button("Cancel", role: .cancel) { flow.cancel() }
        } message: { prompt in
            if case .runtime(let item, let action, let commands) = prompt {
                switch action {
                case .update:
                    Text("These commands will be run for \(item.name) \(item.installedVersion):\n\(commands.joined(separator: "\n"))")
                case .install:
                    Text("These commands will be run to install the version for \(item.name):\n\(commands.joined(separator: "\n"))")
                case .uninstall:
                    Text("\(item.name) \(item.installedVersion) will be removed. This cannot be undone. This command will be run:\n\(commands.joined(separator: "\n"))")
                }
            }
        }
        .alert(
            "Major Update",
            isPresented: isPrompting { if case .major = $0 { true } else { false } },
            presenting: flow.prompt
        ) { _ in
            Button("Update") { flow.confirm() }
            Button("Cancel", role: .cancel) { flow.cancel() }
        } message: { prompt in
            if case .major(let item) = prompt {
                Text("\(item.name) will be updated from \(item.installedVersion) to \(item.latestVersion ?? "–"). Major updates can contain breaking changes. Homebrew may also update dependent packages.")
            }
        }
        .alert(
            "Adopt into Homebrew?",
            isPresented: isPrompting { if case .adopt = $0 { true } else { false } },
            presenting: flow.prompt
        ) { _ in
            Button("Adopt") { flow.confirm() }
            Button("Cancel", role: .cancel) { flow.cancel() }
        } message: { prompt in
            if case .adopt(let item, let token) = prompt {
                Text("Homebrew will manage \(item.name) as cask “\(token)” from now on and can update it. The installed app is kept; Homebrew only adopts it if it is identical to the cask version.")
            }
        }
        .alert(
            "Apps Are Running",
            isPresented: isPrompting { if case .runningApps = $0 { true } else { false } },
            presenting: flow.prompt
        ) { _ in
            Button("Quit and Update") { Task { await flow.quitAndUpdate() } }
            Button("Skip These Apps") { Task { await flow.skipRunningAndUpdate() } }
            Button("Cancel", role: .cancel) { flow.cancel() }
        } message: { prompt in
            if case .runningApps(_, let apps) = prompt {
                Text("These apps need to quit before updating: \(apps.map(\.name).joined(separator: ", ")). Unsaved changes may prompt you.")
            }
        }
    }

    private var runtimeAlertTitle: LocalizedStringKey {
        if case .runtime(_, .uninstall, _)? = flow.prompt { return "Uninstall Runtime?" }
        if case .runtime(_, .install, _)? = flow.prompt { return "Install Version?" }
        return "Run Update Commands?"
    }

    private func isPrompting(_ matches: @escaping (UpdateFlow.Prompt) -> Bool) -> Binding<Bool> {
        Binding {
            flow.prompt.map(matches) ?? false
        } set: { isPresented in
            if !isPresented, flow.prompt.map(matches) == true { flow.cancel() }
        }
    }
}
