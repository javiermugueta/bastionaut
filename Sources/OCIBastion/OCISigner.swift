import CryptoKit
import Foundation
import Security

/// Firma peticiones con el esquema HTTP Signatures de OCI (rsa-sha256).
/// https://docs.oracle.com/iaas/Content/API/Concepts/signingrequests.htm
struct OCIRequestSigner {
    let keyID: String
    let key: SecKey

    static func make(profile: OCIProfile) async throws -> OCIRequestSigner {
        let key = try await PEMKey.loadRSA(path: profile.keyFile, passphrase: profile.passPhrase)
        if let tokenFile = profile.securityTokenFile {
            guard let token = try? String(contentsOfFile: tokenFile, encoding: .utf8) else {
                throw BastionError.keyFileMissing(path: tokenFile)
            }
            return OCIRequestSigner(keyID: "ST$" + token.trimmingCharacters(in: .whitespacesAndNewlines), key: key)
        }
        return OCIRequestSigner(keyID: "\(profile.tenancy)/\(profile.user)/\(profile.fingerprint)", key: key)
    }

    func sign(_ request: inout URLRequest, date: Date = Date()) throws {
        guard let url = request.url, let host = url.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw BastionError.message(String(localized: "URL de OCI no válida."))
        }
        let method = (request.httpMethod ?? "GET").lowercased()
        var target = components.percentEncodedPath
        if let query = components.percentEncodedQuery, !query.isEmpty { target += "?" + query }

        request.setValue(Self.httpDate(date), forHTTPHeaderField: "date")
        var headers: [(String, String)] = [
            ("date", Self.httpDate(date)),
            ("(request-target)", "\(method) \(target)"),
            ("host", host)
        ]
        if method == "post" || method == "put" || method == "patch" {
            let body = request.httpBody ?? Data()
            let digest = Data(SHA256.hash(data: body)).base64EncodedString()
            let contentType = request.value(forHTTPHeaderField: "content-type") ?? "application/json"
            request.setValue(contentType, forHTTPHeaderField: "content-type")
            request.setValue(String(body.count), forHTTPHeaderField: "content-length")
            request.setValue(digest, forHTTPHeaderField: "x-content-sha256")
            headers += [("content-length", String(body.count)), ("content-type", contentType), ("x-content-sha256", digest)]
        }
        let signingString = headers.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                                    Data(signingString.utf8) as CFData, &error) as Data? else {
            throw BastionError.unsupportedAPIKey(error?.takeRetainedValue().localizedDescription ?? "fallo al firmar")
        }
        let names = headers.map(\.0).joined(separator: " ")
        request.setValue(
            #"Signature version="1",headers="\#(names)",keyId="\#(keyID)",algorithm="rsa-sha256",signature="\#(signature.base64EncodedString())""#,
            forHTTPHeaderField: "authorization")
    }

    static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }
}

enum PEMKey {
    static func loadRSA(path: String, passphrase: String?) async throws -> SecKey {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw BastionError.keyFileMissing(path: path)
        }
        if contents.contains("ENCRYPTED") {
            guard let passphrase else { throw BastionError.apiKeyPassphraseRequired(path: path) }
            // LibreSSL del sistema descifra a PEM en memoria; la contraseña viaja por entorno, no por argumentos.
            var environment = ProcessInfo.processInfo.environment
            environment["OCIBASTION_KEY_PASS"] = passphrase
            let result = try await CommandRunner.run("/usr/bin/openssl",
                ["pkey", "-in", path, "-passin", "env:OCIBASTION_KEY_PASS"], environment: environment)
            guard result.status == 0 else {
                throw BastionError.unsupportedAPIKey(String(localized: "no se pudo descifrar con pass_phrase."))
            }
            return try rsaPrivateKey(pem: result.output)
        }
        return try rsaPrivateKey(pem: contents)
    }

    static func rsaPrivateKey(pem: String) throws -> SecKey {
        let isPKCS8 = pem.contains("BEGIN PRIVATE KEY")
        guard isPKCS8 || pem.contains("BEGIN RSA PRIVATE KEY") else {
            throw BastionError.unsupportedAPIKey(String(localized: "se esperaba una clave RSA en formato PEM."))
        }
        // Solo el bloque BEGIN…END: la consola de OCI añade una línea «OCI_API_KEY» detrás.
        let lines = pem.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let begin = lines.firstIndex(where: { $0.hasPrefix("-----BEGIN") }),
              let end = lines[begin...].firstIndex(where: { $0.hasPrefix("-----END") }) else {
            throw BastionError.unsupportedAPIKey(String(localized: "falta el bloque BEGIN/END del PEM."))
        }
        let base64 = lines[(begin + 1)..<end].filter { !$0.contains(":") }.joined()
        guard let der = Data(base64Encoded: base64) else {
            throw BastionError.unsupportedAPIKey(String(localized: "el PEM no contiene base64 válido."))
        }
        let pkcs1 = isPKCS8 ? try pkcs1FromPKCS8(der) : der
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) else {
            throw BastionError.unsupportedAPIKey(error?.takeRetainedValue().localizedDescription ?? "clave RSA no válida.")
        }
        return key
    }

    /// PrivateKeyInfo ::= SEQUENCE { version INTEGER, algorithm AlgorithmIdentifier, privateKey OCTET STRING }
    static func pkcs1FromPKCS8(_ der: Data) throws -> Data {
        var reader = DERReader(Array(der))
        var sequence = DERReader(try reader.read(tag: 0x30))
        _ = try sequence.read(tag: 0x02)
        var algorithm = DERReader(try sequence.read(tag: 0x30))
        let oid = try algorithm.read(tag: 0x06)
        guard oid == [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01] else {
            throw BastionError.unsupportedAPIKey(String(localized: "solo se admiten claves RSA."))
        }
        return Data(try sequence.read(tag: 0x04))
    }
}

struct DERReader {
    private let bytes: [UInt8]
    private var index = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func read(tag: UInt8) throws -> [UInt8] {
        guard index < bytes.count, bytes[index] == tag else { throw BastionError.unsupportedAPIKey(String(localized: "estructura DER inesperada.")) }
        index += 1
        guard index < bytes.count else { throw BastionError.unsupportedAPIKey(String(localized: "DER truncado.")) }
        var length = Int(bytes[index])
        index += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count <= 4, index + count <= bytes.count else { throw BastionError.unsupportedAPIKey(String(localized: "longitud DER no válida.")) }
            length = bytes[index..<index + count].reduce(0) { $0 << 8 | Int($1) }
            index += count
        }
        guard index + length <= bytes.count else { throw BastionError.unsupportedAPIKey(String(localized: "DER truncado.")) }
        defer { index += length }
        return Array(bytes[index..<index + length])
    }
}
