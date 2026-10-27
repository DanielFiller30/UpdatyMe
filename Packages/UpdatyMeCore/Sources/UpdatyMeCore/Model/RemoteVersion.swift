import Foundation

/// Die neueste verfügbare Version eines Eintrags, wie sie eine Quelle (Brew, Registry, Appcast, …) meldet.
public struct RemoteVersion: Sendable, Hashable, Codable {
    public enum Channel: String, Sendable, Hashable, Codable, CaseIterable {
        case stable, lts, current, prerelease
    }

    /// Wie der Status zu bestimmen ist. Quellen, die selbst entscheiden können (z. B. Sparkle über
    /// Build-Nummern, Brew bei nicht vergleichbaren Versionen), liefern das Ergebnis direkt.
    public enum Assessment: String, Sendable, Hashable, Codable, CaseIterable {
        /// Installierte und neueste Version vergleichen; nicht vergleichbar → `unknown`.
        case compareVersions
        /// Laut Quelle veraltet.
        case outdated
        /// Laut Quelle aktuell.
        case upToDate
        /// Quelle kennt eine Version, der Status lässt sich aber nicht ehrlich bestimmen (z. B. `latest`).
        case undeterminable
    }

    public var itemID: InstalledItem.ID
    public var version: String
    public var channel: Channel
    /// Herkunft der Information, z. B. `brew outdated`, `registry.npmjs.org`.
    public var source: String
    public var releaseNotesURL: URL?
    public var releaseDate: Date?
    public var fetchedAt: Date
    public var assessment: Assessment
    /// Ende der Unterstützung der installierten Release-Linie (z. B. Python 3.9), falls bekannt.
    public var endOfLife: Date?
    /// Hinweis auf eine neuere Release-Linie, die bewusst nicht als Update gilt (z. B. „3.15“).
    public var newerReleaseLine: String?

    public init(
        itemID: InstalledItem.ID,
        version: String,
        channel: Channel = .stable,
        source: String,
        releaseNotesURL: URL? = nil,
        releaseDate: Date? = nil,
        fetchedAt: Date = Date(),
        assessment: Assessment = .compareVersions,
        endOfLife: Date? = nil,
        newerReleaseLine: String? = nil
    ) {
        self.itemID = itemID
        self.version = version
        self.channel = channel
        self.source = source
        self.releaseNotesURL = releaseNotesURL
        self.releaseDate = releaseDate
        self.fetchedAt = fetchedAt
        self.assessment = assessment
        self.endOfLife = endOfLife
        self.newerReleaseLine = newerReleaseLine
    }
}
