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

    private func fetch(_ port: Int) async throws -> String {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/"))
        let (data, _) = try await URLSession(configuration: .ephemeral).data(from: url)
        return String(decoding: data, as: UTF8.self)
    }

    func testDirectTunnelReallyListensOnLocalhostUntilDisconnect() async throws {
        let manager = TunnelManager(settings: realSettings(), startServices: false)
        manager.enterDemo()
        manager.connect()
        for _ in 0..<60 where manager.overallState != .connected {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let direct = try XCTUnwrap(manager.settings.tunnels?.first { $0.isDirect })
        let port = try XCTUnwrap(manager.runner(for: direct.id)?.localPort)
        let page = try await fetch(port)
        XCTAssertTrue(page.contains("localhost:\(direct.localPort) → \(direct.remoteHost):\(direct.remotePort)"), page)
        manager.disconnect()
        try await Task.sleep(nanoseconds: 200_000_000)
        do {
            _ = try await fetch(port)
            XCTFail("Al desconectar, el puerto debería cerrarse")
        } catch {}
        manager.exitDemo()
    }

    func testServerFallsBackToAFreePortWhenBusy() async throws {
        let first = DemoTunnelServer()
        let busyPort = await first.serve(id: UUID(), preferredPort: 0, page: "uno")
        let busy = try XCTUnwrap(busyPort)
        let second = DemoTunnelServer()
        let otherPort = await second.serve(id: UUID(), preferredPort: busy, page: "<b>dos</b>")
        let other = try XCTUnwrap(otherPort)
        XCTAssertNotEqual(other, busy)
        let firstPage = try await fetch(busy)
        let secondPage = try await fetch(other)
        XCTAssertEqual(firstPage, "uno")
        XCTAssertEqual(secondPage, "<b>dos</b>")
        first.stopAll()
        second.stopAll()
    }

    func testPageEscapesNames() {
        let page = DemoTunnelServer.page(name: "<script>", localPort: 1, remoteHost: "10.0.0.1", remotePort: 2)
        XCTAssertFalse(page.contains("<script>"))
        XCTAssertTrue(page.contains("&lt;script&gt;"))
    }
}
