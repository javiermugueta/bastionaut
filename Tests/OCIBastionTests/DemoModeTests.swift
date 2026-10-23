import XCTest
@testable import OCIBastion

@MainActor
final class DemoModeTests: XCTestCase {
    private func realSettings() -> Settings {
        var settings = Settings()
        settings.bastionName = "mi-bastion-real"
        settings.destinations = [Destination(name: "Real", host: "10.9.9.9", privateKeyPath: "/k")]
        settings.hasCompletedOnboarding = true
        return settings
    }

    func testEnterAndExitKeepsRealSettings() {
        let manager = TunnelManager(settings: realSettings(), startServices: false)
        manager.enterDemo()
        XCTAssertTrue(manager.isDemo)
        XCTAssertEqual(manager.settings.bastionName, "bastion-prod")
        XCTAssertEqual(manager.settings.destinations.count, 3)
        XCTAssertNotNil(manager.settings.account, "La demo trae su propia cuenta de ejemplo")
        manager.settings.destinations.removeAll()
        manager.exitDemo()
        XCTAssertFalse(manager.isDemo)
        XCTAssertEqual(manager.settings.bastionName, "mi-bastion-real")
        XCTAssertEqual(manager.settings.destinations.map(\.host), ["10.9.9.9"])
    }

    func testConnectSimulatesUntilConnectedAndDisconnects() async throws {
        let manager = TunnelManager(settings: realSettings(), startServices: false)
        manager.enterDemo()
        manager.connect()
        XCTAssertTrue(manager.isRunning)
        if case .working = manager.overallState {} else { XCTFail("Debería estar trabajando: \(manager.overallState)") }
        for _ in 0..<60 where manager.overallState != .connected {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(manager.overallState, .connected)
        let direct = try XCTUnwrap(manager.settings.tunnels?.first { $0.isDirect })
        XCTAssertEqual(manager.runner(for: direct.id)?.localPort, direct.localPort, "El túnel directo usa el puerto que eligió el usuario")
        XCTAssertNotNil(manager.sessionExpiresAt)
        manager.disconnect()
        XCTAssertEqual(manager.overallState, .idle)
        XCTAssertFalse(manager.isRunning)
    }

    func testDemoCannotStartWhileRealTunnelsRun() {
        let manager = TunnelManager(settings: realSettings(), startServices: false)
        manager.enterDemo()
        manager.enterDemo()
        XCTAssertTrue(manager.isDemo)
        manager.exitDemo()
        manager.exitDemo()
        XCTAssertFalse(manager.isDemo)
    }
}
