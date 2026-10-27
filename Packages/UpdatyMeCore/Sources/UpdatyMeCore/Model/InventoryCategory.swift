import Foundation

/// Sidebar-Kategorien. Ein Eintrag kann in mehreren Kategorien erscheinen
/// (z. B. ein Cask mit App unter „Apps“ und „Homebrew“).
public enum InventoryCategory: String, Sendable, Hashable, CaseIterable, Identifiable {
    case favorites, overview, system, apps, homebrew, runtimes, packages, history

    public var id: String { rawValue }

    /// `false` für Kategorien ohne Inventar-Einträge (Verlauf zeigt Update-Läufe).
    public var showsItems: Bool { self != .history }

    public func contains(_ item: InstalledItem, favorites: Set<InstalledItem.ID> = []) -> Bool {
        switch self {
        case .favorites:
            favorites.contains(item.id)
        case .overview:
            true
        case .system:
            item.kind == .os || item.source == .system
        case .apps:
            item.kind == .app && item.source != .system
        case .homebrew:
            item.ecosystem == .brew && item.kind != .package
        case .runtimes:
            item.kind == .runtime
        case .packages:
            item.kind == .package
        case .history:
            false
        }
    }

    /// Einträge dieser Kategorie, optional zusätzlich gefiltert.
    public func items(
        in items: [InstalledItem],
        favorites: Set<InstalledItem.ID> = [],
        filter: InventoryFilter? = nil
    ) -> [InstalledItem] {
        items.filter { item in
            contains(item, favorites: favorites)
                && (filter?.matches(item, isFavorite: favorites.contains(item.id), in: self) ?? true)
        }
    }

    /// Anzahl verfügbarer Updates (Status `outdated`) in dieser Kategorie, nach Filter.
    public func updateCount(
        in items: [InstalledItem],
        favorites: Set<InstalledItem.ID> = [],
        filter: InventoryFilter? = nil
    ) -> Int {
        self.items(in: items, favorites: favorites, filter: filter).lazy.filter { $0.status == .outdated }.count
    }
}
