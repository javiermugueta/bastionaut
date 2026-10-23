import Foundation
import Observation

enum TunnelState: Equatable {
    case idle
    case working(String)
    case connected
    case renewing
    case reconnecting(String)
    case needsAttention(String)

    var isConnected: Bool { self == .connected || self == .renewing }
}

/// Lo que un túnel necesita de OCI, compartido entre los túneles de una misma conexión.
struct RunnerContext {
    let settings: Settings
    let client: OCIAPIClient
    let bastion: BastionDetails
    let proxy: ProxyEndpoint?
}

struct SessionLease {
    let session: OCISession
    let key: BastionKey
    let sshTarget: String
    var expiresAt: Date? { session.expiresAt }
}

/// Mantiene un `ssh` contra el Bastion: reutiliza o crea la sesión, la renueva antes de que caduque
/// y reconecta con espera exponencial. Los errores que necesitan al usuario detienen el bucle.
@Observable
@MainActor
final class ForwardRunner {
    let id: UUID
    let target: SessionTarget
    let label: String
    private(set) var state: TunnelState = .idle
    private(set) var localPort: Int?
    private(set) var sessionExpiresAt: Date?
    private(set) var bastionCommand: String?

    @ObservationIgnored var onLog: (String) -> Void = { _ in }
    @ObservationIgnored private let makeContext: () async throws -> RunnerContext
    @ObservationIgnored private let preferredPort: Int?
    /// El puerto local lo eligió el usuario: no se cambia por otro libre.
    @ObservationIgnored private let fixedPort: Bool
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var record: OwnedTunnelRecord?

    init(id: UUID, target: SessionTarget, label: String, preferredPort: Int?, fixedPort: Bool = false,
         makeContext: @escaping () async throws -> RunnerContext) {
        self.id = id
        self.target = target
        self.label = label
        self.preferredPort = preferredPort
        self.fixedPort = fixedPort
        self.makeContext = makeContext
    }

    var isActive: Bool { task != nil }

    func start() {
        guard task == nil else { return }
        state = .working(String(localized: "Calentando motores 🔥"))
        task = Task { await run() }
    }

    func stop() {
        task?.cancel()
        process?.terminate()
    }

    /// Para cierres de la app: no espera.
    func terminateNow() {
        task?.cancel()
        if let process, process.isRunning { process.terminate() }
        if let record { OwnedTunnelRegistry.remove(record) }
    }

    /// Espera a que el túnel esté listo y devuelve su puerto local.
    func waitUntilConnected(timeout: TimeInterval = 240) async throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch state {
            case .connected, .renewing:
                if let localPort { return localPort }
            case .needsAttention(let message):
                throw BastionError.message(message)
            case .idle:
                throw BastionError.notConnected
            default:
                break
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw BastionError.sessionTimeout
    }

    // MARK: Bucle

    private func run() async {
        var retry = 1
        var freshAuthRetries = 0
        var suspectSessions = Set<String>()
        while !Task.isCancelled {
            var currentSessionID: String?
            var currentLease: SessionLease?
            var delayOverride: Int?
            do {
                let context = try await makeContext()
                if target == .dynamic && !context.bastion.supportsSOCKS {
                    throw BastionError.socksNotEnabled(bastion: context.bastion.name)
                }
                let port = try await reservePort(context.settings)
                localPort = port
                var lease = try await obtainLease(context, excluding: suspectSessions)
                currentSessionID = lease.session.id
                currentLease = lease
                while !Task.isCancelled {
                    try await startForward(lease, context: context, port: port)
                    retry = 1
                    freshAuthRetries = 0
                    lease = try await keepAliveAndRenew(lease, context: context, excluding: suspectSessions)
                    currentSessionID = lease.session.id
                    currentLease = lease
                    await stopProcess()
                }
            } catch is CancellationError {
                break
            } catch BastionError.sshAuthenticationFailed where freshAuthRetries < 4 && Self.isFresh(currentLease) {
                // Igual que el script original: recién creada, el Bastion tarda unos segundos en aceptar la clave.
                freshAuthRetries += 1
                delayOverride = 5
                state = .reconnecting(String(localized: "El Bastion aún está preparando la sesión… (\(freshAuthRetries)/4)"))
                onLog(String(localized: "⏱️ \(label): la sesión es nueva y todavía no acepta la clave; reintento en 5 s"))
            } catch let error as BastionError where error.requiresIntervention {
                state = .needsAttention(error.userMessage)
                onLog("🆘 \(label): \(error.localizedDescription)")
                break
            } catch {
                if case BastionError.sshExited = error, let currentSessionID { suspectSessions.insert(currentSessionID) }
                state = .reconnecting(error.localizedDescription)
                onLog("🔁 \(label): \(error.localizedDescription)")
            }
            await stopProcess()
            if Task.isCancelled { break }
            let delay = delayOverride ?? min(retry, 30)
            if delayOverride == nil { retry = min(retry * 2, 30) }
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
        }
        await stopProcess()
        if case .needsAttention = state {} else { state = .idle }
        sessionExpiresAt = nil
        bastionCommand = nil
        task = nil
    }

    /// Vigila el `ssh` y, cuando toca, pide la sesión siguiente mientras la actual sigue sirviendo.
    private func keepAliveAndRenew(_ lease: SessionLease, context: RunnerContext,
                                   excluding: Set<String>) async throws -> SessionLease {
        let margin = context.settings.effectiveRenewMargin
        var renewAt = SessionPlanner.renewalDate(expiresAt: lease.expiresAt, margin: margin)
        while true {
            while let process, process.isRunning, Date() < renewAt {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if let process, !process.isRunning {
                let output = Self.stderr(of: process)
                onLog(String(localized: "🔌 \(label): el túnel se cerró"))
                throw BastionError.fromSSH(output)
            }
            state = .renewing
            onLog(String(localized: "⏳ \(label): renovando la sesión antes de que caduque"))
            do {
                return try await obtainLease(context, excluding: excluding.union([lease.session.id]), quiet: true)
            } catch let error as BastionError where !error.requiresIntervention &&
                        (lease.expiresAt ?? .distantFuture) > Date().addingTimeInterval(90) {
                onLog(String(localized: "🔁 \(label): no pude renovar todavía (\(error.localizedDescription)); reintento en 1 min"))
                state = .connected
                renewAt = Date().addingTimeInterval(60)
            }
        }
    }

    private func reservePort(_ settings: Settings) async throws -> Int {
        let port: Int
        switch target {
        case .dynamic:
            port = settings.socksPort
        case .portForward:
            if let localPort { port = localPort }
            else if fixedPort, let preferredPort { port = preferredPort }
            else if let preferredPort, OwnedTunnelRecord.isPortFree(preferredPort) { port = preferredPort }
            else if let free = OwnedTunnelRecord.freeLocalPort() { port = free }
            else { throw BastionError.message(String(localized: "No encuentro un puerto local libre.")) }
        }
        try InputCheck.port(port)
        return port
    }

    private func obtainLease(_ context: RunnerContext, excluding: Set<String>, quiet: Bool = false) async throws -> SessionLease {
        let settings = context.settings
        let custom: BastionKey? = settings.effectiveKeyMode == .custom
            ? try await KeyValidation.customKey(publicPath: settings.publicKeyPath, privatePath: settings.privateKeyPath)
            : nil
        let keys = custom.map { [$0] } ?? SessionKeyStore.validKeys()
        let minimum = settings.effectiveRenewMargin + 60
        if !quiet { state = .working(String(localized: "Buscando una sesión que reutilizar 🔎")) }
        if !keys.isEmpty, let sessions = try? await context.client.listActiveSessions(bastionID: context.bastion.id) {
            for candidate in SessionPlanner.candidates(sessions, target: target, minimumRemaining: minimum, excluding: excluding).prefix(5) {
                guard let full = try? await context.client.getSession(id: candidate.id),
                      SessionPlanner.hasRemaining(full, minimum),
                      let key = SessionPlanner.key(for: full, among: keys),
                      let sshTarget = full.sshTarget else { continue }
                SessionKeyStore.attach(key, sessionID: full.id, expiresAt: full.expiresAt)
                onLog(String(localized: "♻️ \(label): reutilizo una sesión que ya existía"))
                return SessionLease(session: full, key: key, sshTarget: sshTarget)
            }
        }

        if !quiet { state = .working(String(localized: "Pidiendo una sesión nueva a OCI 🛎️")) }
        let key: BastionKey
        if let custom { key = custom } else { key = try await SessionKeyStore.generate() }
        let ttl = min(settings.ttlSeconds, context.bastion.maxSessionTtlInSeconds ?? 10800)
        var session = try await context.client.createSession(
            bastionID: context.bastion.id, displayName: Self.displayName(label), publicKey: key.publicKey,
            target: target.ociDetails, ttlSeconds: ttl)
        SessionKeyStore.attach(key, sessionID: session.id, expiresAt: Date().addingTimeInterval(TimeInterval(ttl)))
        onLog(String(localized: "🛎️ \(label): sesión creada, esperando a OCI"))
        let started = Date()
        for _ in 0..<90 {
            if !quiet { state = .working(String(localized: "OCI está preparando la sesión ☕️ · \(Int(Date().timeIntervalSince(started))) s")) }
            switch session.lifecycleState {
            case "ACTIVE":
                if let sshTarget = session.sshTarget {
                    SessionKeyStore.attach(key, sessionID: session.id, expiresAt: session.expiresAt)
                    return SessionLease(session: session, key: key, sshTarget: sshTarget)
                }
            case "FAILED", "DELETED", "DELETING":
                throw BastionError.sessionFailed(session.lifecycleDetails ?? session.lifecycleState)
            default:
                break
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
            session = try await context.client.getSession(id: session.id)
        }
        throw BastionError.sessionTimeout
    }

    private func startForward(_ lease: SessionLease, context: RunnerContext, port: Int) async throws {
        state = .working(String(localized: "Abriendo el túnel 🚇"))
        if !OwnedTunnelRecord.isPortFree(port) {
            throw BastionError.portInUse(port: port, pid: nil)
        }
        let forward: BastionForward
        switch target {
        case .dynamic: forward = .socks(localPort: port)
        case .portForward(let host, let targetPort): forward = .port(localPort: port, host: host, port: targetPort)
        }
        let token = UUID()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = SSHCommands.bastionArguments(target: lease.sshTarget, privateKeyPath: lease.key.privateKeyPath,
                                                          forward: forward, proxy: context.proxy, token: token)
        process.standardError = Pipe()
        process.standardOutput = Pipe()
        process.standardInput = FileHandle.nullDevice
        try process.run()
        self.process = process
        let record = OwnedTunnelRecord(pid: process.processIdentifier, token: token, port: port,
                                       target: lease.sshTarget, forward: forward.arguments.joined(separator: " "))
        self.record = record
        OwnedTunnelRegistry.add(record)

        do {
            try await waitUntilListening(process: process, port: port)
        } catch BastionError.sshExited(let detail) where BastionError.isConnectionFailure(detail) || detail.isEmpty {
            throw BastionError.bastionUnreachable(detail: detail.isEmpty ? String(localized: "sin respuesta") : detail,
                                                  allowList: context.bastion.clientCidrBlockAllowList ?? [])
        } catch BastionError.sshExited(Self.listenTimeoutMessage) {
            throw BastionError.bastionUnreachable(detail: String(localized: "sin respuesta en 30 s"),
                                                  allowList: context.bastion.clientCidrBlockAllowList ?? [])
        }
        sessionExpiresAt = lease.expiresAt
        bastionCommand = try? SSHCommands.bastion(target: lease.sshTarget, privateKeyPath: lease.key.privateKeyPath,
                                                  forward: forward, proxy: context.proxy)
        state = .connected
        onLog(String(localized: "🎉 \(label): túnel listo en 127.0.0.1:\(String(port))"))
    }

    static let listenTimeoutMessage = "SSH no abrió el puerto local a tiempo."

    nonisolated static func isFresh(_ lease: SessionLease?, now: Date = Date()) -> Bool {
        guard let created = lease?.session.timeCreated else { return false }
        return now.timeIntervalSince(created) < 120
    }

    private func waitUntilListening(process: Process, port: Int) async throws {
        state = .working(String(localized: "Llamando a la puerta del Bastion 🚪"))
        for _ in 0..<120 {
            try Task.checkCancellation()
            guard process.isRunning else { throw BastionError.fromSSH(Self.stderr(of: process)) }
            // Comprobamos antes de lanzar ssh que el puerto estaba libre: si ahora escucha, es nuestro ssh.
            if OwnedTunnelRecord.isListening(port) { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw BastionError.sshExited(Self.listenTimeoutMessage)
    }

    private func stopProcess() async {
        if let process {
            if process.isRunning {
                process.terminate()
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        process.waitUntilExit()
                        continuation.resume()
                    }
                }
            }
            self.process = nil
        }
        if let record {
            OwnedTunnelRegistry.remove(record)
            self.record = nil
        }
    }

    private static func stderr(of process: Process) -> String {
        let data = (process.standardError as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func displayName(_ label: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let clean = String(label.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }.prefix(40))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "OCIBastion-\(clean)-\(formatter.string(from: Date()))"
    }
}
