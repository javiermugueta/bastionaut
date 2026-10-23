import XCTest
@testable import OCIBastion

/// Correcciones de la revisión: proxy explícito, ajustes frescos al reconectar, valores fuera de rango y known_hosts.
final class ReviewFixesTests: XCTestCase {
    // MARK: 1. Proxy automático

    func testAutomaticProxyNeverProbesWPADUnlessEnabledInMacOS() {
        XCTAssertEqual(ProxyResolver.automaticPlan(environment: [:], system: [:]), .direct)
        XCTAssertEqual(ProxyResolver.automaticPlan(environment: [:], system: ["ProxyAutoDiscoveryEnable": 0]), .direct)
        XCTAssertEqual(ProxyResolver.automaticPlan(environment: [:], system: ["ProxyAutoDiscoveryEnable": 1]), .wpad)
    }

    func testAutomaticProxyPrefersExplicitSettings() throws {
        let proxy = try ProxyEndpoint(host: "proxy.corp", port: 3128)
        XCTAssertEqual(ProxyResolver.automaticPlan(environment: ["https_proxy": "http://proxy.corp:3128"], system: ["ProxyAutoDiscoveryEnable": 1]),
                       .endpoint(proxy, source: String(localized: "Variable \("https_proxy")")))
        XCTAssertEqual(ProxyResolver.automaticPlan(environment: [:], system: ["HTTPSEnable": 1, "HTTPSProxy": "proxy.corp", "HTTPSPort": 3128]),
                       .endpoint(proxy, source: String(localized: "Proxy del sistema")))
        XCTAssertEqual(ProxyResolver.automaticPlan(environment: [:], system: ["ProxyAutoConfigEnable": 1,
                                                                              "ProxyAutoConfigURLString": "http://pac.corp/proxy.pac"]),
                       .pac(URL(string: "http://pac.corp/proxy.pac")!))
        XCTAssertEqual(ProxyResolver.automaticPlan(environment: [:], system: ["ProxyAutoConfigEnable": 1,
                                                                              "ProxyAutoConfigURLString": "javascript:alert(1)"]), .direct)
    }

    // MARK: 2. Ajustes al reconectar

    @MainActor
    func testContextUsesCurrentSettingsNotCachedOnes() async throws {
        let pem = String(decoding: try runOpenSSL(["genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048"]), as: UTF8.self)
        let account = OCIAccount(name: "A", tenancy: "t", user: "u", fingerprint: "f", region: "eu-madrid-1")
        let client = try await OCIAPIClient.make(profile: account.profile(privateKeyPEM: pem), proxy: nil)
        var first = Settings()
        first.accounts = [account]
        first.accountID = account.id
        first.bastionID = "ocid1.bastion.test"
        first.ttlSeconds = 10800
        first.keyMode = .ephemeral
        let manager = TunnelManager(settings: first, startServices: false)
        manager.primeSharedContext(.init(client: client, bastion: Showcase.bastion, proxy: nil), for: first)

        var changed = first
        changed.ttlSeconds = 3600
        changed.keyMode = .custom
        changed.renewMarginMinutes = 10
        changed.socksPort = 3333
        XCTAssertEqual(TunnelManager.sharedContextKey(for: first), TunnelManager.sharedContextKey(for: changed))
        let context = try await manager.context(for: changed)
        XCTAssertEqual(context.settings.ttlSeconds, 3600)
        XCTAssertEqual(context.settings.effectiveKeyMode, .custom)
        XCTAssertEqual(context.settings.renewMarginMinutes, 10)
        XCTAssertEqual(context.settings.socksPort, 3333)
    }

    @MainActor
    func testIdleRunnersAreNotReused() {
        let runner = ForwardRunner(id: UUID(), target: .portForward(host: "10.0.0.1", port: 22), label: "x", preferredPort: nil) {
            throw CancellationError()
        }
        XCTAssertFalse(runner.isReusable(for: .portForward(host: "10.0.0.1", port: 22), fixedLocalPort: nil))
        runner.showcase(state: .connected, localPort: 5000, expiresAt: nil, command: nil)
        XCTAssertTrue(runner.isReusable(for: .portForward(host: "10.0.0.1", port: 22), fixedLocalPort: nil))
        XCTAssertTrue(runner.isReusable(for: .portForward(host: "10.0.0.1", port: 22), fixedLocalPort: 5000))
        XCTAssertFalse(runner.isReusable(for: .portForward(host: "10.0.0.1", port: 22), fixedLocalPort: 6000))
        XCTAssertFalse(runner.isReusable(for: .portForward(host: "10.0.0.2", port: 22), fixedLocalPort: nil))
    }

    // MARK: 3. Valores fuera de rango

    func testHugeRenewMarginDoesNotCrash() {
        var settings = Settings()
        settings.renewMarginMinutes = Int.max
        XCTAssertEqual(settings.effectiveRenewMargin, 3600, "180 min limitado por la duración (10800 s / 3)")
        settings.renewMarginMinutes = Int.min
        XCTAssertEqual(settings.effectiveRenewMargin, 120)
    }

    func testImportRejectsOutOfRangeNumbers() throws {
        func archive(_ edit: (inout Settings) -> Void) throws -> ConfigurationArchive {
            var settings = Settings()
            edit(&settings)
            let data = try JSONEncoder().encode(ConfigurationArchive(settings: settings, scope: .active))
            return try JSONDecoder().decode(ConfigurationArchive.self, from: data)
        }
        XCTAssertNoThrow(try archive { _ in }.validate())
        XCTAssertThrowsError(try archive { $0.renewMarginMinutes = 9_223_372_036_854_775_807 }.validate())
        XCTAssertThrowsError(try archive { $0.socksPort = 70000 }.validate())
        XCTAssertThrowsError(try archive { $0.destinations = [Destination(host: "h", port: -1)] }.validate())
        XCTAssertThrowsError(try archive { $0.tunnels = [LocalTunnel(localPort: 99999)] }.validate())
    }

    // MARK: 4. known_hosts con espacios

    func testKnownHostsOptionIsQuoted() {
        XCTAssertEqual(SSHCommands.knownHostsOption("/a b/known_hosts"), #"UserKnownHostsFile="/a b/known_hosts""#)
        let arguments = SSHCommands.bastionArguments(target: "a@b", privateKeyPath: "/k", forward: .socks(localPort: 2222), proxy: nil, token: UUID())
        XCTAssertTrue(arguments.contains(SSHCommands.knownHostsOption(SSHCommands.knownHostsURL.path)))
    }

    /// Con un sshd local de verdad: la huella tiene que acabar en el archivo indicado aunque la ruta lleve espacios.
    func testOpenSSHWritesKnownHostsToPathWithSpaces() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd"), "Sin sshd")
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("kh \(UUID().uuidString.prefix(6))")
        let folder = base.appendingPathComponent("Application Support/OCIBastion")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let hostKey = base.appendingPathComponent("hostkey").path
        _ = try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", hostKey])
        let port = try XCTUnwrap(OwnedTunnelRecord.freeLocalPort())
        let config = base.appendingPathComponent("sshd_config")
        // MaxStartups alto: las comprobaciones de «¿ya escucha?» también cuentan como conexiones a medio abrir.
        let pidFile = base.appendingPathComponent("sshd.pid").path
        try "Port \(port)\nListenAddress 127.0.0.1\nHostKey \"\(hostKey)\"\nPidFile \"\(pidFile)\"\nUsePAM no\nMaxStartups 100\n"
            .write(to: config, atomically: true, encoding: .utf8)
        let sshd = Process()
        sshd.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        sshd.arguments = ["-D", "-f", config.path, "-e"]
        sshd.standardError = Pipe()
        try sshd.run()
        defer { sshd.terminate() }
        for _ in 0..<30 where !OwnedTunnelRecord.isListening(port) { Thread.sleep(forTimeInterval: 0.1) }
        try XCTSkipUnless(OwnedTunnelRecord.isListening(port), "sshd no arrancó")

        let knownHosts = folder.appendingPathComponent("known_hosts")
        let ssh = try runCapturing("/usr/bin/ssh", ["-F", "/dev/null", "-p", String(port), "-o", "BatchMode=yes",
                                                     "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=5",
                                                     "-o", SSHCommands.knownHostsOption(knownHosts.path), "nobody@127.0.0.1", "true"])
        let sshdLog = String(decoding: (sshd.standardError as? Pipe)?.fileHandleForReading.availableData ?? Data(), as: UTF8.self)
        XCTAssertTrue(FileManager.default.fileExists(atPath: knownHosts.path),
                      "La huella debe guardarse en known_hosts.\nssh: \(ssh)\nsshd: \(sshdLog.prefix(600))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("Application").path))
    }

    // MARK: Utilidades

    private func runCapturing(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errors = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func runOpenSSL(_ arguments: [String]) throws -> Data { try run("/usr/bin/openssl", arguments) }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String], check: Bool = true) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if check { XCTAssertEqual(process.terminationStatus, 0, executable) }
        return data
    }
}
