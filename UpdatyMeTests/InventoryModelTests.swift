import Foundation
import Testing
import UpdatyMeCore
@testable import UpdatyMe

@Suite("InventoryModel")
@MainActor
struct InventoryModelTests {
    @Test func filterIsSavedAndRestored() throws {
        let suite = "UpdatyMeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = InventoryModel.fixed([], defaults: defaults)
        #expect(first.filter == .default)
        first.filter.showsSystemApps = true
        first.filter.sources = [.cask]

        let second = InventoryModel.fixed([], defaults: defaults)
        #expect(second.filter.showsSystemApps)
        #expect(second.filter.sources == [.cask])

        second.resetFilter()
        #expect(InventoryModel.fixed([], defaults: defaults).filter == .default)
    }

    @Test func systemAppsHiddenByDefaultAndCounted() {
        let model = InventoryModel.fixed(SampleInventory.items)
        #expect(!model.visibleItems(in: .overview).contains { $0.name == "Safari" })
        #expect(model.visibleItems(in: .overview).contains { $0.name == "macOS" })
        #expect(model.hiddenCount(in: .overview) == 1)
        #expect(model.visibleItems(in: .system).contains { $0.name == "Safari" })
    }

    @Test func toggleFavoriteWithoutStore() {
        let model = InventoryModel.fixed(SampleInventory.items)
        model.toggleFavorite("brew:ripgrep")
        #expect(model.visibleItems(in: .favorites).map(\.name) == ["ripgrep"])
        model.toggleFavorite("brew:ripgrep")
        #expect(model.visibleItems(in: .favorites).isEmpty)
    }
}

@Suite("InventoryModel Updates")
@MainActor
struct InventoryModelUpdateTests {
    struct ScriptedExecutor: UpdateExecutor {
        var failing: Set<String> = []

        func update(_ item: InstalledItem) -> AsyncThrowingStream<UpdateEvent, any Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(.output(line: "==> Upgrading \(item.name)", isError: false))
                if failing.contains(item.id) {
                    continuation.yield(.output(line: "Error: Download failed", isError: true))
                    continuation.finish(throwing: UpdateError.failed(exitCode: 1, reason: "Download failed"))
                } else {
                    continuation.yield(.completed(newVersion: item.latestVersion, restartRequired: false))
                    continuation.finish()
                }
            }
        }
    }

    @Test func historyStoresBeforeAndAfterVersionAndFailureCause() async throws {
        let store = try InventoryStore.open(at: nil)
        let model = InventoryModel.fixed(
            SampleInventory.items, store: store,
            executors: [.brew: ScriptedExecutor(failing: ["brew:python@3.12"])]
        )
        let updatable = model.updatableItems(in: .overview)
        #expect(Set(updatable.map(\.name)) == ["Fork", "python@3.12"], "macOS (Einstellungen) und gepinnte Einträge nicht")

        await model.startUpdates(updatable)
        await model.waitForUpdates()

        let runs = try await store.updateRuns()
        let fork = try #require(runs.first { $0.itemName == "Fork" })
        #expect(fork.outcome == .succeeded)
        #expect(fork.fromVersion == "2.70.2")
        #expect(fork.toVersion == "2.71.0")
        #expect(fork.log.contains("Upgrading Fork"))

        let python = try #require(runs.first { $0.itemName == "python@3.12" })
        #expect(python.outcome == .failed)
        #expect(python.fromVersion == "3.12.15_1")
        #expect(python.toVersion == nil)
        #expect(python.failureReason?.contains("Download failed") == true)
        #expect(python.log.contains("Error: Download failed"))

        #expect(model.updateStates["brew:Fork"] == .succeeded)
        guard case .failed? = model.updateStates["brew:python@3.12"] else {
            Issue.record("Fehlgeschlagenes Update sollte als failed angezeigt werden")
            return
        }
        #expect(model.updateLogs["brew:python@3.12"]?.last?.isError == true)
    }

    @Test func skippedUpdateIsRecorded() async throws {
        let store = try InventoryStore.open(at: nil)
        let model = InventoryModel.fixed(SampleInventory.items, store: store)
        let fork = try #require(SampleInventory.items.first { $0.name == "Fork" })
        await model.recordSkippedUpdate(fork, reason: "Skipped because Fork was running.")
        let run = try #require(try await store.updateRuns().first)
        #expect(run.outcome == .cancelled)
        #expect(run.failureReason == "Skipped because Fork was running.")
    }
}
