import Foundation

/// Node.js-Installationen: nvm, fnm, volta, asdf (aus deren Verzeichnissen, ohne Prozessstart) und ein
/// sonstiges `node` im PATH, das nicht von Brew oder einem Manager stammt.
public struct NodeEcosystem: InventoryProvider {
    public static let id: EcosystemID = .node

    private let environment: ResolvedEnvironment
    private let runner: any CommandRunning

    public init(environment: ResolvedEnvironment, runner: any CommandRunning) {
        self.environment = environment
        self.runner = runner
    }

    public func scan() async throws -> [InstalledItem] {
        var items: [InstalledItem] = []
        var managedRoots: [String] = []
        for manager in environment.versionManagers {
            let root = manager.root.path
            let defaultBin = manager.binDirectories.first.map { DevTools.realPath($0.path) }
            let installs: [(version: String, bin: String)]
            switch manager.kind {
            case .nvm:
                installs = DevTools.subdirectories(of: "\(root)/versions/node").map { ($0, "\(root)/versions/node/\($0)/bin") }
            case .fnm:
                installs = DevTools.subdirectories(of: "\(root)/node-versions").map { ($0, "\(root)/node-versions/\($0)/installation/bin") }
            case .volta:
                installs = DevTools.subdirectories(of: "\(root)/tools/image/node").map { ($0, "\(root)/tools/image/node/\($0)/bin") }
            case .asdf:
                installs = DevTools.subdirectories(of: "\(root)/installs/nodejs").map { ($0, "\(root)/installs/nodejs/\($0)/bin") }
            case .pyenv, .rbenv, .sdkman:
                continue
            }
            managedRoots.append(DevTools.realPath(root))
            for install in installs where DevTools.isExecutable("\(install.bin)/node") {
                let version = Self.normalize(install.version)
                let isDefault = defaultBin == DevTools.realPath(install.bin)
                items.append(DevTools.runtime(
                    Self.id, identifier: "\(manager.kind.rawValue)/\(version)", name: "Node.js", version: version,
                    path: install.bin, source: ItemSource(rawValue: manager.kind.rawValue),
                    metadata: [InstalledItem.MetadataKey.manager: manager.kind.rawValue,
                               InstalledItem.MetadataKey.isDefault: String(isDefault)]
                ))
            }
        }

        // Sonstiges node (z. B. offizieller Installer unter /usr/local), nicht Brew, kein Manager.
        if let node = environment.executable(named: "node")?.path {
            let real = DevTools.realPath(node)
            let isManaged = managedRoots.contains { real.hasPrefix($0 + "/") } || DevTools.isBrewFormulaManaged(node)
            if !isManaged, let output = await DevTools.versionOutput(runner, executable: node, arguments: ["--version"], environment: environment),
               let version = DevTools.firstMatch(#"v?(\d+\.\d+\.\d+)"#, in: output) {
                items.append(DevTools.runtime(Self.id, identifier: "path\(real)", name: "Node.js", version: version,
                                              path: (real as NSString).deletingLastPathComponent, source: .manual))
            }
        }
        return items
    }

    static func normalize(_ version: String) -> String {
        version.hasPrefix("v") ? String(version.dropFirst()) : version
    }
}

/// Global installierte npm- bzw. pnpm-Pakete der aktiven Node-Installation.
/// Lokal verlinkte Pakete (`file:`) werden übersprungen.
public struct NodePackagesEcosystem: InventoryProvider {
    public enum Manager: String, Sendable {
        case npm, pnpm
    }

    private let manager: Manager
    private let environment: ResolvedEnvironment
    private let runner: any CommandRunning

    public init(_ manager: Manager, environment: ResolvedEnvironment, runner: any CommandRunning) {
        self.manager = manager
        self.environment = environment
        self.runner = runner
    }

    public var id: EcosystemID { manager == .npm ? .npm : .pnpm }

    public func scan() async throws -> [InstalledItem] {
        guard let executable = environment.executable(named: manager.rawValue) else { return [] }
        let arguments = manager == .npm ? ["ls", "-g", "--json", "--depth=0"] : ["ls", "-g", "--json"]
        let command = Command(executable: executable, arguments: arguments,
                              environment: environment.processEnvironment, timeout: .seconds(60))
        // npm meldet bei Auffälligkeiten (z. B. „extraneous“) Exit-Code 1, liefert aber gültiges JSON.
        let result = try await runner.run(command)
        let packages: [(name: String, version: String)]
        do {
            packages = try manager == .npm ? Self.parseNpm(Data(result.stdout.utf8)) : Self.parsePnpm(Data(result.stdout.utf8))
        } catch {
            throw InventoryError.commandFailed(command: command.description, exitCode: result.exitCode, stderr: result.stderr)
        }
        let source: ItemSource = manager == .npm ? .npm : .pnpm
        return packages.map { package in
            DevTools.runtime(id, identifier: package.name, name: package.name, version: package.version, path: nil,
                             source: source, kind: .package,
                             metadata: [InstalledItem.MetadataKey.packageName: package.name])
        }
    }

    private struct Dependency: Decodable {
        var version: String?
        var resolved: String?
    }

    static func parseNpm(_ data: Data) throws -> [(name: String, version: String)] {
        struct Output: Decodable { var dependencies: [String: Dependency]? }
        let output = try JSONDecoder().decode(Output.self, from: data)
        return packages(output.dependencies ?? [:])
    }

    static func parsePnpm(_ data: Data) throws -> [(name: String, version: String)] {
        struct Entry: Decodable { var dependencies: [String: Dependency]? }
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        return packages(entries.reduce(into: [:]) { $0.merge($1.dependencies ?? [:]) { first, _ in first } })
    }

    private static func packages(_ dependencies: [String: Dependency]) -> [(name: String, version: String)] {
        dependencies
            .filter { $0.value.version != nil && !($0.value.resolved ?? "").hasPrefix("file:") }
            .map { ($0.key, $0.value.version ?? "") }
            .sorted { $0.name < $1.name }
    }
}
