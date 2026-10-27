import Foundation
import UpdatyMeCore

/// Sortiert Versionsstrings nach Version statt alphabetisch („1.9“ vor „1.10“). Leere Werte (keine
/// neueste Version bekannt) stehen in beiden Richtungen am Ende. Nicht vergleichbare Versionen
/// werden natürlich-alphabetisch sortiert.
struct VersionSortComparator: SortComparator, Hashable {
    var order: SortOrder = .forward

    func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        switch (lhs.isEmpty, rhs.isEmpty) {
        case (true, true): return .orderedSame
        case (true, false): return .orderedDescending
        case (false, true): return .orderedAscending
        case (false, false): break
        }
        let result = VersionComparator.compare(lhs, rhs) ?? lhs.localizedStandardCompare(rhs)
        guard order == .reverse else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}

extension InstalledItem {
    /// Sortierschlüssel der Spalte „Neueste“ (leer = unbekannt).
    var latestVersionSortKey: String { latestVersion ?? "" }

    /// Sortierschlüssel der Spalte „Status“: Wichtiges zuerst.
    var statusSortRank: Int {
        switch status {
        case .outdated: isMajorUpdate ? 0 : 1
        case .unknown: 2
        case .pinned: 3
        case .upToDate: 4
        }
    }
}
