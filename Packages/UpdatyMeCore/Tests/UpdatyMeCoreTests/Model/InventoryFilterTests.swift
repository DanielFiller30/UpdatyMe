import Foundation
import Testing
import UpdatyMeCore

@Suite("InventoryFilter")
struct InventoryFilterTests {
    typealias C = InventoryCategoryTests

    static let pinned = C.item("docker", kind: .cli, ecosystem: .brew, source: .brew, status: .pinned)
    static let all = C.all + [pinned]

    static func names(_ category: InventoryCategory, _ filter: InventoryFilter, favorites: Set<String> = []) -> [String] {
        category.items(in: all, favorites: favorites, filter: filter).map(\.name)
    }

    @Test func defaultHidesSystemAppsButKeepsMacOS() {
        #expect(Self.names(.overview, .default) == ["macOS", "Spotify", "Fork", "gcloud", "ripgrep", "libpng", "node", "docker"])
        #expect(!InventoryFilter.default.isActive)
    }

    @Test func systemAppsStayVisibleInSystemAndFavorites() {
        #expect(Self.names(.system, .default) == ["macOS", "Safari"])
        #expect(Self.names(.favorites, .default, favorites: ["app-bundle:Safari"]) == ["Safari"])
    }

    @Test func showsSystemAppsWhenEnabled() {
        var filter = InventoryFilter()
        filter.showsSystemApps = true
        #expect(Self.names(.overview, filter).contains("Safari"))
        #expect(filter.isActive)
    }

    @Test(arguments: [
        (InventoryFilter.StatusFilter.updates, ["macOS", "Spotify", "Fork", "libpng"]),
        (.unknown, ["gcloud", "ripgrep", "node"]),
        (.upToDate, []),
        (.all, ["macOS", "Spotify", "Fork", "gcloud", "ripgrep", "libpng", "node", "docker"]),
    ])
    func filtersByStatus(status: InventoryFilter.StatusFilter, expected: [String]) {
        var filter = InventoryFilter()
        filter.status = status
        #expect(Self.names(.overview, filter) == expected, "Fixierte Einträge gelten nicht als Update")
    }

    @Test func filtersBySources() {
        var filter = InventoryFilter()
        filter.sources = [.cask, .manual]
        #expect(Self.names(.overview, filter) == ["Spotify", "Fork", "gcloud"])

        filter.sources = [.system]
        #expect(Self.names(.overview, filter) == ["macOS"], "System-Apps bleiben trotz Quelle ausgeblendet")
        filter.showsSystemApps = true
        #expect(Self.names(.overview, filter) == ["macOS", "Safari"])
    }

    @Test func favoritesOnly() {
        var filter = InventoryFilter()
        filter.favoritesOnly = true
        #expect(Self.names(.overview, filter, favorites: ["brew:ripgrep", "node:node"]) == ["ripgrep", "node"])
    }

    @Test func updateCountRespectsFilter() {
        #expect(InventoryCategory.overview.updateCount(in: Self.all) == 4)
        var filter = InventoryFilter()
        filter.sources = [.cask]
        #expect(InventoryCategory.overview.updateCount(in: Self.all, filter: filter) == 1)
    }

    @Test func roundTripsThroughJSON() throws {
        var filter = InventoryFilter()
        filter.showsSystemApps = true
        filter.status = .updates
        filter.sources = [.mas, .sparkle]
        filter.favoritesOnly = true
        let decoded = try JSONDecoder().decode(InventoryFilter.self, from: JSONEncoder().encode(filter))
        #expect(decoded == filter)
    }
}
