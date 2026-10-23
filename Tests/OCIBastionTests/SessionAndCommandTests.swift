import XCTest
@testable import OCIBastion

final class SessionAndCommandTests: XCTestCase {
    private func session(_ id: String, type: String = "DYNAMIC_PORT_FORWARDING", ip: String? = nil, port: Int? = nil,
                         created: Date, ttl: Int = 10800, key: String? = nil, state: String = "ACTIVE") -> OCISession {
        OCISession(id: id, bastionId: "b", displayName: nil, lifecycleState: state, lifecycleDetails: nil,
                   timeCreated: created, sessionTtlInSeconds: ttl,
                   targetResourceDetails: .init(sessionType: type, targetResourcePrivateIpAddress: ip, targetResourcePort: port),
                   keyDetails: key.map { .init(publicKeyContent: $0) }, sshMetadata: nil)
    }

    func testCandidatesFilterByTargetMarginAndExclusions() {
        let now = Date()
        let fresh = session("fresh", created: now.addingTimeInterval(-600))
        let older = session("older", created: now.addingTimeInterval(-3600))
        let expiring = session("expiring", created: now.addingTimeInterval(-10000))
        let otherType = session("pf", type: "PORT_FORWARDING", ip: "10.0.0.1", port: 22, created: now)
        let inactive = session("dead", created: now, state: "DELETED")
        let result = SessionPlanner.candidates([older, expiring, otherType, inactive, fresh], target: .dynamic,
                                               minimumRemaining: 1860, excluding: [], now: now)
        XCTAssertEqual(result.map(\.id), ["fresh", "older"])
        let excluded = SessionPlanner.candidates([fresh, older], target: .dynamic, minimumRemaining: 60,
                                                 excluding: ["fresh"], now: now)
        XCTAssertEqual(excluded.map(\.id), ["older"])
    }

    func testKeyMatchingIgnoresComments() {
        let key = BastionKey(privateKeyPath: "/k", publicKey: "ssh-rsa AAAAB3Nza mi-portatil", ephemeralID: nil)
        let matching = session("s", created: Date(), key: "ssh-rsa AAAAB3Nza ocibastion-temporal\n")
        let other = session("s", created: Date(), key: "ssh-rsa ZZZZ")
        XCTAssertEqual(SessionPlanner.key(for: matching, among: [key]), key)
        XCTAssertNil(SessionPlanner.key(for: other, among: [key]))
    }

    func testRenewalDate() {
        let expires = Date(timeIntervalSince1970: 10000)
        XCTAssertEqual(SessionPlanner.renewalDate(expiresAt: expires, margin: 1800), Date(timeIntervalSince1970: 8200))
        XCTAssertEqual(SessionPlanner.renewalDate(expiresAt: nil, margin: 1800), Date.distantFuture.addingTimeInterval(-1800))
    }

    func testEphemeralKeyLifetime() {
        let now = Date()
        var record = EphemeralKeyRecord(id: UUID(), publicKey: "k", created: now.addingTimeInterval(-7200))
        XCTAssertFalse(SessionKeyStore.isAlive(record, now: now), "Clave sin sesión y vieja: se borra")
        record.expiresAt = now.addingTimeInterval(60)
        XCTAssertTrue(SessionKeyStore.isAlive(record, now: now))
        record.expiresAt = now.addingTimeInterval(-1)
        XCTAssertFalse(SessionKeyStore.isAlive(record, now: now))
    }

    func testSSHErrorClassification() {
        XCTAssertEqual(BastionError.fromSSH("x@y: Permission denied (publickey)."), .sshAuthenticationFailed("x@y: Permission denied (publickey)."))
        XCTAssertTrue(BastionError.fromSSH("bind [127.0.0.1]:2222: Address already in use").requiresIntervention)
        XCTAssertFalse(BastionError.fromSSH("Connection reset by peer").requiresIntervention)
        XCTAssertFalse(BastionError.fromSSH("").requiresIntervention)
    }

    func testAPIErrorsRetryOnlyWhenTransient() {
        XCTAssertTrue(BastionError.api(status: 404, code: "NotAuthorizedOrNotFound", message: "", requestID: nil).requiresIntervention)
        XCTAssertTrue(BastionError.api(status: 401, code: "NotAuthenticated", message: "", requestID: nil).requiresIntervention)
        XCTAssertFalse(BastionError.api(status: 429, code: "TooManyRequests", message: "", requestID: nil).requiresIntervention)
        XCTAssertFalse(BastionError.api(status: 503, code: "ServiceUnavailable", message: "", requestID: nil).requiresIntervention)
        XCTAssertFalse(BastionError.network("offline").requiresIntervention)
        XCTAssertTrue(BastionError.socksNotEnabled(bastion: "b").requiresIntervention)
    }

    func testDestinationCommandForBothRoutes() throws {
        var destination = Destination()
        destination.host = "10.0.0.47"
        destination.privateKeyPath = "/tmp/key"
        let socks = try SSHCommands.destination(destination, route: .socks(port: 20000))
        XCTAssertTrue(socks.contains("'ProxyCommand=/usr/bin/nc -X 5 -x 127.0.0.1:20000 %h %p'"))
        XCTAssertTrue(socks.hasSuffix("-p 22 'opc@10.0.0.47'"))
        let jump = try SSHCommands.destination(destination, route: .jump(localPort: 51234))
        XCTAssertTrue(jump.contains("'HostKeyAlias=10.0.0.47'"))
        XCTAssertTrue(jump.hasSuffix("-p 51234 'opc@127.0.0.1'"))
        XCTAssertFalse(jump.contains("ProxyCommand"))
    }

    func testLocalTunnelCommandForBothRoutes() throws {
        var tunnel = LocalTunnel()
        tunnel.host = "10.0.0.47"
        tunnel.privateKeyPath = "/tmp/example-agent.key"
        tunnel.localPort = 19081
        tunnel.remotePort = 9081
        let socks = try SSHCommands.localTunnel(tunnel, route: .socks(port: 20000))
        XCTAssertTrue(socks.contains("ProxyCommand=/usr/bin/nc -X 5 -x 127.0.0.1:20000 %h %p"))
        XCTAssertTrue(socks.contains("-N -L '127.0.0.1:19081:127.0.0.1:9081'"))
        XCTAssertTrue(socks.contains("'opc@10.0.0.47'"))
        let jump = try SSHCommands.localTunnel(tunnel, route: .jump(localPort: 50001))
        XCTAssertTrue(jump.contains("-N -L '127.0.0.1:19081:127.0.0.1:9081'"))
        XCTAssertTrue(jump.hasSuffix("-p 50001 'opc@127.0.0.1'"))
    }

    func testCommandsRejectInjection() {
        var destination = Destination()
        destination.host = "10.0.0.1; rm -rf ~"
        destination.privateKeyPath = "/k"
        XCTAssertThrowsError(try SSHCommands.destination(destination, route: .socks(port: 2222)))
        destination.host = "-oProxyCommand=evil"
        XCTAssertThrowsError(try SSHCommands.destination(destination, route: .socks(port: 2222)))
    }

    func testBastionArgumentsAndOwnership() throws {
        let token = UUID()
        let target = "ocid1.bastionsession.x@host.bastion.eu-madrid-1.oci.oraclecloud.com"
        let forward = BastionForward.port(localPort: 50001, host: "10.0.0.5", port: 22)
        let arguments = SSHCommands.bastionArguments(target: target, privateKeyPath: "/k", forward: forward, proxy: nil, token: token)
        XCTAssertEqual(Array(arguments.prefix(5)), ["-i", "/k", "-N", "-L", "127.0.0.1:50001:10.0.0.5:22"])
        XCTAssertEqual(arguments.last, target)
        let record = OwnedTunnelRecord(pid: 1, token: token, port: 50001, target: target, forward: forward.arguments.joined(separator: " "))
        let command = "/usr/bin/ssh " + arguments.joined(separator: " ")
        XCTAssertTrue(record.matches(command: command))
        XCTAssertFalse(record.matches(command: command.replacingOccurrences(of: token.uuidString, with: UUID().uuidString)))
        XCTAssertFalse(record.matches(command: command.replacingOccurrences(of: "50001", with: "50002")))

        let copied = try SSHCommands.bastion(target: target, privateKeyPath: "/k", forward: .socks(localPort: 2222),
                                             proxy: try ProxyEndpoint(host: "proxy.corp", port: 80))
        XCTAssertTrue(copied.contains("-D '127.0.0.1:2222'"))
        XCTAssertTrue(copied.contains("ProxyCommand=/usr/bin/nc -X connect -x proxy.corp:80 %h %p"))
    }

    func testLegacyOwnedRecordStillMatchesSocks() {
        let token = UUID()
        let record = OwnedTunnelRecord(pid: 123, token: token, port: 20000, target: "session@bastion.example")
        let command = "/usr/bin/ssh -N -D 127.0.0.1:20000 -o SetEnv=OCIBASTION_TUNNEL_ID=\(token.uuidString) session@bastion.example"
        XCTAssertTrue(record.matches(command: command))
        XCTAssertFalse(record.matches(command: command.replacingOccurrences(of: "20000", with: "20001")))
    }

    func testFreeLocalPortAndDisplayName() {
        let port = OwnedTunnelRecord.freeLocalPort()
        XCTAssertNotNil(port)
        XCTAssertTrue((1024...65535).contains(port ?? 0))
        XCTAssertTrue(ForwardRunner.displayName("Mi BD ñ/1").hasPrefix("OCIBastion-Mi-BD-ñ-1-"))
        XCTAssertTrue(InputCheck.isIPAddress("10.0.0.1"))
        XCTAssertFalse(InputCheck.isIPAddress("db.internal"))
        XCTAssertEqual(19081.formatted(.number.grouping(.never)), "19081")
    }

    func testCountdownFormatting() {
        XCTAssertEqual(CountdownRing.format(3725), "1:02:05")
        XCTAssertEqual(CountdownRing.format(65), "1:05")
    }
}

final class TunnelModelTests: XCTestCase {
    func testDirectTunnelHasNoSSHServer() {
        var tunnel = LocalTunnel()
        tunnel.remoteHost = "10.201.0.89"
        tunnel.remotePort = 3771
        tunnel.localPort = 43771
        XCTAssertTrue(tunnel.isDirect)
        tunnel.host = "  "
        XCTAssertTrue(tunnel.isDirect)
        tunnel.host = "10.201.32.14"
        XCTAssertFalse(tunnel.isDirect)
    }

    func testOldTunnelsKeepTheirServer() throws {
        let json = #"{"id":"6F1E3D52-7C7B-4E64-9A0B-3B7E1C9E2A11","name":"Agente","host":"10.0.0.47","user":"opc","sshPort":22,"privateKeyPath":"/k","localPort":19081,"remoteHost":"127.0.0.1","remotePort":9081}"#
        let tunnel = try JSONDecoder().decode(LocalTunnel.self, from: Data(json.utf8))
        XCTAssertFalse(tunnel.isDirect)
    }
}
