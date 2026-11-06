import XCTest
@testable import OCIBastion

final class AccountAndSandboxTests: XCTestCase {
    private func run(_ executable: String, _ arguments: [String], input: Data? = nil) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        if let input {
            let stdin = Pipe()
            process.standardInput = stdin
            try process.run()
            stdin.fileHandleForWriting.write(input)
            try stdin.fileHandleForWriting.close()
        } else {
            try process.run()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return data
    }

    func testFingerprintMatchesOpenSSL() async throws {
        let pem = String(decoding: try run("/usr/bin/openssl", ["genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048"]), as: UTF8.self)
        let der = try run("/usr/bin/openssl", ["pkey", "-pubout", "-outform", "DER"], input: Data(pem.utf8))
        let expected = String(decoding: try run("/usr/bin/openssl", ["md5", "-c"], input: der), as: UTF8.self)
            .split(separator: " ").last.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let imported = try await APIKeyImport.prepare(pem: pem, passphrase: nil)
        XCTAssertEqual(imported.fingerprint, expected)
        XCTAssertEqual(imported.fingerprint.split(separator: ":").count, 16)
    }

    func testEncryptedKeyIsDecryptedOnImport() async throws {
        let pem = String(decoding: try run("/usr/bin/openssl", ["genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048",
                                                                 "-aes256", "-pass", "pass:secreto"]), as: UTF8.self)
        do {
            _ = try await APIKeyImport.prepare(pem: pem, passphrase: nil)
            XCTFail("Debería pedir la contraseña")
        } catch {}
        let imported = try await APIKeyImport.prepare(pem: pem, passphrase: "secreto")
        XCTAssertFalse(imported.pem.contains("ENCRYPTED"))
        _ = try PEMKey.rsaPrivateKey(pem: imported.pem)
    }

    func testFillFromConsoleSnippet() {
        var account = OCIAccount()
        let snippet = """
        [DEFAULT]
        user=ocid1.user.oc1..aaaa
        fingerprint=12:34:56
        tenancy=ocid1.tenancy.oc1..bbbb
        region=eu-amsterdam-1
        key_file=<path to your private keyfile> # TODO
        """
        XCTAssertTrue(account.fill(fromSnippet: snippet))
        XCTAssertEqual(account.user, "ocid1.user.oc1..aaaa")
        XCTAssertEqual(account.tenancy, "ocid1.tenancy.oc1..bbbb")
        XCTAssertEqual(account.fingerprint, "12:34:56")
        XCTAssertEqual(account.region, "eu-amsterdam-1")

        var loose = OCIAccount()
        XCTAssertTrue(loose.fill(fromSnippet: "tenancy=ocid1.tenancy.oc1..cccc\nregion=eu-madrid-1"))
        XCTAssertEqual(loose.tenancy, "ocid1.tenancy.oc1..cccc")
        XCTAssertFalse(loose.fill(fromSnippet: "nada útil aquí"))
    }

    func testAccountProfileUsesInMemoryKey() {
        let account = OCIAccount(name: "Mi tenancy", tenancy: "t", user: "u", fingerprint: "f", region: "eu-madrid-1")
        let profile = account.profile(privateKeyPEM: "PEM")
        XCTAssertEqual(profile.keyPEM, "PEM")
        XCTAssertEqual(profile.region, "eu-madrid-1")
    }

    func testAccountTravelsWithTheConnection() {
        var settings = Settings()
        XCTAssertNil(settings.account)
        let account = OCIAccount(name: "A", tenancy: "t", user: "u", fingerprint: "f", region: "r")
        settings.accounts = [account]
        settings.accountID = account.id
        XCTAssertEqual(settings.account, account)
        var restored = Settings()
        ConnectionSnapshot(settings: settings).apply(to: &restored)
        XCTAssertEqual(restored.accountID, account.id)
    }

    func testOldSettingsWithCredentialSourceStillDecode() throws {
        let json = #"{"configPath":"/x","profile":"P","compartmentID":"","bastionID":"b","publicKeyPath":"","privateKeyPath":"","socksPort":2222,"ttlSeconds":10800,"proxyHost":"","proxyPort":0,"destinations":[],"credentialSource":"configFile"}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.bastionID, "b")
        XCTAssertNil(settings.account)
    }

    /// `ssh -G` resuelve la configuración sin conectar: comprueba lo que usará de verdad el terminal integrado.
    func testEmbeddedSSHUsesAppKnownHosts() throws {
        let key = FileManager.default.temporaryDirectory.appendingPathComponent("clave \(UUID().uuidString)")
        try "x".write(to: key, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: key) }
        let destination = Destination(name: "d", host: "10.0.0.5", privateKeyPath: key.path)
        func resolved(_ command: String) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command.replacingOccurrences(of: "ssh ", with: "/usr/bin/ssh -G ", options: .anchored)]
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = Pipe()
            try process.run(); process.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        let embedded = try resolved(SSHCommands.destination(destination, route: .jump(localPort: 2201), embedded: true))
        // Un único archivo (la ruta lleva espacios) y la clave tal cual.
        XCTAssertTrue(embedded.contains("userknownhostsfile \(SSHCommands.knownHostsURL.path)\n"), embedded)
        XCTAssertTrue(embedded.contains("identityfile \(key.path)\n"), embedded)
        XCTAssertFalse(try SSHCommands.destination(destination, route: .socks(port: 1080)).contains("UserKnownHostsFile"))
        var tunnel = LocalTunnel()
        tunnel.host = "10.0.0.6"; tunnel.user = "opc"; tunnel.remoteHost = "db"; tunnel.privateKeyPath = "/k"
        tunnel.sshPort = 22; tunnel.localPort = 15432; tunnel.remotePort = 5432
        XCTAssertTrue(try SSHCommands.localTunnel(tunnel, route: .socks(port: 1080), embedded: true).hasPrefix("ssh -F /dev/null -o "))
    }

    func testBastionSSHUsesOwnKnownHosts() {
        let arguments = SSHCommands.bastionArguments(target: "a@b", privateKeyPath: "/k", forward: .socks(localPort: 2222),
                                                     proxy: nil, token: UUID())
        XCTAssertTrue(arguments.contains("-F"))
        XCTAssertTrue(arguments.contains { $0.hasPrefix("UserKnownHostsFile=\"") && $0.hasSuffix("/OCIBastion/known_hosts\"") })
    }

    func testEntitlementsHaveNoAppleEvents() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["OCIBastion.entitlements", "OCIBastion.appstore.entitlements"] {
            let text = try String(contentsOf: root.appendingPathComponent("Assets/\(name)"), encoding: .utf8)
            XCTAssertFalse(text.contains("apple-events"), name)
        }
    }

    func testEmbeddedTerminalRunsCommandThroughShell() throws {
        let command = #"ssh -i '/a b/"k"' -o 'ProxyCommand=nc \x' user@host"#
        let launch = TerminalWindows.launch(command: command)
        XCTAssertEqual(launch.executable, "/bin/sh")
        XCTAssertEqual(launch.args, ["-c", command])
        // El shell recibe exactamente el comando que se copia al portapapeles.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = ["-c", "printf '%s|' " + "'/a b/\"k\"' 'ProxyCommand=nc \\x'"]
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), #"/a b/"k"|ProxyCommand=nc \x|"#)
    }

    func testPortProbes() throws {
        let port = try XCTUnwrap(OwnedTunnelRecord.freeLocalPort())
        XCTAssertTrue(OwnedTunnelRecord.isPortFree(port))
        XCTAssertFalse(OwnedTunnelRecord.isListening(port))
        let listener = Process()
        listener.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        listener.arguments = ["-l", "127.0.0.1", String(port)]
        try listener.run()
        defer { listener.terminate() }
        var listening = false
        for _ in 0..<30 where !listening {
            Thread.sleep(forTimeInterval: 0.1)
            listening = OwnedTunnelRecord.isListening(port)
        }
        XCTAssertTrue(listening)
        XCTAssertFalse(OwnedTunnelRecord.isPortFree(port))
    }

    func testCFProxyEntriesBecomeEndpoints() throws {
        XCTAssertEqual(ProxyResolver.endpoint(fromCFProxy: [kCFProxyHostNameKey as String: "proxy.corp",
                                                            kCFProxyPortNumberKey as String: NSNumber(value: 8080)]),
                       try ProxyEndpoint(host: "proxy.corp", port: 8080))
        XCTAssertNil(ProxyResolver.endpoint(fromCFProxy: [kCFProxyHostNameKey as String: "proxy.corp"]))
        XCTAssertNil(ProxyResolver.endpoint(fromCFProxy: [kCFProxyHostNameKey as String: "-oProxyCommand=x",
                                                          kCFProxyPortNumberKey as String: NSNumber(value: 80)]))
    }

    func testPortInUseMessageWithoutPID() {
        XCTAssertTrue(BastionError.portInUse(port: 2222, pid: nil).localizedDescription.contains("2222"))
        XCTAssertTrue(BastionError.portInUse(port: 2222, pid: 42).localizedDescription.contains("42"))
    }
}
