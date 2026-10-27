import Foundation
import Testing
import UpdatyMeCore
@testable import UpdatyMe

@Suite("Table sorting")
@MainActor
struct SortingTests {
    static func item(_ name: String, _ installed: String, latest: String? = nil, status: InstalledItem.Status = .unknown,
                     major: Bool = false) -> InstalledItem {
        InstalledItem(id: name, name: name, kind: .cli, ecosystem: .brew, installedVersion: installed, source: .brew,
                      latestVersion: latest, status: status, isMajorUpdate: major)
    }

    static let items = [
        item("a", "1.10.0", latest: "1.10.0", status: .upToDate),
        item("b", "1.9.0", latest: "2.0.0", status: .outdated, major: true),
        item("c", "1.9.5", status: .unknown),
        item("d", "1.2.3_1", latest: "1.2.4", status: .outdated),
        item("e", "latest", latest: "1.0", status: .pinned),
    ]

    static func names(_ comparator: KeyPathComparator<InstalledItem>) -> [String] {
        items.sorted(using: [comparator, KeyPathComparator(\InstalledItem.name, comparator: .localizedStandard)]).map(\.name)
    }

    @Test func installedSortsByVersion() {
        #expect(Self.names(KeyPathComparator(\.installedVersion, comparator: VersionSortComparator()))
                == ["d", "b", "c", "a", "e"], "1.9 vor 1.10; nicht vergleichbares „latest“ alphabetisch dahinter")
        #expect(Self.names(KeyPathComparator(\.installedVersion, comparator: VersionSortComparator(), order: .reverse)).first == "e")
    }

    @Test func latestSortsByVersionWithUnknownLast() {
        #expect(Self.names(KeyPathComparator(\.latestVersionSortKey, comparator: VersionSortComparator())) == ["e", "d", "a", "b", "c"])
        #expect(Self.names(KeyPathComparator(\.latestVersionSortKey, comparator: VersionSortComparator(), order: .reverse))
                == ["b", "a", "d", "e", "c"], "Ohne neueste Version auch absteigend am Ende")
    }

    @Test func statusSortsImportantFirst() {
        #expect(Self.names(KeyPathComparator(\.statusSortRank)) == ["b", "d", "c", "e", "a"])
    }
}
