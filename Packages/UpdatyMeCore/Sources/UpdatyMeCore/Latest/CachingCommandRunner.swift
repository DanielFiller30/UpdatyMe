import CryptoKit
import Foundation

/// Cache mit TTL für CLI-Abfragen, die das Netz nutzen (`softwareupdate --list`, `brew outdated`).
/// Innerhalb der TTL wird das Programm nicht erneut gestartet. Gespeichert wird nur, was `shouldCache`
/// erlaubt (Standard: Exit-Code 0). Schlüssel sind Programm und Argumente, nicht die Umgebung.
public actor CachingCommandRunner: CommandRunning {
    private struct Entry: Codable {
        var command: String
        var storedAt: Date
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    private let base: any CommandRunning
    private let directory: URL
    private let ttl: Duration
    private let now: @Sendable () -> Date
    private let shouldCache: @Sendable (CommandResult) -> Bool

    public init(
        base: any CommandRunning,
        directory: URL,
        ttl: Duration = CachingHTTPClient.defaultTTL,
        now: @escaping @Sendable () -> Date = { Date() },
        shouldCache: @escaping @Sendable (CommandResult) -> Bool = { $0.succeeded }
    ) {
        self.base = base
        self.directory = directory
        self.ttl = ttl
        self.now = now
        self.shouldCache = shouldCache
    }

    /// `~/Library/Caches/<bundleIdentifier>/commands`
    public static func defaultDirectory(bundleIdentifier: String) throws -> URL {
        try FileManager.default
            .url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("commands", isDirectory: true)
    }

    public func stream(_ command: Command) async -> AsyncThrowingStream<CommandEvent, any Error> {
        let key = command.description
        if let entry = entry(for: key), isFresh(entry) {
            let result = CommandResult(exitCode: entry.exitCode, stdout: entry.stdout, stderr: entry.stderr)
            return AsyncThrowingStream { continuation in
                for line in Self.lines(result.stdout) { continuation.yield(.stdoutLine(line)) }
                for line in Self.lines(result.stderr) { continuation.yield(.stderrLine(line)) }
                continuation.yield(.completed(result))
                continuation.finish()
            }
        }

        let upstream = await base.stream(command)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in upstream {
                        if case .completed(let result) = event, self.shouldCache(result) {
                            self.store(Entry(command: key, storedAt: self.now(), exitCode: result.exitCode,
                                             stdout: result.stdout, stderr: result.stderr))
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Verwirft alle Einträge (z. B. für „Ohne Cache prüfen“ oder nach einem Update).
    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Verwirft Einträge, deren Befehl (Programm + Argumente) `predicate` erfüllt – z. B. `brew outdated`
    /// nach einem Update, ohne die teure `softwareupdate`-Abfrage zu verlieren.
    public func remove(where predicate: @Sendable (String) -> Bool) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  predicate(entry.command) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Speicher

    private func isFresh(_ entry: Entry) -> Bool {
        let age = now().timeIntervalSince(entry.storedAt)
        let (seconds, attoseconds) = ttl.components
        return age >= 0 && age < Double(seconds) + Double(attoseconds) / 1e18
    }

    private func entry(for key: String) -> Entry? {
        guard let data = try? Data(contentsOf: fileURL(for: key)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.command == key else {
            return nil
        }
        return entry
    }

    private nonisolated func store(_ entry: Entry) {
        // Ein nicht schreibbarer Cache darf die Abfrage nicht scheitern lassen.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(entry).write(to: fileURL(for: entry.command), options: .atomic)
    }

    private nonisolated func fileURL(for key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(hash).json")
    }

    private static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("\n") { lines.removeLast() }
        return lines
    }
}
