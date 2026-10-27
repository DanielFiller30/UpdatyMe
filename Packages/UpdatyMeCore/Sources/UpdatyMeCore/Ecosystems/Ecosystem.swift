import Foundation

/// Erfasst die lokal installierten Einträge eines Ökosystems.
public protocol InventoryProvider: Sendable {
    func scan() async throws -> [InstalledItem]
}

/// Ermittelt die neueste Version eines Eintrags; `nil`, wenn die Quelle keine kennt.
public protocol LatestVersionProvider: Sendable {
    func latest(for item: InstalledItem) async throws -> RemoteVersion?

    /// Mehrere Einträge auf einmal. Quellen mit Sammelabfrage (`brew outdated`, `softwareupdate`)
    /// überschreiben das; Standard: einzeln mit begrenzter Parallelität. Ein Fehler betrifft nur den Eintrag.
    func latest(for items: [InstalledItem]) async -> [InstalledItem.ID: Result<RemoteVersion?, any Error>]
}

extension LatestVersionProvider {
    public func latest(for items: [InstalledItem]) async -> [InstalledItem.ID: Result<RemoteVersion?, any Error>] {
        await withTaskGroup(of: (InstalledItem.ID, Result<RemoteVersion?, any Error>).self) { group in
            var results: [InstalledItem.ID: Result<RemoteVersion?, any Error>] = [:]
            var pending = items[...]
            let maxConcurrent = 4
            func addNext() {
                guard let item = pending.popFirst() else { return }
                group.addTask {
                    do {
                        return (item.id, .success(try await latest(for: item)))
                    } catch {
                        return (item.id, .failure(error))
                    }
                }
            }
            for _ in 0..<maxConcurrent { addNext() }
            for await (id, result) in group {
                results[id] = result
                addNext()
            }
            return results
        }
    }
}

/// Führt ein Update aus und meldet Log, Fortschritt und Ergebnis.
public protocol UpdateExecutor: Sendable {
    func update(_ item: InstalledItem) -> AsyncThrowingStream<UpdateEvent, any Error>
}

/// Bündelt die drei Rollen für einen Tool-Typ (z. B. Brew, npm, macOS, App-Bundles).
/// Neue Tools werden als weiteres `Ecosystem` ergänzt, der Kern bleibt unberührt.
public protocol Ecosystem: InventoryProvider, LatestVersionProvider, UpdateExecutor {
    var id: EcosystemID { get }
    var displayName: String { get }
}
