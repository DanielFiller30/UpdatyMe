import Foundation

/// Gemeinsame Hilfen für Entwickler-Tools (Phase 6).
///
/// Grundsätze:
/// - Ein Eintrag je Installation.
/// - Von Brew-Formulae verwaltete Installationen (`…/Cellar/…`) werden nicht doppelt erfasst; sie sind
///   schon Brew-Einträge.
/// - Fehlt ein Tool, ist das normal: Ergebnis ist eine leere Liste, kein Fehler.
/// - Entwickler-Tools sind in Phase 6 nur erfasst, nicht aktualisierbar (`updateCapability = .manual`).
enum DevTools {
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Liegt die Datei (nach Auflösen von Symlinks) in einem Brew-Cellar?
    static func isBrewFormulaManaged(_ path: String) -> Bool {
        realPath(path).contains("/Cellar/")
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    static func subdirectories(of path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
            .filter { !$0.hasPrefix(".") && isDirectory("\(path)/\($0)") }
            .sorted()
    }

    /// Erste Capture-Gruppe (sonst ganzer Treffer) des Musters im Text.
    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        let group = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound ? 1 : 0
        return Range(match.range(at: group), in: text).map { String(text[$0]) }
    }

    /// Versionsbefehl ausführen (stdout und stderr, viele Tools schreiben die Version nach stderr).
    static func versionOutput(_ runner: any CommandRunning, executable: String, arguments: [String],
                              environment: ResolvedEnvironment) async -> String? {
        let command = Command(executable: URL(fileURLWithPath: executable), arguments: arguments,
                              environment: environment.processEnvironment, timeout: .seconds(20))
        guard let result = try? await runner.run(command), result.succeeded else { return nil }
        return result.stdout + "\n" + result.stderr
    }

    static func runtime(
        _ ecosystem: EcosystemID,
        identifier: String,
        name: String,
        version: String,
        path: String?,
        source: ItemSource,
        kind: InstalledItem.Kind = .runtime,
        metadata: [String: String] = [:]
    ) -> InstalledItem {
        InstalledItem(
            id: InstalledItem.makeID(ecosystem: ecosystem, identifier: identifier),
            name: name,
            kind: kind,
            ecosystem: ecosystem,
            installedVersion: version,
            installPath: path,
            source: source,
            updateCapability: .manual,
            metadata: metadata
        )
    }
}

extension InstalledItem.MetadataKey {
    /// Versionsmanager, über den die Runtime installiert ist (nvm, fnm, pyenv, …).
    public static let manager = "manager"
    /// `true` für die Default-/aktive Version des Managers.
    public static let isDefault = "isDefault"
    /// Paketname in der Registry (npm, PyPI, crates.io), falls abweichend vom Anzeigenamen.
    public static let packageName = "packageName"
    /// Brew-Cask-Token-Präfixe, unter denen dieselbe Installation als Cask erscheinen kann (Deduplizierung).
    public static let brewCaskCandidates = "brewCaskCandidates"
}
