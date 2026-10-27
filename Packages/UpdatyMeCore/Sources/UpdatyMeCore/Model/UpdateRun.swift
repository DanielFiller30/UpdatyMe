import Foundation

/// Ein Eintrag in der Update-Historie mit Vorher-/Nachher-Version.
public struct UpdateRun: Sendable, Hashable, Codable, Identifiable {
    public enum Outcome: String, Sendable, Hashable, Codable, CaseIterable {
        case running
        case succeeded
        case succeededRestartRequired
        case failed
        case cancelled
    }

    public var id: UUID
    public var itemID: InstalledItem.ID
    public var itemName: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var fromVersion: String
    public var toVersion: String?
    public var outcome: Outcome
    public var failureReason: String?
    public var log: String

    public init(
        id: UUID = UUID(),
        itemID: InstalledItem.ID,
        itemName: String,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        fromVersion: String,
        toVersion: String? = nil,
        outcome: Outcome = .running,
        failureReason: String? = nil,
        log: String = ""
    ) {
        self.id = id
        self.itemID = itemID
        self.itemName = itemName
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.outcome = outcome
        self.failureReason = failureReason
        self.log = log
    }
}
