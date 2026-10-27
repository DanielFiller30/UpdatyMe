import Foundation
import SwiftData

// SwiftData-Persistenzmodelle. Nur `InventoryStore` sieht sie; nach außen gehen die
// Sendable-Werttypen `InstalledItem`, `RemoteVersion`, `UpdateRun`.
// Enums und offene Kennungen werden als Rohwert-String gespeichert, damit neue Fälle
// keine Schema-Migration erfordern.

@Model
final class StoredItem {
    @Attribute(.unique) var itemID: String
    var name: String
    var kind: String
    var ecosystem: String
    var installedVersion: String
    var installPath: String?
    var source: String
    var latestVersion: String?
    var status: String
    var updateCapability: String
    var isMajorUpdate: Bool
    /// JSON-kodiertes `[String: String]`.
    var metadata: Data
    var lastSeenAt: Date

    init(_ item: InstalledItem, seenAt: Date) {
        itemID = item.id
        name = item.name
        kind = item.kind.rawValue
        ecosystem = item.ecosystem.rawValue
        installedVersion = item.installedVersion
        installPath = item.installPath
        source = item.source.rawValue
        latestVersion = item.latestVersion
        status = item.status.rawValue
        updateCapability = item.updateCapability.rawValue
        isMajorUpdate = item.isMajorUpdate
        metadata = Self.encode(item.metadata)
        lastSeenAt = seenAt
    }

    func update(from item: InstalledItem, seenAt: Date) {
        name = item.name
        kind = item.kind.rawValue
        ecosystem = item.ecosystem.rawValue
        installedVersion = item.installedVersion
        installPath = item.installPath
        source = item.source.rawValue
        latestVersion = item.latestVersion
        status = item.status.rawValue
        updateCapability = item.updateCapability.rawValue
        isMajorUpdate = item.isMajorUpdate
        metadata = Self.encode(item.metadata)
        lastSeenAt = seenAt
    }

    /// Unbekannte Rohwerte (z. B. aus einer neueren App-Version) werden ehrlich zu `unknown`/`none`.
    var value: InstalledItem {
        InstalledItem(
            id: itemID,
            name: name,
            kind: InstalledItem.Kind(rawValue: kind) ?? .cli,
            ecosystem: EcosystemID(rawValue: ecosystem),
            installedVersion: installedVersion,
            installPath: installPath,
            source: ItemSource(rawValue: source),
            latestVersion: latestVersion,
            status: InstalledItem.Status(rawValue: status) ?? .unknown,
            updateCapability: InstalledItem.UpdateCapability(rawValue: updateCapability) ?? .none,
            isMajorUpdate: isMajorUpdate,
            metadata: (try? JSONDecoder().decode([String: String].self, from: metadata)) ?? [:]
        )
    }

    private static func encode(_ metadata: [String: String]) -> Data {
        (try? JSONEncoder().encode(metadata)) ?? Data()
    }
}

@Model
final class StoredRemoteVersion {
    @Attribute(.unique) var itemID: String
    var version: String
    var channel: String
    var source: String
    var releaseNotesURL: URL?
    var releaseDate: Date?
    var fetchedAt: Date
    /// Standardwert für die automatische Migration von Stores ohne diese Spalte.
    var assessment: String = RemoteVersion.Assessment.compareVersions.rawValue
    var endOfLife: Date?
    var newerReleaseLine: String?

    init(_ remote: RemoteVersion) {
        itemID = remote.itemID
        version = remote.version
        channel = remote.channel.rawValue
        source = remote.source
        releaseNotesURL = remote.releaseNotesURL
        releaseDate = remote.releaseDate
        fetchedAt = remote.fetchedAt
        assessment = remote.assessment.rawValue
        endOfLife = remote.endOfLife
        newerReleaseLine = remote.newerReleaseLine
    }

    func update(from remote: RemoteVersion) {
        version = remote.version
        channel = remote.channel.rawValue
        source = remote.source
        releaseNotesURL = remote.releaseNotesURL
        releaseDate = remote.releaseDate
        fetchedAt = remote.fetchedAt
        assessment = remote.assessment.rawValue
        endOfLife = remote.endOfLife
        newerReleaseLine = remote.newerReleaseLine
    }

    var value: RemoteVersion {
        RemoteVersion(
            itemID: itemID,
            version: version,
            channel: RemoteVersion.Channel(rawValue: channel) ?? .stable,
            source: source,
            releaseNotesURL: releaseNotesURL,
            releaseDate: releaseDate,
            fetchedAt: fetchedAt,
            assessment: RemoteVersion.Assessment(rawValue: assessment) ?? .undeterminable,
            endOfLife: endOfLife,
            newerReleaseLine: newerReleaseLine
        )
    }
}

@Model
final class StoredUpdateRun {
    @Attribute(.unique) var runID: UUID
    var itemID: String
    var itemName: String
    var startedAt: Date
    var finishedAt: Date?
    var fromVersion: String
    var toVersion: String?
    var outcome: String
    var failureReason: String?
    var log: String

    init(_ run: UpdateRun) {
        runID = run.id
        itemID = run.itemID
        itemName = run.itemName
        startedAt = run.startedAt
        finishedAt = run.finishedAt
        fromVersion = run.fromVersion
        toVersion = run.toVersion
        outcome = run.outcome.rawValue
        failureReason = run.failureReason
        log = run.log
    }

    func update(from run: UpdateRun) {
        itemID = run.itemID
        itemName = run.itemName
        startedAt = run.startedAt
        finishedAt = run.finishedAt
        fromVersion = run.fromVersion
        toVersion = run.toVersion
        outcome = run.outcome.rawValue
        failureReason = run.failureReason
        log = run.log
    }

    var value: UpdateRun {
        UpdateRun(
            id: runID,
            itemID: itemID,
            itemName: itemName,
            startedAt: startedAt,
            finishedAt: finishedAt,
            fromVersion: fromVersion,
            toVersion: toVersion,
            outcome: UpdateRun.Outcome(rawValue: outcome) ?? .failed,
            failureReason: failureReason,
            log: log
        )
    }
}

/// In der App fixierter Eintrag (Pin), unabhängig vom Inventar gespeichert.
@Model
final class StoredPin {
    @Attribute(.unique) var itemID: String
    var pinnedAt: Date

    init(itemID: String, pinnedAt: Date) {
        self.itemID = itemID
        self.pinnedAt = pinnedAt
    }
}

/// Favorit, unabhängig vom Inventar gespeichert: Er übersteht Neu-Scans und bleibt erhalten,
/// wenn ein Eintrag vorübergehend nicht gefunden wird.
@Model
final class StoredFavorite {
    @Attribute(.unique) var itemID: String
    var addedAt: Date

    init(itemID: String, addedAt: Date) {
        self.itemID = itemID
        self.addedAt = addedAt
    }
}
