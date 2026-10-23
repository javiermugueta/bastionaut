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

    static func destination(_ destination: Destination, route: SSHRoute) throws -> String {
        let host = try InputCheck.sshToken(destination.host, name: "Host")
        let user = try InputCheck.sshToken(destination.user, name: "Usuario")
        let key = try InputCheck.singleLine(destination.privateKeyPath, name: "Clave privada de la instancia")
        try InputCheck.port(destination.port)
        let routed = try routeOptions(route, host: host, port: destination.port)
        return (["ssh", "-i", quote(key), "-o", quote("IdentitiesOnly=yes")] + routed.options + [
            "-o", quote("ServerAliveInterval=30"),
            "-o", quote("ServerAliveCountMax=3"),
            "-p", String(routed.port), quote("\(user)@\(routed.host)")
        ]).joined(separator: " ")
    }

    static func localTunnel(_ tunnel: LocalTunnel, route: SSHRoute) throws -> String {
        let host = try InputCheck.sshToken(tunnel.host, name: "Host SSH")
        let user = try InputCheck.sshToken(tunnel.user, name: "Usuario SSH")
        let remoteHost = try InputCheck.sshToken(tunnel.remoteHost, name: "Host destino del túnel")
        let key = try InputCheck.singleLine(tunnel.privateKeyPath, name: "Clave privada del túnel")
        try InputCheck.port(tunnel.sshPort)
        try InputCheck.port(tunnel.localPort)
        try InputCheck.port(tunnel.remotePort)
        let routed = try routeOptions(route, host: host, port: tunnel.sshPort)
        let forwarding = "127.0.0.1:\(tunnel.localPort):\(remoteHost):\(tunnel.remotePort)"
        return (["ssh", "-i", quote(key), "-o", quote("IdentitiesOnly=yes")] + routed.options + [
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
        if let proxy { arguments += ["-o", "ProxyCommand=/usr/bin/nc -X connect -x \(proxy.address) %h %p"] }
        arguments.append(target)
        return arguments
    }

    /// Versión para copiar y pegar del túnel con el Bastion.
    static func bastion(target: String, privateKeyPath: String, forward: BastionForward, proxy: ProxyEndpoint?) throws -> String {
        let key = try InputCheck.singleLine(privateKeyPath, name: "Clave privada del Bastion")
        try InputCheck.port(forward.localPort)
        let parts = target.split(separator: "@")
        guard parts.count == 2 else { throw BastionError.message("Destino SSH del Bastion no válido.") }
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

enum TerminalLauncher {
    static func open(command: String, in app: TerminalApp) async throws {
        let arguments: [String]
        switch app {
        case .terminal:
            let script = """
            on run argv
                tell application "Terminal"
                    activate
                    do script (item 1 of argv)
                end tell
            end run
            """
            arguments = ["-e", script, command]
        case .iterm:
            guard let script = Bundle.main.url(forResource: "LaunchITerm", withExtension: "applescript") else {
                throw BastionError.terminal("falta el script de iTerm2 en la aplicación.")
            }
            arguments = [script.path, command]
        }
        let result = try await CommandRunner.run("/usr/bin/osascript", arguments)
        guard result.status == 0 else { throw BastionError.terminal(result.error.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}
