import Foundation
import Network

/// En el modo demostración, los túneles a puertos escuchan de verdad en 127.0.0.1 y sirven una página de ejemplo,
/// para que se pueda ver el túnel funcionando (en el navegador) sin cuenta de OCI. Con una cuenta real quien escucha
/// es el `ssh -L`; aquí lo hace la propia app, solo en loopback, y lo cierra al desconectar o salir de la demo.
@MainActor
final class DemoTunnelServer {
    private var listeners: [UUID: NWListener] = [:]
    private var ports: [UUID: Int] = [:]

    func port(for id: UUID) -> Int? { ports[id] }

    /// Empieza a escuchar (si no lo hacía ya) en `preferredPort`, o en uno libre si ese está ocupado.
    /// Devuelve el puerto en el que escucha, o nil si no ha podido.
    func serve(id: UUID, preferredPort: Int, page: String) async -> Int? {
        if let port = ports[id] { return port }
        let response = Self.httpResponse(html: page)
        var port = await listen(id: id, port: preferredPort, response: response)
        if port == nil { port = await listen(id: id, port: 0, response: response) }
        if let port { ports[id] = port }
        return port
    }

    func stop(id: UUID) {
        listeners.removeValue(forKey: id)?.cancel()
        ports[id] = nil
    }

    func stopAll() {
        listeners.values.forEach { $0.cancel() }
        listeners = [:]
        ports = [:]
    }

    private func listen(id: UUID, port: Int, response: Data) async -> Int? {
        guard (0...65535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        listener.newConnectionHandler = { connection in Self.answer(connection, with: response) }
        let ready: Int? = await withCheckedContinuation { continuation in
            let once = Once(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(listener.port.map { Int($0.rawValue) })
                case .failed, .cancelled: once.resume(nil)
                default: break
                }
            }
            listener.start(queue: .main)
        }
        guard let ready else {
            listener.cancel()
            return nil
        }
        listeners[id]?.cancel()
        listeners[id] = listener
        return ready
    }

    /// Lee la petición (sea la que sea) y contesta siempre con la página, cerrando después.
    nonisolated private static func answer(_ connection: NWConnection, with response: Data) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, _, _ in
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    nonisolated static func httpResponse(html: String) -> Data {
        let body = Data(html.utf8)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    /// Página que se ve al abrir el túnel de ejemplo en el navegador.
    nonisolated static func page(name: String, localPort: Int, remoteHost: String, remotePort: Int) -> String {
        let title = escape(String(localized: "Túnel de ejemplo: \(name)"))
        let lead = escape(String(localized: "Esta página llega a través de localhost:\(String(localPort)). La sirve el modo demostración de Bastionaut, que está escuchando de verdad en 127.0.0.1."))
        let real = escape(String(localized: "Con una cuenta de Oracle Cloud, en este puerto escucha el ssh que lanza Bastionaut y cada conexión viaja por el Bastion de OCI hasta \(remoteHost):\(String(remotePort)), un servidor privado de tu red en la nube."))
        let close = escape(String(localized: "Al desconectar o salir de la demo, el puerto se cierra."))
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <style>
        :root { color-scheme: light dark; --bg: #f6f4fb; --fg: #1d1b24; --muted: #5d5970; --card: #ffffff; --accent: #7a4fd6; }
        @media (prefers-color-scheme: dark) { :root { --bg: #17151d; --fg: #eeeaf7; --muted: #a8a2bd; --card: #221f2b; --accent: #b393ff; } }
        body { margin: 0; background: var(--bg); color: var(--fg); font: 16px/1.5 -apple-system, BlinkMacSystemFont, sans-serif; }
        main { max-width: 640px; margin: 64px auto; padding: 32px; background: var(--card); border-radius: 16px; }
        h1 { font-size: 26px; margin: 0 0 16px; }
        code { color: var(--accent); font-size: 15px; }
        p { margin: 12px 0; } .muted { color: var(--muted); }
        </style></head>
        <body><main>
        <h1>🚇 \(title)</h1>
        <p><code>localhost:\(localPort) → \(escape(remoteHost)):\(remotePort)</code></p>
        <p>\(lead)</p>
        <p>\(real)</p>
        <p class="muted">\(close)</p>
        </main></body></html>
        """
    }

    nonisolated static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Reanuda la continuación una sola vez (el listener puede pasar por varios estados).
private final class Once: @unchecked Sendable {
    private var continuation: CheckedContinuation<Int?, Never>?
    private let lock = NSLock()
    init(_ continuation: CheckedContinuation<Int?, Never>) { self.continuation = continuation }
    func resume(_ value: Int?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
