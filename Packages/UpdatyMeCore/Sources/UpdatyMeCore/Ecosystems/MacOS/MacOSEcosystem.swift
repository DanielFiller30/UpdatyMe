import Foundation

/// Erfasst die installierte macOS-Version über `sw_vers` und `sysctl kern.osversion`.
/// Updates laufen ausschließlich über die Systemeinstellungen (kein Auto-Install von macOS).
public struct MacOSEcosystem: InventoryProvider {
    public static let id: EcosystemID = .macOS
    static let swVers = "/usr/bin/sw_vers"
    static let sysctl = "/usr/sbin/sysctl"

    private let runner: any CommandRunning

    public init(runner: any CommandRunning) {
        self.runner = runner
    }

    public func scan() async throws -> [InstalledItem] {
        let output = try await runner.runChecked(Command(Self.swVers, timeout: .seconds(10))).stdout
        let values = Self.parseSwVers(output)
        guard let version = values["ProductVersion"], !version.isEmpty else {
            throw InventoryError.unexpectedOutput(source: "sw_vers", detail: "ProductVersion missing")
        }

        // Build bevorzugt aus dem Kernel (Plan Abschnitt 4), sw_vers als Rückfallebene.
        let kernelBuild = try? await runner.runChecked(Command(Self.sysctl, ["-n", "kern.osversion"], timeout: .seconds(10)))
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let build = kernelBuild.flatMap { $0.isEmpty ? nil : $0 } ?? values["BuildVersion"]

        var metadata: [String: String] = [:]
        metadata[InstalledItem.MetadataKey.osBuild] = build
        // Rapid Security Responses, z. B. „(a)“.
        metadata["versionExtra"] = values["ProductVersionExtra"]

        return [InstalledItem(
            id: InstalledItem.makeID(ecosystem: Self.id, identifier: "macos"),
            name: values["ProductName"] ?? "macOS",
            kind: .os,
            ecosystem: Self.id,
            installedVersion: version,
            source: .system,
            updateCapability: .openSettings,
            metadata: metadata
        )]
    }

    /// Zeilen der Form `ProductVersion:\t\t26.7.1`.
    static func parseSwVers(_ output: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { values[key] = value }
        }
        return values
    }
}
