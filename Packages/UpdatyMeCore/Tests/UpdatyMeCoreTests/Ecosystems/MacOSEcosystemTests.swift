import Foundation
import Testing
@testable import UpdatyMeCore
import UpdatyMeCoreTestSupport

@Suite("MacOSEcosystem")
struct MacOSEcosystemTests {
    static let sysctlArguments = ["-n", "kern.osversion"]

    @Test func parsesRecordedSwVers() throws {
        let values = MacOSEcosystem.parseSwVers(try Fixture.string("MacOS/sw_vers.txt"))
        #expect(values == ["ProductName": "macOS", "ProductVersion": "26.7.1", "BuildVersion": "25G241"])
    }

    @Test func scanBuildsSingleOSItem() async throws {
        let mock = MockCommandRunner()
        await mock.stub(MacOSEcosystem.swVers, arguments: [], stdout: try Fixture.string("MacOS/sw_vers.txt"))
        await mock.stub(MacOSEcosystem.sysctl, arguments: Self.sysctlArguments,
                        stdout: try Fixture.string("MacOS/sysctl-kern.osversion.txt"))

        let items = try await MacOSEcosystem(runner: mock).scan()

        #expect(items == [InstalledItem(
            id: "macos:macos",
            name: "macOS",
            kind: .os,
            ecosystem: .macOS,
            installedVersion: "26.7.1",
            source: .system,
            status: .unknown,
            updateCapability: .openSettings,
            metadata: ["build": "25G241"]
        )])
    }

    @Test func keepsRapidSecurityResponseSuffix() async throws {
        let mock = MockCommandRunner()
        await mock.stub(MacOSEcosystem.swVers, stdout: """
            ProductName:\t\tmacOS
            ProductVersion:\t\t26.7.1
            ProductVersionExtra:\t(a)
            BuildVersion:\t\t25G300a

            """)
        await mock.stub(MacOSEcosystem.sysctl, exitCode: 1)

        let item = try #require(try await MacOSEcosystem(runner: mock).scan().first)
        #expect(item.metadata["versionExtra"] == "(a)")
        #expect(item.metadata["build"] == "25G300a", "Ohne sysctl gilt BuildVersion aus sw_vers")
    }

    @Test func failsWithoutProductVersion() async {
        let mock = MockCommandRunner()
        await mock.stub(MacOSEcosystem.swVers, stdout: "ProductName: macOS\n")
        await mock.stub(MacOSEcosystem.sysctl, stdout: "25G241\n")

        await #expect(throws: InventoryError.unexpectedOutput(source: "sw_vers", detail: "ProductVersion missing")) {
            _ = try await MacOSEcosystem(runner: mock).scan()
        }
    }

    @Test func propagatesFailingSwVers() async {
        let mock = MockCommandRunner()
        await mock.stub(MacOSEcosystem.swVers, exitCode: 1, stderr: "boom")
        await #expect(throws: InventoryError.self) { _ = try await MacOSEcosystem(runner: mock).scan() }
    }
}
