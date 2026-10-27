import Foundation

/// Python-Interpreter (PATH, pyenv, asdf, uv-verwaltete Pythons, Python der Xcode-/Command-Line-Tools)
/// sowie Tools aus `pipx` und `uv tool`.
///
/// - `/usr/bin/python3` ist nur ein Shim; ohne Developer-Tools würde ein Aufruf einen Installationsdialog
///   öffnen. Stattdessen wird das Python des aktiven Developer-Verzeichnisses (`xcode-select -p`) gelesen.
/// - pip-Pakete einzelner Interpreter werden nicht erfasst (zu viele, gehören zum jeweiligen Projekt).
public struct PythonEcosystem: InventoryProvider {
    public static let id: EcosystemID = .python
    static let xcodeSelect = "/usr/bin/xcode-select"
    static let systemShim = "/usr/bin/python3"

    private let environment: ResolvedEnvironment
    private let runner: any CommandRunning
    private let homeDirectory: URL

    public init(environment: ResolvedEnvironment, runner: any CommandRunning,
                homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.environment = environment
        self.runner = runner
        self.homeDirectory = homeDirectory
    }

    public func scan() async throws -> [InstalledItem] {
        var items: [InstalledItem] = []
        var seen = Set<String>()
        for candidate in await interpreterCandidates() {
            let real = DevTools.realPath(candidate.path)
            guard seen.insert(real).inserted, !DevTools.isBrewFormulaManaged(candidate.path),
                  let output = await DevTools.versionOutput(runner, executable: candidate.path, arguments: ["--version"], environment: environment),
                  let version = DevTools.firstMatch(#"Python (\d+\.\d+\.\d+\S*)"#, in: output) else { continue }
            items.append(DevTools.runtime(
                Self.id, identifier: real, name: "Python", version: version,
                path: (candidate.path as NSString).deletingLastPathComponent, source: candidate.source,
                metadata: [InstalledItem.MetadataKey.manager: candidate.source.rawValue]
            ))
        }
        items += await pipxTools() + uvTools()
        return items
    }

    // MARK: - Interpreter

    struct Candidate: Equatable {
        var path: String
        var source: ItemSource
    }

    func interpreterCandidates() async -> [Candidate] {
        var candidates: [Candidate] = []
        let home = homeDirectory.path
        let pyenvRoot = environment.versionManagers.first { $0.kind == .pyenv }?.root.path
        let asdfRoot = environment.versionManagers.first { $0.kind == .asdf }?.root.path
        let uvRoot = "\(home)/.local/share/uv/python"

        // Shims der Manager liefern nur die gerade aktive Version; die Versionsverzeichnisse alle.
        if let pyenvRoot {
            candidates += DevTools.subdirectories(of: "\(pyenvRoot)/versions").map { Candidate(path: "\(pyenvRoot)/versions/\($0)/bin/python3", source: .pyenv) }
        }
        if let asdfRoot {
            candidates += DevTools.subdirectories(of: "\(asdfRoot)/installs/python").map { Candidate(path: "\(asdfRoot)/installs/python/\($0)/bin/python3", source: .asdf) }
        }
        candidates += DevTools.subdirectories(of: uvRoot).map { Candidate(path: "\(uvRoot)/\($0)/bin/python3", source: .uv) }

        let skipPrefixes = [pyenvRoot, asdfRoot].compactMap { $0 }
        for directory in environment.searchPath {
            let path = "\(directory)/python3"
            guard path != Self.systemShim, DevTools.isExecutable(path),
                  !skipPrefixes.contains(where: { directory.hasPrefix($0 + "/") }) else { continue }
            candidates.append(Candidate(path: path, source: Self.isConda(directory) ? .conda : .manual))
        }

        if let developer = await developerDirectory() {
            candidates.append(Candidate(path: "\(developer)/usr/bin/python3", source: .system))
        }
        return candidates.filter { DevTools.isExecutable($0.path) }
    }

    /// conda-Umgebungen erkennt man am `conda`-Programm bzw. `conda-meta` neben dem Interpreter.
    static func isConda(_ binDirectory: String) -> Bool {
        let prefix = (binDirectory as NSString).deletingLastPathComponent
        return DevTools.isDirectory("\(prefix)/conda-meta")
    }

    private func developerDirectory() async -> String? {
        let command = Command(Self.xcodeSelect, ["-p"], timeout: .seconds(10))
        guard let result = try? await runner.run(command), result.succeeded else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    // MARK: - pipx / uv tool

    private func pipxTools() async -> [InstalledItem] {
        guard let pipx = environment.executable(named: "pipx"),
              let result = try? await runner.run(Command(executable: pipx, arguments: ["list", "--json"],
                                                          environment: environment.processEnvironment, timeout: .seconds(60))),
              result.succeeded else { return [] }
        return Self.parsePipx(Data(result.stdout.utf8)).map { tool in
            DevTools.runtime(Self.id, identifier: "pipx/\(tool.name)", name: tool.name, version: tool.version, path: nil,
                             source: .pipx, kind: .package, metadata: [InstalledItem.MetadataKey.packageName: tool.name])
        }
    }

    private func uvTools() async -> [InstalledItem] {
        guard let uv = environment.executable(named: "uv"),
              let result = try? await runner.run(Command(executable: uv, arguments: ["tool", "list"],
                                                          environment: environment.processEnvironment, timeout: .seconds(60))),
              result.succeeded else { return [] }
        return Self.parseUvToolList(result.stdout).map { tool in
            DevTools.runtime(Self.id, identifier: "uv/\(tool.name)", name: tool.name, version: tool.version, path: nil,
                             source: .uv, kind: .package, metadata: [InstalledItem.MetadataKey.packageName: tool.name])
        }
    }

    static func parsePipx(_ data: Data) -> [(name: String, version: String)] {
        struct Output: Decodable {
            struct Venv: Decodable {
                struct Metadata: Decodable {
                    struct Package: Decodable {
                        var package: String
                        var packageVersion: String
                        enum CodingKeys: String, CodingKey { case package, packageVersion = "package_version" }
                    }
                    var mainPackage: Package
                    enum CodingKeys: String, CodingKey { case mainPackage = "main_package" }
                }
                var metadata: Metadata
            }
            var venvs: [String: Venv]
        }
        guard let output = try? JSONDecoder().decode(Output.self, from: data) else { return [] }
        return output.venvs.values.map { ($0.metadata.mainPackage.package, $0.metadata.mainPackage.packageVersion) }
            .sorted { $0.0 < $1.0 }
    }

    /// Zeilen `name vX.Y.Z`, darunter `- executable`. „No tools installed“ → leer.
    static func parseUvToolList(_ output: String) -> [(name: String, version: String)] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard !line.hasPrefix("-"), !line.hasPrefix(" ") else { return nil }
            let parts = line.split(separator: " ")
            guard parts.count >= 2, parts[1].hasPrefix("v") else { return nil }
            return (String(parts[0]), String(parts[1].dropFirst()))
        }
    }
}
