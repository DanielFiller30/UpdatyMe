import Foundation

/// Rust-Toolchains aus rustup (`~/.rustup/toolchains/*`, Version per `rustc --version`) und per
/// `cargo install` installierte Programme. Lokal (aus Pfad) installierte Crates werden übersprungen.
public struct RustEcosystem: InventoryProvider {
    public static let id: EcosystemID = .rust

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
        let rustupHome = environment.variables["RUSTUP_HOME"] ?? "\(homeDirectory.path)/.rustup"
        let cargoHome = environment.variables["CARGO_HOME"] ?? "\(homeDirectory.path)/.cargo"
        let defaultToolchain = Self.defaultToolchain(settings: try? String(contentsOfFile: "\(rustupHome)/settings.toml", encoding: .utf8))

        var items: [InstalledItem] = []
        for toolchain in DevTools.subdirectories(of: "\(rustupHome)/toolchains") {
            let rustc = "\(rustupHome)/toolchains/\(toolchain)/bin/rustc"
            guard DevTools.isExecutable(rustc),
                  let output = await DevTools.versionOutput(runner, executable: rustc, arguments: ["--version"], environment: environment),
                  let version = DevTools.firstMatch(#"rustc (\d+\.\d+\.\d+(?:-[A-Za-z]+)?)"#, in: output) else { continue }
            items.append(DevTools.runtime(
                Self.id, identifier: "toolchain/\(toolchain)", name: "Rust (\(Self.channel(of: toolchain)))", version: version,
                path: "\(rustupHome)/toolchains/\(toolchain)", source: .rustup,
                metadata: ["toolchain": toolchain, InstalledItem.MetadataKey.isDefault: String(toolchain == defaultToolchain)]
            ))
        }

        let cargo = DevTools.isExecutable("\(cargoHome)/bin/cargo") ? "\(cargoHome)/bin/cargo" : environment.executable(named: "cargo")?.path
        if let cargo, let result = try? await runner.run(Command(cargo, ["install", "--list"], environment: environment.processEnvironment,
                                                                  timeout: .seconds(30))), result.succeeded {
            items += Self.parseCargoInstallList(result.stdout).map { crate in
                DevTools.runtime(Self.id, identifier: "cargo/\(crate.name)", name: crate.name, version: crate.version, path: nil,
                                 source: .cargo, kind: .package, metadata: [InstalledItem.MetadataKey.packageName: crate.name])
            }
        }
        return items
    }

    /// `stable-aarch64-apple-darwin` → `stable`, `1.80.0-aarch64-apple-darwin` → `1.80.0`.
    static func channel(of toolchain: String) -> String {
        for suffix in ["-aarch64-apple-darwin", "-x86_64-apple-darwin"] where toolchain.hasSuffix(suffix) {
            return String(toolchain.dropLast(suffix.count))
        }
        return toolchain
    }

    static func defaultToolchain(settings: String?) -> String? {
        settings.flatMap { DevTools.firstMatch(#"default_toolchain\s*=\s*"([^"]+)""#, in: $0) }
    }

    /// Zeilen `name vX.Y.Z:` bzw. `name vX.Y.Z (pfad):`, eingerückte Zeilen sind Programme.
    static func parseCargoInstallList(_ output: String) -> [(name: String, version: String)] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard !line.hasPrefix(" "), line.hasSuffix(":"), !line.contains("(") else { return nil }
            let parts = line.dropLast().split(separator: " ")
            guard parts.count == 2, parts[1].hasPrefix("v") else { return nil }
            return (String(parts[0]), String(parts[1].dropFirst()))
        }
    }
}
