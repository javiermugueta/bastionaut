import XCTest
@testable import OCIBastion

final class ArchiveTests: XCTestCase {
    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    private func archive(_ name: String) throws -> ConfigurationArchive {
        let data = try Data(contentsOf: fixtures.appendingPathComponent(name))
        let value = try JSONDecoder().decode(ConfigurationArchive.self, from: data)
        try value.validate()
        return value
    }

    func testLegacyMergeKeepsOtherConnections() throws {
        let archive = try archive("LegacyArchive.json")
        var settings = Settings()
        settings.profile = "LOCAL"
        let untouched = SavedConnection(id: UUID(), name: "Otra conexión", snapshot: ConnectionSnapshot(settings: settings))
        let collision = SavedConnection(id: UUID(), name: "Example instance", snapshot: ConnectionSnapshot(settings: settings))
        settings.savedConnections = [untouched, collision]
        XCTAssertEqual(archive.conflictingNames(with: settings), ["Example instance"])
        let merged = archive.merged(into: settings)
        XCTAssertEqual(merged.savedConnections?.count, 2)
        XCTAssertEqual(merged.savedConnections?.first?.id, untouched.id)
        XCTAssertEqual(merged.savedConnections?.first?.snapshot.profile, "LOCAL")
        XCTAssertEqual(merged.savedConnections?.last?.id, collision.id)
        XCTAssertEqual(merged.savedConnections?.last?.snapshot.profile, "SAMPLE")
        XCTAssertEqual(merged.profile, "SAMPLE")
        XCTAssertEqual(merged.selectedSavedConnectionID, collision.id)
    }

    func testLegacyArchiveDefaultsToSocksAndCustomKeys() throws {
        let archive = try archive("LegacyArchive.json")
        let merged = archive.merged(into: Settings())
        XCTAssertEqual(merged.effectiveSessionMode, .socks)
        if !merged.publicKeyPath.isEmpty { XCTAssertEqual(merged.effectiveKeyMode, .custom) }
    }

    func testNamedExportCarriesVisibleChangesAndEmoji() throws {
        var settings = Settings()
        settings.profile = "EDITADO"
        settings.sessionMode = .portForwarding
        settings.region = "eu-madrid-1"
        var tunnel = LocalTunnel()
        tunnel.name = "Agente"
        tunnel.host = "10.0.0.47"
        tunnel.privateKeyPath = "/tmp/example-agent.key"
        tunnel.localPort = 19081
        tunnel.remotePort = 9081
        settings.tunnels = [tunnel]
        var savedSettings = Settings()
        savedSettings.profile = "ANTERIOR"
        let saved = SavedConnection(id: UUID(), name: "Example agent", snapshot: ConnectionSnapshot(settings: savedSettings), emoji: "🦊")
        settings.savedConnections = [saved]
        settings.selectedSavedConnectionID = saved.id
        let data = try JSONEncoder().encode(ConfigurationArchive(settings: settings, scope: .active))
        let archive = try JSONDecoder().decode(ConfigurationArchive.self, from: data)
        try archive.validate()
        XCTAssertNil(archive.current)
        XCTAssertEqual(archive.savedConnections.count, 1)
        XCTAssertEqual(archive.savedConnections[0].emoji, "🦊")
        XCTAssertEqual(archive.savedConnections[0].snapshot.profile, "EDITADO")
        XCTAssertEqual(archive.savedConnections[0].snapshot.sessionMode, .portForwarding)
        XCTAssertEqual(archive.savedConnections[0].snapshot.region, "eu-madrid-1")
        XCTAssertEqual(archive.savedConnections[0].snapshot.tunnels, [tunnel])
    }

    func testCurrentOnlyExport() throws {
        var settings = Settings()
        settings.profile = "NUEVO"
        let archive = ConfigurationArchive(settings: settings, scope: .active)
        XCTAssertNotNil(archive.current)
        XCTAssertTrue(archive.savedConnections.isEmpty)
        var existing = Settings()
        existing.profile = "VIEJO"
        let saved = SavedConnection(id: UUID(), name: "Guardada", snapshot: ConnectionSnapshot(settings: existing))
        existing.savedConnections = [saved]
        let merged = archive.merged(into: existing)
        XCTAssertEqual(merged.profile, "NUEVO")
        XCTAssertEqual(merged.savedConnections, [saved])
    }

    func testAllExportAndNamedImport() throws {
        var original = Settings()
        original.profile = "ORIGINAL"
        let first = SavedConnection(id: UUID(), name: "Uno", snapshot: ConnectionSnapshot(settings: original))
        original.savedConnections = [first]
        original.selectedSavedConnectionID = first.id
        let all = try JSONDecoder().decode(ConfigurationArchive.self,
                                           from: JSONEncoder().encode(ConfigurationArchive(settings: original, scope: .all)))
        try all.validate()
        XCTAssertEqual(all.current?.profile, "ORIGINAL")
        XCTAssertEqual(all.savedConnections, [first])
        XCTAssertEqual(all.selectedSavedConnectionID, first.id)

        var other = Settings()
        other.profile = "SIN CAMBIAR"
        other.savedConnections = [SavedConnection(id: UUID(), name: "Otra", snapshot: ConnectionSnapshot(settings: other))]
        let merged = ConfigurationArchive(settings: original, scope: .active).merged(into: other)
        XCTAssertEqual(merged.profile, "SIN CAMBIAR")
        XCTAssertEqual(merged.savedConnections?.count, 2)
        XCTAssertEqual(merged.savedConnections?.last?.name, "Uno")
    }

    func testFixtures() throws {
        XCTAssertEqual(try archive("FromScriptArchive.json").savedConnections.count, 2)
        let namedOnly = try archive("NamedOnlyArchive.json")
        XCTAssertNil(namedOnly.current)
        var existing = Settings()
        existing.profile = "PERFIL ACTUAL"
        let merged = namedOnly.merged(into: existing)
        XCTAssertEqual(merged.profile, "PERFIL ACTUAL")
        XCTAssertEqual(merged.savedConnections?.count, 1)
    }

    func testOldSettingsJSONStillDecodes() throws {
        let json = #"{"configPath":"/x","profile":"P","compartmentID":"c","bastionID":"b","publicKeyPath":"/k.pub","privateKeyPath":"/k","socksPort":2222,"ttlSeconds":10800,"proxyHost":"","proxyPort":0,"destinations":[],"ownedSessionID":"s","ownedSessionKeyFingerprint":"f"}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.bastionID, "b")
        XCTAssertEqual(settings.effectiveKeyMode, .custom)
        XCTAssertEqual(settings.effectiveSessionMode, .socks)
    }

    func testRenewMarginIsClampedToSessionLength() {
        var settings = Settings()
        settings.ttlSeconds = 1800
        settings.renewMarginMinutes = 30
        XCTAssertEqual(settings.effectiveRenewMargin, 600)
        settings.ttlSeconds = 10800
        XCTAssertEqual(settings.effectiveRenewMargin, 1800)
        settings.renewMarginMinutes = 1
        XCTAssertEqual(settings.effectiveRenewMargin, 120)
    }
}
