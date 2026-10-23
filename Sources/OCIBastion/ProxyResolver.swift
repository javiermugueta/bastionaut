import Foundation

struct ProxyEndpoint: Equatable {
    let host: String
    let port: Int

    init(host: String, port: Int) throws {
        self.host = try InputCheck.sshToken(host, name: "Host del proxy")
        try InputCheck.port(port)
        self.port = port
    }

    var address: String { "\(host):\(port)" }
}

enum ProxyResolver {
    static func resolve(settings: Settings) async throws -> (endpoint: ProxyEndpoint?, source: String) {
        switch settings.effectiveProxyMode {
        case .direct:
            return (nil, String(localized: "Conexión directa"))
        case .manual:
            return (try ProxyEndpoint(host: settings.proxyHost, port: settings.proxyPort), String(localized: "Proxy manual"))
        case .automatic:
            let system = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] ?? [:]
            switch automaticPlan(environment: ProcessInfo.processInfo.environment, system: system) {
            case .endpoint(let endpoint, let source):
                return (endpoint, source)
            case .pac(let url):
                if let endpoint = await proxy(fromScriptAt: url) { return (endpoint, String(localized: "PAC del sistema")) }
            case .wpad:
                if let endpoint = await proxy(fromScriptAt: URL(string: "http://wpad/wpad.dat")!) {
                    return (endpoint, String(localized: "WPAD (activado en macOS)"))
                }
            case .direct:
                break
            }
            return (nil, String(localized: "Sin proxy detectado; conexión directa"))
        }
    }

    /// Qué hacer en modo automático. Solo se sigue lo configurado de forma explícita: variables de entorno,
    /// el proxy del sistema o su PAC, y WPAD únicamente si está activado en los ajustes de red de macOS.
    /// (Consultar http://wpad/wpad.dat siempre dejaría que cualquier red impusiera su proxy.)
    enum AutomaticPlan: Equatable {
        case endpoint(ProxyEndpoint, source: String)
        case pac(URL)
        case wpad
        case direct
    }

    static func automaticPlan(environment: [String: String], system: [String: Any]) -> AutomaticPlan {
        for key in ["http_proxy", "HTTP_PROXY", "https_proxy", "HTTPS_PROXY"] {
            if let value = environment[key], let endpoint = endpoint(fromURL: value) {
                return .endpoint(endpoint, source: String(localized: "Variable \(key)"))
            }
        }
        if let endpoint = endpoint(fromSystemSettings: system) {
            return .endpoint(endpoint, source: String(localized: "Proxy del sistema"))
        }
        if (system["ProxyAutoConfigEnable"] as? Int) == 1,
           let value = system["ProxyAutoConfigURLString"] as? String, let url = URL(string: value),
           ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") {
            return .pac(url)
        }
        if (system["ProxyAutoDiscoveryEnable"] as? Int) == 1 { return .wpad }
        return .direct
    }

    static func endpoint(fromURL value: String) -> ProxyEndpoint? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard let parts = URLComponents(string: normalized),
              parts.scheme?.lowercased() == "http",
              parts.user == nil, parts.password == nil,
              let host = parts.host else { return nil }
        return try? ProxyEndpoint(host: host, port: parts.port ?? 80)
    }

    static func endpoint(fromWPAD contents: String) -> ProxyEndpoint? {
        let proxyLine = contents.split(whereSeparator: \.isNewline)
            .first { $0.range(of: "proxies\\s*=", options: [.regularExpression, .caseInsensitive]) != nil }
        if let proxyLine, let endpoint = firstHostPort(in: String(proxyLine)) { return endpoint }
        let pattern = #"(?i)\bPROXY\s+([A-Za-z0-9._-]+):(\d{1,5})"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        guard let match = regex?.firstMatch(in: contents, range: range),
              let hostRange = Range(match.range(at: 1), in: contents),
              let portRange = Range(match.range(at: 2), in: contents),
              let port = Int(contents[portRange]) else { return nil }
        return try? ProxyEndpoint(host: String(contents[hostRange]), port: port)
    }

    private static func firstHostPort(in value: String) -> ProxyEndpoint? {
        let pattern = #"([A-Za-z0-9._-]+):(\d{1,5})"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex?.firstMatch(in: value, range: range),
              let hostRange = Range(match.range(at: 1), in: value),
              let portRange = Range(match.range(at: 2), in: value),
              let port = Int(value[portRange]) else { return nil }
        return try? ProxyEndpoint(host: String(value[hostRange]), port: port)
    }

    static func endpoint(fromSystemSettings values: [String: Any]) -> ProxyEndpoint? {
        for prefix in ["HTTP", "HTTPS"] {
            guard (values[prefix + "Enable"] as? Int) == 1,
                  let host = values[prefix + "Proxy"] as? String,
                  let port = values[prefix + "Port"] as? Int else { continue }
            if let endpoint = try? ProxyEndpoint(host: host, port: port) { return endpoint }
        }
        return nil
    }

    /// Descarga un script PAC/WPAD (solo de una URL configurada en el sistema) y toma su primer proxy.
    private static func proxy(fromScriptAt url: URL) async -> ProxyEndpoint? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 5
        guard let (data, response) = try? await URLSession(configuration: configuration).data(from: url) else { return nil }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { return nil }
        return endpoint(fromWPAD: String(decoding: data, as: UTF8.self))
    }
}
