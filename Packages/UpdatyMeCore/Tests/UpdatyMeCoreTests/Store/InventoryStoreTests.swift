import Foundation
import Testing
import UpdatyMeCore

@Suite("InventoryStore")
struct InventoryStoreTests {
    static func item(_ name: String, ecosystem: EcosystemID = .brew, version: String = "1.0.0") -> InstalledItem {
        InstalledItem(
            id: InstalledItem.makeID(ecosystem: ecosystem, identifier: name),
            name: name,
            kind: .cli,
            ecosystem: ecosystem,
            installedVersion: version,
            installPath: "/opt/homebrew/Cellar/\(name)/\(version)",
            source: .brew,
            latestVersion: "2.0.0",
            status: .outdated,
            updateCapability: .auto,
            isMajorUpdate: true,
            metadata: ["tap": "homebrew/core", "pinned": "false"]
        )
    }

    @Test func persistsAndLoadsItemsAcrossInstances() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("UpdatyMe.store")
        let items = [Self.item("wget"), Self.item("git"), Self.item("Xcode", ecosystem: .appBundle)]
        let remote = RemoteVersion(
            itemID: items[0].id, version: "2.0.0", channel: .stable, source: "brew outdated",
            releaseNotesURL: URL(string: "https://example.org/notes"),
            releaseDate: Date(timeIntervalSince1970: 1_700_000_000),
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let run = UpdateRun(
            itemID: items[0].id, itemName: "wget", startedAt: Date(timeIntervalSince1970: 1_800_000_100),
            finishedAt: Date(timeIntervalSince1970: 1_800_000_200), fromVersion: "1.0.0", toVersion: "2.0.0",
            outcome: .succeeded, log: "==> Upgrading wget\n"
        )

        do {
            let store = try InventoryStore.open(at: url)
            try await store.save(items)
            try await store.saveRemoteVersion(remote)
            try await store.record(run)
        }

        let reopened = try InventoryStore.open(at: url)
        let loaded = try await reopened.items()
        #expect(Set(loaded) == Set(items))
        #expect(loaded.map(\.name) == ["git", "wget", "Xcode"], "Sortierung nach Name, ohne Groß-/Kleinschreibung")
        #expect(try await reopened.items(ecosystem: .appBundle).map(\.name) == ["Xcode"])
        #expect(try await reopened.item(id: items[0].id) == items[0])
        #expect(try await reopened.remoteVersion(for: items[0].id) == remote)
        #expect(try await reopened.updateRuns() == [run])
    }

    @Test func saveUpdatesExistingItemInsteadOfDuplicating() async throws {
        let store = try InventoryStore.open(at: nil)
        try await store.save([Self.item("node", version: "22.0.0")])
        try await store.save([Self.item("node", version: "24.0.0")])

        let items = try await store.items()
        #expect(items.count == 1)
        #expect(items.first?.installedVersion == "24.0.0")
    }

    @Test func replaceItemsRemovesVanishedEntriesOfThatEcosystemOnly() async throws {
        let store = try InventoryStore.open(at: nil)
        let wget = Self.item("wget")
        let git = Self.item("git")
        let xcode = Self.item("Xcode", ecosystem: .appBundle)
        try await store.save([wget, git, xcode])
        try await store.saveRemoteVersion(RemoteVersion(itemID: wget.id, version: "2.0.0", source: "test"))
        try await store.record(UpdateRun(itemID: wget.id, itemName: "wget", fromVersion: "1.0.0"))

        try await store.replaceItems(of: .brew, with: [git])

        #expect(try await store.items().map(\.name) == ["git", "Xcode"])
        #expect(try await store.remoteVersion(for: wget.id) == nil)
        #expect(try await store.updateRuns(itemID: wget.id).count == 1, "Historie bleibt erhalten")
    }

    @Test func recordUpdatesRunAndSortsNewestFirst() async throws {
        let store = try InventoryStore.open(at: nil)
        var older = UpdateRun(itemID: "brew:a", itemName: "a", startedAt: Date(timeIntervalSince1970: 100), fromVersion: "1")
        let newer = UpdateRun(itemID: "brew:b", itemName: "b", startedAt: Date(timeIntervalSince1970: 200), fromVersion: "1")
        try await store.record(older)
        try await store.record(newer)

        older.outcome = .failed
        older.failureReason = "Error: Cannot write to /opt/homebrew"
        older.finishedAt = Date(timeIntervalSince1970: 150)
        try await store.record(older)

        let runs = try await store.updateRuns()
        #expect(runs == [newer, older])
        #expect(try await store.updateRuns(limit: 1) == [newer])
        #expect(try await store.updateRuns(itemID: "brew:a").first?.outcome == .failed)
    }

    @Test func favoritesPersistAndSurviveItemReplacement() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("UpdatyMe.store")
        do {
            let store = try InventoryStore.open(at: url)
            try await store.save([Self.item("wget"), Self.item("git")])
            try await store.setFavorite(true, for: "brew:wget")
            try await store.setFavorite(true, for: "brew:wget")
            try await store.setFavorite(true, for: "brew:git")
            try await store.setFavorite(false, for: "brew:git")
            try await store.replaceItems(of: .brew, with: [])
        }
        let reopened = try InventoryStore.open(at: url)
        #expect(try await reopened.favorites() == ["brew:wget"])
    }

    @Test func remoteVersionIsUpsertedPerItem() async throws {
        let store = try InventoryStore.open(at: nil)
        try await store.saveRemoteVersion(RemoteVersion(itemID: "node:node", version: "22.0.0", channel: .lts, source: "nodejs.org"))
        try await store.saveRemoteVersion(RemoteVersion(itemID: "node:node", version: "24.0.0", channel: .lts, source: "nodejs.org"))

        let versions = try await store.remoteVersions()
        #expect(versions.map(\.version) == ["24.0.0"])
    }
}
