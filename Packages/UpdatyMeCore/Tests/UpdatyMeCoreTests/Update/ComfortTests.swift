import Foundation
import Testing
@testable import UpdatyMeCore
import UpdatyMeCoreTestSupport

@Suite("Pinning")
struct PinningTests {
    static func item(_ id: String, brewPinned: Bool = false) -> InstalledItem {
        InstalledItem(id: id, name: id, kind: .cli, ecosystem: .brew, installedVersion: "1.0", source: .brew,
                      updateCapability: .auto, metadata: brewPinned ? ["pinned": "true"] : [:])
    }

    @Test func appAndBrewPinsKeepItemsPinnedAndNotUpdatable() {
        let remotes = ["a": RemoteVersion(itemID: "a", version: "2.0", source: "t"),
                       "b": RemoteVersion(itemID: "b", version: "2.0", source: "t"),
                       "c": RemoteVersion(itemID: "c", version: "2.0", source: "t")]
        let merged = RefreshCoordinator.merge([Self.item("a"), Self.item("b"), Self.item("c", brewPinned: true)],
                                              remotes: remotes, pinned: ["b"])
        #expect(merged.map(\.status) == [.outdated, .pinned, .pinned])
        #expect(merged.map(\.canUpdateAutomatically) == [true, false, false])
        #expect(merged[1].latestVersion == "2.0", "Neueste Version bleibt sichtbar")
    }

    @Test func pinsPersist() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("UpdatyMe.store")
        do {
            let store = try InventoryStore.open(at: url)
            try await store.setPinned(true, for: "brew:formula/node")
            try await store.setPinned(true, for: "brew:formula/node")
            try await store.setPinned(true, for: "x")
            try await store.setPinned(false, for: "x")
        }
        #expect(try await InventoryStore.open(at: url).pins() == ["brew:formula/node"])
    }
}

@Suite("Adopt")
struct AdoptTests {
    static let app = InstalledItem(id: "app-bundle:/Applications/Docker.app", name: "Docker", kind: .app, ecosystem: .appBundle,
                                   installedVersion: "4.96.3", installPath: "/Applications/Docker.app", source: .manual,
                                   updateCapability: .manual)

    @Test func onlyIdenticalVersionsOfUniquelyMatchedCasks() {
        let same = RemoteVersion(itemID: Self.app.id, version: "4.96.3", source: "Homebrew Cask docker-desktop")
        #expect(Self.app.adoptableCaskToken(remote: same) == "docker-desktop")
        #expect(Self.app.adoptableCaskToken(remote: RemoteVersion(itemID: Self.app.id, version: "4.97.0", source: "Homebrew Cask docker-desktop")) == nil)
        #expect(Self.app.adoptableCaskToken(remote: RemoteVersion(itemID: Self.app.id, version: "4.96.3", source: "Sparkle")) == nil)
        #expect(Self.app.adoptableCaskToken(remote: nil) == nil)
        var mas = Self.app
        mas.source = .mas
        #expect(mas.adoptableCaskToken(remote: same) == nil)
        #expect(CaskMatchLatestProvider.token(fromSource: "Homebrew Cask ") == nil)
    }

    @Test func adoptionRunsInBrewLaneWithAdoptArguments() async throws {
        let job = Self.app.adoptionJob(token: "docker-desktop")
        #expect(BrewUpdateExecutor.arguments(for: job) == ["install", "--cask", "--adopt", "docker-desktop"])
        #expect(UpdateQueue.standardLane(job) == .brew)
        #expect(UpdateQueue.standardLane(Self.app) == .appBundle)

        // Übernahme und Brew-Update teilen sich die Spur → nie gleichzeitig (Brew-Sperre).
        let recorder = UpdateQueueTests.Recorder()
        let queue = UpdateQueue(executors: [.brew: recorder])
        let formula = UpdateQueueTests.item("brew:formula/x", .brew)
        await queue.enqueue([formula, job])
        await queue.waitUntilIdle()
        #expect(recorder.order == [formula.id, job.id])
        #expect(recorder.maximumConcurrency == 1)
    }
}
