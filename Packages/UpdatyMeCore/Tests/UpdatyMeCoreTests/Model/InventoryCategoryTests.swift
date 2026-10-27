import Testing
import UpdatyMeCore

@Suite("InventoryCategory")
struct InventoryCategoryTests {
    static func item(
        _ name: String, kind: InstalledItem.Kind, ecosystem: EcosystemID, source: ItemSource,
        status: InstalledItem.Status = .unknown
    ) -> InstalledItem {
        InstalledItem(id: "\(ecosystem):\(name)", name: name, kind: kind, ecosystem: ecosystem,
                      installedVersion: "1.0", source: source, status: status)
    }

    static let macOS = item("macOS", kind: .os, ecosystem: .macOS, source: .system, status: .outdated)
    static let safari = item("Safari", kind: .app, ecosystem: .appBundle, source: .system)
    static let spotify = item("Spotify", kind: .app, ecosystem: .appBundle, source: .manual, status: .outdated)
    static let caskApp = item("Fork", kind: .app, ecosystem: .brew, source: .cask, status: .outdated)
    static let caskCLI = item("gcloud", kind: .cli, ecosystem: .brew, source: .cask)
    static let formula = item("ripgrep", kind: .cli, ecosystem: .brew, source: .brew)
    static let dependency = item("libpng", kind: .package, ecosystem: .brew, source: .brew, status: .outdated)
    static let runtime = item("node", kind: .runtime, ecosystem: .node, source: .nvm)
    static let all = [macOS, safari, spotify, caskApp, caskCLI, formula, dependency, runtime]

    @Test(arguments: [
        (InventoryCategory.overview, ["macOS", "Safari", "Spotify", "Fork", "gcloud", "ripgrep", "libpng", "node"]),
        (.system, ["macOS", "Safari"]),
        (.apps, ["Spotify", "Fork"]),
        (.homebrew, ["Fork", "gcloud", "ripgrep"]),
        (.runtimes, ["node"]),
        (.packages, ["libpng"]),
        (.history, []),
        (.favorites, []),
    ])
    func assignsItems(category: InventoryCategory, expected: [String]) {
        #expect(category.items(in: Self.all).map(\.name) == expected)
    }

    @Test func favoritesCategoryUsesFavoriteSet() {
        let favorites: Set<String> = ["brew:Fork", "app-bundle:Safari"]
        #expect(InventoryCategory.favorites.items(in: Self.all, favorites: favorites).map(\.name) == ["Safari", "Fork"])
        #expect(InventoryCategory.favorites.updateCount(in: Self.all, favorites: favorites) == 1)
    }

    @Test func countsOnlyOutdatedItems() {
        #expect(InventoryCategory.overview.updateCount(in: Self.all) == 4)
        #expect(InventoryCategory.apps.updateCount(in: Self.all) == 2)
        #expect(InventoryCategory.homebrew.updateCount(in: Self.all) == 1)
        #expect(InventoryCategory.system.updateCount(in: Self.all) == 1)
        #expect(InventoryCategory.history.updateCount(in: Self.all) == 0)
    }
}
