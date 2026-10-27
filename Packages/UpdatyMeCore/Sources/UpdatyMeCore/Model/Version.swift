import Foundation

/// Vergleichbare Version. Deckt SemVer ab und fällt für andere Schemata auf einen
/// segmentweisen Vergleich zurück:
///
/// - **SemVer** inkl. Pre-Release (`1.0.0-rc.1 < 1.0.0`), Build-Metadaten (`+abc`) werden ignoriert.
/// - **Pre-Release ohne Bindestrich** (`3.13.0a1`, `2.0b3`, `1.5rc2`, `1.0beta`): Rangfolge
///   dev/snapshot/nightly/canary < alpha/a/ea < beta/b < pre/preview < rc/c.
/// - **Buchstaben-Suffix als Release** (`1.1.1w` > `1.1.1`): einzelne Buchstaben ohne folgende Zahl
///   gelten nicht als Pre-Release.
/// - **Datumsversionen** (`2025.10.01`, `2025-10-01`, `20251001`) segmentweise numerisch.
/// - **Brew-Revisionen** (`1.2.3_1 > 1.2.3`), **Cask-Builds** (`4.2,1234`) und numerische
///   Bindestrich-Suffixe (`8.0.1-1`) als nachrangige Revision.
/// - **Build-Nummern** (`25G241`, `17F113`): automatisch erkannt oder per `Scheme.build`; Zahlen- und
///   Buchstabenblöcke werden natürlich verglichen, ohne Pre-Release-Logik.
public struct Version: Sendable, Comparable, CustomStringConvertible {
    public enum Scheme: String, Sendable, Hashable, Codable {
        /// Erkennt das Schema anhand des Strings.
        case automatic
        /// Reine Build-Nummer (z. B. `CFBundleVersion`, macOS-Build).
        case build
    }

    enum Token: Sendable, Hashable {
        /// Ziffern ohne führende Nullen (beliebig lang, kein Überlauf).
        case number(String)
        /// Kleingeschriebener Buchstabenblock.
        case text(String)
    }

    public let raw: String
    let isBuildNumber: Bool
    let release: [Token]
    let preRelease: [Token]
    let revision: [Token]

    /// `nil`, wenn der String keine Ziffer enthält oder nicht mit einer Zahl beginnt (z. B. `latest`).
    public init?(_ raw: String, scheme: Scheme = .automatic) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        self.raw = trimmed

        var main = Substring(trimmed)
        if let first = main.first, first == "v" || first == "V", main.dropFirst().first?.isNumber == true {
            main = main.dropFirst()
        }

        if scheme == .build || main.wholeMatch(of: /\d+[A-Za-z]\d+[a-z]?/) != nil {
            let tokens = Self.tokenize(main)
            guard case .number = tokens.first else { return nil }
            isBuildNumber = true
            release = tokens
            preRelease = []
            revision = []
            return
        }
        isBuildNumber = false

        if let plus = main.firstIndex(of: "+") {
            main = main[..<plus]
        }

        var revision: [Token] = []
        if let comma = main.firstIndex(of: ",") {
            revision = Self.tokenize(main[main.index(after: comma)...])
            main = main[..<comma]
        }
        if let match = main.firstMatch(of: /_(\d+)$/) {
            revision = Self.tokenize(match.output.1) + revision
            main = main[..<match.range.lowerBound]
        }

        var preRelease: [Token] = []
        if main.wholeMatch(of: /\d{4}-\d{1,2}-\d{1,2}/) == nil, let hyphen = main.firstIndex(of: "-") {
            let tail = main[main.index(after: hyphen)...]
            if tail.contains(where: \.isLetter) {
                preRelease = Self.tokenize(tail)
            } else {
                revision = Self.tokenize(tail) + revision
            }
            main = main[..<hyphen]
        }

        var tokens = Self.tokenize(main)
        if let marker = Self.preReleaseMarkerIndex(in: tokens) {
            preRelease = Array(tokens[marker...]) + preRelease
            tokens = Array(tokens[..<marker])
        }
        guard case .number = tokens.first else { return nil }

        self.release = tokens
        self.preRelease = preRelease
        self.revision = revision
    }

    public var description: String { raw }

    /// Erstes numerisches Segment (bei SemVer die Major-Version).
    public var major: String? {
        guard case .number(let value) = release.first else { return nil }
        return value
    }

    public var isPreRelease: Bool { !preRelease.isEmpty }

    public static func == (lhs: Version, rhs: Version) -> Bool {
        compare(lhs, rhs) == .orderedSame
    }

    public static func < (lhs: Version, rhs: Version) -> Bool {
        compare(lhs, rhs) == .orderedAscending
    }

    // MARK: - Vergleich

    static func compare(_ lhs: Version, _ rhs: Version) -> ComparisonResult {
        let release = compareRelease(lhs.release, rhs.release)
        if release != .orderedSame { return release }

        switch (lhs.preRelease.isEmpty, rhs.preRelease.isEmpty) {
        case (true, false): return .orderedDescending
        case (false, true): return .orderedAscending
        case (false, false):
            let pre = comparePreRelease(lhs.preRelease, rhs.preRelease)
            if pre != .orderedSame { return pre }
        case (true, true): break
        }
        return compareMissingFirst(lhs.revision, rhs.revision)
    }

    /// Fehlende Segmente zählen als `0` gegenüber Zahlen (`1.2 == 1.2.0`) und als kleiner gegenüber
    /// Buchstaben (`1.1.1 < 1.1.1w`). Zahl schlägt Text an gleicher Position.
    private static func compareRelease(_ lhs: [Token], _ rhs: [Token]) -> ComparisonResult {
        for index in 0..<max(lhs.count, rhs.count) {
            let result: ComparisonResult
            switch (lhs[safe: index], rhs[safe: index]) {
            case (let left?, let right?): result = compareToken(left, right)
            case (nil, .number(let right)?): result = compareDigits("0", right)
            case (.number(let left)?, nil): result = compareDigits(left, "0")
            case (nil, .text?): result = .orderedAscending
            case (.text?, nil): result = .orderedDescending
            case (nil, nil): result = .orderedSame
            }
            if result != .orderedSame { return result }
        }
        return .orderedSame
    }

    private static func comparePreRelease(_ lhs: [Token], _ rhs: [Token]) -> ComparisonResult {
        if case .text(let left) = lhs[0], case .text(let right) = rhs[0],
           let leftRank = preReleaseRank[left], let rightRank = preReleaseRank[right] {
            if leftRank != rightRank { return leftRank < rightRank ? .orderedAscending : .orderedDescending }
            return compareMissingFirst(Array(lhs.dropFirst()), Array(rhs.dropFirst()), numbersFirst: true)
        }
        return compareMissingFirst(lhs, rhs, numbersFirst: true)
    }

    /// SemVer-Regel: Bei gleichem Präfix hat die längere Liste Vorrang (`rc < rc.1`, `1.2.3 < 1.2.3_1`).
    /// `numbersFirst`: SemVer-Pre-Release-Regel, Zahl < Text (`alpha.1 < alpha.beta`).
    private static func compareMissingFirst(
        _ lhs: [Token], _ rhs: [Token], numbersFirst: Bool = false
    ) -> ComparisonResult {
        for (left, right) in zip(lhs, rhs) {
            let result = compareToken(left, right, numbersFirst: numbersFirst)
            if result != .orderedSame { return result }
        }
        if lhs.count == rhs.count { return .orderedSame }
        return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
    }

    private static func compareToken(_ lhs: Token, _ rhs: Token, numbersFirst: Bool = false) -> ComparisonResult {
        switch (lhs, rhs) {
        case (.number(let left), .number(let right)): compareDigits(left, right)
        case (.text(let left), .text(let right)): left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
        case (.number, .text): numbersFirst ? .orderedAscending : .orderedDescending
        case (.text, .number): numbersFirst ? .orderedDescending : .orderedAscending
        }
    }

    static func compareDigits(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if lhs.count != rhs.count { return lhs.count < rhs.count ? .orderedAscending : .orderedDescending }
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    // MARK: - Zerlegung

    static let preReleaseRank: [String: Int] = [
        "dev": 0, "snapshot": 0, "nightly": 0, "canary": 0,
        "alpha": 1, "a": 1, "ea": 1,
        "beta": 2, "b": 2,
        "pre": 3, "preview": 3,
        "rc": 4, "c": 4,
    ]

    /// Index des ersten Pre-Release-Markers. Einzelbuchstaben (`a`, `b`, `c`) zählen nur, wenn eine
    /// Zahl folgt (`3.13.0a1`), damit `1.1.1a` (OpenSSL-Stil) eine Release-Version bleibt.
    private static func preReleaseMarkerIndex(in tokens: [Token]) -> Int? {
        for (index, token) in tokens.enumerated() where index > 0 {
            guard case .text(let text) = token, preReleaseRank[text] != nil else { continue }
            if text.count > 1 { return index }
            if case .number? = tokens[safe: index + 1] { return index }
        }
        return nil
    }

    /// Zerlegt in Zahlen- und Buchstabenblöcke; alle anderen Zeichen trennen nur.
    static func tokenize(_ string: Substring) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var currentIsNumber = false

        func flush() {
            guard !current.isEmpty else { return }
            if currentIsNumber {
                let trimmed = current.drop { $0 == "0" }
                tokens.append(.number(trimmed.isEmpty ? "0" : String(trimmed)))
            } else {
                tokens.append(.text(current.lowercased()))
            }
            current = ""
        }

        for character in string {
            let isNumber = character.isASCII && character.isNumber
            let isLetter = character.isLetter
            if isNumber || isLetter {
                if !current.isEmpty && isNumber != currentIsNumber { flush() }
                currentIsNumber = isNumber
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }
}

/// Bequeme Vergleichsfunktionen auf Strings.
public enum VersionComparator {
    /// `nil`, wenn eine der Versionen nicht interpretierbar ist.
    public static func compare(_ lhs: String, _ rhs: String, scheme: Version.Scheme = .automatic) -> ComparisonResult? {
        guard let left = Version(lhs, scheme: scheme), let right = Version(rhs, scheme: scheme) else { return nil }
        return Version.compare(left, right)
    }

    /// Major-Update, wenn das erste numerische Segment steigt (gilt auch für Datumsversionen).
    /// Kompakte Datumsversionen (`20261013`) zählen nur bei Jahreswechsel als Major.
    /// Build-Nummern sind nie Major.
    public static func isMajorUpdate(from installed: Version, to latest: Version) -> Bool {
        guard !installed.isBuildNumber, !latest.isBuildNumber,
              var from = installed.major, var to = latest.major else { return false }
        if let fromYear = compactDateYear(from), let toYear = compactDateYear(to) {
            from = fromYear
            to = toYear
        }
        return Version.compareDigits(from, to) == .orderedAscending
    }

    /// Jahr einer kompakten Datumsversion `JJJJMMTT` (1900–2999, Monat 1–12, Tag 1–31), sonst `nil`.
    static func compactDateYear(_ digits: String) -> String? {
        guard digits.count == 8, let value = Int(digits) else { return nil }
        let year = value / 10_000, month = value / 100 % 100, day = value % 100
        guard (1900...2999).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        return String(year)
    }

    public static func isMajorUpdate(from installed: String, to latest: String, scheme: Version.Scheme = .automatic) -> Bool {
        guard let from = Version(installed, scheme: scheme), let to = Version(latest, scheme: scheme) else { return false }
        return isMajorUpdate(from: from, to: to)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
