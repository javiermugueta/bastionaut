import CryptoKit
import Foundation
import Security

/// Cuenta de OCI guardada en la app. La clave privada no está aquí: vive en el Llavero.
struct OCIAccount: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String = ""
    var tenancy: String = ""
    var user: String = ""
    var fingerprint: String = ""
    var region: String = ""

    var displayName: String { name.isEmpty ? String(tenancy.suffix(10)) : name }

    func profile(privateKeyPEM: String) -> OCIProfile {
        OCIProfile(name: displayName, tenancy: tenancy, user: user, fingerprint: fingerprint,
                   keyFile: "", region: region, keyPEM: privateKeyPEM)
    }

    /// Rellena los campos a partir del fragmento `[DEFAULT] user=… fingerprint=…` que muestra la consola de OCI.
    mutating func fill(fromSnippet text: String) -> Bool {
        guard let values = OCIConfig.parse(text).values.first ?? Self.looseValues(text) else { return false }
        var changed = false
        func take(_ key: String, _ path: WritableKeyPath<OCIAccount, String>) {
            if let value = values[key], !value.isEmpty { self[keyPath: path] = value; changed = true }
        }
        take("tenancy", \.tenancy)
        take("user", \.user)
        take("fingerprint", \.fingerprint)
        take("region", \.region)
        return changed
    }

    /// Fragmento pegado sin la cabecera `[DEFAULT]`.
    private static func looseValues(_ text: String) -> [String: String]? {
        let values = OCIConfig.parse("[_]\n" + text)["_"] ?? [:]
        return values.isEmpty ? nil : values
    }
}

/// Clave privada de API validada y lista para guardar.
struct ImportedAPIKey: Equatable {
    let pem: String
    let fingerprint: String
}

enum APIKeyImport {
    /// Valida la clave (descifrándola si trae contraseña) y calcula su huella de OCI.
    static func prepare(pem rawPEM: String, passphrase: String?) async throws -> ImportedAPIKey {
        var pem = rawPEM.trimmingCharacters(in: .whitespacesAndNewlines)
        if pem.contains("ENCRYPTED") {
            guard let passphrase, !passphrase.isEmpty else {
                throw BastionError.apiKeyPassphraseRequired(path: String(localized: "la clave pegada"))
            }
            // openssl necesita un archivo: uno temporal y privado, que se borra al momento.
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pem")
            FileManager.default.createFile(atPath: url.path, contents: Data(pem.utf8), attributes: [.posixPermissions: 0o600])
            defer { try? FileManager.default.removeItem(at: url) }
            var environment = ProcessInfo.processInfo.environment
            environment["OCIBASTION_KEY_PASS"] = passphrase
            let result = try await CommandRunner.run("/usr/bin/openssl",
                ["pkey", "-in", url.path, "-passin", "env:OCIBASTION_KEY_PASS"], environment: environment)
            guard result.status == 0 else { throw BastionError.unsupportedAPIKey(String(localized: "no se pudo descifrar con pass_phrase.")) }
            pem = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let key = try PEMKey.rsaPrivateKey(pem: pem)
        return ImportedAPIKey(pem: pem, fingerprint: try PEMKey.ociFingerprint(of: key))
    }
}

extension PEMKey {
    /// Huella de OCI: MD5 de la clave pública en DER (SubjectPublicKeyInfo), en hexadecimal separado por «:».
    static func ociFingerprint(of privateKey: SecKey) throws -> String {
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw BastionError.unsupportedAPIKey(String(localized: "no se pudo obtener la clave pública."))
        }
        let algorithm: [UInt8] = [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]
        let bitString = DER.encode(tag: 0x03, [0x00] + Array(pkcs1))
        let spki = DER.encode(tag: 0x30, algorithm + bitString)
        return Insecure.MD5.hash(data: Data(spki)).map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

enum DER {
    static func encode(tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        let length = content.count
        if length < 0x80 { return [tag, UInt8(length)] + content }
        var bytes: [UInt8] = []
        var value = length
        while value > 0 { bytes.insert(UInt8(value & 0xFF), at: 0); value >>= 8 }
        return [tag, 0x80 | UInt8(bytes.count)] + bytes + content
    }
}

/// Claves privadas de API en el Llavero de macOS, una entrada por cuenta.
enum APIKeyKeychain {
    private static let service = "OCIBastion.api-key"

    static func save(_ pem: String, for account: UUID) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: account.uuidString]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData] = Data(pem.utf8)
        attributes[kSecAttrLabel] = "Bastionaut – clave de API"
        attributes[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BastionError.message(String(localized: "No se pudo guardar la clave en el Llavero (\(status))."))
        }
    }

    static func load(for account: UUID) throws -> String {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: account.uuidString, kSecReturnData: true,
                                      kSecMatchLimit: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw BastionError.message(String(localized: "No encuentro la clave de API de esta cuenta en el Llavero. Vuelve a añadirla con el asistente ✨."))
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func delete(for account: UUID) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: account.uuidString]
        SecItemDelete(query as CFDictionary)
    }
}
