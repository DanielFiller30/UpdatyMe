import Foundation

/// Filter für die Inventarliste. Codable, damit die App ihn über Neustarts speichern kann.
public struct InventoryFilter: Sendable, Hashable, Codable {
    public enum StatusFilter: String, Sendable, Hashable, Codable, CaseIterable {
        case all
        /// Nur `outdated`. Fixierte Einträge zählen nicht dazu, sie werden bewusst nicht aktualisiert.
        case updates
        case unknown
        case upToDate
    }

    /// Quellen, die im Filter-Menü angeboten werden.
    public static let selectableSources: [ItemSource] = [.mas, .sparkle, .brew, .cask, .manual, .system]

    /// Apps mit Quelle `system` (TV, Music, …). Standardmäßig ausgeblendet. Gilt nicht für macOS selbst
    /// und nicht in den Kategorien „System“ und „Favoriten“.
    public var showsSystemApps = false
    public var status: StatusFilter = .all
    /// Leer = alle Quellen.
    public var sources: Set<ItemSource> = []
    public var favoritesOnly = false

    public init() {}

    public static let `default` = InventoryFilter()

    /// `true`, wenn vom Standard abweichend (für die Anzeige des Filter-Symbols).
    public var isActive: Bool { self != .default }

    public func matches(_ item: InstalledItem, isFavorite: Bool, in category: InventoryCategory) -> Bool {
        if !showsSystemApps, item.source == .system, item.kind != .os,
           category != .system, category != .favorites {
            return false
        }
        switch status {
        case .all: break
        case .updates: guard item.status == .outdated else { return false }
        case .unknown: guard item.status == .unknown else { return false }
        case .upToDate: guard item.status == .upToDate else { return false }
        }
        if !sources.isEmpty, !sources.contains(item.source) {
            return false
        }
        if favoritesOnly, !isFavorite {
            return false
        }
        return true
    }
}
