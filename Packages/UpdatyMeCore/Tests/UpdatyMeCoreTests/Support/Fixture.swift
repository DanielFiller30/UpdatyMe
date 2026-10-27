import Foundation
import Testing

/// Lädt aufgezeichnete bzw. nachgebildete CLI-Ausgaben aus `Tests/UpdatyMeCoreTests/Fixtures/`.
enum Fixture {
    static func string(_ path: String) throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: path, withExtension: nil, subdirectory: "Fixtures"),
            "Fixture fehlt: \(path)"
        )
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }
}

/// Temporäres Verzeichnis als Home-Ersatz für Dateisystem-Tests.
struct TemporaryDirectory: ~Copyable {
    let url: URL

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdatyMeCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // `resolvingSymlinksInPath()` lässt `/var` → `/private/var` absichtlich aus; `realpath` nicht.
        let resolved = try #require(realpath(directory.path, nil))
        defer { free(resolved) }
        url = URL(fileURLWithPath: String(cString: resolved))
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func makeDirectory(_ relativePath: String) throws -> URL {
        let directory = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    func makeExecutable(_ relativePath: String) throws -> URL {
        let file = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    @discardableResult
    func makeFile(_ relativePath: String) throws -> URL {
        let file = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data().write(to: file)
        return file
    }
}
