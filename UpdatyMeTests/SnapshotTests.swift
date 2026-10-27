import AppKit
import SwiftUI
import Testing
import UpdatyMeCore
@testable import UpdatyMe

/// Rendert die Inhalts-Komponenten in Light und Dark als PNG nach `docs/snapshots/` zur Sichtprüfung
/// (kein Pixelvergleich, Entscheidung Phase 3).
///
/// Grenzen, bewusst so entschieden:
/// - Liquid Glass (Toolbar, Sidebar-Container, Inspector-Container) rendert offscreen nicht
///   (`cacheDisplay` erfasst keine Backdrop-Ebenen). Deshalb werden Komponenten ohne Glass-Container
///   gerendert; Glass wird in der laufenden App geprüft.
/// - Reduce Transparency ist eine Systemeinstellung und in SwiftUI nur lesbar. Ist sie beim Testlauf
///   aktiv, enthält der Dateiname `reduced-transparency`.
/// - Sprache über `xcodebuild test -testLanguage de|en`; der Dateiname enthält die Sprache.
@Suite("Snapshots", .serialized)
@MainActor
struct SnapshotTests {
    static let outputDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/snapshots")

    enum Appearance: String, CaseIterable {
        case light, dark

        var name: NSAppearance.Name { self == .light ? .aqua : .darkAqua }
    }

    static let python = SampleInventory.items.first { $0.name == "python@3.12" }!

    @Test(arguments: Appearance.allCases)
    func overviewTable(appearance: Appearance) async throws {
        let model = InventoryModel.fixed(SampleInventory.items, favorites: SampleInventory.favorites)
        let view = ItemTableView(model: model, flow: UpdateFlow(model: model), category: .overview, selection: .constant(Self.python.id), searchText: "")
        try await render(view, name: "table-overview", appearance: appearance, size: CGSize(width: 860, height: 500))
    }

    @Test(arguments: Appearance.allCases)
    func homebrewTableWithFailure(appearance: Appearance) async throws {
        let model = InventoryModel.fixed(
            SampleInventory.items,
            failures: [.brew: InventoryScanner.ScanFailure(error: InventoryError.toolNotFound("Homebrew"))]
        )
        let view = ItemTableView(model: model, flow: UpdateFlow(model: model), category: .homebrew, selection: .constant(nil), searchText: "")
        try await render(view, name: "table-homebrew-failure", appearance: appearance, size: CGSize(width: 860, height: 360))
    }

    @Test(arguments: Appearance.allCases)
    func inspector(appearance: Appearance) async throws {
        let remote = RemoteVersion(itemID: Self.python.id, version: "4.0.0", source: "brew outdated",
                                   releaseNotesURL: URL(string: "https://www.python.org"), fetchedAt: Date().addingTimeInterval(-600))
        try await render(InspectorView(item: Self.python, remote: remote, isFavorite: true), name: "inspector",
                         appearance: appearance, size: CGSize(width: 340, height: 860))
        let spotify = SampleInventory.items.first { $0.name == "Spotify" }!
        try await render(InspectorView(item: spotify, lookupError: "The Internet connection appears to be offline."),
                         name: "inspector-error", appearance: appearance, size: CGSize(width: 340, height: 700))
    }

    @Test(arguments: Appearance.allCases)
    func favoritesAndFilters(appearance: Appearance) async throws {
        let model = InventoryModel.fixed(SampleInventory.items, favorites: SampleInventory.favorites)
        try await render(ItemTableView(model: model, flow: UpdateFlow(model: model), category: .favorites, selection: .constant(nil), searchText: ""),
                         name: "table-favorites", appearance: appearance, size: CGSize(width: 860, height: 260))

        var filter = InventoryFilter()
        filter.sources = [.mas]
        let filtered = InventoryModel.fixed(SampleInventory.items, filter: filter)
        try await render(ItemTableView(model: filtered, flow: UpdateFlow(model: filtered), category: .apps, selection: .constant(nil), searchText: ""),
                         name: "empty-filtered", appearance: appearance, size: CGSize(width: 600, height: 360))

        let empty = InventoryModel.fixed(SampleInventory.items)
        try await render(ItemTableView(model: empty, flow: UpdateFlow(model: empty), category: .favorites, selection: .constant(nil), searchText: ""),
                         name: "empty-favorites", appearance: appearance, size: CGSize(width: 600, height: 360))
    }

    @Test(arguments: Appearance.allCases)
    func sidebar(appearance: Appearance) async throws {
        let model = InventoryModel.fixed(SampleInventory.items, favorites: SampleInventory.favorites)
        try await render(SidebarView(model: model, selection: .constant(.overview)), name: "sidebar",
                         appearance: appearance, size: CGSize(width: 220, height: 380))
    }

    @Test(arguments: Appearance.allCases)
    func emptyStates(appearance: Appearance) async throws {
        let model = InventoryModel.fixed(SampleInventory.items)
        try await render(ItemTableView(model: model, flow: UpdateFlow(model: model), category: .runtimes, selection: .constant(nil), searchText: ""),
                         name: "empty-runtimes", appearance: appearance, size: CGSize(width: 600, height: 360))
        try await render(HistoryView(runs: []), name: "empty-history", appearance: appearance,
                         size: CGSize(width: 600, height: 360))
    }

    @Test(arguments: Appearance.allCases)
    func updateStates(appearance: Appearance) async throws {
        typealias Line = InventoryModel.LogLine
        let log = [Line(id: 0, text: "==> Upgrading python@3.12", isError: false),
                   Line(id: 1, text: "Error: Download failed: https://ghcr.io/v2/homebrew/core/python/3.12/blobs/sha256:abc", isError: true)]
        let runs = [
            UpdateRun(itemID: "brew:ripgrep", itemName: "ripgrep", startedAt: Date().addingTimeInterval(-3600),
                      finishedAt: Date().addingTimeInterval(-3590), fromVersion: "15.1.0", toVersion: "15.2.0", outcome: .succeeded,
                      log: "==> Upgrading ripgrep\n15.1.0 -> 15.2.0"),
            UpdateRun(itemID: "brew:python@3.12", itemName: "python@3.12", startedAt: Date().addingTimeInterval(-600),
                      finishedAt: Date().addingTimeInterval(-590), fromVersion: "3.12.15_1", outcome: .failed,
                      failureReason: "Download failed: https://ghcr.io/v2/homebrew/core/python/3.12/blobs/sha256:abc"),
            UpdateRun(itemID: "brew:Fork", itemName: "Fork", startedAt: Date().addingTimeInterval(-300), fromVersion: "2.70.2",
                      outcome: .cancelled, failureReason: "Skipped because Fork was running."),
        ]
        let model = InventoryModel.fixed(
            SampleInventory.items,
            updateStates: ["brew:Fork": .running, "brew:python@3.12": .queued],
            updateLogs: ["brew:python@3.12": log],
            updateRuns: runs
        )
        try await render(ItemTableView(model: model, flow: UpdateFlow(model: model), category: .overview,
                                       selection: .constant(nil), searchText: ""),
                         name: "table-update-states", appearance: appearance, size: CGSize(width: 980, height: 500))
        let failed = InventoryModel.fixed(SampleInventory.items, updateStates: ["brew:Fork": .succeeded, "brew:python@3.12": .failed("Download failed")])
        try await render(ItemTableView(model: failed, flow: UpdateFlow(model: failed), category: .homebrew,
                                       selection: .constant(nil), searchText: ""),
                         name: "table-update-results", appearance: appearance, size: CGSize(width: 980, height: 340))
        try await render(InspectorView(item: Self.python, logLines: log, updateState: .failed("Download failed"), lastRun: runs[1]),
                         name: "inspector-update-failed", appearance: appearance, size: CGSize(width: 340, height: 900))
        try await render(HistoryView(runs: runs), name: "history", appearance: appearance, size: CGSize(width: 600, height: 420))
        let outdated = SampleInventory.items.filter(\.canUpdateAutomatically)
        try await render(UpdateAllSheet(items: outdated, onConfirm: {}, onCancel: {}), name: "update-all-sheet",
                         appearance: appearance, size: CGSize(width: 460, height: 360))
    }

    @Test(arguments: Appearance.allCases)
    func developerTools(appearance: Appearance) async throws {
        let python = InstalledItem(id: "python:/opt/miniconda/bin/python3", name: "Python", kind: .runtime, ecosystem: .python,
                                   installedVersion: "3.13.14", installPath: "/opt/miniconda/bin", source: .conda,
                                   latestVersion: "3.13.18", status: .outdated, updateCapability: .manual, metadata: ["manager": "conda"])
        let remote = RemoteVersion(itemID: python.id, version: "3.13.18", source: "endoflife.date",
                                   releaseNotesURL: URL(string: "https://www.python.org"), fetchedAt: Date().addingTimeInterval(-300),
                                   endOfLife: try Date("2029-10-31T00:00:00Z", strategy: .iso8601), newerReleaseLine: "3.15")
        try await render(InspectorView(item: python, remote: remote), name: "inspector-python",
                         appearance: appearance, size: CGSize(width: 340, height: 860))

        let scanned = InstalledItem(id: "python:/xcode/python3", name: "Python", kind: .runtime, ecosystem: .python, installedVersion: "3.9.6",
                                    source: .system, updateCapability: .manual)
        let systemRemote = RemoteVersion(itemID: scanned.id, version: "3.9.25", source: "endoflife.date", assessment: .undeterminable,
                                         endOfLife: try Date("2025-10-31T00:00:00Z", strategy: .iso8601), newerReleaseLine: "3.15")
        let system = scanned.applying(latest: systemRemote)
        try await render(InspectorView(item: system, remote: systemRemote), name: "inspector-python-eol",
                         appearance: appearance, size: CGSize(width: 340, height: 700))

        let broken = InstalledItem(id: "config:kubectl", name: "kubectl", kind: .cli, ecosystem: .configuredTools, installedVersion: "",
                                   source: .config, updateCapability: .manual,
                                   metadata: ["configError": "commandNotFound", "configErrorDetail": "kubectl"])
        try await render(InspectorView(item: broken), name: "inspector-config-error",
                         appearance: appearance, size: CGSize(width: 340, height: 600))

        try await render(SettingsView(model: .fixed([])), name: "settings", appearance: appearance, size: CGSize(width: 460, height: 720))
    }

    @Test(arguments: Appearance.allCases)
    func comfort(appearance: Appearance) async throws {
        let demoApp = InstalledItem(id: "app-bundle:/Applications/DemoApp.app", name: "DemoApp", kind: .app, ecosystem: .appBundle,
                                  installedVersion: "2.0.2", installPath: "/Applications/DemoApp.app", source: .mas,
                                  latestVersion: "2.0.5", status: .outdated, updateCapability: .manual)
        let iterm = InstalledItem(id: "app-bundle:/Applications/iTerm.app", name: "iTerm", kind: .app, ecosystem: .appBundle,
                                  installedVersion: "3.7.5", installPath: "/Applications/iTerm.app", source: .sparkle,
                                  latestVersion: "3.7.6", status: .outdated, updateCapability: .manual)
        let docker = InstalledItem(id: "app-bundle:/Applications/Docker.app", name: "Docker", kind: .app, ecosystem: .appBundle,
                                   installedVersion: "4.96.3", installPath: "/Applications/Docker.app", source: .manual,
                                   latestVersion: "4.96.3", status: .upToDate, updateCapability: .manual)
        let remotes = [
            demoApp.id: RemoteVersion(itemID: demoApp.id, version: "2.0.5", source: "App Store",
                                    releaseNotesURL: URL(string: "https://apps.apple.com/de/app/demoApp/id1")),
            iterm.id: RemoteVersion(itemID: iterm.id, version: "3.7.6", source: "Sparkle"),
            docker.id: RemoteVersion(itemID: docker.id, version: "4.96.3", source: "Homebrew Cask docker-desktop"),
        ]
        let items = SampleInventory.items + [demoApp, iterm, docker]
        let model = InventoryModel.fixed(items, remotes: remotes)
        model.togglePin("brew:Fork")
        try await render(ItemTableView(model: model, flow: UpdateFlow(model: model), category: .apps, selection: .constant(nil), searchText: ""),
                         name: "table-app-actions", appearance: appearance, size: CGSize(width: 980, height: 520))
        try await render(InspectorView(item: docker, remote: remotes[docker.id], onAdopt: {}), name: "inspector-adopt",
                         appearance: appearance, size: CGSize(width: 340, height: 820))
        try await render(InspectorView(item: model.item(id: "brew:Fork")!, remote: nil, isPinnedInApp: true), name: "inspector-pinned",
                         appearance: appearance, size: CGSize(width: 340, height: 820))
        try await render(VStack(alignment: .leading, spacing: 6) { MenuBarContent(model: model) }.padding(12),
                         name: "menubar-content", appearance: appearance, size: CGSize(width: 340, height: 360))
    }

    @Test(arguments: Appearance.allCases)
    func offlineBanner(appearance: Appearance) async throws {
        let model = InventoryModel.fixed(SampleInventory.items, failures: [
            .nodeReleases: .init(error: URLError(.notConnectedToInternet)),
            .appStore: .init(error: URLError(.notConnectedToInternet)),
            .caskMatch: .init(error: URLError(.cannotFindHost)),
            .brew: .init(error: InventoryError.commandFailed(command: "brew info", exitCode: 1, stderr: "Error: Another active Homebrew process is already in progress.")),
        ])
        try await render(ItemTableView(model: model, flow: UpdateFlow(model: model), category: .homebrew, selection: .constant(nil), searchText: ""),
                         name: "table-offline-banner", appearance: appearance, size: CGSize(width: 980, height: 360))
    }

    @Test(arguments: Appearance.allCases)
    func runtimeGuide(appearance: Appearance) async throws {
        let node = InstalledItem(id: "node:nvm/24.21.0", name: "Node.js", kind: .runtime, ecosystem: .node, installedVersion: "24.21.0",
                                 source: .nvm, latestVersion: "24.22.1", status: .outdated, updateCapability: .manual,
                                 metadata: ["isDefault": "true"])
        let java = InstalledItem(id: "java:/jdk", name: "Java (Azul Zulu)", kind: .runtime, ecosystem: .java, installedVersion: "25.0.5",
                                 source: .manual, latestVersion: "25.0.4.1", status: .upToDate, updateCapability: .manual,
                                 metadata: ["distribution": "zulu"])
        try await render(RuntimeGuideView(item: node, guide: RuntimeGuide.guide(for: node)!), name: "runtime-guide-nvm",
                         appearance: appearance, size: CGSize(width: 400, height: 420))
        try await render(RuntimeGuideView(item: java, guide: RuntimeGuide.guide(for: java)!), name: "runtime-guide-java",
                         appearance: appearance, size: CGSize(width: 400, height: 380))
        let model = InventoryModel.fixed(SampleInventory.items + [node, java])
        try await render(ItemTableView(model: model, flow: UpdateFlow(model: model), category: .runtimes, selection: .constant(nil), searchText: ""),
                         name: "table-runtimes", appearance: appearance, size: CGSize(width: 980, height: 260))
    }

    @Test(arguments: Appearance.allCases)
    func statusChips(appearance: Appearance) async throws {
        let chips = VStack(alignment: .leading, spacing: 10) {
            StatusChip(status: .upToDate)
            StatusChip(status: .outdated)
            StatusChip(status: .outdated, isMajor: true)
            StatusChip(status: .unknown)
            StatusChip(status: .pinned)
        }
        .padding(20)
        try await render(chips, name: "status-chips", appearance: appearance, size: CGSize(width: 240, height: 200))
    }

    /// Echtes Inventar dieses Macs (nur lesend, ohne Store):
    /// `TEST_RUNNER_UPDATYME_LIVE_TESTS=1 xcodebuild test …`
    @Test(.enabled(if: ProcessInfo.processInfo.environment["UPDATYME_LIVE_TESTS"] == "1"))
    func liveInventory() async throws {
        let model = InventoryModel.scanningWithoutStore()
        await model.refresh()
        #expect(!model.items.isEmpty)
        #expect(model.failures.isEmpty, "Fehlgeschlagene Quellen: \(model.failures)")
        print("[live] \(model.items.count) Einträge; je Kategorie: \(InventoryCategory.allCases.map { "\($0.rawValue)=\(model.visibleItems(in: $0).count)" })")
        let byStatus = Dictionary(grouping: model.items, by: \.status.rawValue).mapValues(\.count)
        print("[live] Status: \(byStatus.sorted { $0.key < $1.key }), Major: \(model.items.filter(\.isMajorUpdate).map(\.name))")
        print("[live] Fehler je Eintrag: \(model.itemErrors.mapValues(\.message))")
        for item in model.items where [.node, .npm, .pnpm, .python, .rust, .java, .gcloud, .configuredTools].contains(item.ecosystem)
            || item.metadata["brewRecordedVersion"] != nil {
            let remote = model.remotes[item.id]
            print("[live-dev] \(item.ecosystem.rawValue) | \(item.name) [\(item.source.rawValue)] \(item.installedVersion) → \(item.latestVersion ?? "-") = \(item.status.rawValue) via \(remote?.source ?? "-") eol=\(remote?.endOfLife.map { "\($0)" } ?? "-") newer=\(remote?.newerReleaseLine ?? "-")")
        }
        for item in model.items where item.ecosystem == .appBundle && item.source != .system {
            print("[live-app] \(item.name) [\(item.source.rawValue)]: \(item.installedVersion) → \(item.latestVersion ?? "-") = \(item.status.rawValue) via \(model.remotes[item.id]?.source ?? "-")")
        }
        for item in model.items where item.status == .outdated {
            print("[live]   \(item.name): \(item.installedVersion) → \(item.latestVersion ?? "-") via \(model.remotes[item.id]?.source ?? "-")")
        }
        var updates = InventoryFilter()
        updates.status = .updates
        model.filter = updates
        let view = ItemTableView(model: model, flow: UpdateFlow(model: model), category: .overview, selection: .constant(nil), searchText: "")
        try await render(view, name: "live-updates", appearance: .light, size: CGSize(width: 900, height: 900))
    }

    // MARK: - Rendering

    private func render(_ view: some View, name: String, appearance: Appearance, size: CGSize) async throws {
        let host = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // Ohne dies gibt `close()` das Fenster zusätzlich zu ARC frei → Absturz (doppelte Freigabe).
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: appearance.name)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }

        // SwiftUI rendert asynchron; kurz warten, bis Layout und Icons stehen.
        try await Task.sleep(for: .milliseconds(600))
        host.layoutSubtreeIfNeeded()

        let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: representation)
        let png = try #require(representation.representation(using: .png, properties: [:]))

        let language = Bundle.main.preferredLocalizations.first ?? "en"
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? "-reduced-transparency" : ""
        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
        let url = Self.outputDirectory.appendingPathComponent("\(name)-\(appearance.rawValue)-\(language)\(reduced).png")
        try png.write(to: url)
        #expect(png.count > 2_000, "Snapshot \(url.lastPathComponent) wirkt leer")
    }
}
