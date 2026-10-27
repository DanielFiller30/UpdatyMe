import Foundation

/// Befehle, mit denen man eine Runtime aktualisiert, als Standard setzt oder entfernt. Die App zeigt sie
/// zum Kopieren an; ausgeführt werden Update und Deinstallation nur nach Bestätigung (`RuntimeScriptExecutor`).
public struct RuntimeGuide: Sendable, Hashable {
    public struct Step: Sendable, Hashable {
        public enum Purpose: String, Sendable, Hashable {
            /// Neueste Version installieren.
            case installLatest
            /// Version als Standard für neue Shells setzen.
            case setDefault
            /// Installierte Versionen anzeigen.
            case list
            /// Toolchain/Kandidat über den Manager aktualisieren.
            case update
            /// Version über den Manager entfernen (nicht Teil von `steps`, siehe `uninstall`).
            case uninstall
        }

        public var purpose: Purpose
        /// Anzeige- und Kopiertext.
        public var command: String
        /// Programm und Argumente zum Ausführen; `nil`, wenn der Schritt nur angezeigt wird (z. B. `export`).
        public var arguments: [String]?

        public init(purpose: Purpose, command: String, arguments: [String]? = nil) {
            self.purpose = purpose
            self.command = command
            self.arguments = arguments
        }

        /// Ausführbarer Schritt; der Anzeigetext entsteht aus den Argumenten, sofern keiner vorgegeben ist.
        static func run(_ purpose: Purpose, _ arguments: [String], command: String? = nil) -> Step {
            Step(purpose: purpose, command: command ?? arguments.joined(separator: " "), arguments: arguments)
        }
    }

    /// Was die App per Knopfdruck ausführen kann.
    public enum Action: String, Sendable, Hashable {
        case update
        case uninstall
        /// Vom Nutzer eingegebene Version installieren (siehe `installSteps(for:version:setDefault:)`).
        case install
    }

    /// Hinweise, die die App übersetzt anzeigt.
    public enum Note: String, Sendable, Hashable {
        /// Python der Xcode-/Command-Line-Tools: kommt mit Xcode bzw. Softwareupdate.
        case providedByDeveloperTools
        /// asdf ab 0.16 (`asdf set --home`); ältere Versionen: `asdf global`.
        case asdfVersion
        /// Java-Standard über `JAVA_HOME` im Shell-Profil (z. B. `~/.zshrc`).
        case javaHomeInProfile
        /// Ohne Versionsmanager installiert: neue Version vom Hersteller laden.
        case manualInstallation
    }

    public var steps: [Step]
    public var downloadURL: URL?
    public var notes: [Note]
    /// Befehl zum Entfernen dieser Version; `nil`, wenn der Manager das nicht kann oder die Version nicht
    /// von einem Manager stammt.
    public var uninstall: Step?

    public init(steps: [Step], downloadURL: URL? = nil, notes: [Note] = [], uninstall: Step? = nil) {
        self.steps = steps
        self.downloadURL = downloadURL
        self.notes = notes
        self.uninstall = uninstall
    }

    /// Schritte, die „Update ausführen“ nacheinander startet: installieren/aktualisieren und Standard setzen.
    public var updateSteps: [Step] {
        steps.filter { $0.arguments != nil && $0.purpose != .list }
    }

    /// Update ist nur sinnvoll, wenn eine neuere Version bekannt ist.
    public var canRunUpdate: Bool {
        hasNewerVersion && !updateSteps.isEmpty
    }

    public private(set) var hasNewerVersion = false

    public func steps(for action: Action) -> [Step] {
        switch action {
        case .update: updateSteps
        case .uninstall: uninstall.map { [$0] } ?? []
        case .install: []
        }
    }

    /// Eine Versionsangabe, die gefahrlos als Argument übergeben werden kann (kein führendes `-`, keine Leerzeichen).
    public static func isValidVersion(_ version: String) -> Bool {
        version.range(of: #"^[A-Za-z0-9][A-Za-z0-9._+/-]*$"#, options: .regularExpression) != nil
    }

    /// Befehle, um genau `version` über den Manager der Runtime zu installieren (optional als Standard).
    /// Leer, wenn der Manager das nicht kann oder die Version ungültig ist.
    public static func installSteps(for item: InstalledItem, version: String, setDefault: Bool) -> [Step] {
        guard item.kind == .runtime, isValidVersion(version) else { return [] }
        let v = version
        func pair(_ install: [String], _ makeDefault: [String]?) -> [Step] {
            [Step.run(.installLatest, install)] + (setDefault ? makeDefault.map { [Step.run(.setDefault, $0)] } ?? [] : [])
        }
        switch (item.ecosystem, item.source) {
        case (.node, .nvm):
            return pair(["nvm", "install", v, "--reinstall-packages-from=\(item.installedVersion)"], ["nvm", "alias", "default", v])
        case (.node, .fnm): return pair(["fnm", "install", v], ["fnm", "default", v])
        case (.node, .volta): return [Step.run(.installLatest, ["volta", "install", "node@\(v)"])]
        case (.node, .asdf): return pair(["asdf", "install", "nodejs", v], ["asdf", "set", "--home", "nodejs", v])
        case (.python, .pyenv): return pair(["pyenv", "install", v], ["pyenv", "global", v])
        case (.python, .uv): return pair(["uv", "python", "install", v], ["uv", "python", "pin", "--global", v])
        case (.python, .conda): return [Step.run(.installLatest, ["conda", "install", "python=\(v)"], command: "conda install \"python=\(v)\"")]
        case (.python, .asdf): return pair(["asdf", "install", "python", v], ["asdf", "set", "--home", "python", v])
        case (.rust, _): return pair(["rustup", "toolchain", "install", v], ["rustup", "default", v])
        case (.java, .sdkman): return pair(["sdk", "install", "java", v], ["sdk", "default", "java", v])
        default: return []
        }
    }

    /// Ob für diese Runtime eine frei wählbare Version installiert werden kann.
    public static func supportsCustomVersion(_ item: InstalledItem) -> Bool {
        !installSteps(for: item, version: "1.0", setDefault: false).isEmpty
    }

    /// Alle Befehle zeilenweise (zum Kopieren in die Shell).
    public var script: String {
        steps.map(\.command).joined(separator: "\n")
    }

    /// Anleitung für eine Runtime (`kind == .runtime`); `nil` für alles andere.
    /// Mit neuerer Version (Status „Update“): installieren und als Standard setzen. Sonst: als Standard setzen
    /// (falls nicht schon Standard) und installierte Versionen anzeigen.
    public static func guide(for item: InstalledItem) -> RuntimeGuide? {
        guard item.kind == .runtime, var guide = makeGuide(for: item) else { return nil }
        guide.hasNewerVersion = item.status == .outdated && item.latestVersion != nil
        return guide
    }

    private static func makeGuide(for item: InstalledItem) -> RuntimeGuide? {
        let installed = item.installedVersion
        let latest = item.status == .outdated ? item.latestVersion : nil
        let target = latest ?? installed
        let isDefault = item.metadata[InstalledItem.MetadataKey.isDefault] == "true"
        func steps(install: [String]?, setDefault: [String]?, list: String, installCommand: String? = nil) -> [Step] {
            var steps: [Step] = []
            if latest != nil, let install { steps.append(.run(.installLatest, install, command: installCommand)) }
            if latest != nil || !isDefault, let setDefault { steps.append(.run(.setDefault, setDefault)) }
            steps.append(Step(purpose: .list, command: list))
            return steps
        }
        func remove(_ arguments: [String]) -> Step { .run(.uninstall, arguments) }

        switch (item.ecosystem, item.source) {
        case (.node, .nvm):
            return RuntimeGuide(steps: steps(install: ["nvm", "install", target, "--reinstall-packages-from=\(installed)"],
                                             setDefault: ["nvm", "alias", "default", target], list: "nvm ls"),
                                uninstall: remove(["nvm", "uninstall", installed]))
        case (.node, .fnm):
            return RuntimeGuide(steps: steps(install: ["fnm", "install", target], setDefault: ["fnm", "default", target], list: "fnm list"),
                                uninstall: remove(["fnm", "uninstall", installed]))
        case (.node, .volta):
            // `volta install` installiert und setzt die Standardversion in einem Schritt.
            let purpose: Step.Purpose? = latest != nil ? .installLatest : (isDefault ? nil : .setDefault)
            return RuntimeGuide(steps: (purpose.map { [Step.run($0, ["volta", "install", "node@\(target)"])] } ?? [])
                                + [Step(purpose: .list, command: "volta list node")])
        case (.node, .asdf):
            return RuntimeGuide(steps: steps(install: ["asdf", "install", "nodejs", target], setDefault: ["asdf", "set", "--home", "nodejs", target],
                                             list: "asdf list nodejs"), notes: [.asdfVersion],
                                uninstall: remove(["asdf", "uninstall", "nodejs", installed]))
        case (.node, _):
            return RuntimeGuide(steps: [Step(purpose: .list, command: "node --version")],
                                downloadURL: URL(string: "https://nodejs.org/en/download"), notes: [.manualInstallation])

        case (.python, .pyenv):
            return RuntimeGuide(steps: steps(install: ["pyenv", "install", target], setDefault: ["pyenv", "global", target], list: "pyenv versions"),
                                uninstall: remove(["pyenv", "uninstall", "-f", installed]))
        case (.python, .uv):
            return RuntimeGuide(steps: steps(install: ["uv", "python", "install", target], setDefault: ["uv", "python", "pin", "--global", target],
                                             list: "uv python list --only-installed"),
                                uninstall: remove(["uv", "python", "uninstall", installed]))
        case (.python, .conda):
            return RuntimeGuide(steps: steps(install: ["conda", "install", "python=\(target)"], setDefault: nil, list: "conda list python",
                                             installCommand: "conda install \"python=\(target)\""))
        case (.python, .asdf):
            return RuntimeGuide(steps: steps(install: ["asdf", "install", "python", target], setDefault: ["asdf", "set", "--home", "python", target],
                                             list: "asdf list python"), notes: [.asdfVersion],
                                uninstall: remove(["asdf", "uninstall", "python", installed]))
        case (.python, .system):
            return RuntimeGuide(steps: [Step(purpose: .list, command: "xcrun python3 --version")], notes: [.providedByDeveloperTools])
        case (.python, _):
            return RuntimeGuide(steps: [Step(purpose: .list, command: "python3 --version")],
                                downloadURL: URL(string: "https://www.python.org/downloads/macos/"), notes: [.manualInstallation])

        case (.rust, _):
            let toolchain = item.metadata["toolchain"].map(RustEcosystem.channel(of:)) ?? "stable"
            var steps = [Step]()
            if latest != nil { steps.append(.run(.update, ["rustup", "update", toolchain])) }
            if !isDefault { steps.append(.run(.setDefault, ["rustup", "default", toolchain])) }
            steps.append(Step(purpose: .list, command: "rustup toolchain list"))
            let fullName = item.metadata["toolchain"] ?? toolchain
            return RuntimeGuide(steps: steps, uninstall: remove(["rustup", "toolchain", "uninstall", fullName]))

        case (.java, .sdkman):
            var steps = [Step]()
            if latest != nil { steps.append(.run(.update, ["sdk", "upgrade", "java"])) }
            steps.append(Step(purpose: .list, command: "sdk list java"))
            let candidate = item.installPath.map { URL(fileURLWithPath: $0).lastPathComponent }
            return RuntimeGuide(steps: steps, uninstall: candidate.map { remove(["sdk", "uninstall", "java", $0]) })
        case (.java, _):
            let major = String(installed.split(separator: ".").first ?? "")
            return RuntimeGuide(
                steps: [Step(purpose: .setDefault, command: "export JAVA_HOME=$(/usr/libexec/java_home -v \(major))"),
                        Step(purpose: .list, command: "/usr/libexec/java_home -V")],
                downloadURL: javaDownloadURL(distribution: item.metadata["distribution"]),
                notes: [.javaHomeInProfile, .manualInstallation]
            )

        default:
            return nil
        }
    }

    static func javaDownloadURL(distribution: String?) -> URL? {
        let urls = [
            "zulu": "https://www.azul.com/downloads/?package=jdk#zulu",
            "temurin": "https://adoptium.net/temurin/releases/",
            "corretto": "https://aws.amazon.com/corretto/",
            "oracle": "https://www.oracle.com/java/technologies/downloads/",
            "microsoft": "https://learn.microsoft.com/java/openjdk/download",
            "liberica": "https://bell-sw.com/pages/downloads/",
            "semeru": "https://developer.ibm.com/languages/java/semeru-runtimes/downloads/",
            "sap_machine": "https://sap.github.io/SapMachine/",
            "graalvm_community": "https://github.com/graalvm/graalvm-ce-builds/releases",
        ]
        return distribution.flatMap { urls[$0] }.flatMap(URL.init(string:))
    }
}
