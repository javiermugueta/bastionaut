import Darwin
import Foundation

/// Marca de propiedad de un `ssh` lanzado por la app, para poder cerrarlo si la app se cerró de golpe.
struct OwnedTunnelRecord: Codable, Equatable {
    let pid: Int32
    let token: UUID
    let port: Int
    let target: String
    /// Argumento de reenvío, p. ej. `-D 127.0.0.1:2222` o `-L 127.0.0.1:50000:10.0.0.5:22`.
    var forward: String? = nil

    var forwardArgument: String { forward ?? "-D 127.0.0.1:\(port)" }

    func matches(command: String) -> Bool {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("/usr/bin/ssh ") &&
            value.contains("SetEnv=OCIBASTION_TUNNEL_ID=\(token.uuidString)") &&
            value.contains(forwardArgument + " ") &&
            value.contains(target)
    }

    func isRunning() async -> Bool {
        guard let result = try? await CommandRunner.run("/bin/ps", ["-ww", "-p", String(pid), "-o", "command="]),
              result.status == 0 else { return false }
        return matches(command: result.output)
    }

    func terminateIfRunning() async throws -> Bool {
        guard await isRunning() else { return false }
        guard Darwin.kill(pid, SIGTERM) == 0 || errno == ESRCH else {
            throw BastionError.ownedTunnelCouldNotStop(pid: pid)
        }
        for _ in 0..<30 {
            if !(await isRunning()) { return true }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw BastionError.ownedTunnelCouldNotStop(pid: pid)
    }

    /// `true` si se puede reservar el puerto en 127.0.0.1 (nadie escucha en él).
    static func isPortFree(_ port: Int) -> Bool {
        withLoopbackSocket(port: port) { socketFD, address in
            var reuse: Int32 = 1
            setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            return bind(socketFD, address, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        } ?? false
    }

    /// `true` si algo acepta conexiones en 127.0.0.1:puerto.
    static func isListening(_ port: Int) -> Bool {
        withLoopbackSocket(port: port) { socketFD, address in
            connect(socketFD, address, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        } ?? false
    }

    private static func withLoopbackSocket(port: Int, _ body: (Int32, UnsafePointer<sockaddr>) -> Bool) -> Bool? {
        guard (1...65535).contains(port) else { return nil }
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return nil }
        defer { close(socketFD) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body(socketFD, $0) }
        }
    }

    /// Puerto TCP libre en 127.0.0.1 asignado por el sistema.
    static func freeLocalPort() -> Int? {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return nil }
        defer { close(socketFD) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, length) == 0 && getsockname(socketFD, $0, &length) == 0
            }
        }
        return bound ? Int(UInt16(bigEndian: address.sin_port)) : nil
    }
}

/// Registro en disco de los `ssh` propios en marcha.
@MainActor
enum OwnedTunnelRegistry {
    static var fileURL: URL {
        Settings.fileURL.deletingLastPathComponent().appendingPathComponent("owned-tunnels.json")
    }

    private static var legacyURL: URL {
        Settings.fileURL.deletingLastPathComponent().appendingPathComponent("owned-tunnel.json")
    }

    static func load() -> [OwnedTunnelRecord] {
        var records: [OwnedTunnelRecord] = []
        if let data = try? Data(contentsOf: fileURL),
           let value = try? JSONDecoder().decode([OwnedTunnelRecord].self, from: data) { records += value }
        if let data = try? Data(contentsOf: legacyURL),
           let value = try? JSONDecoder().decode(OwnedTunnelRecord.self, from: data) { records.append(value) }
        return records
    }

    private static func write(_ records: [OwnedTunnelRecord]) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(records).write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func add(_ record: OwnedTunnelRecord) {
        write(load().filter { $0.token != record.token } + [record])
    }

    static func remove(_ record: OwnedTunnelRecord) {
        write(load().filter { $0.token != record.token })
    }

    /// Cierra los `ssh` que dejó una ejecución anterior de la app. Devuelve cuántos cerró.
    static func reclaimStale() async -> Int {
        var closed = 0
        for record in load() where (try? await record.terminateIfRunning()) == true { closed += 1 }
        write([])
        try? FileManager.default.removeItem(at: legacyURL)
        return closed
    }
}
