import Foundation

/// Kennung eines Ökosystems (Brew, npm, macOS, …). Als offener Typ statt `enum`, damit neue
/// Ökosysteme (Plugins, Config-Tools aus Phase 6) den Kern nicht ändern müssen.
public struct EcosystemID: RawRepresentable, Sendable, Hashable, Codable, ExpressibleByStringLiteral,
    CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public var description: String { rawValue }

    public static let macOS: EcosystemID = "macos"
    public static let brew: EcosystemID = "brew"
    public static let appBundle: EcosystemID = "app-bundle"
    public static let node: EcosystemID = "node"
    public static let npm: EcosystemID = "npm"
    public static let pnpm: EcosystemID = "pnpm"
    public static let python: EcosystemID = "python"
    public static let rust: EcosystemID = "rust"
    public static let java: EcosystemID = "java"
    public static let gcloud: EcosystemID = "gcloud"
    /// Tools aus der Konfigurationsdatei (`tools.json`).
    public static let configuredTools: EcosystemID = "config"

    // Quellen für neueste Versionen, u. a. für Fehlermeldungen.
    public static let nodeReleases: EcosystemID = "latest.nodejs"
    public static let npmRegistry: EcosystemID = "latest.npm"
    public static let pythonReleases: EcosystemID = "latest.python"
    public static let pypi: EcosystemID = "latest.pypi"
    public static let rustReleases: EcosystemID = "latest.rust"
    public static let crates: EcosystemID = "latest.crates"
    public static let javaReleases: EcosystemID = "latest.java"
    public static let gcloudReleases: EcosystemID = "latest.gcloud"
    public static let configuredToolReleases: EcosystemID = "latest.config"
    public static let softwareUpdate: EcosystemID = "latest.softwareupdate"
    public static let brewOutdated: EcosystemID = "latest.brew"
    public static let appStore: EcosystemID = "latest.appstore"
    public static let sparkle: EcosystemID = "latest.sparkle"
    public static let caskMatch: EcosystemID = "latest.cask"
}

/// Herkunft eines installierten Eintrags. Offener Typ aus demselben Grund wie `EcosystemID`.
public struct ItemSource: RawRepresentable, Sendable, Hashable, Codable, ExpressibleByStringLiteral,
    CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public var description: String { rawValue }

    public static let system: ItemSource = "system"
    public static let brew: ItemSource = "brew"
    public static let cask: ItemSource = "cask"
    public static let mas: ItemSource = "mas"
    public static let sparkle: ItemSource = "sparkle"
    public static let manual: ItemSource = "manual"
    public static let npm: ItemSource = "npm"
    public static let pnpm: ItemSource = "pnpm"
    public static let yarn: ItemSource = "yarn"
    public static let bun: ItemSource = "bun"
    public static let pip: ItemSource = "pip"
    public static let pipx: ItemSource = "pipx"
    public static let uv: ItemSource = "uv"
    public static let cargo: ItemSource = "cargo"
    public static let rustup: ItemSource = "rustup"
    public static let gem: ItemSource = "gem"
    public static let nvm: ItemSource = "nvm"
    public static let fnm: ItemSource = "fnm"
    public static let volta: ItemSource = "volta"
    public static let pyenv: ItemSource = "pyenv"
    public static let rbenv: ItemSource = "rbenv"
    public static let asdf: ItemSource = "asdf"
    public static let sdkman: ItemSource = "sdkman"
    public static let conda: ItemSource = "conda"
    /// Tool aus der Konfigurationsdatei.
    public static let config: ItemSource = "config"
}
