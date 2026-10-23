import CryptoKit
import Security
import XCTest
@testable import OCIBastion

final class SigningAndConfigTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ocib-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func openssl(_ arguments: [String]) throws -> URL {
        let output = directory.appendingPathComponent(UUID().uuidString + ".pem")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments + ["-out", output.path]
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return output
    }

    private func verify(_ request: URLRequest, key: SecKey) throws -> [String: String] {
        let header = try XCTUnwrap(request.value(forHTTPHeaderField: "authorization"))
        XCTAssertTrue(header.hasPrefix("Signature version=\"1\""))
        var fields: [String: String] = [:]
        let regex = try NSRegularExpression(pattern: #"(\w+)="([^"]*)""#)
        for match in regex.matches(in: header, range: NSRange(header.startIndex..., in: header)) {
            fields[String(header[Range(match.range(at: 1), in: header)!])] = String(header[Range(match.range(at: 2), in: header)!])
        }
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let target = components.percentEncodedPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        let lines = try XCTUnwrap(fields["headers"]).split(separator: " ").map { name -> String in
            switch name {
            case "(request-target)": return "(request-target): \(request.httpMethod!.lowercased()) \(target)"
            case "host": return "host: \(url.host!)"
            default: return "\(name): \(request.value(forHTTPHeaderField: String(name)) ?? "")"
            }
        }
        let signature = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(fields["signature"])))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        XCTAssertTrue(SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                            Data(lines.joined(separator: "\n").utf8) as CFData, signature as CFData, nil))
        return fields
    }

    func testSignsGETWithPKCS8Key() async throws {
        let keyURL = try openssl(["genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048"])
        XCTAssertTrue(try String(contentsOf: keyURL, encoding: .utf8).contains("BEGIN PRIVATE KEY"))
        let key = try await PEMKey.loadRSA(path: keyURL.path, passphrase: nil)
        let signer = OCIRequestSigner(keyID: "ocid1.tenancy/ocid1.user/aa:bb", key: key)
        var request = URLRequest(url: URL(string: "https://bastion.eu-madrid-1.oci.oraclecloud.com/20210331/sessions?bastionId=ocid1.bastion.oc1..x&sessionLifecycleState=ACTIVE")!)
        request.httpMethod = "GET"
        try signer.sign(&request, date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(request.value(forHTTPHeaderField: "date"), "Thu, 01 Jan 1970 00:00:00 GMT")
        let fields = try verify(request, key: key)
        XCTAssertEqual(fields["headers"], "date (request-target) host")
        XCTAssertEqual(fields["keyId"], "ocid1.tenancy/ocid1.user/aa:bb")
        XCTAssertEqual(fields["algorithm"], "rsa-sha256")
    }

    func testSignsPOSTBodyWithPKCS1Key() async throws {
        let keyURL = try openssl(["genrsa", "2048"])
        let key = try await PEMKey.loadRSA(path: keyURL.path, passphrase: nil)
        let signer = OCIRequestSigner(keyID: "k", key: key)
        var request = URLRequest(url: URL(string: "https://query.eu-madrid-1.oci.oraclecloud.com/20180409/resources")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"type":"Structured"}"#.utf8)
        try signer.sign(&request)
        let fields = try verify(request, key: key)
        XCTAssertEqual(fields["headers"], "date (request-target) host content-length content-type x-content-sha256")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-content-sha256"),
                       Data(SHA256.hash(data: request.httpBody!)).base64EncodedString())
        XCTAssertEqual(request.value(forHTTPHeaderField: "content-length"), String(request.httpBody!.count))
    }

    func testConsoleKeyWithTrailingMarker() async throws {
        let keyURL = try openssl(["genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048"])
        let contents = try String(contentsOf: keyURL, encoding: .utf8) + "OCI_API_KEY\n"
        try contents.write(to: keyURL, atomically: true, encoding: .utf8)
        _ = try await PEMKey.loadRSA(path: keyURL.path, passphrase: nil)
    }

    func testEncryptedKeyNeedsPassphrase() async throws {
        let keyURL = try openssl(["genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048",
                                  "-aes256", "-pass", "pass:secreto"])
        do {
            _ = try await PEMKey.loadRSA(path: keyURL.path, passphrase: nil)
            XCTFail("Debería pedir pass_phrase")
        } catch let error as BastionError {
            XCTAssertEqual(error, .apiKeyPassphraseRequired(path: keyURL.path))
        }
        _ = try await PEMKey.loadRSA(path: keyURL.path, passphrase: "secreto")
    }

    func testConfigInheritsDefaultAndExpandsTilde() throws {
        let config = directory.appendingPathComponent("config")
        try """
        [DEFAULT]
        tenancy=ocid1.tenancy.oc1..t
        region=eu-madrid-1
        key_file=~/.oci/key.pem
        # comentario
        user=ocid1.user.oc1..default
        fingerprint=aa

        [OTRO]
        user = ocid1.user.oc1..otro
        fingerprint = bb
        region = eu-frankfurt-1

        [TOKEN]
        security_token_file=~/.oci/sessions/token
        """.write(to: config, atomically: true, encoding: .utf8)
        XCTAssertEqual(try OCIConfig.profiles(at: config.path), ["DEFAULT", "OTRO", "TOKEN"])
        let other = try OCIConfig.load(at: config.path, profile: "OTRO")
        XCTAssertEqual(other.tenancy, "ocid1.tenancy.oc1..t")
        XCTAssertEqual(other.user, "ocid1.user.oc1..otro")
        XCTAssertEqual(other.region, "eu-frankfurt-1")
        XCTAssertEqual(other.keyFile, NSHomeDirectory() + "/.oci/key.pem")
        let token = try OCIConfig.load(at: config.path, profile: "TOKEN")
        XCTAssertEqual(token.securityTokenFile, NSHomeDirectory() + "/.oci/sessions/token")
        XCTAssertThrowsError(try OCIConfig.load(at: config.path, profile: "NOPE")) { error in
            XCTAssertEqual(error as? BastionError, .profileNotFound("NOPE"))
        }
    }

    func testMissingFieldIsReported() throws {
        let config = directory.appendingPathComponent("config")
        try "[A]\ntenancy=t\nregion=r\nkey_file=/k\n".write(to: config, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try OCIConfig.load(at: config.path, profile: "A")) { error in
            XCTAssertEqual(error as? BastionError, .profileMissingField(profile: "A", field: "user"))
        }
    }

    func testRealmHosts() {
        XCTAssertEqual(OCIRealm.host("bastion", region: "eu-madrid-1"), "bastion.eu-madrid-1.oci.oraclecloud.com")
        XCTAssertEqual(OCIRealm.host("query", region: "us-gov-ashburn-1"), "query.us-gov-ashburn-1.oci.oraclegovcloud.com")
        XCTAssertEqual(OCIRealm.host("identity", region: "eu-madrid-2"), "identity.eu-madrid-2.oci.oraclecloud.eu")
    }

    func testSessionDecodingFromAPI() throws {
        let json = """
        {"id":"ocid1.bastionsession.oc1.eu-madrid-1.abc","bastionId":"ocid1.bastion.x","displayName":"OCIBastion-x",
         "lifecycleState":"ACTIVE","timeCreated":"2026-10-23T10:00:00.123Z","sessionTtlInSeconds":10800,
         "targetResourceDetails":{"sessionType":"PORT_FORWARDING","targetResourcePrivateIpAddress":"10.0.0.5","targetResourcePort":22},
         "keyDetails":{"publicKeyContent":"ssh-rsa AAAA test"},
         "sshMetadata":{"command":"ssh -i <privateKey> -N -L <localPort>:10.0.0.5:22 -p 22 ocid1.bastionsession.oc1.eu-madrid-1.abc@host.bastion.eu-madrid-1.oci.oraclecloud.com"}}
        """
        let session = try OCIAPIClient.decoder.decode(OCISession.self, from: Data(json.utf8))
        XCTAssertEqual(session.sshTarget, "ocid1.bastionsession.oc1.eu-madrid-1.abc@host.bastion.eu-madrid-1.oci.oraclecloud.com")
        XCTAssertEqual(session.expiresAt, OCIAPIClient.parseDate("2026-10-23T13:00:00.123Z"))
        XCTAssertTrue(SessionTarget.portForward(host: "10.0.0.5", port: 22).matches(session))
        XCTAssertFalse(SessionTarget.portForward(host: "10.0.0.5", port: 2222).matches(session))
        XCTAssertFalse(SessionTarget.dynamic.matches(session))
    }

    func testCreateSessionBodyUsesFQDNForHostnames() throws {
        let data = try JSONEncoder().encode(SessionTarget.portForward(host: "db.internal", port: 1521).ociDetails)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["targetResourceFqdn"] as? String, "db.internal")
        XCTAssertNil(object?["targetResourcePrivateIpAddress"])
        XCTAssertEqual(SessionTarget.dynamic.ociDetails.sessionType, "DYNAMIC_PORT_FORWARDING")
    }
}

/// Lecturas contra OCI de verdad. Solo con `OCIB_LIVE=1` (y opcionalmente `OCIB_PROFILE`).
final class LiveOCITests: XCTestCase {
    func testReadOnlyCalls() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["OCIB_LIVE"] == "1", "Define OCIB_LIVE=1 para probar contra OCI")
        let profile = try OCIConfig.load(at: OCIConfig.defaultPath, profile: environment["OCIB_PROFILE"] ?? "DEFAULT")
        let client = try await OCIAPIClient.make(profile: profile, proxy: nil)
        let regions = try await client.regionSubscriptions()
        XCTAssertFalse(regions.isEmpty)
        let bastions = try await client.searchBastions()
        print("🌍 regiones: \(regions.map(\.regionName)); 🏰 bastiones en \(client.region): \(bastions.count)")
        if let first = bastions.first {
            let details = try await client.getBastion(id: first.id)
            let sessions = try await client.listActiveSessions(bastionID: first.id)
            print("🏰 \(details.name): SOCKS5=\(details.supportsSOCKS) ttlMax=\(details.maxSessionTtlInSeconds ?? 0) sesiones activas=\(sessions.count)")
        }
    }
}
