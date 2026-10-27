import Foundation
import Testing
@testable import UpdatyMeCore

@Suite("AppBundleEcosystem")
struct AppBundleEcosystemTests {
    /// Baut einen Programme-Ordner mit Bundles aus den (gekürzt aufgezeichneten) Info.plist-Fixtures nach.
    struct Tree: ~Copyable {
        let root: TemporaryDirectory
        var applications: URL { root.url.appendingPathComponent("Applications") }
        var system: URL { root.url.appendingPathComponent("System/Applications") }

        init() throws {
            let root = try TemporaryDirectory()
            try root.makeDirectory("Applications")
            try root.makeDirectory("System/Applications")
            self.root = root
        }

        @discardableResult
        func app(_ relativePath: String, fixture: String? = nil, plist: [String: String]? = nil, in base: URL? = nil) throws -> URL {
            let bundle = (base ?? applications).appendingPathComponent(relativePath)
            let contents = bundle.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            if let fixture {
                let source = try #require(Bundle.module.url(forResource: "Fixtures/AppBundle/\(fixture)-Info", withExtension: "plist"))
                try FileManager.default.copyItem(at: source, to: contents.appendingPathComponent("Info.plist"))
            } else if let plist {
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: contents.appendingPathComponent("Info.plist"))
            }
            return bundle
        }

        func scan(maxDepth: Int = 2) async throws -> [String: InstalledItem] {
            let ecosystem = AppBundleEcosystem(
                searchDirectories: [applications, system],
                systemDirectories: [system.path],
                maxDepth: maxDepth
            )
            let items = try await ecosystem.scan()
            return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        }
    }

    @Test func sparkleAppFromRecordedPlist() async throws {
        let tree = try Tree()
        let fork = try tree.app("Fork.app", fixture: "Fork")

        let item = try #require(try await tree.scan()["Fork"])
        #expect(item == InstalledItem(
            id: "app-bundle:\(fork.path)",
            name: "Fork",
            kind: .app,
            ecosystem: .appBundle,
            installedVersion: "2.70.2",
            installPath: fork.path,
            source: .sparkle,
            updateCapability: .manual,
            metadata: [
                "bundleIdentifier": "com.DanPristupov.Fork",
                "bundleVersion": "2.70.2",
                "sparkleFeedURL": "https://fork.dev/update/feed.xml",
            ]
        ))
    }

    @Test func classifiesOrigins() async throws {
        let tree = try Tree()
        try tree.app("Safari.app", fixture: "Safari")
        try tree.app("Spotify.app", fixture: "Spotify")
        try tree.app("Xcode.app", fixture: "Xcode")
        let mas = try tree.app("Things.app", plist: ["CFBundleIdentifier": "com.culturedcode.ThingsMac", "CFBundleShortVersionString": "3.22"])
        try FileManager.default.createDirectory(at: mas.appendingPathComponent("Contents/_MASReceipt"), withIntermediateDirectories: true)
        try Data().write(to: mas.appendingPathComponent("Contents/_MASReceipt/receipt"))
        try tree.app("Calculator.app", plist: ["CFBundleIdentifier": "com.apple.calculator", "CFBundleShortVersionString": "11.0"], in: tree.system)
        // MAS-Beleg schlägt Apple-ID: z. B. Pages aus dem App Store.
        let pages = try tree.app("Pages.app", plist: ["CFBundleIdentifier": "com.apple.iWork.Pages", "CFBundleShortVersionString": "14.4"])
        try FileManager.default.createDirectory(at: pages.appendingPathComponent("Contents/_MASReceipt"), withIntermediateDirectories: true)
        try Data().write(to: pages.appendingPathComponent("Contents/_MASReceipt/receipt"))

        let items = try await tree.scan()
        #expect(items["Safari"]?.source == .system)
        #expect(items["Safari"]?.updateCapability == .openSettings)
        #expect(items["Safari"]?.installedVersion == "27.0")
        #expect(items["Spotify"]?.source == .manual)
        #expect(items["Xcode"]?.source == .manual, "Xcode-Download wird nicht mit macOS aktualisiert")
        #expect(items["Things"]?.source == .mas)
        #expect(items["Pages"]?.source == .mas)
        #expect(items["Calculator"]?.source == .system)
    }

    @Test func wrappedIOSAppIsFromAppStore() async throws {
        let tree = try Tree()
        let bundle = tree.applications.appendingPathComponent("DemoApp.app")
        let inner = bundle.appendingPathComponent("Wrapper/DemoApp.app")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data().write(to: bundle.appendingPathComponent("Wrapper/iTunesMetadata.plist"))
        let source = try #require(Bundle.module.url(forResource: "Fixtures/AppBundle/DemoApp-wrapped-Info", withExtension: "plist"))
        try FileManager.default.copyItem(at: source, to: inner.appendingPathComponent("Info.plist"))
        try FileManager.default.createSymbolicLink(atPath: bundle.appendingPathComponent("WrappedBundle").path,
                                                   withDestinationPath: "Wrapper/DemoApp.app")

        let item = try #require(try await tree.scan()["DemoApp"])
        #expect(item.source == .mas)
        #expect(item.installedVersion == "2.0.2")
        #expect(item.metadata["iOSApp"] == "true")
        #expect(item.metadata["bundleIdentifier"] == "com.example.DemoApp")
    }

    @Test func searchesSubfoldersUpToMaxDepthButNotInsideBundles() async throws {
        let tree = try Tree()
        try tree.app("Utilities/Terminal Tool.app", plist: ["CFBundleIdentifier": "x.tool", "CFBundleShortVersionString": "1.0"])
        try tree.app("Vendor/Suite/Two.app", plist: ["CFBundleIdentifier": "x.two", "CFBundleShortVersionString": "1.0"])
        try tree.app("A/B/C/Deep.app", plist: ["CFBundleIdentifier": "x.deep", "CFBundleShortVersionString": "1.0"])
        let host = try tree.app("Host.app", plist: ["CFBundleIdentifier": "x.host", "CFBundleShortVersionString": "1.0"])
        try tree.app("Contents/Helpers/Helper.app", plist: ["CFBundleIdentifier": "x.helper"], in: host)

        let names = Set(try await tree.scan().keys)
        #expect(names == ["Terminal Tool", "Two", "Host"])
        #expect(Set(try await tree.scan(maxDepth: 3).keys).contains("Deep"))
    }

    @Test func skipsBrokenBundlesAndDeduplicatesSymlinks() async throws {
        let tree = try Tree()
        let fork = try tree.app("Fork.app", fixture: "Fork")
        try tree.app("Broken.app")
        try FileManager.default.createSymbolicLink(
            at: tree.applications.appendingPathComponent("Alias.app"), withDestinationURL: fork
        )

        let items = try await tree.scan()
        #expect(Set(items.keys) == ["Fork"] || Set(items.keys) == ["Alias"])
        #expect(items.count == 1)
    }

    @Test func findsSymlinkedAndHiddenFlaggedAppsButSkipsDotFiles() async throws {
        let tree = try Tree()
        // Nachbildung von /Applications/Safari.app → /System/Cryptexes/App/System/Applications/Safari.app
        let cryptex = try tree.app("Safari.app", fixture: "Safari", in: tree.root.url.appendingPathComponent("Cryptexes"))
        let link = tree.applications.appendingPathComponent("Safari.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cryptex)
        var values = URLResourceValues()
        values.isHidden = true
        var hiddenLink = link
        try hiddenLink.setResourceValues(values)
        try tree.app(".Hidden.app", plist: ["CFBundleIdentifier": "x.hidden", "CFBundleShortVersionString": "1.0"])

        let items = try await tree.scan()
        #expect(Set(items.keys) == ["Safari"])
        #expect(items["Safari"]?.source == .system)
        #expect(items["Safari"]?.installPath == link.path)
    }

    @Test func versionFallsBackToBundleVersionThenEmpty() async throws {
        let tree = try Tree()
        try tree.app("BuildOnly.app", plist: ["CFBundleIdentifier": "x.build", "CFBundleVersion": "1234"])
        try tree.app("NoVersion.app", plist: ["CFBundleIdentifier": "x.none", "CFBundleShortVersionString": " "])

        let items = try await tree.scan()
        #expect(items["BuildOnly"]?.installedVersion == "1234")
        #expect(items["NoVersion"]?.installedVersion == "")
        #expect(items["NoVersion"]?.status == .unknown)
    }

    @Test func missingSearchDirectoryYieldsNoItems() async throws {
        let ecosystem = AppBundleEcosystem(searchDirectories: [URL(fileURLWithPath: "/does/not/exist")])
        #expect(try await ecosystem.scan().isEmpty)
    }
}
