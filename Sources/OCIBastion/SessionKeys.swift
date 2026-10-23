import Foundation

/// Par de claves con el que se firma una sesión del Bastion.
struct BastionKey: Equatable {
    let privateKeyPath: String
    let publicKey: String
    /// Identificador si la clave es temporal y la gestiona `SessionKeyStore`.
    let ephemeralID: UUID?
}

struct EphemeralKeyRecord: Codable, Equatable {
    let id: UUID
    let publicKey: String
    let created: Date
    var sessionIDs: [String] = []
    var expiresAt: Date?
}

/// Claves temporales: una por sesión, en Application Support con permisos 0600 y borradas al caducar.
@MainActor
enum SessionKeyStore {
    /// Tiempo que se conserva una clave nunca usada (p. ej. si falló la creación de la sesión).
    nonisolated static let unusedKeyLifetime: TimeInterval = 3600

    static var directory: URL {
        Settings.fileURL.deletingLastPathComponent().appendingPathComponent("keys", isDirectory: true)
    }

    private static var indexURL: URL { directory.appendingPathComponent("index.json") }

    static func privateKeyURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString) }

    static func records() -> [EphemeralKeyRecord] {
        guard let data = try? Data(contentsOf: indexURL),
              let value = try? JSONDecoder().decode([EphemeralKeyRecord].self, from: data) else { return [] }
        return value
    }

    private static func write(_ records: [EphemeralKeyRecord]) throws {
        try ensureDirectory()
        try JSONEncoder().encode(records).write(to: indexURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
    }

    private static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    /// Claves temporales todavía utilizables.
    static func validKeys(now: Date = Date()) -> [BastionKey] {
        records().filter { isAlive($0, now: now) }.compactMap { record in
            let url = privateKeyURL(record.id)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return BastionKey(privateKeyPath: url.path, publicKey: record.publicKey, ephemeralID: record.id)
        }
    }

    static func generate() async throws -> BastionKey {
        try ensureDirectory()
        let id = UUID()
        let url = privateKeyURL(id)
        // RSA porque es el tipo que OCI Bastion acepta en todas las regiones.
        let result = try await CommandRunner.run("/usr/bin/ssh-keygen", [
            "-q", "-t", "rsa", "-b", "3072", "-N", "", "-C", "ocibastion-temporal", "-f", url.path
        ])
        _ = try CommandRunner.requireSuccess(result, label: "No se pudo generar la clave temporal")
        let publicURL = url.appendingPathExtension("pub")
        let publicKey = try String(contentsOf: publicURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        try? FileManager.default.removeItem(at: publicURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var all = records()
        all.append(EphemeralKeyRecord(id: id, publicKey: publicKey, created: Date()))
        try write(all)
        return BastionKey(privateKeyPath: url.path, publicKey: publicKey, ephemeralID: id)
    }

    /// Asocia la clave a una sesión: vivirá mientras viva la sesión más duradera que la use.
    static func attach(_ key: BastionKey, sessionID: String, expiresAt: Date?) {
        guard let id = key.ephemeralID else { return }
        var all = records()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        if !all[index].sessionIDs.contains(sessionID) { all[index].sessionIDs.append(sessionID) }
        if let expiresAt { all[index].expiresAt = max(all[index].expiresAt ?? expiresAt, expiresAt) }
        try? write(all)
    }

    /// Borra claves caducadas o huérfanas. Devuelve cuántas eliminó.
    @discardableResult
    static func prune(now: Date = Date()) -> Int {
        let all = records()
        let (alive, dead) = (all.filter { isAlive($0, now: now) }, all.filter { !isAlive($0, now: now) })
        for record in dead { try? FileManager.default.removeItem(at: privateKeyURL(record.id)) }
        if !dead.isEmpty { try? write(alive) }
        return dead.count
    }

    nonisolated static func isAlive(_ record: EphemeralKeyRecord, now: Date) -> Bool {
        if let expiresAt = record.expiresAt { return expiresAt > now }
        return record.created.addingTimeInterval(unusedKeyLifetime) > now
    }
}

enum KeyValidation {
    static func fingerprint(path: String) async throws -> String {
        guard FileManager.default.fileExists(atPath: path) else { throw BastionError.keyFileMissing(path: path) }
        let result = try await CommandRunner.run("/usr/bin/ssh-keygen", ["-l", "-E", "sha256", "-f", path])
        let output = try CommandRunner.requireSuccess(result, label: "No se pudo leer la clave SSH")
        guard let value = output.split(whereSeparator: \.isWhitespace).dropFirst().first else {
            throw BastionError.message("No se pudo obtener la huella de la clave SSH.")
        }
        return String(value)
    }

    static func customKey(publicPath: String, privatePath: String) async throws -> BastionKey {
        let publicFingerprint = try await fingerprint(path: publicPath)
        let privateFingerprint = try await fingerprint(path: privatePath)
        guard publicFingerprint == privateFingerprint else { throw BastionError.keyPairMismatch }
        let publicKey = try String(contentsOfFile: publicPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return BastionKey(privateKeyPath: privatePath, publicKey: publicKey, ephemeralID: nil)
    }
}

/// Hacia dónde apunta una sesión del Bastion.
enum SessionTarget: Equatable, Hashable {
    case dynamic
    case portForward(host: String, port: Int)

    var ociDetails: OCISession.Target {
        switch self {
        case .dynamic:
            return .init(sessionType: "DYNAMIC_PORT_FORWARDING")
        case .portForward(let host, let port):
            return InputCheck.isIPAddress(host)
                ? .init(sessionType: "PORT_FORWARDING", targetResourcePrivateIpAddress: host, targetResourcePort: port)
                : .init(sessionType: "PORT_FORWARDING", targetResourcePort: port, targetResourceFqdn: host)
        }
    }

    func matches(_ session: OCISession) -> Bool {
        guard let details = session.targetResourceDetails else { return false }
        switch self {
        case .dynamic:
            return details.sessionType == "DYNAMIC_PORT_FORWARDING"
        case .portForward(let host, let port):
            return details.sessionType == "PORT_FORWARDING" && details.targetResourcePort == port &&
                (details.targetResourcePrivateIpAddress == host || details.targetResourceFqdn == host)
        }
    }
}

enum SessionPlanner {
    /// Normaliza «tipo base64 comentario» a «tipo base64» para comparar claves públicas.
    static func normalized(_ publicKey: String) -> String {
        publicKey.split(whereSeparator: \.isWhitespace).prefix(2).joined(separator: " ")
    }

    /// Sesiones de la lista que merece la pena consultar en detalle: mismo destino, activas,
    /// con margen suficiente y no descartadas por fallos previos.
    static func candidates(_ sessions: [OCISession], target: SessionTarget, minimumRemaining: TimeInterval,
                           excluding: Set<String>, now: Date = Date()) -> [OCISession] {
        sessions.filter { session in
            session.lifecycleState == "ACTIVE" && target.matches(session) && !excluding.contains(session.id) &&
                hasRemaining(session, minimumRemaining, now: now, unknown: true)
        }.sorted { ($0.expiresAt ?? .distantPast) > ($1.expiresAt ?? .distantPast) }
    }

    /// Si el resumen no trae caducidad se decide con `unknown`; el detalle de la sesión sí la incluye.
    static func hasRemaining(_ session: OCISession, _ minimum: TimeInterval, now: Date = Date(), unknown: Bool = false) -> Bool {
        session.expiresAt.map { $0 > now.addingTimeInterval(minimum) } ?? unknown
    }

    /// Clave local capaz de abrir la sesión, si la tenemos.
    static func key(for session: OCISession, among keys: [BastionKey]) -> BastionKey? {
        guard let content = session.keyDetails?.publicKeyContent else { return nil }
        let wanted = normalized(content)
        return keys.first { normalized($0.publicKey) == wanted }
    }

    static func renewalDate(expiresAt: Date?, margin: TimeInterval) -> Date {
        (expiresAt ?? .distantFuture).addingTimeInterval(-margin)
    }
}
