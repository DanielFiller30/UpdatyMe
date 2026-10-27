import Foundation
import SwiftData
import Synchronization

/// Persistenz für Inventar-Cache, neueste Versionen und Update-Historie (SwiftData).
/// Nach außen nur Sendable-Werttypen; die SwiftData-Objekte verlassen den Actor nie.
@ModelActor
public actor InventoryStore {
    static let schema = Schema([StoredItem.self, StoredRemoteVersion.self, StoredUpdateRun.self, StoredFavorite.self, StoredPin.self])

    /// Gleichzeitiges Öffnen mehrerer Container mit demselben Schema stürzt in Core Data ab
    /// (`_generateTriggerSQL` verändert geteilte Modell-Daten ohne Synchronisierung; beobachtet bei
    /// parallel laufenden Tests). Daher wird das Öffnen serialisiert.
    private static let openLock = Mutex(())

    /// Öffnet den Store unter `url` oder – mit `nil` – nur im Speicher.
    public static func open(at url: URL?) throws -> InventoryStore {
        let configuration = if let url {
            ModelConfiguration(schema: schema, url: url)
        } else {
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        }
        let container = try openLock.withLock { _ in
            try ModelContainer(for: schema, configurations: configuration)
        }
        return InventoryStore(modelContainer: container)
    }

    /// `~/Library/Application Support/<bundleIdentifier>/UpdatyMe.store`. Ohne Sandbox wäre der
    /// SwiftData-Standardpfad (`default.store`) mit anderen Apps geteilt, daher ein eigener Ordner.
    public static func defaultURL(bundleIdentifier: String) throws -> URL {
        let directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("UpdatyMe.store")
    }

    // MARK: - Inventar

    public func items(ecosystem: EcosystemID? = nil) throws -> [InstalledItem] {
        let descriptor: FetchDescriptor<StoredItem>
        if let ecosystem {
            let raw = ecosystem.rawValue
            descriptor = FetchDescriptor(predicate: #Predicate { $0.ecosystem == raw }, sortBy: [SortDescriptor(\.name)])
        } else {
            descriptor = FetchDescriptor(sortBy: [SortDescriptor(\.name)])
        }
        return try modelContext.fetch(descriptor).map(\.value)
    }

    public func item(id: InstalledItem.ID) throws -> InstalledItem? {
        try storedItem(id: id)?.value
    }

    /// Legt Einträge an oder aktualisiert sie (Schlüssel: `id`).
    public func save(_ items: [InstalledItem], seenAt: Date = Date()) throws {
        for item in items {
            if let stored = try storedItem(id: item.id) {
                stored.update(from: item, seenAt: seenAt)
            } else {
                modelContext.insert(StoredItem(item, seenAt: seenAt))
            }
        }
        try modelContext.save()
    }

    /// Übernimmt das Scan-Ergebnis eines Ökosystems als maßgeblich: Einträge, die nicht mehr
    /// gefunden wurden, werden samt neuester Version entfernt. Die Update-Historie bleibt erhalten.
    public func replaceItems(of ecosystem: EcosystemID, with items: [InstalledItem], seenAt: Date = Date()) throws {
        let keep = Set(items.map(\.id))
        let raw = ecosystem.rawValue
        let existing = try modelContext.fetch(FetchDescriptor<StoredItem>(predicate: #Predicate { $0.ecosystem == raw }))
        for stored in existing where !keep.contains(stored.itemID) {
            try deleteRemoteVersion(itemID: stored.itemID)
            modelContext.delete(stored)
        }
        try save(items, seenAt: seenAt)
    }

    // MARK: - Neueste Versionen

    public func saveRemoteVersion(_ remote: RemoteVersion) throws {
        if let stored = try storedRemoteVersion(itemID: remote.itemID) {
            stored.update(from: remote)
        } else {
            modelContext.insert(StoredRemoteVersion(remote))
        }
        try modelContext.save()
    }

    public func remoteVersion(for itemID: InstalledItem.ID) throws -> RemoteVersion? {
        try storedRemoteVersion(itemID: itemID)?.value
    }

    public func remoteVersions() throws -> [RemoteVersion] {
        try modelContext.fetch(FetchDescriptor<StoredRemoteVersion>()).map(\.value)
    }

    // MARK: - Update-Historie

    /// Legt einen Lauf an oder aktualisiert ihn (z. B. von `running` auf `succeeded`).
    public func record(_ run: UpdateRun) throws {
        let id = run.id
        let existing = try modelContext.fetch(FetchDescriptor<StoredUpdateRun>(predicate: #Predicate { $0.runID == id }))
        if let stored = existing.first {
            stored.update(from: run)
        } else {
            modelContext.insert(StoredUpdateRun(run))
        }
        try modelContext.save()
    }

    /// Neueste zuerst.
    public func updateRuns(itemID: InstalledItem.ID? = nil, limit: Int? = nil) throws -> [UpdateRun] {
        var descriptor: FetchDescriptor<StoredUpdateRun>
        if let itemID {
            descriptor = FetchDescriptor(predicate: #Predicate { $0.itemID == itemID })
        } else {
            descriptor = FetchDescriptor()
        }
        descriptor.sortBy = [SortDescriptor(\.startedAt, order: .reverse)]
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map(\.value)
    }

    // MARK: - Favoriten

    public func favorites() throws -> Set<InstalledItem.ID> {
        Set(try modelContext.fetch(FetchDescriptor<StoredFavorite>()).map(\.itemID))
    }

    public func setFavorite(_ isFavorite: Bool, for itemID: InstalledItem.ID, at date: Date = Date()) throws {
        let existing = try modelContext.fetch(FetchDescriptor<StoredFavorite>(predicate: #Predicate { $0.itemID == itemID }))
        if isFavorite, existing.isEmpty {
            modelContext.insert(StoredFavorite(itemID: itemID, addedAt: date))
        } else if !isFavorite {
            existing.forEach(modelContext.delete)
        }
        try modelContext.save()
    }

    // MARK: - Fixierte Einträge (App-interne Pins)

    public func pins() throws -> Set<InstalledItem.ID> {
        Set(try modelContext.fetch(FetchDescriptor<StoredPin>()).map(\.itemID))
    }

    public func setPinned(_ isPinned: Bool, for itemID: InstalledItem.ID, at date: Date = Date()) throws {
        let existing = try modelContext.fetch(FetchDescriptor<StoredPin>(predicate: #Predicate { $0.itemID == itemID }))
        if isPinned, existing.isEmpty {
            modelContext.insert(StoredPin(itemID: itemID, pinnedAt: date))
        } else if !isPinned {
            existing.forEach(modelContext.delete)
        }
        try modelContext.save()
    }

    // MARK: - Hilfsfunktionen

    private func storedItem(id: String) throws -> StoredItem? {
        var descriptor = FetchDescriptor<StoredItem>(predicate: #Predicate { $0.itemID == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func storedRemoteVersion(itemID: String) throws -> StoredRemoteVersion? {
        var descriptor = FetchDescriptor<StoredRemoteVersion>(predicate: #Predicate { $0.itemID == itemID })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func deleteRemoteVersion(itemID: String) throws {
        if let stored = try storedRemoteVersion(itemID: itemID) {
            modelContext.delete(stored)
        }
    }
}
