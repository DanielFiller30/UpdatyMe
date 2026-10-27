import Foundation
import Testing
import UpdatyMeCore
@testable import UpdatyMe

@MainActor
final class RecordingNotifier: UpdateNotifier {
    var newUpdates: [[String]] = []
    var finished: [(succeeded: [String], failed: [String])] = []

    func notifyNewUpdates(_ names: [String]) { newUpdates.append(names) }
    func notifyUpdatesFinished(succeeded: [String], failed: [String]) { finished.append((succeeded, failed)) }
}

@Suite("Phase 7")
@MainActor
struct ComfortTests {
    static var fork: InstalledItem { SampleInventory.items.first { $0.name == "Fork" }! }

    /// Akzeptanzkriterium: Gepinnte Items werden bei „Alle aktualisieren“ übersprungen.
    @Test func pinnedItemsAreSkippedByUpdateAll() async throws {
        let store = try InventoryStore.open(at: nil)
        let executor = InventoryModelUpdateTests.ScriptedExecutor()
        let model = InventoryModel.fixed(SampleInventory.items, store: store, executors: [.brew: executor])
        #expect(Set(model.updatableItems(in: .overview).map(\.name)) == ["Fork", "python@3.12"])

        model.togglePin(Self.fork.id)
        #expect(model.item(id: Self.fork.id)?.status == .pinned)
        #expect(model.item(id: Self.fork.id)?.latestVersion == "2.71.0")
        #expect(model.updatableItems(in: .overview).map(\.name) == ["python@3.12"])

        // Auch ein direkt übergebener fixierter Eintrag wird nicht aktualisiert.
        await model.startUpdates(model.visibleItems(in: .overview))
        await model.waitForUpdates()
        #expect(try await store.updateRuns().map(\.itemName) == ["python@3.12"])
        #expect(try await store.pins() == [Self.fork.id])

        model.togglePin(Self.fork.id)
        #expect(model.item(id: Self.fork.id)?.status == .outdated, "Lösen stellt den Status wieder her")
    }

    /// Akzeptanzkriterium: Menüleiste zeigt die korrekte Anzahl (= Übersicht mit Filter, ohne Fixierte).
    @Test func menuBarCountMatchesOverview() {
        let model = InventoryModel.fixed(SampleInventory.items)
        let expected = model.visibleItems(in: .overview).filter { $0.status == .outdated }.count
        #expect(model.updateCount(in: .overview) == expected)
        #expect(expected == 3, "macOS, Fork, python@3.12; docker ist fixiert")

        model.togglePin(Self.fork.id)
        #expect(model.updateCount(in: .overview) == 2)

        var onlyCasks = InventoryFilter()
        onlyCasks.sources = [.cask]
        model.filter = onlyCasks
        #expect(model.updateCount(in: .overview) == 0)
    }

    @Test func notifiesOnlyAboutNewUpdatesAndNotOnFirstRun() {
        let notifier = RecordingNotifier()
        let model = InventoryModel.fixed(SampleInventory.items, notifier: notifier)
        model.notifyAboutNewUpdates()
        #expect(notifier.newUpdates.isEmpty, "Erster Lauf merkt sich nur den Stand")
        model.notifyAboutNewUpdates()
        #expect(notifier.newUpdates.isEmpty, "Nichts Neues")

        model.setNotifiedUpdates(["macos:macOS"])
        model.notifyAboutNewUpdates()
        #expect(notifier.newUpdates == [["Fork", "python@3.12"]])
    }

    @Test func notifiesWhenUpdatesFinishInBackgroundOnly() async {
        let notifier = RecordingNotifier()
        let model = InventoryModel.fixed(SampleInventory.items,
                                         executors: [.brew: InventoryModelUpdateTests.ScriptedExecutor(failing: ["brew:python@3.12"])],
                                         notifier: notifier)
        model.isAppActive = { false }
        await model.startUpdates(model.updatableItems(in: .overview))
        await model.waitForUpdates()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(notifier.finished.count == 1)
        #expect(notifier.finished.first?.succeeded == ["Fork"])
        #expect(notifier.finished.first?.failed == ["python@3.12"])

        let foreground = RecordingNotifier()
        let active = InventoryModel.fixed(SampleInventory.items,
                                          executors: [.brew: InventoryModelUpdateTests.ScriptedExecutor()],
                                          notifier: foreground)
        active.isAppActive = { true }
        await active.startUpdates(active.updatableItems(in: .overview))
        await active.waitForUpdates()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(foreground.finished.isEmpty)
    }

    @Test func adoptionRunsThroughBrewLaneAndKeepsVersion() async throws {
        let docker = InstalledItem(id: "app-bundle:/Applications/Docker.app", name: "Docker", kind: .app, ecosystem: .appBundle,
                                   installedVersion: "4.96.3", installPath: "/Applications/Docker.app", source: .manual,
                                   status: .upToDate, updateCapability: .manual)
        final class Recorder: UpdateExecutor, @unchecked Sendable {
            var jobs: [InstalledItem] = []
            func update(_ item: InstalledItem) -> AsyncThrowingStream<UpdateEvent, any Error> {
                jobs.append(item)
                return AsyncThrowingStream { continuation in
                    continuation.yield(.output(line: "==> Adopting \(item.name)", isError: false))
                    continuation.yield(.completed(newVersion: nil, restartRequired: false))
                    continuation.finish()
                }
            }
        }
        let recorder = Recorder()
        let store = try InventoryStore.open(at: nil)
        let model = InventoryModel.fixed([docker], store: store, executors: [.brew: recorder],
                                         remotes: [docker.id: RemoteVersion(itemID: docker.id, version: "4.96.3", source: "Homebrew Cask docker-desktop")])

        await model.startAdoption(docker)
        await model.waitForUpdates()

        #expect(recorder.jobs.first?.metadata["adoptCask"] == "docker-desktop")
        let run = try #require(try await store.updateRuns().first)
        #expect(run.outcome == .succeeded)
        #expect(run.fromVersion == "4.96.3")
        #expect(run.toVersion == "4.96.3")
    }
}

@Suite("Settings")
@MainActor
struct SettingsTests {
    @Test func disabledNotificationsStayQuietButRememberTheState() throws {
        let suite = "UpdatyMeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: AppSettings.notifyNewUpdatesKey)

        let notifier = RecordingNotifier()
        let model = InventoryModel.fixed(SampleInventory.items, defaults: defaults, notifier: notifier)
        model.setNotifiedUpdates(["macos:macOS"])
        model.notifyAboutNewUpdates()
        #expect(notifier.newUpdates.isEmpty)

        // Nach dem Einschalten keine nachträgliche Mitteilung über bereits bekannte Updates.
        defaults.set(true, forKey: AppSettings.notifyNewUpdatesKey)
        model.notifyAboutNewUpdates()
        #expect(notifier.newUpdates.isEmpty)
    }

    @Test func disabledFinishNotificationStaysQuiet() async throws {
        let suite = "UpdatyMeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: AppSettings.notifyUpdatesFinishedKey)

        let notifier = RecordingNotifier()
        let model = InventoryModel.fixed(SampleInventory.items, defaults: defaults,
                                         executors: [.brew: InventoryModelUpdateTests.ScriptedExecutor()], notifier: notifier)
        model.isAppActive = { false }
        await model.startUpdates(model.updatableItems(in: .overview))
        await model.waitForUpdates()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(notifier.finished.isEmpty)
    }

    @Test func checkIntervalDefaultsToCacheTTLAndIsReadFromDefaults() throws {
        let suite = "UpdatyMeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = InventoryModel.fixed([], defaults: defaults)
        #expect(model.checkInterval == .sixHours)
        #expect(CheckInterval.sixHours.duration == CachingHTTPClient.defaultTTL)

        defaults.set(CheckInterval.never.rawValue, forKey: AppSettings.checkIntervalKey)
        #expect(model.checkInterval == .never)
        #expect(CheckInterval.never.duration == nil)

        defaults.set("unbekannt", forKey: AppSettings.checkIntervalKey)
        #expect(model.checkInterval == .sixHours)
    }
}
