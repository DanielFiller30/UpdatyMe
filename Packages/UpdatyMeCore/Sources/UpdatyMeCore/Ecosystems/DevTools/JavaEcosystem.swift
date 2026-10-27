import Foundation

/// JDKs aus `/usr/libexec/java_home -V` und sdkman. Details aus der `release`-Datei der JDK
/// (ohne Java zu starten). Per Brew-Cask installierte JDKs (z. B. `zulu@25`) erscheinen nur als Cask
/// (Deduplizierung über `brewCaskCandidates` im `InventoryScanner`).
public struct JavaEcosystem: InventoryProvider {
    public static let id: EcosystemID = .java
    static let javaHome = "/usr/libexec/java_home"

    /// foojay-Distribution und Brew-Cask-Präfixe je `IMPLEMENTOR` der `release`-Datei.
    static let distributions: [(implementor: String, foojay: String, display: String, casks: [String])] = [
        ("Azul Systems, Inc.", "zulu", "Azul Zulu", ["zulu"]),
        ("Eclipse Adoptium", "temurin", "Eclipse Temurin", ["temurin"]),
        ("Amazon.com Inc.", "corretto", "Amazon Corretto", ["corretto"]),
        ("Oracle Corporation", "oracle", "Oracle", ["oracle-jdk"]),
        ("Microsoft", "microsoft", "Microsoft", ["microsoft-openjdk"]),
        ("BellSoft", "liberica", "BellSoft Liberica", ["liberica"]),
        ("International Business Machines Corporation", "semeru", "IBM Semeru", ["semeru"]),
        ("SAP SE", "sap_machine", "SapMachine", ["sapmachine"]),
        ("GraalVM Community", "graalvm_community", "GraalVM Community", ["graalvm"]),
    ]

    private let environment: ResolvedEnvironment
    private let runner: any CommandRunning

    public init(environment: ResolvedEnvironment, runner: any CommandRunning) {
        self.environment = environment
        self.runner = runner
    }

    public func scan() async throws -> [InstalledItem] {
        var homes: [(path: String, source: ItemSource)] = []
        if DevTools.isExecutable(Self.javaHome),
           let result = try? await runner.run(Command(Self.javaHome, ["-V"], timeout: .seconds(10))), result.succeeded {
            homes += Self.parseJavaHomeList(result.stderr).map { ($0, .manual) }
        }
        if let sdkman = environment.versionManagers.first(where: { $0.kind == .sdkman })?.root.path {
            let candidates = "\(sdkman)/candidates/java"
            homes += DevTools.subdirectories(of: candidates).filter { $0 != "current" }.map { ("\(candidates)/\($0)", .sdkman) }
        }

        var seen = Set<String>()
        return homes.compactMap { home in
            let real = DevTools.realPath(home.path)
            guard seen.insert(real).inserted,
                  let release = try? String(contentsOfFile: "\(home.path)/release", encoding: .utf8) else { return nil }
            return Self.item(home: home.path, release: release, source: home.source)
        }
    }

    static func item(home: String, release: String, source: ItemSource) -> InstalledItem? {
        let values = parseRelease(release)
        guard let version = values["JAVA_VERSION"] else { return nil }
        let implementor = values["IMPLEMENTOR"] ?? ""
        let distribution = distributions.first { $0.implementor == implementor }
        var metadata: [String: String] = ["vendor": implementor]
        metadata["distribution"] = distribution?.foojay
        metadata["vendorVersion"] = values["IMPLEMENTOR_VERSION"]
        metadata[InstalledItem.MetadataKey.brewCaskCandidates] = distribution?.casks.joined(separator: ",")
        let display = distribution?.display ?? (implementor.isEmpty ? "JDK" : implementor)
        return DevTools.runtime(id, identifier: home, name: "Java (\(display))", version: version, path: home, source: source,
                                metadata: metadata)
    }

    /// stderr von `java_home -V`: je JDK eine eingerückte Zeile, die mit dem Home-Pfad endet.
    static func parseJavaHomeList(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.hasPrefix(" ") || line.hasPrefix("\t"), let range = line.range(of: " /", options: .backwards) else { return nil }
            return String(line[line.index(after: range.lowerBound)...])
        }
    }

    /// `KEY="value"`-Zeilen der `release`-Datei.
    static func parseRelease(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            values[String(line[..<equals])] = line[line.index(after: equals)...].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return values
    }
}

/// gcloud außerhalb von Homebrew (z. B. `~/google-cloud-sdk`). Per Brew-Cask installiertes gcloud
/// erscheint als Cask; dessen echte Version liest `BrewEcosystem`.
public struct GcloudEcosystem: InventoryProvider {
    public static let id: EcosystemID = .gcloud

    private let environment: ResolvedEnvironment
    private let runner: any CommandRunning
    private let brewPrefixes: [String]

    public init(environment: ResolvedEnvironment, runner: any CommandRunning, brewPrefixes: [String] = BrewEcosystem.knownPrefixes) {
        self.environment = environment
        self.runner = runner
        self.brewPrefixes = brewPrefixes
    }

    public func scan() async throws -> [InstalledItem] {
        guard let gcloud = environment.executable(named: "gcloud")?.path else { return [] }
        let real = DevTools.realPath(gcloud)
        let prefixes = brewPrefixes + [environment.variables["HOMEBREW_PREFIX"]].compactMap { $0 }
        guard !prefixes.contains(where: { real.hasPrefix($0 + "/") }),
              let output = await DevTools.versionOutput(runner, executable: gcloud, arguments: ["version"], environment: environment),
              let version = DevTools.firstMatch(#"Google Cloud SDK (\S+)"#, in: output) else { return [] }
        return [DevTools.runtime(Self.id, identifier: real, name: "Google Cloud CLI", version: version,
                                 path: (real as NSString).deletingLastPathComponent, source: .manual, kind: .cli)]
    }
}
