import Foundation

/// Führt Updates aus: pro Spur streng nacheinander (z. B. Brew-Lock), verschiedene Spuren parallel.
/// Die Spur ist standardmäßig das Ökosystem; Aufgaben, die dasselbe Werkzeug nutzen (z. B. „In Homebrew
/// übernehmen“ für ein App-Bundle), laufen über `lane` in derselben Spur. Fortschritt über `events`.
///
/// Wartende Updates lassen sich abbrechen, laufende nicht (ein halbes `brew upgrade` kann Brews
/// Zustand beschädigen).
public actor UpdateQueue {
    public enum Event: Sendable {
        case queued(InstalledItem.ID)
        case started(InstalledItem.ID)
        case output(InstalledItem.ID, line: String, isError: Bool)
        case succeeded(InstalledItem.ID, newVersion: String?, restartRequired: Bool)
        case failed(InstalledItem.ID, any Error)
        case cancelled(InstalledItem.ID)
    }

    public nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    private var executors: [EcosystemID: any UpdateExecutor]
    private let lane: @Sendable (InstalledItem) -> EcosystemID
    private var pending: [EcosystemID: [InstalledItem]] = [:]
    private var running: [EcosystemID: InstalledItem.ID] = [:]
    private var workers: [EcosystemID: Task<Void, Never>] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        executors: [EcosystemID: any UpdateExecutor] = [:],
        lane: @escaping @Sendable (InstalledItem) -> EcosystemID = UpdateQueue.standardLane
    ) {
        self.executors = executors
        self.lane = lane
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// Ausführer setzen oder ersetzen (z. B. sobald die Umgebung aufgelöst ist).
    public func setExecutor(_ executor: any UpdateExecutor, for ecosystem: EcosystemID) {
        executors[ecosystem] = executor
    }

    /// Reiht Einträge ein. Bereits wartende oder laufende Einträge werden ignoriert.
    public func enqueue(_ items: [InstalledItem]) {
        for item in items where !contains(item.id) {
            let lane = lane(item)
            guard executors[lane] != nil else {
                continuation.yield(.failed(item.id, UpdateError.unsupported(item.name)))
                continue
            }
            pending[lane, default: []].append(item)
            continuation.yield(.queued(item.id))
            startWorkerIfNeeded(for: lane)
        }
    }

    /// Entfernt einen wartenden Eintrag. `false`, wenn er schon läuft oder unbekannt ist.
    @discardableResult
    public func cancelQueued(_ id: InstalledItem.ID) -> Bool {
        for (ecosystem, items) in pending {
            if let index = items.firstIndex(where: { $0.id == id }) {
                pending[ecosystem]?.remove(at: index)
                continuation.yield(.cancelled(id))
                return true
            }
        }
        return false
    }

    public var isIdle: Bool { workers.isEmpty }

    /// Ökosystem als Spur; „In Homebrew übernehmen“ läuft in der Brew-Spur.
    public static let standardLane: @Sendable (InstalledItem) -> EcosystemID = { item in
        item.metadata[InstalledItem.MetadataKey.adoptCask] != nil ? .brew : item.ecosystem
    }

    public func contains(_ id: InstalledItem.ID) -> Bool {
        running.values.contains(id) || pending.values.contains { $0.contains { $0.id == id } }
    }

    /// Wartet, bis keine Updates mehr laufen oder warten.
    public func waitUntilIdle() async {
        guard !workers.isEmpty else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    // MARK: - Abarbeitung

    private func startWorkerIfNeeded(for ecosystem: EcosystemID) {
        guard workers[ecosystem] == nil else { return }
        workers[ecosystem] = Task { await self.work(on: ecosystem) }
    }

    private func work(on ecosystem: EcosystemID) async {
        while let item = nextItem(for: ecosystem) {
            guard let executor = executors[ecosystem] else { break }
            running[ecosystem] = item.id
            continuation.yield(.started(item.id))
            do {
                var completion: (String?, Bool)?
                for try await event in executor.update(item) {
                    switch event {
                    case .output(let line, let isError):
                        continuation.yield(.output(item.id, line: line, isError: isError))
                    case .progress:
                        break
                    case .completed(let newVersion, let restartRequired):
                        completion = (newVersion, restartRequired)
                    }
                }
                guard let (newVersion, restartRequired) = completion else { throw UpdateError.incomplete }
                continuation.yield(.succeeded(item.id, newVersion: newVersion, restartRequired: restartRequired))
            } catch {
                continuation.yield(.failed(item.id, error))
            }
            running[ecosystem] = nil
        }
        workers[ecosystem] = nil
        if workers.isEmpty {
            idleWaiters.forEach { $0.resume() }
            idleWaiters.removeAll()
        }
    }

    private func nextItem(for ecosystem: EcosystemID) -> InstalledItem? {
        guard var items = pending[ecosystem], !items.isEmpty else { return nil }
        let item = items.removeFirst()
        pending[ecosystem] = items
        return item
    }
}
