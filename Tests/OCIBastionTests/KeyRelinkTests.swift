import XCTest
@testable import OCIBastion

final class KeyRelinkTests: XCTestCase {
    func testImportReusesCopyWithSameContents() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let a = base.appendingPathComponent("exo.key"), b = base.appendingPathComponent("otra.key")
        try "clave-A".write(to: a, atomically: true, encoding: .utf8)
        try "clave-B".write(to: b, atomically: true, encoding: .utf8)
        let store = base.appendingPathComponent("imported")
        let first = try SSHKeyImport.importCopy(of: a, into: store)
        XCTAssertEqual(try SSHKeyImport.importCopy(of: a, into: store), first, "La misma clave no se duplica")
        XCTAssertNotEqual(try SSHKeyImport.importCopy(of: b, into: store), first, "Otra clave tiene su propia copia")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.path).count, 2)
    }

    func testRelinkOnlyTouchesUnreadableCopiesOfTheSameFile() {
        let old = "/Users/u/keys/exo.key", other = "/Users/u/keys/otra.key", copy = "/c/imported/1-exo.key"
        var settings = Settings()
        settings.destinations = [Destination(name: "a", host: "h1", privateKeyPath: old),
                                 Destination(name: "b", host: "h2", privateKeyPath: other),
                                 Destination(name: "c", host: "h3", privateKeyPath: "~/../u/keys/./exo.key")]
        var tunnel = LocalTunnel(); tunnel.privateKeyPath = old
        settings.tunnels = [tunnel]
        var snapshot = ConnectionSnapshot(settings: settings)
        snapshot.destinations = [Destination(name: "s", host: "h4", privateKeyPath: old)]
        settings.savedConnections = [SavedConnection(id: UUID(), name: "Otra", snapshot: snapshot)]

        // «otra.key» no se arregla aunque tampoco se pueda leer: es otra clave.
        let changed = settings.relinkKeys(from: old, to: copy, isUnreadable: { _ in true })
        XCTAssertEqual(settings.destinations.map(\.privateKeyPath), [copy, other, copy])
        XCTAssertEqual(settings.tunnels?.first?.privateKeyPath, copy)
        XCTAssertEqual(settings.savedConnections?.first?.snapshot.destinations.first?.privateKeyPath, copy)
        XCTAssertEqual(settings.savedConnections?.first?.snapshot.tunnels?.first?.privateKeyPath, copy)
        XCTAssertEqual(changed, 5)

        // Si la ruta antigua se puede leer (p. ej. fuera del sandbox), se respeta.
        var readable = Settings()
        readable.destinations = [Destination(name: "a", host: "h", privateKeyPath: old)]
        XCTAssertEqual(readable.relinkKeys(from: old, to: copy, isUnreadable: { _ in false }), 0)
        XCTAssertEqual(readable.destinations.first?.privateKeyPath, old)
    }

    @MainActor
    func testManagerSavesAndLogsRelink() {
        var settings = Settings()
        settings.destinations = [Destination(name: "a", host: "h", privateKeyPath: "/old/exo.key")]
        let manager = TunnelManager(settings: settings, startServices: false)
        manager.enterDemo()
        XCTAssertEqual(manager.relinkImportedKey(original: "/old/exo.key", copy: "/new", isUnreadable: { _ in true }), 0,
                       "En modo demo no se toca nada")
    }
}
