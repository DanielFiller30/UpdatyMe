import Foundation
import Testing
@testable import UpdatyMeCore

@Suite("VersionComparator")
struct VersionComparatorTests {
    struct Pair: Sendable, CustomTestStringConvertible {
        let lower: String
        let higher: String
        var testDescription: String { "\(lower) < \(higher)" }
    }

    static func ascending(_ versions: String...) -> [Pair] {
        zip(versions, versions.dropFirst()).map { Pair(lower: $0, higher: $1) }
    }

    static let semVer = ascending("0.9.9", "1.0.0", "1.0.1", "1.1.0", "1.10.0", "2.0.0", "10.0.0")
        + [Pair(lower: "v24.10.0", higher: "v24.11.0"), Pair(lower: "1.2", higher: "1.2.1")]

    /// Reihenfolge aus der SemVer-2.0-Spezifikation, Abschnitt 11.
    static let semVerPreRelease = ascending(
        "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
        "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"
    )

    static let preReleaseWithoutHyphen = ascending("3.13.0a1", "3.13.0a2", "3.13.0b1", "3.13.0rc1", "3.13.0", "3.13.1")
        + ascending("2.0dev", "2.0alpha", "2.0beta", "2.0preview", "2.0rc", "2.0")
        + ascending("1.5b2", "1.5")
        + [Pair(lower: "1.0.0-beta.1", higher: "1.0.0-rc.1"), Pair(lower: "25.0-SNAPSHOT", higher: "25.0")]

    static let dates = ascending("2024.12.31", "2025.1.1", "2025.01.02", "2025.10.01")
        + ascending("2024-12-31", "2025-01-01", "2025-10-01")
        + ascending("20241231", "20250101")
        + [Pair(lower: "2025.10.01", higher: "2025.10.01.1")]

    static let brewRevisions = ascending("1.2.3", "1.2.3_1", "1.2.3_2", "1.2.3_10", "1.2.4")
        + ascending("4.2,1234", "4.2,1240", "4.3,1000")
        + ascending("8.0.1", "8.0.1-1", "8.0.1-2")

    static let buildNumbers = ascending("25F71", "25G100", "25G241", "26A123")
        + ascending("17E202", "17F113")
        + ascending("999", "1000", "1000.1")
        + [Pair(lower: "21A5248p", higher: "21A5248q")]

    static let letterSuffixReleases = ascending("1.1.1", "1.1.1a", "1.1.1w", "1.1.2")

    @Test(arguments: semVer + semVerPreRelease + preReleaseWithoutHyphen + dates + brewRevisions + letterSuffixReleases)
    func ordersAutomatic(pair: Pair) throws {
        let lower = try #require(Version(pair.lower))
        let higher = try #require(Version(pair.higher))
        #expect(lower < higher)
        #expect(!(higher < lower))
        #expect(lower != higher)
        #expect(VersionComparator.compare(pair.lower, pair.higher) == .orderedAscending)
        #expect(VersionComparator.compare(pair.higher, pair.lower) == .orderedDescending)
    }

    @Test(arguments: buildNumbers)
    func ordersBuildNumbers(pair: Pair) throws {
        let lower = try #require(Version(pair.lower, scheme: .build))
        let higher = try #require(Version(pair.higher, scheme: .build))
        #expect(lower < higher)
        #expect(!(higher < lower))
    }

    @Test func detectsAppleBuildNumbersAutomatically() throws {
        // Ohne Erkennung wäre „25B12“ eine Beta (b + Zahl) und damit kleiner als „25A1“.
        let version = try #require(Version("25B12"))
        #expect(version.isBuildNumber)
        #expect(!version.isPreRelease)
        #expect(VersionComparator.compare("25A1", "25B12") == .orderedAscending)
    }

    @Test(arguments: [
        ("1.2", "1.2.0"), ("1.2.0", "1.2.0.0"), ("v1.2.3", "1.2.3"), ("1.2.3+build.5", "1.2.3+build.9"),
        ("01.002.0003", "1.2.3"), ("1.0.0-RC.1", "1.0.0-rc.1"), (" 1.2.3\n", "1.2.3"),
    ])
    func treatsAsEqual(lhs: String, rhs: String) throws {
        #expect(try #require(Version(lhs)) == #require(Version(rhs)))
        #expect(VersionComparator.compare(lhs, rhs) == .orderedSame)
    }

    @Test(arguments: ["", "   ", "latest", "stable", "beta", "v", "-1"])
    func rejectsUninterpretable(raw: String) {
        #expect(Version(raw) == nil)
        #expect(VersionComparator.compare(raw, "1.0") == nil)
    }

    @Test func handlesNumbersBeyondInt64() {
        #expect(VersionComparator.compare("1.99999999999999999999", "1.100000000000000000000") == .orderedAscending)
    }

    @Test func exposesParts() throws {
        let version = try #require(Version("v3.13.0rc2"))
        #expect(version.major == "3")
        #expect(version.isPreRelease)
        #expect(version.description == "v3.13.0rc2")
    }

    // MARK: - Major

    @Test(arguments: [
        ("1.9.9", "2.0.0", true),
        ("1.2.3", "1.3.0", false),
        ("1.2.3", "1.2.3_1", false),
        ("v22.11.0", "v24.11.0", true),
        ("0.9.0", "0.10.0", false),
        ("2025.10.01", "2026.01.15", true),
        ("2025.10.01", "2025.11.01", false),
        ("20261013", "20261023", false),
        ("20251231", "20260101", true),
        ("20261013", "30000000", true),
        ("2.0.0", "1.0.0", false),
        ("2.0.0-rc.1", "2.0.0", false),
        ("1.9", "2.0-beta", true),
        ("25F71", "26A123", false),
        ("latest", "2.0", false),
    ])
    func majorUpdate(from: String, to: String, expected: Bool) {
        #expect(VersionComparator.isMajorUpdate(from: from, to: to) == expected)
    }

    @Test func buildSchemeIsNeverMajor() {
        #expect(!VersionComparator.isMajorUpdate(from: "1000", to: "2000", scheme: .build))
        #expect(VersionComparator.isMajorUpdate(from: "1000", to: "2000"))
    }
}
