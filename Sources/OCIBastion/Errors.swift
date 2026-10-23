import Foundation

/// Errores de la app. `requiresIntervention` decide si el bucle de conexión reintenta
/// o se detiene a esperar al usuario, sin depender del texto del mensaje.
enum BastionError: LocalizedError, Equatable {
    case message(String)
    case configNotFound(path: String)
    case profileNotFound(String)
    case profileMissingField(profile: String, field: String)
    case unsupportedAPIKey(String)
    case apiKeyPassphraseRequired(path: String)
    case keyFileMissing(path: String)
    case keyPairMismatch
    case api(status: Int, code: String, message: String, requestID: String?)
    case network(String)
    case bastionNotFound
    case socksNotEnabled(bastion: String)
    case sessionFailed(String)
    case sessionTimeout
    case sshAuthenticationFailed(String)
    case sshHostKeyFailed(String)
    case sshPassphraseRequired
    case sshForwardFailed(String)
    /// No se llega al Bastion: casi siempre es la lista de IPs permitidas o un proxy/cortafuegos.
    case bastionUnreachable(detail: String, allowList: [String])
    case sshExited(String)
    case portInUse(port: Int, pid: Int32?)
    case ownedTunnelCouldNotStop(pid: Int32)
    case notConnected
    case terminal(String)

    var errorDescription: String? {
        switch self {
        case .message(let value):
            return value
        case .configNotFound(let path):
            return String(localized: "No encuentro el archivo de configuración OCI en \(path).")
        case .profileNotFound(let profile):
            return String(localized: "El perfil «\(profile)» no existe en la configuración OCI.")
        case .profileMissingField(let profile, let field):
            return String(localized: "Al perfil «\(profile)» le falta el campo «\(field)».")
        case .unsupportedAPIKey(let detail):
            return String(localized: "No puedo usar la clave de API de OCI: \(detail)")
        case .apiKeyPassphraseRequired(let path):
            return String(localized: "La clave de API \(path) está cifrada. Añade pass_phrase al perfil OCI.")
        case .keyFileMissing(let path):
            return String(localized: "No existe la clave: \(path)")
        case .keyPairMismatch:
            return String(localized: "La clave pública y la privada del Bastion no forman pareja.")
        case .api(let status, let code, let message, let requestID):
            let id = requestID.map { " (opc-request-id: \($0))" } ?? ""
            return String(localized: "OCI respondió \(status) \(code): \(message)\(id)")
        case .network(let detail):
            return String(localized: "No hay forma de hablar con OCI: \(detail)")
        case .bastionNotFound:
            return String(localized: "No encuentro el Bastion. ¿Está en la región elegida?")
        case .socksNotEnabled(let bastion):
            return String(localized: "El Bastion «\(bastion)» no tiene activado SOCKS5. Usa el modo de reenvío de puerto o activa «FQDN y SOCKS5» en el Bastion.")
        case .sessionFailed(let detail):
            return String(localized: "OCI no pudo crear la sesión: \(detail)")
        case .sessionTimeout:
            return String(localized: "La sesión de OCI tardó demasiado en activarse.")
        case .sshAuthenticationFailed(let detail):
            return String(localized: "SSH rechazó la clave: \(detail)")
        case .sshHostKeyFailed(let detail):
            return String(localized: "La huella del servidor no coincide: \(detail)")
        case .sshPassphraseRequired:
            return String(localized: "La clave privada tiene contraseña. Cárgala antes en ssh-agent.")
        case .sshForwardFailed(let detail):
            return String(localized: "SSH no pudo abrir el puerto local: \(detail)")
        case .bastionUnreachable(let detail, let allowList):
            let list = allowList.isEmpty ? "" : String(localized: " Solo acepta conexiones desde: \(allowList.joined(separator: ", ")).")
            return String(localized: "No consigo conectar con el Bastion por SSH.\(list) (\(detail))")
        case .sshExited(let detail):
            return detail.isEmpty ? String(localized: "El túnel SSH terminó.") : detail
        case .portInUse(let port, let pid?):
            return String(localized: "El puerto local \(String(port)) lo está usando otro proceso (PID \(String(pid))). Libéralo o elige otro.")
        case .portInUse(let port, nil):
            return String(localized: "El puerto local \(String(port)) lo está usando otro programa. Libéralo o elige otro.")
        case .ownedTunnelCouldNotStop(let pid):
            return String(localized: "El SSH anterior (PID \(String(pid))) sigue vivo; no abro otro hasta que termine.")
        case .notConnected:
            return String(localized: "Conecta primero el Bastion.")
        case .terminal(let detail):
            return String(localized: "No pude abrir la terminal: \(detail)")
        }
    }

    /// Consejo para arreglarlo, si lo hay.
    var hint: String? {
        switch self {
        case .bastionUnreachable:
            return String(localized: "Comprueba que tu IP pública esté en la lista de IPs permitidas del Bastion (consola OCI › Bastion › Editar). Si sales por un proxy o VPN, cuenta la IP de salida.")
        case .socksNotEnabled:
            return String(localized: "Cambia a «Reenvío de puerto» en Ajustes.")
        case .api(let status, _, _, _) where status == 401:
            return String(localized: "Revisa la huella y la clave de API del perfil OCI.")
        case .api(let status, _, _, _) where status == 404:
            return String(localized: "Puede faltar un permiso IAM (p. ej. «manage bastion-session») o el recurso no está en esta región.")
        case .sshAuthenticationFailed:
            return String(localized: "Si usas tus propias claves, comprueba que la privada corresponde a la pública.")
        case .sshHostKeyFailed:
            return String(localized: "Borra la entrada antigua de ~/.ssh/known_hosts para ese host.")
        case .portInUse, .sshForwardFailed:
            return String(localized: "Elige otro puerto local o cierra lo que lo esté usando.")
        case .configNotFound, .profileNotFound, .profileMissingField:
            return String(localized: "Abre el asistente ✨ y revisa la cuenta OCI.")
        default:
            return nil
        }
    }

    /// Mensaje completo para mostrar al usuario.
    var userMessage: String {
        [errorDescription, hint.map { "💡 " + $0 }].compactMap { $0 }.joined(separator: "\n")
    }

    /// Fallos de conexión de red de `ssh` (antes de autenticarse).
    static func isConnectionFailure(_ stderr: String) -> Bool {
        ["Connection timed out", "Operation timed out", "Connection refused", "Connection closed by",
         "Connection reset by", "kex_exchange_identification", "No route to host", "Network is unreachable",
         "banner exchange"].contains { stderr.contains($0) }
    }

    /// `true` cuando reintentar no lo arreglará: hace falta que el usuario cambie algo.
    var requiresIntervention: Bool {
        switch self {
        case .network, .sessionTimeout, .sshExited:
            return false
        case .api(let status, _, _, _):
            return !(status == 409 || status == 429 || status >= 500)
        default:
            return true
        }
    }

    /// Clasifica la salida de error de `ssh`.
    static func fromSSH(_ stderr: String) -> BastionError {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("Permission denied") { return .sshAuthenticationFailed(text) }
        if text.contains("Host key verification failed") || text.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
            return .sshHostKeyFailed(text)
        }
        if text.contains("passphrase") { return .sshPassphraseRequired }
        if text.contains("Address already in use") || text.contains("Could not request local forwarding")
            || text.contains("cannot listen to port") {
            return .sshForwardFailed(text)
        }
        return .sshExited(text)
    }
}
