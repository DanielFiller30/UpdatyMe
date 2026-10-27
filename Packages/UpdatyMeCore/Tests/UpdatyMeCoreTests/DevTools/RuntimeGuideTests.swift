import Foundation
import Testing
@testable import UpdatyMeCore

@Suite("RuntimeGuide")
struct RuntimeGuideTests {
    static func runtime(_ ecosystem: EcosystemID, _ source: ItemSource, _ installed: String, latest: String? = nil,
                        isDefault: Bool = false, metadata: [String: String] = [:]) -> InstalledItem {
        var metadata = metadata
        metadata["isDefault"] = String(isDefault)
        return InstalledItem(id: "\(ecosystem.rawValue):x", name: "x", kind: .runtime, ecosystem: ecosystem, installedVersion: installed,
                             source: source, latestVersion: latest, status: latest == nil ? .upToDate : .outdated,
                             updateCapability: .manual, metadata: metadata)
    }

    static func commands(_ item: InstalledItem) -> [String] {
        RuntimeGuide.guide(for: item)?.steps.map(\.command) ?? []
    }

    @Test func nvmWithUpdateReinstallsPackagesAndSetsDefault() throws {
        let guide = try #require(RuntimeGuide.guide(for: Self.runtime(.node, .nvm, "24.21.0", latest: "24.22.1", isDefault: true)))
        #expect(guide.steps.map(\.purpose) == [.installLatest, .setDefault, .list])
        #expect(guide.script == "nvm install 24.22.1 --reinstall-packages-from=24.21.0\nnvm alias default 24.22.1\nnvm ls")
    }

    @Test func nvmWithoutUpdate() {
        #expect(Self.commands(Self.runtime(.node, .nvm, "24.22.1", isDefault: true)) == ["nvm ls"])
        #expect(Self.commands(Self.runtime(.node, .nvm, "26.12.1")) == ["nvm alias default 26.12.1", "nvm ls"])
    }

    @Test func otherNodeManagers() {
        #expect(Self.commands(Self.runtime(.node, .fnm, "22.1.0", latest: "22.23.4")) == ["fnm install 22.23.4", "fnm default 22.23.4", "fnm list"])
        #expect(Self.commands(Self.runtime(.node, .volta, "22.1.0", latest: "22.23.4")) == ["volta install node@22.23.4", "volta list node"])
        #expect(Self.commands(Self.runtime(.node, .volta, "22.1.0", isDefault: true)) == ["volta list node"])
        let asdf = RuntimeGuide.guide(for: Self.runtime(.node, .asdf, "22.1.0", latest: "22.23.4"))
        #expect(asdf?.script == "asdf install nodejs 22.23.4\nasdf set --home nodejs 22.23.4\nasdf list nodejs")
        #expect(asdf?.notes == [.asdfVersion])
        let manual = RuntimeGuide.guide(for: Self.runtime(.node, .manual, "20.1.0", latest: "20.19.0"))
        #expect(manual?.downloadURL?.host == "nodejs.org")
    }

    @Test func python() {
        #expect(Self.commands(Self.runtime(.python, .pyenv, "3.12.1", latest: "3.12.16"))
                == ["pyenv install 3.12.16", "pyenv global 3.12.16", "pyenv versions"])
        #expect(Self.commands(Self.runtime(.python, .uv, "3.14.7", latest: "3.14.10"))
                == ["uv python install 3.14.10", "uv python pin --global 3.14.10", "uv python list --only-installed"])
        #expect(Self.commands(Self.runtime(.python, .conda, "3.13.14", latest: "3.13.18"))
                == ["conda install \"python=3.13.18\"", "conda list python"])
        let system = RuntimeGuide.guide(for: Self.runtime(.python, .system, "3.9.6"))
        #expect(system?.notes == [.providedByDeveloperTools])
        #expect(system?.steps.map(\.purpose) == [.list])
    }

    @Test func rustAndJava() {
        #expect(Self.commands(Self.runtime(.rust, .rustup, "1.98.0", latest: "1.99.1", isDefault: true,
                                           metadata: ["toolchain": "stable-aarch64-apple-darwin"]))
                == ["rustup update stable", "rustup toolchain list"])
        #expect(Self.commands(Self.runtime(.rust, .rustup, "1.101.0-nightly", metadata: ["toolchain": "nightly-aarch64-apple-darwin"]))
                == ["rustup default nightly", "rustup toolchain list"])
        let zulu = RuntimeGuide.guide(for: Self.runtime(.java, .manual, "25.0.5", metadata: ["distribution": "zulu"]))
        #expect(zulu?.script == "export JAVA_HOME=$(/usr/libexec/java_home -v 25)\n/usr/libexec/java_home -V")
        #expect(zulu?.downloadURL?.host == "www.azul.com")
        #expect(RuntimeGuide.guide(for: Self.runtime(.java, .manual, "21.0.1"))?.downloadURL == nil, "Unbekannter Hersteller: kein geratener Link")
        #expect(Self.commands(Self.runtime(.java, .sdkman, "21.0.1", latest: "21.0.5")) == ["sdk upgrade java", "sdk list java"])
    }

    @Test func onlyRuntimes() {
        var package = Self.runtime(.npm, .npm, "1.0")
        package.kind = .package
        #expect(RuntimeGuide.guide(for: package) == nil)
    }
}
