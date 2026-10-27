import AppKit
import Foundation
import Observation
import OSLog
import UpdatyMeCore

/// Hält das Inventar für die UI: lädt beim Start den Cache aus dem Store, scannt dann neu, ermittelt
/// die neuesten Versionen (Phase 4) und führt Updates aus (Phase 5).
@Observable
final class InventoryModel {
    private(set) var items: [InstalledItem] = []
    private(set) var isRefreshing = false
    /// Teilschritt während `isRefreshing` (für die Anzeige).
    private(set) var refreshStep: RefreshStep?
    private(set) var lastRefresh: Date?
    /// Fehlgeschlagene Ökosysteme bzw. Versionsquellen des letzten Refreshs.
    private(set) var failures: [EcosystemID: InventoryScanner.ScanFailure] = [:]
    /// Einzelne Einträge, deren neueste Version nicht ermittelt werden konnte.
    private(set) var itemErrors: [InstalledItem.ID: InventoryScanner.ScanFailure] = [:]
    /// Neueste Versionen samt Quelle und Release-Notes-Link (für den Inspector).
    private(set) var remotes: [InstalledItem.ID: RemoteVersion] = [:]

    enum RefreshStep {
        case scanning, checkingVersions
    }

    enum UpdateState: Equatable {
        case queued, running, succeeded
        case failed(String)
    }

    struct LogLine: Identifiable, Equatable {
        let id: Int
        let text: String
        let isError: Bool
    }

    /// Zustand laufender bzw. zuletzt ausgeführter Updates dieser Sitzung.
    private(set) var updateStates: [InstalledItem.ID: UpdateState] = [:]
    /// Live-Log je Eintrag (letzter Lauf dieser Sitzung).
    private(set) var updateLogs: [InstalledItem.ID: [LogLine]] = [:]
    private var activeRuns: [InstalledItem.ID: UpdateRun] = [:]
    /// Ergebnisse der laufenden Update-Serie (für die Abschluss-Mitteilung).
    private var batchSucceeded: [String] = []
    private var batchFailed: [String] = []
    /// Einträge, deren Auftrag „In Homebrew übernehmen“ war.
    private var adoptionJobs: Set<InstalledItem.ID> = []
    /// Einträge, deren laufender Auftrag eine Deinstallation ist (Anzeige „Removing…“).
    private(set) var removalJobs: Set<InstalledItem.ID> = []

    /// In der App fixierte Einträge (zusätzlich zu `brew pin`).
    private(set) var pins: Set<InstalledItem.ID> = []
    private var hasStarted = false
    private var automaticChecks: Task<Void, Never>?
    /// Mitteilungen; in Tests ein Rekorder.
    var notifier: any UpdateNotifier = SystemNotifier()
    /// Ob die App im Vordergrund ist (Abschluss-Mitteilung nur im Hintergrund).
    var isAppActive: @MainActor () -> Bool = { NSApplication.shared.isActive }
    static let notifiedUpdatesDefaultsKey = "notifiedUpdateIDs"
    /// Ohne `UserDefaults` (Tests) im Speicher.
    private var notifiedUpdatesInMemory: Set<InstalledItem.ID>?
    private var succeededAwaitingRescan: [InstalledItem.ID: String?] = [:]
    private(set) var storeError: String?
    private(set) var updateRuns: [UpdateRun] = []
    private(set) var favorites: Set<InstalledItem.ID> = []

    /// Gilt für alle Kategorien und wird über Neustarts gespeichert.
    var filter: InventoryFilter = .default {
        didSet { saveFilter() }
    }

    static let filterDefaultsKey = "inventoryFilter"
    static let nodeChannelDefaultsKey = "nodeChannel"

    /// Node: LTS (Standard) oder Current; aus den Einstellungen.
    var nodeChannel: NodeLatestProvider.Channel {
        defaults?.string(forKey: Self.nodeChannelDefaultsKey).flatMap(NodeLatestProvider.Channel.init(rawValue:)) ?? .lts
    }

    private let runner = CommandRunner()
    private let resolver: EnvironmentResolver
    private let http: CachingHTTPClient
    private let commandCache: CachingCommandRunner
    private let updateQueue: UpdateQueue
    /// Ausführer werden mit der aufgelösten Umgebung erzeugt; in Tests vorgegeben.
    private let fixedExecutors: [EcosystemID: any UpdateExecutor]?
    private let store: InventoryStore?
    private let scansLive: Bool
    /// `nil` = Filter nicht speichern (Previews, Tests).
    private let defaults: UserDefaults?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "UpdatyMe", category: "Inventory")

    private init(
        store: InventoryStore?,
        storeError: String?,
        scansLive: Bool,
        defaults: UserDefaults? = nil,
        executors: [EcosystemID: any UpdateExecutor]? = nil
    ) {
        self.store = store
        self.storeError = storeError
        self.scansLive = scansLive
        self.defaults = defaults
        resolver = EnvironmentResolver(runner: runner)
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "de.df.UpdatyMe"
        let fallback = FileManager.default.temporaryDirectory.appendingPathComponent(bundleIdentifier)
        http = CachingHTTPClient(cache: HTTPDiskCache(
            directory: (try? HTTPDiskCache.defaultDirectory(bundleIdentifier: bundleIdentifier)) ?? fallback.appendingPathComponent("http")
        ))
        commandCache = CachingCommandRunner(
            base: runner,
            directory: (try? CachingCommandRunner.defaultDirectory(bundleIdentifier: bundleIdentifier)) ?? fallback.appendingPathComponent("commands")
        )
        fixedExecutors = executors
        updateQueue = UpdateQueue(executors: executors ?? [:])
        if let data = defaults?.data(forKey: Self.filterDefaultsKey),
           let saved = try? JSONDecoder().decode(InventoryFilter.self, from: data) {
            filter = saved
        }
    }

    /// Inventar dieses Macs mit persistentem Cache.
    static func live() -> InventoryModel {
        do {
            let url = try InventoryStore.defaultURL(bundleIdentifier: Bundle.main.bundleIdentifier ?? "de.df.UpdatyMe")
            return InventoryModel(store: try InventoryStore.open(at: url), storeError: nil, scansLive: true, defaults: .standard)
        } catch {
            return InventoryModel(store: nil, storeError: String(describing: error), scansLive: true, defaults: .standard)
        }
    }

    /// Scannt diesen Mac, ohne den Store zu lesen oder zu schreiben (für Live-Snapshots).
    static func scanningWithoutStore() -> InventoryModel {
        InventoryModel(store: nil, storeError: nil, scansLive: true)
    }

    /// Feste Daten für Previews und Snapshot-Tests, ohne Store und ohne Scan.
    static func fixed(
        _ items: [InstalledItem],
        failures: [EcosystemID: InventoryScanner.ScanFailure] = [:],
        favorites: Set<InstalledItem.ID> = [],
        filter: InventoryFilter? = nil,
        lastRefresh: Date? = nil,
        isRefreshing: Bool = false,
        defaults: UserDefaults? = nil,
        store: InventoryStore? = nil,
        executors: [EcosystemID: any UpdateExecutor] = [:],
        updateStates: [InstalledItem.ID: UpdateState] = [:],
        updateLogs: [InstalledItem.ID: [LogLine]] = [:],
        updateRuns: [UpdateRun] = [],
        pins: Set<InstalledItem.ID> = [],
        notifier: any UpdateNotifier = SilentNotifier(),
        remotes: [InstalledItem.ID: RemoteVersion]? = nil
    ) -> InventoryModel {
        let model = InventoryModel(store: store, storeError: nil, scansLive: false, defaults: defaults, executors: executors)
        model.listenForUpdateEvents()
        model.items = items
        model.favorites = favorites
        if let filter {
            model.filter = filter
        }
        model.failures = failures
        model.remotes = Dictionary(items.compactMap { item in
            item.latestVersion.map { (item.id, RemoteVersion(itemID: item.id, version: $0, source: "Sample")) }
        }, uniquingKeysWith: { first, _ in first })
        if let remotes {
            model.remotes.merge(remotes) { _, given in given }
        }
        model.lastRefresh = lastRefresh
        model.isRefreshing = isRefreshing
        model.updateStates = updateStates
        model.updateLogs = updateLogs
        model.updateRuns = updateRuns
        model.pins = pins
        model.items = items.map { pins.contains($0.id) ? $0.applying(latest: model.remotes[$0.id], isPinned: true) : $0 }
        model.notifier = notifier
        return model
    }

    /// Einmalig beim App-Start: Cache laden, prüfen, danach automatisch im eingestellten Intervall.
    func start() async {
        guard scansLive, !hasStarted else { return }
        hasStarted = true
        listenForUpdateEvents()
        if let store {
            do {
                items = Self.sorted(try await store.items())
                updateRuns = try await store.updateRuns(limit: 100)
                favorites = try await store.favorites()
                pins = try await store.pins()
                remotes = Dictionary(try await store.remoteVersions().map { ($0.itemID, $0) }, uniquingKeysWith: { _, last in last })
            } catch {
                storeError = String(describing: error)
            }
        }
        await refresh()
        scheduleAutomaticChecks()
    }

    /// Aus den Einstellungen; Standard alle 6 h (= Cache-TTL).
    var checkInterval: CheckInterval {
        defaults?.string(forKey: AppSettings.checkIntervalKey).flatMap(CheckInterval.init(rawValue:)) ?? .default
    }

    /// Startet die automatische Prüfung neu (beim Start und nach Änderung des Intervalls).
    func scheduleAutomaticChecks() {
        automaticChecks?.cancel()
        automaticChecks = nil
        guard scansLive, hasStarted, let interval = checkInterval.duration else { return }
        automaticChecks = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    /// - Parameter ignoringCache: Fragt alle Versionsquellen neu ab statt den TTL-Cache (6 h) zu nutzen.
    func refresh(ignoringCache: Bool = false) async {
        guard scansLive, !isRefreshing else { return }
        isRefreshing = true
        refreshStep = .scanning
        defer {
            isRefreshing = false
            refreshStep = nil
        }

        if ignoringCache {
            await http.expireAll()
            await commandCache.removeAll()
        }
        let environment = await resolver.resolve()
        let scan = await InventoryScanner(providers: [
            .init(.macOS, MacOSEcosystem(runner: runner)),
            .init(.brew, BrewEcosystem(runner: runner, environment: environment)),
            .init(.appBundle, AppBundleEcosystem()),
            .init(.node, NodeEcosystem(environment: environment, runner: runner)),
            .init(.npm, NodePackagesEcosystem(.npm, environment: environment, runner: runner)),
            .init(.pnpm, NodePackagesEcosystem(.pnpm, environment: environment, runner: runner)),
            .init(.python, PythonEcosystem(environment: environment, runner: runner)),
            .init(.rust, RustEcosystem(environment: environment, runner: runner)),
            .init(.java, JavaEcosystem(environment: environment, runner: runner)),
            .init(.gcloud, GcloudEcosystem(environment: environment, runner: runner)),
            .init(.configuredTools, ConfiguredToolsEcosystem(configuration: Self.toolsConfigurationURL, environment: environment, runner: runner)),
        ]).scan()

        var scanned: [InstalledItem] = []
        var failures: [EcosystemID: InventoryScanner.ScanFailure] = [:]
        var succeeded: [EcosystemID] = []
        for result in scan.results {
            switch result.outcome {
            case .success:
                scanned += scan.items.filter { $0.ecosystem == result.ecosystem }
                succeeded.append(result.ecosystem)
            case .failure(let failure):
                failures[result.ecosystem] = failure
                // Letzter bekannter Stand bleibt sichtbar; der Fehler wird angezeigt.
                scanned += items.filter { $0.ecosystem == result.ecosystem }
                logger.error("Scan \(result.ecosystem.rawValue, privacy: .public) failed: \(failure.message, privacy: .public)")
            }
        }

        refreshStep = .checkingVersions
        let coordinator = RefreshCoordinator.standard(
            http: http,
            commands: commandCache,
            environment: environment,
            country: Locale.current.region?.identifier ?? "us",
            systemVersion: Self.systemVersion,
            nodeChannel: nodeChannel
        )
        // Langsame Quellen (softwareupdate, live ~70 s) laufen im Hintergrund; bis dahin gilt deren letzter Stand.
        let fastSources = coordinator.sources.subtracting(RefreshCoordinator.slowSources)
        let slowItems = coordinator.items(scanned, handledBy: RefreshCoordinator.slowSources)
        var latest = await coordinator.latest(for: scanned, sources: fastSources)
        for item in slowItems {
            latest.remotes[item.id] = remotes[item.id]
        }
        let merged = RefreshCoordinator.merge(scanned, remotes: latest.remotes, pinned: pins)
        failures.merge(latest.failures) { first, _ in first }
        for source in RefreshCoordinator.slowSources {
            failures[source] = self.failures[source]
        }
        lastLatestDurations = latest.durations
        for (source, failure) in latest.failures {
            logger.error("Latest \(source.rawValue, privacy: .public) failed: \(failure.message, privacy: .public)")
        }

        do {
            for ecosystem in succeeded {
                try await store?.replaceItems(of: ecosystem, with: merged.filter { $0.ecosystem == ecosystem })
            }
            for remote in latest.remotes.values {
                try await store?.saveRemoteVersion(remote)
            }
        } catch {
            storeError = String(describing: error)
        }

        items = Self.sorted(merged)
        remotes = latest.remotes
        itemErrors = latest.itemErrors
        self.failures = failures
        lastRefresh = Date()
        notifyAboutNewUpdates()
        checkSlowSources(slowItems, coordinator: coordinator)
    }

    /// Einträge, deren neueste Version gerade im Hintergrund ermittelt wird (macOS).
    private(set) var pendingLatest: Set<InstalledItem.ID> = []
    /// Dauer je Versionsquelle beim letzten Refresh (Diagnose).
    private(set) var lastLatestDurations: [EcosystemID: Duration] = [:]
    private var slowCheck: Task<Void, Never>?

    private func checkSlowSources(_ slowItems: [InstalledItem], coordinator: RefreshCoordinator) {
        guard !slowItems.isEmpty, slowCheck == nil else { return }
        pendingLatest.formUnion(slowItems.map(\.id))
        slowCheck = Task { [weak self] in
            let result = await coordinator.latest(for: slowItems, sources: RefreshCoordinator.slowSources)
            await self?.applySlowResult(result, for: slowItems.map(\.id))
        }
    }

    private func applySlowResult(_ result: RefreshCoordinator.LatestResult, for ids: [InstalledItem.ID]) async {
        defer {
            slowCheck = nil
            pendingLatest.subtract(ids)
        }
        for id in ids {
            remotes[id] = result.remotes[id]
            itemErrors[id] = result.itemErrors[id]
        }
        for source in RefreshCoordinator.slowSources {
            failures[source] = result.failures[source]
        }
        lastLatestDurations.merge(result.durations) { _, new in new }
        var updated: [InstalledItem] = []
        items = items.map { item in
            guard ids.contains(item.id) else { return item }
            let merged = RefreshCoordinator.merge([item], remotes: remotes, pinned: pins)[0]
            updated.append(merged)
            return merged
        }
        do {
            try await store?.save(updated)
            for remote in result.remotes.values {
                try await store?.saveRemoteVersion(remote)
            }
        } catch {
            storeError = String(describing: error)
        }
        notifyAboutNewUpdates()
    }

    // MARK: - Mitteilungen

    /// Neue Updates gegenüber der letzten Mitteilung (Zählung wie Menüleiste/Übersicht). Beim allerersten
    /// Lauf ohne gespeicherten Stand wird nur gemerkt, nicht mitgeteilt (sonst eine Flut beim ersten Start).
    func notifyAboutNewUpdates() {
        let current = visibleItems(in: .overview).filter { $0.status == .outdated }
        let currentIDs = Set(current.map(\.id))
        let previous = notifiedUpdates
        notifiedUpdates = currentIDs
        guard let previous else { return }
        let new = current.filter { !previous.contains($0.id) }
        // Der Stand wird auch bei ausgeschalteten Mitteilungen gemerkt: nach dem Einschalten keine Flut.
        if !new.isEmpty, AppSettings.bool(AppSettings.notifyNewUpdatesKey, in: defaults) {
            notifier.notifyNewUpdates(new.map(\.name))
        }
    }

    private var notifiedUpdates: Set<InstalledItem.ID>? {
        get {
            if let defaults {
                return defaults.stringArray(forKey: Self.notifiedUpdatesDefaultsKey).map(Set.init)
            }
            return notifiedUpdatesInMemory
        }
        set {
            if let defaults {
                defaults.set(newValue.map { Array($0).sorted() }, forKey: Self.notifiedUpdatesDefaultsKey)
            } else {
                notifiedUpdatesInMemory = newValue
            }
        }
    }

    /// Für Tests: Zustand „bereits einmal mitgeteilt“ setzen.
    func setNotifiedUpdates(_ ids: Set<InstalledItem.ID>) {
        notifiedUpdates = ids
    }

    /// `~/Library/Application Support/<Bundle-ID>/tools.json`.
    static var toolsConfigurationURL: URL {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "de.df.UpdatyMe"
        return (try? ToolConfiguration.defaultURL(bundleIdentifier: bundleIdentifier))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("tools.json")
    }

    private static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// Einträge der Kategorie nach Anwendung des Filters.
    func visibleItems(in category: InventoryCategory) -> [InstalledItem] {
        category.items(in: items, favorites: favorites, filter: filter)
    }

    /// Einträge der Kategorie, die der Filter ausblendet.
    func hiddenCount(in category: InventoryCategory) -> Int {
        category.items(in: items, favorites: favorites).count - visibleItems(in: category).count
    }

    /// Updates unter den sichtbaren Einträgen.
    func updateCount(in category: InventoryCategory) -> Int {
        category.updateCount(in: items, favorites: favorites, filter: filter)
    }

    func isFavorite(_ id: InstalledItem.ID) -> Bool {
        favorites.contains(id)
    }

    func toggleFavorite(_ id: InstalledItem.ID) {
        let isFavorite = !favorites.contains(id)
        if isFavorite {
            favorites.insert(id)
        } else {
            favorites.remove(id)
        }
        guard let store else { return }
        Task {
            do {
                try await store.setFavorite(isFavorite, for: id)
            } catch {
                storeError = String(describing: error)
            }
        }
    }

    // MARK: - Fixieren

    func isPinnedInApp(_ id: InstalledItem.ID) -> Bool {
        pins.contains(id)
    }

    /// Fixiert bzw. löst einen Eintrag (App-interne Liste). Brew-Pins (`brew pin`) bleiben unberührt.
    func togglePin(_ id: InstalledItem.ID) {
        let isPinned = !pins.contains(id)
        if isPinned {
            pins.insert(id)
        } else {
            pins.remove(id)
        }
        items = items.map { item in
            guard item.id == id else { return item }
            return item.applying(latest: remotes[id], isPinned: isPinned || item.isPinnedInBrew)
        }
        guard let store else { return }
        Task {
            do {
                try await store.setPinned(isPinned, for: id)
            } catch {
                storeError = String(describing: error)
            }
        }
    }

    func resetFilter() {
        filter = .default
    }

    private func saveFilter() {
        guard let defaults, let data = try? JSONEncoder().encode(filter) else { return }
        defaults.set(data, forKey: Self.filterDefaultsKey)
    }

    // MARK: - Updates

    /// Sichtbare, per Knopfdruck aktualisierbare Einträge der Kategorie (für „Alle aktualisieren“).
    func updatableItems(in category: InventoryCategory) -> [InstalledItem] {
        visibleItems(in: category).filter { $0.canUpdateAutomatically && !isUpdateActive($0.id) }
    }

    func isUpdateActive(_ id: InstalledItem.ID) -> Bool {
        switch updateStates[id] {
        case .queued?, .running?: true
        default: false
        }
    }

    var hasActiveUpdates: Bool {
        updateStates.values.contains { $0 == .queued || $0 == .running }
    }

    /// Startet Updates. Bestätigungen (Major, laufende Apps) erfolgen vorher in der UI.
    func startUpdates(_ items: [InstalledItem]) async {
        await enqueue(items.filter { $0.canUpdateAutomatically && !isUpdateActive($0.id) })
    }

    /// „In Homebrew übernehmen“ (`brew install --cask --adopt`). Bestätigung erfolgt vorher in der UI.
    func startAdoption(_ item: InstalledItem) async {
        guard !isUpdateActive(item.id), let token = item.adoptableCaskToken(remote: remotes[item.id]) else { return }
        adoptionJobs.insert(item.id)
        await enqueue([item.adoptionJob(token: token)])
    }

    /// Führt Update- bzw. Deinstallationsbefehle einer Runtime aus. Bestätigung erfolgt vorher in der UI.
    func startRuntimeScript(_ item: InstalledItem, action: RuntimeGuide.Action) async {
        guard !isUpdateActive(item.id), !RuntimeScriptExecutor.steps(for: item.runtimeJob(action)).isEmpty else { return }
        if action == .uninstall { removalJobs.insert(item.id) }
        await enqueue([item.runtimeJob(action)])
    }

    private func enqueue(_ items: [InstalledItem]) async {
        guard !items.isEmpty else { return }
        if fixedExecutors == nil {
            let environment = await resolver.resolve()
            await updateQueue.setExecutor(BrewUpdateExecutor(runner: runner, environment: environment), for: .brew)
            let runtimeExecutor = RuntimeScriptExecutor(runner: runner, environment: environment)
            for ecosystem: EcosystemID in [.node, .python, .rust, .java] {
                await updateQueue.setExecutor(runtimeExecutor, for: ecosystem)
            }
        }
        for item in items {
            let run = UpdateRun(itemID: item.id, itemName: item.name, fromVersion: item.installedVersion)
            activeRuns[item.id] = run
            updateStates[item.id] = .queued
            updateLogs[item.id] = []
            await record(run)
        }
        await updateQueue.enqueue(items)
    }

    func cancelQueuedUpdate(_ id: InstalledItem.ID) async {
        await updateQueue.cancelQueued(id)
    }

    /// Markiert ein Update als übersprungen (z. B. App läuft und soll nicht beendet werden).
    func recordSkippedUpdate(_ item: InstalledItem, reason: String) async {
        var run = UpdateRun(itemID: item.id, itemName: item.name, fromVersion: item.installedVersion)
        run.finishedAt = run.startedAt
        run.outcome = .cancelled
        run.failureReason = reason
        await record(run)
    }

    /// Wartet, bis alle Updates samt anschließendem Neu-Scan abgeschlossen sind (für Tests).
    func waitForUpdates() async {
        while hasActiveUpdates || !succeededAwaitingRescan.isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private var isListening = false

    private func listenForUpdateEvents() {
        guard !isListening else { return }
        isListening = true
        let events = updateQueue.events
        Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
        }
    }

    private func handle(_ event: UpdateQueue.Event) async {
        switch event {
        case .queued(let id):
            updateStates[id] = .queued
        case .started(let id):
            updateStates[id] = .running
            if var run = activeRuns[id] {
                run.startedAt = Date()
                activeRuns[id] = run
            }
        case .output(let id, let line, let isError):
            var log = updateLogs[id] ?? []
            log.append(LogLine(id: log.count, text: line, isError: isError))
            updateLogs[id] = log
        case .succeeded(let id, let newVersion, _):
            updateStates[id] = .succeeded
            succeededAwaitingRescan[id] = newVersion
            batchSucceeded.append(activeRuns[id]?.itemName ?? id)
        case .failed(let id, let error):
            let message = ErrorText.message(for: error)
            updateStates[id] = .failed(message)
            batchFailed.append(activeRuns[id]?.itemName ?? id)
            adoptionJobs.remove(id)
            removalJobs.remove(id)
            await finishRun(id, outcome: .failed, toVersion: nil, failureReason: message)
        case .cancelled(let id):
            updateStates[id] = nil
            removalJobs.remove(id)
            await finishRun(id, outcome: .cancelled, toVersion: nil, failureReason: nil)
        }
        guard !hasActiveUpdates, await updateQueue.isIdle else { return }
        if !succeededAwaitingRescan.isEmpty {
            await rescanAfterUpdates()
        }
        if !batchSucceeded.isEmpty || !batchFailed.isEmpty {
            if !isAppActive(), AppSettings.bool(AppSettings.notifyUpdatesFinishedKey, in: defaults) {
                notifier.notifyUpdatesFinished(succeeded: batchSucceeded, failed: batchFailed)
            }
            batchSucceeded.removeAll()
            batchFailed.removeAll()
        }
    }

    /// Nach erfolgreichen Updates: Brew-Ergebnis-Cache verwerfen, neu scannen, Nachher-Version eintragen.
    private func rescanAfterUpdates() async {
        let succeeded = succeededAwaitingRescan
        if scansLive {
            // Ein bereits laufender Refresh kennt den Stand nach dem Update noch nicht.
            while isRefreshing {
                try? await Task.sleep(for: .milliseconds(100))
            }
            await commandCache.remove { $0.contains(" outdated ") }
            await refresh()
        }
        for (id, reportedVersion) in succeeded {
            // Eine Übernahme ändert die Version nicht; der Eintrag erscheint danach als Cask.
            let adopted = adoptionJobs.remove(id) != nil
            let removed = removalJobs.remove(id) != nil
            let toVersion = removed ? nil : adopted ? activeRuns[id]?.fromVersion
                : scansLive ? (item(id: id)?.installedVersion ?? reportedVersion) : (reportedVersion ?? nil)
            await finishRun(id, outcome: .succeeded, toVersion: toVersion, failureReason: nil)
        }
        succeededAwaitingRescan.removeAll()
    }

    private func finishRun(_ id: InstalledItem.ID, outcome: UpdateRun.Outcome, toVersion: String?, failureReason: String?) async {
        guard var run = activeRuns.removeValue(forKey: id) else { return }
        run.finishedAt = Date()
        run.outcome = outcome
        run.toVersion = toVersion
        run.failureReason = failureReason
        run.log = (updateLogs[id] ?? []).map(\.text).joined(separator: "\n")
        await record(run)
    }

    private func record(_ run: UpdateRun) async {
        if let index = updateRuns.firstIndex(where: { $0.id == run.id }) {
            updateRuns[index] = run
        } else {
            updateRuns.insert(run, at: 0)
        }
        do {
            try await store?.record(run)
        } catch {
            storeError = String(describing: error)
        }
    }

    func item(id: InstalledItem.ID?) -> InstalledItem? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }

    private static func sorted(_ items: [InstalledItem]) -> [InstalledItem] {
        items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
