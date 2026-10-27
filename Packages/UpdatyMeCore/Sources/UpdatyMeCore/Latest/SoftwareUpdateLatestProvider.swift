import Foundation

/// Neueste macOS-Version laut `softwareupdate --list`. Betas werden ignoriert.
/// Meldet `softwareupdate` kein macOS-Update, gilt das installierte macOS als aktuell.
public struct SoftwareUpdateLatestProvider: LatestVersionProvider {
    public static let source = "softwareupdate"
    static let path = "/usr/sbin/softwareupdate"

    struct Entry: Equatable {
        var label: String
        var title: String
        var version: String
        var recommended: Bool
    }

    private let runner: any CommandRunning

    /// - Parameter runner: Sollte ein `CachingCommandRunner` sein (Abfrage geht ans Netz und dauert).
    public init(runner: any CommandRunning) {
        self.runner = runner
    }

    public func latest(for item: InstalledItem) async throws -> RemoteVersion? {
        guard item.kind == .os else { return nil }
        let result = try await runner.runChecked(Command(Self.path, ["--list"], timeout: .seconds(300)))
        let macOSUpdates = Self.parse(result.stdout).filter { entry in
            entry.title.hasPrefix("macOS") && !entry.title.localizedCaseInsensitiveContains("beta")
        }
        let newest = macOSUpdates.max { lhs, rhs in
            VersionComparator.compare(lhs.version, rhs.version) == .orderedAscending
        }
        guard let newest else {
            return RemoteVersion(itemID: item.id, version: item.installedVersion, source: Self.source, assessment: .upToDate)
        }
        return RemoteVersion(itemID: item.id, version: newest.version, source: Self.source)
    }

    /// Einträge der Form
    /// ```
    /// * Label: macOS Tahoe 26.8-25H12
    /// 	Title: macOS Tahoe 26.8, Version: 26.8, Size: 7012345KiB, Recommended: YES, Action: restart,
    /// ```
    static func parse(_ output: String) -> [Entry] {
        var entries: [Entry] = []
        var label: String?
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("* Label:") {
                label = line.dropFirst("* Label:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Title:"), let currentLabel = label {
                var fields: [String: String] = [:]
                for part in line.split(separator: ",") {
                    guard let colon = part.firstIndex(of: ":") else { continue }
                    fields[part[..<colon].trimmingCharacters(in: .whitespaces)] =
                        part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                if let title = fields["Title"], let version = fields["Version"] {
                    entries.append(Entry(label: currentLabel, title: title, version: version,
                                         recommended: fields["Recommended"] == "YES"))
                }
                label = nil
            }
        }
        return entries
    }
}
