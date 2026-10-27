import Foundation
import Testing
import UpdatyMeCore

@Suite("InstalledItem")
struct InstalledItemTests {
    static let item = InstalledItem(
        id: InstalledItem.makeID(ecosystem: .brew, identifier: "formula/node"),
        name: "node",
        kind: .runtime,
        ecosystem: .brew,
        installedVersion: "22.11.0",
        installPath: "/opt/homebrew/Cellar/node/22.11.0",
        source: .brew,
        updateCapability: .auto,
        metadata: ["tap": "homebrew/core"]
    )

    static func remote(_ version: String) -> RemoteVersion {
        RemoteVersion(itemID: item.id, version: version, source: "test")
    }

    @Test func idCombinesEcosystemAndIdentifier() {
        #expect(Self.item.id == "brew:formula/node")
    }

    @Test func outdatedMinor() {
        let result = Self.item.applying(latest: Self.remote("22.12.0"))
        #expect(result.status == .outdated)
        #expect(result.latestVersion == "22.12.0")
        #expect(!result.isMajorUpdate)
    }

    @Test func outdatedMajor() {
        let result = Self.item.applying(latest: Self.remote("24.11.0"))
        #expect(result.status == .outdated)
        #expect(result.isMajorUpdate)
    }

    @Test(arguments: ["22.11.0", "22.10.0", "22.11"])
    func upToDateWhenNotOlder(latest: String) {
        let result = Self.item.applying(latest: Self.remote(latest))
        #expect(result.status == .upToDate)
        #expect(!result.isMajorUpdate)
    }

    @Test func unknownWithoutRemote() {
        var outdated = Self.item.applying(latest: Self.remote("24.0.0"))
        outdated = outdated.applying(latest: nil)
        #expect(outdated.status == .unknown)
        #expect(outdated.latestVersion == nil)
        #expect(!outdated.isMajorUpdate)
    }

    @Test func unknownWhenVersionsNotComparable() {
        #expect(Self.item.applying(latest: Self.remote("latest")).status == .unknown)

        var unparseable = Self.item
        unparseable.installedVersion = "unbekannt"
        #expect(unparseable.applying(latest: Self.remote("1.0")).status == .unknown)
    }

    @Test func pinnedWinsButKeepsLatestVersion() {
        let result = Self.item.applying(latest: Self.remote("24.0.0"), isPinned: true)
        #expect(result.status == .pinned)
        #expect(result.latestVersion == "24.0.0")
        #expect(!result.isMajorUpdate)
    }

    @Test func roundTripsThroughCodable() throws {
        let item = Self.item.applying(latest: Self.remote("24.0.0"))
        let decoded = try JSONDecoder().decode(InstalledItem.self, from: JSONEncoder().encode(item))
        #expect(decoded == item)
    }
}
