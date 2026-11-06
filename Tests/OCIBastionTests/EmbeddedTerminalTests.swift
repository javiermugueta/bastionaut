import XCTest
@testable import OCIBastion

final class EmbeddedTerminalTests: XCTestCase {
    func testMarkersAreRemovedFromOutput() {
        var bytes = Array("hola".utf8) + SandboxTerminalView.rawModeMarker + Array("adiós".utf8)
        XCTAssertTrue(SandboxTerminalView.remove(SandboxTerminalView.rawModeMarker, from: &bytes))
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "holaadiós")
        XCTAssertFalse(SandboxTerminalView.remove(SandboxTerminalView.rawModeMarker, from: &bytes))
    }

    func testPartialMarkerIsHeldForNextRead() {
        let marker = SandboxTerminalView.echoOffMarker
        var first = Array("Enter passphrase: ".utf8) + marker.prefix(6)
        let held = SandboxTerminalView.splitPartialMarker(&first)
        XCTAssertEqual(String(decoding: first, as: UTF8.self), "Enter passphrase: ")
        var next = held + Array(marker.dropFirst(6))
        XCTAssertTrue(SandboxTerminalView.remove(marker, from: &next))
        XCTAssertTrue(next.isEmpty)
        // Un ESC normal (colores) no se retiene.
        var colored = Array("\u{1B}[0m".utf8)
        XCTAssertTrue(SandboxTerminalView.splitPartialMarker(&colored).isEmpty)
        XCTAssertEqual(colored.count, 4)
    }

    func testRawModeMatchesOpenSSH() {
        var settings = termios()
        settings.c_lflag = tcflag_t(ICANON | ECHO | ISIG)
        settings.c_iflag = tcflag_t(ICRNL | IXON)
        settings.c_oflag = tcflag_t(OPOST)
        SandboxTerminalView.makeRaw(&settings)
        XCTAssertEqual(settings.c_lflag & tcflag_t(ICANON | ECHO | ISIG), 0)
        XCTAssertEqual(settings.c_iflag & tcflag_t(ICRNL | IXON), 0)
        XCTAssertEqual(settings.c_oflag & tcflag_t(OPOST), 0)
        withUnsafeBytes(of: settings.c_cc) { XCTAssertEqual($0[Int(VMIN)], 1) }
    }

    func testInteractiveSSHAsksAppForRawMode() throws {
        let destination = Destination(name: "d", host: "10.0.0.5", privateKeyPath: "/k")
        XCTAssertTrue(try SSHCommands.destination(destination, route: .socks(port: 1080), embedded: true).contains("bastionaut-raw"))
        XCTAssertFalse(try SSHCommands.destination(destination, route: .socks(port: 1080)).contains("LocalCommand"))
    }

    func testAskpassHidesSecretsThroughApp() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("Assets/askpass.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("bastionaut-noecho") && script.contains("bastionaut-echo"))
        XCTAssertFalse(script.contains("stty -echo") || script.contains("stty echo"), "stty no funciona en sandbox")
    }
}
