import Foundation

/// Cómo llega un SSH de usuario a su destino a través del Bastion.
enum SSHRoute: Equatable {
    /// Por el proxy SOCKS5 local de una sesión dinámica.
    case socks(port: Int)
    /// Por un puerto local que una sesión de reenvío gestionado lleva al SSH del destino.
    case jump(localPort: Int)
}

/// Reenvío que abre el `ssh` contra el Bastion.
enum BastionForward: Equatable {
    case socks(localPort: Int)
    case port(localPort: Int, host: String, port: Int)

    var localPort: Int {
        switch self {
        case .socks(let port), .port(let port, _, _): return port
        }
    }

    var arguments: [String] {
        switch self {
        case .socks(let localPort): return ["-D", "127.0.0.1:\(localPort)"]
        case .port(let localPort, let host, let port): return ["-L", "127.0.0.1:\(localPort):\(host):\(port)"]
        }
    }
}

enum SSHCommands {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func routeOptions(_ route: SSHRoute, host: String, port: Int) throws -> (options: [String], port: Int, host: String) {
        switch route {
        case .socks(let socksPort):
            try InputCheck.port(socksPort)
            return (["-o", quote("ProxyCommand=/usr/bin/nc -X 5 -x 127.0.0.1:\(socksPort) %h %p")], port, host)
        case .jump(let localPort):
            try InputCheck.port(localPort)
            // HostKeyAlias evita que todos los destinos compartan la entrada de known_hosts de 127.0.0.1.
            return (["-o", quote("HostKeyAlias=\(host)")], localPort, "127.0.0.1")
        }
    }

    /// Opciones para el terminal integrado: en sandbox no se puede leer ~/.ssh, así que usa el known_hosts de la app.
    /// (El comando para copiar no las lleva: en Terminal se usan tu ~/.ssh/config y tu known_hosts.)
    static func embeddedOptions(_ embedded: Bool) -> [String] {
        embedded ? ["-F", "/dev/null", "-o", quote(knownHostsOption(knownHostsURL.path))] + quietPQWarning.flatMap { ["-o", $0] } : []
    }

    /// OpenSSH 10 avisa en cada conexión si el servidor no usa intercambio de claves post-cuántico (los de OCI aún no):
    /// en la app no aporta nada que el usuario pueda arreglar. Solo se apaga ese aviso; los de cifrado débil siguen.
    /// IgnoreUnknown va primero para que los ssh anteriores (macOS 14) no fallen con una opción que no conocen.
    static let quietPQWarning = ["IgnoreUnknown=WarnWeakCrypto", "WarnWeakCrypto=no-pq-kex"]

    static func destination(_ destination: Destination, route: SSHRoute, embedded: Bool = false) throws -> String {
        let host = try InputCheck.sshToken(destination.host, name: "Host")
        let user = try InputCheck.sshToken(destination.user, name: "Usuario")
        let key = try InputCheck.singleLine(destination.privateKeyPath, name: "Clave privada de la instancia")
        try InputCheck.port(destination.port)
        let routed = try routeOptions(route, host: host, port: destination.port)
        return (["ssh"] + embeddedOptions(embedded) + ["-i", quote(key), "-o", quote("IdentitiesOnly=yes")] + routed.options + [
            "-o", quote("ServerAliveInterval=30"),
            "-o", quote("ServerAliveCountMax=3"),
            "-p", String(routed.port), quote("\(user)@\(routed.host)")
        ]).joined(separator: " ")
    }

    static func tunnelReadyMessage(_ tunnel: LocalTunnel, remoteHost: String) -> String {
        String(localized: "✅ Túnel listo: localhost:\(String(tunnel.localPort)) → \(remoteHost):\(String(tunnel.remotePort)). Deja esta ventana abierta; al cerrarla se cierra el túnel.")
    }

    /// Texto seguro dentro de `echo '…'` en LocalCommand: sin comillas simples ni % (ssh expande %h, %p…).
    static func safeEcho(_ text: String) -> String {
        text.replacingOccurrences(of: "'", with: "’").replacingOccurrences(of: "%", with: "")
    }

    static func localTunnel(_ tunnel: LocalTunnel, route: SSHRoute, embedded: Bool = false) throws -> String {
        let host = try InputCheck.sshToken(tunnel.host, name: "Host SSH")
        let user = try InputCheck.sshToken(tunnel.user, name: "Usuario SSH")
        let remoteHost = try InputCheck.sshToken(tunnel.remoteHost, name: "Host destino del túnel")
        let key = try InputCheck.singleLine(tunnel.privateKeyPath, name: "Clave privada del túnel")
        try InputCheck.port(tunnel.sshPort)
        try InputCheck.port(tunnel.localPort)
        try InputCheck.port(tunnel.remotePort)
        let routed = try routeOptions(route, host: host, port: tunnel.sshPort)
        let forwarding = "127.0.0.1:\(tunnel.localPort):\(remoteHost):\(tunnel.remotePort)"
        // En el terminal integrado, `ssh -N` no muestra nada: LocalCommand avisa cuando ya está conectado.
        let ready = embedded ? ["-o", quote("PermitLocalCommand=yes"),
                                "-o", quote("LocalCommand=echo '\(safeEcho(tunnelReadyMessage(tunnel, remoteHost: remoteHost)))'")] : []
        return (["ssh"] + embeddedOptions(embedded) + ready + ["-i", quote(key), "-o", quote("IdentitiesOnly=yes")] + routed.options + [
            "-o", quote("ExitOnForwardFailure=yes"),
            "-o", quote("ServerAliveInterval=30"),
            "-o", quote("ServerAliveCountMax=3"),
            "-N", "-L", quote(forwarding),
            "-p", String(routed.port), quote("\(user)@\(routed.host)")
        ]).joined(separator: " ")
    }

    /// Argumentos del `ssh` que mantiene el túnel con el Bastion.
    static func bastionArguments(target: String, privateKeyPath: String, forward: BastionForward,
                                 proxy: ProxyEndpoint?, token: UUID) -> [String] {
        var arguments = ["-i", privateKeyPath, "-N"] + forward.arguments + [
            "-p", "22", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
            "-o", "ConnectTimeout=20",
            "-o", "IdentitiesOnly=yes",
            "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "SetEnv=OCIBASTION_TUNNEL_ID=\(token.uuidString)"
        ]
        // En sandbox no se puede leer ~/.ssh/config ni escribir ~/.ssh/known_hosts: usamos uno propio del contenedor.
        // Entre comillas: OpenSSH separa por espacios varios archivos en esta opción, y la ruta lleva «Application Support».
        arguments += ["-F", "/dev/null", "-o", knownHostsOption(knownHostsURL.path)] + quietPQWarning.flatMap { ["-o", $0] }
        if let proxy { arguments += ["-o", "ProxyCommand=/usr/bin/nc -X connect -x \(proxy.address) %h %p"] }
        arguments.append(target)
        return arguments
    }

    static func knownHostsOption(_ path: String) -> String {
        "UserKnownHostsFile=\"\(path)\""
    }

    static var knownHostsURL: URL {
        Settings.fileURL.deletingLastPathComponent().appendingPathComponent("known_hosts")
    }

    /// Archivo donde las versiones anteriores, por la ruta sin comillas, guardaban las huellas.
    static var misplacedKnownHostsURL: URL {
        Settings.fileURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Application")
    }

    /// Traslada las huellas ya conocidas al archivo correcto (sin perderlas: si no, accept-new aceptaría a ciegas
    /// la siguiente clave del servidor). El archivo antiguo solo se borra cuando las huellas ya están a salvo.
    static func migrateMisplacedKnownHosts(from stray: URL = misplacedKnownHostsURL, to target: URL = knownHostsURL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: stray.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              let contents = try? String(contentsOf: stray, encoding: .utf8) else { return }
        let lines = contents.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        // Solo si parece un known_hosts: no tocamos un archivo que no sea nuestro.
        guard lines.allSatisfy(isKnownHostsLine) else { return }
        do {
            let existing = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
            let known = Set(existing.split(whereSeparator: \.isNewline).map(String.init))
            let missing = lines.filter { !known.contains($0) }
            if !missing.isEmpty {
                let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
                let merged = existing + separator + missing.joined(separator: "\n") + "\n"
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try merged.write(to: target, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            }
            try FileManager.default.removeItem(at: stray)
        } catch {
            // Si no se pudo escribir, el archivo antiguo se queda: mejor duplicado que sin huellas.
        }
    }

    /// `host[,host…] tipo-de-clave base64 [comentario]`, también con marcadores (@cert-authority) o hosts cifrados (|1|…).
    static func isKnownHostsLine(_ line: String) -> Bool {
        if line.hasPrefix("#") { return true }
        let fields = line.split(separator: " ")
        let offset = fields.first?.hasPrefix("@") == true ? 1 : 0
        guard fields.count >= 3 + offset else { return false }
        let type = fields[1 + offset]
        return type.hasPrefix("ssh-") || type.hasPrefix("ecdsa-") || type.hasPrefix("sk-")
    }

    /// Versión para copiar y pegar del túnel con el Bastion.
    static func bastion(target: String, privateKeyPath: String, forward: BastionForward, proxy: ProxyEndpoint?) throws -> String {
        let key = try InputCheck.singleLine(privateKeyPath, name: "Clave privada del Bastion")
        try InputCheck.port(forward.localPort)
        let parts = target.split(separator: "@")
        guard parts.count == 2 else { throw BastionError.message(String(localized: "Destino SSH del Bastion no válido.")) }
        _ = try InputCheck.sshToken(String(parts[0]), name: "Usuario de sesión")
        _ = try InputCheck.sshToken(String(parts[1]), name: "Host del Bastion")
        var arguments = ["ssh", "-i", quote(key), "-N", forward.arguments[0], quote(forward.arguments[1])] + [
            "-p", "22", "-o", quote("ServerAliveInterval=30"),
            "-o", quote("ServerAliveCountMax=3"),
            "-o", quote("ExitOnForwardFailure=yes")
        ]
        if let proxy { arguments += ["-o", quote("ProxyCommand=/usr/bin/nc -X connect -x \(proxy.address) %h %p")] }
        arguments.append(quote(target))
        return arguments.joined(separator: " ")
    }
}
