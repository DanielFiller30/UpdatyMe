import AppKit
import Observation
import UpdatyMeCore

/// Ablauf vor dem Start von Updates und Deinstallationen: Bestätigung (immer), dann Prüfung auf
/// laufende Apps mit Rückfrage „Beenden & aktualisieren“ bzw. „Überspringen“.
@Observable
final class UpdateFlow {
    struct RunningApp: Identifiable, Equatable {
        let id: pid_t
        let name: String
        let itemID: InstalledItem.ID
    }

    enum Prompt: Identifiable {
        case single(InstalledItem)
        case major(InstalledItem)
        case runtime(InstalledItem, RuntimeGuide.Action, commands: [String])
        case all([InstalledItem])
        case adopt(InstalledItem, token: String)
        case runningApps(items: [InstalledItem], apps: [RunningApp])

        var id: String {
            switch self {
            case .single(let item): "single-\(item.id)"
            case .major(let item): "major-\(item.id)"
            case .runtime(let item, let action, _): "runtime-\(action.rawValue)-\(item.id)"
            case .adopt(let item, _): "adopt-\(item.id)"
            case .all: "all"
            case .runningApps: "running"
            }
        }
    }

    var prompt: Prompt?
    private(set) var isQuittingApps = false
    private let model: InventoryModel

    init(model: InventoryModel) {
        self.model = model
    }

    /// Einzelnes Update: immer mit Bestätigung (Major-Updates mit eigenem Warntext).
    func requestUpdate(_ item: InstalledItem) {
        prompt = item.isMajorUpdate ? .major(item) : .single(item)
    }

    /// Update bzw. Deinstallation einer Runtime per Skript: immer mit Bestätigung, die die Befehle zeigt.
    func requestRuntimeScript(_ item: InstalledItem, action: RuntimeGuide.Action) {
        guard let guide = RuntimeGuide.guide(for: item) else { return }
        let commands = guide.steps(for: action).map(\.command)
        guard !commands.isEmpty else { return }
        prompt = .runtime(item, action, commands: commands)
    }

    /// „Alle aktualisieren“: immer mit Bestätigung.
    func requestUpdateAll(_ items: [InstalledItem]) {
        guard !items.isEmpty else { return }
        prompt = .all(items)
    }

    /// Frei eingegebene Version installieren: immer mit Bestätigung, die die Befehle zeigt.
    func requestRuntimeInstall(_ item: InstalledItem, version: String, setDefault: Bool) {
        let job = item.runtimeInstallJob(version: version, setDefault: setDefault)
        let commands = RuntimeScriptExecutor.steps(for: job).map(\.command)
        guard !commands.isEmpty else { return }
        prompt = .runtime(job, .install, commands: commands)
    }

    /// „In Homebrew übernehmen“: immer mit Bestätigung.
    func requestAdoption(_ item: InstalledItem) {
        guard let token = item.adoptableCaskToken(remote: model.remotes[item.id]) else { return }
        prompt = .adopt(item, token: token)
    }

    /// Nach Bestätigung von `.major`, `.all` oder `.adopt`.
    func confirm() {
        switch prompt {
        case .single(let item), .major(let item): checkRunningApps(then: [item])
        case .runtime(let item, let action, _):
            prompt = nil
            Task { await model.startRuntimeScript(item, action: action) }
        case .all(let items): checkRunningApps(then: items)
        case .adopt(let item, _):
            prompt = nil
            Task { await model.startAdoption(item) }
        case .runningApps, nil: prompt = nil
        }
    }

    func cancel() {
        prompt = nil
    }

    /// Laufende Apps regulär beenden (wie ⌘Q), dann aktualisieren. Apps, die nicht beendet wurden
    /// (z. B. Sichern-Dialog abgebrochen), werden übersprungen.
    func quitAndUpdate() async {
        guard case .runningApps(let items, let apps) = prompt else { return }
        prompt = nil
        isQuittingApps = true
        defer { isQuittingApps = false }

        var stillRunning = Set<InstalledItem.ID>()
        for app in apps {
            if await !Self.quit(pid: app.id) {
                stillRunning.insert(app.itemID)
            }
        }
        for item in items where stillRunning.contains(item.id) {
            await model.recordSkippedUpdate(item, reason: String(localized: "\(item.name) was not quit."))
        }
        await model.startUpdates(items.filter { !stillRunning.contains($0.id) })
    }

    /// Nur Einträge ohne laufende App aktualisieren.
    func skipRunningAndUpdate() async {
        guard case .runningApps(let items, let apps) = prompt else { return }
        prompt = nil
        let running = Set(apps.map(\.itemID))
        for item in items where running.contains(item.id) {
            await model.recordSkippedUpdate(item, reason: String(localized: "Skipped because \(item.name) was running."))
        }
        await model.startUpdates(items.filter { !running.contains($0.id) })
    }

    // MARK: - Laufende Apps

    private func checkRunningApps(then items: [InstalledItem]) {
        let apps = Self.runningApps(for: items)
        if apps.isEmpty {
            prompt = nil
            Task { await model.startUpdates(items) }
        } else {
            prompt = .runningApps(items: items, apps: apps)
        }
    }

    static func runningApps(for items: [InstalledItem]) -> [RunningApp] {
        let running = NSWorkspace.shared.runningApplications
        var result: [RunningApp] = []
        for item in items {
            let paths = Set(item.appPathsToCheckBeforeUpdate.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
            guard !paths.isEmpty else { continue }
            for app in running {
                guard let path = app.bundleURL?.standardizedFileURL.path, paths.contains(path) else { continue }
                result.append(RunningApp(id: app.processIdentifier, name: app.localizedName ?? item.name, itemID: item.id))
            }
        }
        return result
    }

    /// Bittet die App, sich zu beenden, und wartet bis zu 30 s.
    private static func quit(pid: pid_t) async -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return true }
        guard app.terminate() else { return app.isTerminated }
        for _ in 0..<120 {
            if app.isTerminated { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return app.isTerminated
    }
}
