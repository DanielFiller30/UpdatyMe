import Foundation

/// Erfasst App-Bundles aus den Programme-Ordnern über deren `Info.plist` und erkennt die Herkunft:
/// App Store (`Contents/_MASReceipt`), Sparkle (`SUFeedURL`), System (Apple) oder manuell.
/// iPhone-/iPad-Apps auf Apple Silicon (`Wrapper/` + `WrappedBundle`) stammen immer aus dem App Store.
/// Liest nur das Dateisystem, startet keine Prozesse.
public struct AppBundleEcosystem: InventoryProvider {
    public static let id: EcosystemID = .appBundle

    public static var defaultSearchDirectories: [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/System/Applications"),
        ]
    }

    /// Apple-Apps, die nicht mit macOS aktualisiert werden (separater Download), bleiben „manuell“.
    static let appleManualBundleIdentifiers: Set<String> = ["com.apple.dt.Xcode"]

    private let searchDirectories: [URL]
    private let systemDirectories: [String]
    private let maxDepth: Int

    /// - Parameters:
    ///   - systemDirectories: Apps unterhalb dieser Pfade gelten immer als System-Apps.
    ///   - maxDepth: Wie tief in Unterordner (ohne `.app`) gesucht wird; 2 erfasst z. B.
    ///     `/Applications/Utilities/…` und `/Applications/Hersteller/Unterordner/…`.
    public init(
        searchDirectories: [URL] = AppBundleEcosystem.defaultSearchDirectories,
        systemDirectories: [String] = ["/System/Applications"],
        maxDepth: Int = 2
    ) {
        self.searchDirectories = searchDirectories
        self.systemDirectories = systemDirectories
        self.maxDepth = maxDepth
    }

    public func scan() async throws -> [InstalledItem] {
        var seen = Set<String>()
        var items: [InstalledItem] = []
        for directory in searchDirectories {
            for bundle in appBundles(in: directory, depth: 0) {
                let resolved = bundle.resolvingSymlinksInPath().path
                guard seen.insert(resolved).inserted, let item = item(for: bundle) else { continue }
                items.append(item)
            }
        }
        return items
    }

    // MARK: - Suche

    private func appBundles(in directory: URL, depth: Int) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        // Bewusst ohne `.skipsHiddenFiles`: Der Safari-Symlink in /Applications (→ Cryptex) trägt das
        // Hidden-Flag und würde sonst fehlen. Nur Punkt-Dateien werden übersprungen.
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: []
        ) else {
            return []
        }
        var bundles: [URL] = []
        for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where !url.lastPathComponent.hasPrefix(".") {
            if url.pathExtension == "app" {
                bundles.append(url)
            } else if depth < maxDepth, isPlainDirectory(url) {
                bundles += appBundles(in: url, depth: depth + 1)
            }
        }
        return bundles
    }

    /// Echter Ordner, kein Symlink (verhindert Zyklen) und kein Bundle.
    private func isPlainDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true && values?.isPackage != true
    }

    // MARK: - Auswertung

    /// `nil` für Bundles ohne lesbare `Info.plist` (kein gültiges App-Bundle).
    func item(for bundle: URL) -> InstalledItem? {
        let isWrapped = isWrappedIOSApp(bundle)
        let plistURL = bundle.appendingPathComponent(isWrapped ? "WrappedBundle/Info.plist" : "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        let bundleIdentifier = plist["CFBundleIdentifier"] as? String
        let shortVersion = (plist["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespaces)
        let bundleVersion = (plist["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespaces)
        let feedURL = (plist["SUFeedURL"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let source = isWrapped ? .mas : origin(of: bundle, bundleIdentifier: bundleIdentifier, hasFeed: feedURL != nil)

        var metadata: [String: String] = [:]
        metadata["iOSApp"] = isWrapped ? "true" : nil
        metadata[InstalledItem.MetadataKey.bundleIdentifier] = bundleIdentifier
        metadata[InstalledItem.MetadataKey.bundleVersion] = bundleVersion
        metadata[InstalledItem.MetadataKey.sparkleFeedURL] = feedURL

        return InstalledItem(
            id: InstalledItem.makeID(ecosystem: Self.id, identifier: bundle.path),
            name: bundle.deletingPathExtension().lastPathComponent,
            kind: .app,
            ecosystem: Self.id,
            installedVersion: nonEmpty(shortVersion) ?? nonEmpty(bundleVersion) ?? "",
            installPath: bundle.path,
            source: source,
            updateCapability: source == .system ? .openSettings : .manual,
            metadata: metadata
        )
    }

    /// Reihenfolge: App-Store-Beleg → Sparkle → System-Pfad/Apple-ID → manuell.
    func origin(of bundle: URL, bundleIdentifier: String?, hasFeed: Bool) -> ItemSource {
        if FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/_MASReceipt/receipt").path) {
            return .mas
        }
        if hasFeed {
            return .sparkle
        }
        if systemDirectories.contains(where: { bundle.path.hasPrefix($0 + "/") }) {
            return .system
        }
        if let bundleIdentifier, bundleIdentifier.hasPrefix("com.apple."),
           !Self.appleManualBundleIdentifiers.contains(bundleIdentifier) {
            return .system
        }
        return .manual
    }

    private func isWrappedIOSApp(_ bundle: URL) -> Bool {
        FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Wrapper/iTunesMetadata.plist").path)
            && !FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Info.plist").path)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
