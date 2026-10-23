import CFNetwork
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

/// Elige el proxy HTTP CONNECT para un destino concreto (la API de OCI, el SSH del Bastion…).
/// En modo automático solo sigue lo configurado de forma explícita y, si hay un PAC, lo ejecuta de verdad
/// (`FindProxyForURL`) para ese destino.
enum ProxyResolver {
    static func resolve(settings: Settings, destination: URL) async throws -> (endpoint: ProxyEndpoint?, source: String) {
        switch settings.effectiveProxyMode {
        case .direct:
            return (nil, String(localized: "Conexión directa"))
        case .manual:
            return (try ProxyEndpoint(host: settings.proxyHost, port: settings.proxyPort), String(localized: "Proxy manual"))
        case .automatic:
            let system = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] ?? [:]
            switch automaticPlan(environment: ProcessInfo.processInfo.environment, system: system, destination: destination) {
            case .endpoint(let endpoint, let source):
                return (endpoint, source)
            case .pac(let url):
                if let script = await downloadScript(url),
                   let endpoint = await PACEvaluator.proxy(script: script, destination: destination) {
                    return (endpoint, String(localized: "PAC del sistema"))
                }
            case .pacScript(let script):
                if let endpoint = await PACEvaluator.proxy(script: script, destination: destination) {
                    return (endpoint, String(localized: "PAC del sistema"))
                }
            case .wpad:
                if let script = await downloadScript(URL(string: "http://wpad/wpad.dat")!),
                   let endpoint = await PACEvaluator.proxy(script: script, destination: destination) {
                    return (endpoint, String(localized: "WPAD (activado en macOS)"))
                }
            case .direct:
                break
            }
            return (nil, String(localized: "Sin proxy detectado; conexión directa"))
        }
    }

    /// Qué hacer en modo automático. Solo se sigue lo configurado de forma explícita: variables de entorno,
    /// el proxy del sistema (con sus excepciones) o su PAC, y WPAD únicamente si está activado en macOS.
    /// (Consultar http://wpad/wpad.dat siempre dejaría que cualquier red impusiera su proxy.)
    enum AutomaticPlan: Equatable {
        case endpoint(ProxyEndpoint, source: String)
        case pac(URL)
        case pacScript(String)
        case wpad
        case direct
    }

    static func automaticPlan(environment: [String: String], system: [String: Any], destination: URL) -> AutomaticPlan {
        for key in ["https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY"] {
            if let value = environment[key], let endpoint = endpoint(fromURL: value) {
                return .endpoint(endpoint, source: String(localized: "Variable \(key)"))
            }
        }
        // CFNetwork aplica la configuración del sistema al destino: proxies explícitos, lista de excepciones y PAC.
        let entries = CFNetworkCopyProxiesForURL(destination as CFURL, system as CFDictionary).takeRetainedValue() as? [[String: Any]] ?? []
        for entry in entries {
            let type = entry[kCFProxyTypeKey as String] as? String
            if type == kCFProxyTypeHTTP as String || type == kCFProxyTypeHTTPS as String,
               let endpoint = endpoint(fromCFProxy: entry) {
                return .endpoint(endpoint, source: String(localized: "Proxy del sistema"))
            }
            if type == kCFProxyTypeAutoConfigurationURL as String,
               let url = entry[kCFProxyAutoConfigurationURLKey as String] as? URL,
               ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") {
                return .pac(url)
            }
            if type == kCFProxyTypeAutoConfigurationJavaScript as String,
               let script = entry[kCFProxyAutoConfigurationJavaScriptKey as String] as? String {
                return .pacScript(script)
            }
            if type == kCFProxyTypeNone as String { break }
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

    static func endpoint(fromCFProxy entry: [String: Any]) -> ProxyEndpoint? {
        guard let host = entry[kCFProxyHostNameKey as String] as? String,
              let port = (entry[kCFProxyPortNumberKey as String] as? NSNumber)?.intValue else { return nil }
        return try? ProxyEndpoint(host: host, port: port)
    }

    /// Scripts PAC descargados: un minuto, y se olvidan al cambiar la red.
    final class ScriptCache {
        private var entries: [URL: (date: Date, script: String)] = [:]
        private let lock = NSLock()

        func script(for url: URL, maxAge: TimeInterval = 60) -> String? {
            lock.lock(); defer { lock.unlock() }
            guard let entry = entries[url], Date().timeIntervalSince(entry.date) < maxAge else { return nil }
            return entry.script
        }

        func store(_ script: String, for url: URL) {
            lock.lock(); defer { lock.unlock() }
            entries[url] = (Date(), script)
        }

        func clear() {
            lock.lock(); defer { lock.unlock() }
            entries.removeAll()
        }
    }

    static let scriptCache = ScriptCache()

    /// Descarga un script PAC/WPAD de la URL configurada en el sistema, sin proxy y con límites de tiempo y tamaño.
    private static func downloadScript(_ url: URL) async -> String? {
        if let cached = scriptCache.script(for: url) { return cached }
        guard let script = await fetchScript(url) else { return nil }
        scriptCache.store(script, for: url)
        return script
    }

    private static func fetchScript(_ url: URL) async -> String? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 5
        guard let (data, response) = try? await URLSession(configuration: configuration).data(from: url),
              data.count < 1_000_000 else { return nil }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Ejecuta un script PAC con el motor de CFNetwork (`FindProxyForURL(url, host)`) para un destino.
enum PACEvaluator {
    private final class Box {
        var entries: [[String: Any]]?
    }

    /// Primer proxy HTTP(S) que el PAC devuelve para el destino; `nil` si dice DIRECT, falla o solo ofrece SOCKS.
    static func proxy(script: String, destination: URL) async -> ProxyEndpoint? {
        let entries = await evaluate(script: script, destination: destination)
        for entry in entries {
            let type = entry[kCFProxyTypeKey as String] as? String
            if type == kCFProxyTypeNone as String { return nil }
            if type == kCFProxyTypeHTTP as String || type == kCFProxyTypeHTTPS as String,
               let endpoint = ProxyResolver.endpoint(fromCFProxy: entry) {
                return endpoint
            }
        }
        return nil
    }

    /// El motor necesita un run loop: se usa un hilo propio con un tiempo máximo.
    static func evaluate(script: String, destination: URL, timeout: TimeInterval = 10) async -> [[String: Any]] {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                let box = Box()
                var context = CFStreamClientContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
                                                    retain: nil, release: nil, copyDescription: nil)
                let callback: CFProxyAutoConfigurationResultCallback = { info, proxies, _ in
                    let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
                    box.entries = proxies as? [[String: Any]] ?? []
                    CFRunLoopStop(CFRunLoopGetCurrent())
                }
                let source = CFNetworkExecuteProxyAutoConfigurationScript(script as CFString, destination as CFURL,
                                                                          callback, &context)
                CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
                _ = CFRunLoopRunInMode(.defaultMode, timeout, false)
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .defaultMode)
                continuation.resume(returning: box.entries ?? [])
            }
            thread.start()
        }
    }
}
