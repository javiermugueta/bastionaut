import XCTest
@testable import OCIBastion

final class ReachabilityTests: XCTestCase {
    func testCIDRMatching() {
        XCTAssertEqual(PublicIP.isAllowed("83.45.10.7", by: ["83.45.10.0/24"]), true)
        XCTAssertEqual(PublicIP.isAllowed("83.45.11.7", by: ["83.45.10.0/24", "10.0.0.0/8"]), false)
        XCTAssertEqual(PublicIP.isAllowed("1.2.3.4", by: ["0.0.0.0/0"]), true)
        XCTAssertEqual(PublicIP.isAllowed("1.2.3.4", by: ["1.2.3.4"]), true)
        XCTAssertNil(PublicIP.isAllowed("1.2.3.4", by: ["2001:db8::/32"]))
        XCTAssertNil(PublicIP.isAllowed("2001:db8::1", by: ["1.2.3.0/24"]))
        XCTAssertTrue(PublicIP.report(ip: "83.45.11.7", allowList: ["83.45.10.0/24"]).hasPrefix("❌"))
    }

    func testConnectionFailuresAreRecognised() {
        XCTAssertTrue(BastionError.isConnectionFailure("ssh: connect to host host.bastion.eu-amsterdam-1.oci.oraclecloud.com port 22: Operation timed out"))
        XCTAssertTrue(BastionError.isConnectionFailure("kex_exchange_identification: Connection closed by remote host"))
        XCTAssertFalse(BastionError.isConnectionFailure("Permission denied (publickey)."))
    }

    func testUnreachableMessageExplainsAllowList() {
        let error = BastionError.bastionUnreachable(detail: "Operation timed out", allowList: ["83.45.10.0/24"])
        XCTAssertTrue(error.requiresIntervention)
        XCTAssertTrue(error.userMessage.contains("83.45.10.0/24"))
        XCTAssertTrue(error.userMessage.contains("💡"))
    }

    func testFreshSessionWindow() {
        let now = Date()
        func lease(createdAgo seconds: TimeInterval) -> SessionLease {
            SessionLease(session: OCISession(id: "s", bastionId: nil, displayName: nil, lifecycleState: "ACTIVE",
                                             lifecycleDetails: nil, timeCreated: now.addingTimeInterval(-seconds),
                                             sessionTtlInSeconds: 10800, targetResourceDetails: nil, keyDetails: nil,
                                             sshMetadata: nil),
                         key: BastionKey(privateKeyPath: "/k", publicKey: "k", ephemeralID: nil), sshTarget: "a@b")
        }
        XCTAssertTrue(ForwardRunner.isFresh(lease(createdAgo: 10), now: now))
        XCTAssertFalse(ForwardRunner.isFresh(lease(createdAgo: 600), now: now))
        XCTAssertFalse(ForwardRunner.isFresh(nil, now: now))
    }

    func testBastionSSHHasConnectTimeout() {
        let arguments = SSHCommands.bastionArguments(target: "a@b", privateKeyPath: "/k", forward: .socks(localPort: 2222),
                                                     proxy: nil, token: UUID())
        XCTAssertTrue(arguments.contains("ConnectTimeout=20"))
    }
}
