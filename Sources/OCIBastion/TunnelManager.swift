import AppKit
import Foundation
import Observation

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let date = Date()
    let message: String
}

@Observable
@MainActor
final class TunnelManager {
    var settings = Settings.load()
    var proxyDescription = ""
    var toast: String?
    var toastIsError = false
    /// Detalles del Bastion de la conexión activa (lista de IPs permitidas, SOCKS5…).
    private(set) var bastionDetails: BastionDetails?
    var publicIPReport: String?
    private(set) var isCheckingPublicIP = false
    private(set) var log: [LogEntry] = []
    private(set) var socksRunner: ForwardRunner?
    private(set) var portRunners: [UUID: ForwardRunner] = [:]

    /// Solo lo costoso de obtener (cliente de OCI, Bastion, proxy). La configuración se toma nueva en cada conexión.
    @ObservationIgnored private var contextCache: (key: String, task: Task<SharedContext, Error>)?
    @ObservationIgnored private var cachedProxy: (key: String, endpoint: ProxyEndpoint?, source: String)?
    @ObservationIgnored private var startup: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var lastPorts: [UUID: Int] = [:]

    /// `startServices: false` (tests) no cierra túneles antiguos ni limpia claves al arrancar.
    init(settings initial: Settings? = nil, startServices: Bool = true) {
        if let initial { settings = initial }
        if Showcase.launchedForScreenshots {
            enterDemo(scene: Showcase.scene)
            return
        }
        if let selected = settings.selectedSavedConnectionID,
           !(settings.savedConnections ?? []).contains(where: { $0.id == selected }) {
            settings.selectedSavedConnectionID = nil
        }
        guard startServices else { return }
        SSHCommands.removeMisplacedKnownHosts()
        startup = Task {
            let closed = await OwnedTunnelRegistry.reclaimStale()
            if closed > 0 { record(String(localized: "🧹 Cerré \(closed) túnel(es) que quedaron de la última vez")) }
            let pruned = SessionKeyStore.prune()
            if pruned > 0 { record(String(localized: "🧹 Borré \(pruned) clave(s) temporal(es) caducada(s)")) }
        }
    }

    // MARK: Modo demostración

    /// Datos de ejemplo en memoria (para probar la app sin cuenta de OCI y para la revisión de Apple).
    /// La configuración real queda apartada: no se guarda nada ni se lanza ningún proceso.
    private(set) var isDemo = false
    @ObservationIgnored private var realSettings: Settings?
    @ObservationIgnored private var demoTasks: [UUID: Task<Void, Never>] = [:]

    func enterDemo(scene: String? = nil) {
        guard !isDemo, !isRunning else { return }
        realSettings = settings
        isDemo = true
        socksRunner = nil
        portRunners = [:]
        contextCache = nil
        publicIPReport = nil
        log.removeAll()
        settings = Showcase.settings()
        bastionDetails = Showcase.bastion
        switch scene {
        case "attention":
            let destination = settings.destinations[0]
            let error = BastionError.bastionUnreachable(detail: "Operation timed out", allowList: Showcase.bastion.clientCidrBlockAllowList ?? [])
            demoRunner(id: destination.id, host: destination.host, port: destination.port, name: destination.name)
                .showcase(state: .needsAttention(error.userMessage), localPort: nil, expiresAt: nil, command: nil)
            publicIPReport = PublicIP.report(ip: "88.12.200.7", allowList: Showcase.bastion.clientCidrBlockAllowList ?? [])
            record(String(localized: "🆘 \(destination.name): \(error.localizedDescription)"))
        case "main", "dark", "help":
            for line in Showcase.logLines { record(line) }
            let expires = Date().addingTimeInterval(2 * 3600 + 14 * 60 + 37)
            let destinations = settings.destinations
            let tunnel = (settings.tunnels ?? [])[0]
            demoRunner(id: destinations[0].id, host: destinations[0].host, port: 22, name: destinations[0].name)
                .showcase(state: .connected, localPort: 52211, expiresAt: expires, command: Showcase.command(port: 52211, host: destinations[0].host, remotePort: 22))
            demoRunner(id: destinations[1].id, host: destinations[1].host, port: 22, name: destinations[1].name)
                .showcase(state: .connected, localPort: 52214, expiresAt: expires.addingTimeInterval(600), command: Showcase.command(port: 52214, host: destinations[1].host, remotePort: 22))
            demoRunner(id: tunnel.id, host: tunnel.remoteHost, port: tunnel.remotePort, name: tunnel.name)
                .showcase(state: .connected, localPort: tunnel.localPort, expiresAt: expires.addingTimeInterval(900), command: Showcase.command(port: tunnel.localPort, host: tunnel.remoteHost, remotePort: tunnel.remotePort))
        default:
            record(String(localized: "🎮 Modo demostración: datos de ejemplo, nada se conecta de verdad"))
        }
    }

    func exitDemo() {
        guard isDemo else { return }
        demoTasks.values.forEach { $0.cancel() }
        demoTasks = [:]
        portRunners = [:]
        socksRunner = nil
        bastionDetails = nil
        publicIPReport = nil
        log.removeAll()
        if let realSettings { settings = realSettings }
        realSettings = nil
        isDemo = false
        record(String(localized: "👋 Has salido de la demo"))
    }

    @discardableResult
    private func demoRunner(id: UUID, host: String, port: Int, name: String) -> ForwardRunner {
        if let existing = portRunners[id] { return existing }
        let runner = ForwardRunner(id: id, target: .portForward(host: host, port: port), label: name, preferredPort: nil) {
            throw CancellationError()
        }
        portRunners[id] = runner
        return runner
    }

    /// Recorre los mismos pasos que una conexión real, sin red, y deja el túnel «conectado».
    private func demoConnect(id: UUID, host: String, port: Int, name: String, localPort: Int?) -> Task<Void, Never> {
        if let running = demoTasks[id] { return running }
        let runner = demoRunner(id: id, host: host, port: port, name: name)
        runner.showcase(state: .working(String(localized: "Calentando motores 🔥")), localPort: nil, expiresAt: nil, command: nil)
        let local = localPort ?? Int.random(in: 52000...52999)
        let task = Task { @MainActor [weak self] in
            @MainActor func step(_ state: TunnelState, _ seconds: Double) async -> Bool {
                runner.showcase(state: state, localPort: nil, expiresAt: nil, command: nil)
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return !Task.isCancelled
            }
            guard await step(.working(String(localized: "Buscando una sesión que reutilizar 🔎")), 0.6),
                  await step(.working(String(localized: "Pidiendo una sesión nueva a OCI 🛎️")), 0.8) else { return }
            self?.record(String(localized: "🛎️ \(name): sesión creada, esperando a OCI"))
            for elapsed in [1, 3, 5] {
                guard await step(.working(String(localized: "OCI está preparando la sesión ☕️ · \(elapsed) s")), 0.5) else { return }
            }
            guard await step(.working(String(localized: "Llamando a la puerta del Bastion 🚪")), 0.6) else { return }
            runner.showcase(state: .connected, localPort: local, expiresAt: Date().addingTimeInterval(3 * 3600),
                            command: Showcase.command(port: local, host: host, remotePort: port))
            self?.record(String(localized: "🎉 \(name): túnel listo en 127.0.0.1:\(String(local))"))
            self?.demoTasks[id] = nil
        }
        demoTasks[id] = task
        return task
    }

    private func demoConnectAll() {
        record(String(localized: "🚀 Conectando «\(selectedConnection?.name ?? settings.bastionName ?? "Bastion")»"))
        for destination in settings.destinations {
            _ = demoConnect(id: destination.id, host: destination.host, port: destination.port, name: destination.name, localPort: nil)
        }
        for tunnel in settings.tunnels ?? [] {
            _ = tunnel.isDirect
                ? demoConnect(id: tunnel.id, host: tunnel.remoteHost, port: tunnel.remotePort, name: tunnel.name, localPort: tunnel.localPort)
                : demoConnect(id: tunnel.id, host: tunnel.host, port: tunnel.sshPort, name: tunnel.name, localPort: nil)
        }
    }

    private func demoDisconnect(_ id: UUID? = nil) {
        let targets = id.map { [$0] } ?? Array(portRunners.keys)
        for target in targets {
            demoTasks.removeValue(forKey: target)?.cancel()
            portRunners[target]?.showcase(state: .idle, localPort: nil, expiresAt: nil, command: nil)
        }
        if id == nil { record(String(localized: "👋 Desconectado")) }
    }

    private func demoOpen(id: UUID, host: String, port: Int, name: String, localPort: Int?, message: @escaping (Int) -> String) {
        let task = portRunners[id]?.state.isConnected == true ? nil : demoConnect(id: id, host: host, port: port, name: name, localPort: localPort)
        Task {
            await task?.value
            guard let local = portRunners[id]?.localPort, portRunners[id]?.state.isConnected == true else { return }
            showToast(message(local))
        }
    }

    // MARK: Estado

    var needsOnboarding: Bool { settings.hasCompletedOnboarding != true && savedConnections.isEmpty }

    var allRunners: [ForwardRunner] { (socksRunner.map { [$0] } ?? []) + Array(portRunners.values) }

    var isRunning: Bool { allRunners.contains { $0.isActive } }

    /// Estado global que se muestra en la tarjeta principal y en la barra de menús.
    var overallState: TunnelState {
        if settings.effectiveSessionMode == .socks || socksRunner != nil { return socksRunner?.state ?? .idle }
        let states = portRunners.values.map(\.state)
        if let attention = states.first(where: { if case .needsAttention = $0 { return true }; return false }) { return attention }
        if states.isEmpty || states.allSatisfy({ $0 == .idle }) { return .idle }
        if let working = states.first(where: { if case .working = $0 { return true }; return false }) { return working }
        if let retrying = states.first(where: { if case .reconnecting = $0 { return true }; return false }) { return retrying }
        return .connected
    }

    var isConnected: Bool { overallState.isConnected }

    var sessionExpiresAt: Date? {
        allRunners.compactMap(\.sessionExpiresAt).min()
    }

    func runner(for id: UUID) -> ForwardRunner? { portRunners[id] }

    func record(_ message: String) {
        log.append(LogEntry(message: message))
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    func clearLog() { log.removeAll() }

    func showToast(_ message: String, isError: Bool = false) {
        toast = message
        toastIsError = isError
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: isError ? 8_000_000_000 : 3_500_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    private func report(_ error: Error) {
        record("⚠️ \(error.localizedDescription)")
        showToast((error as? BastionError)?.userMessage ?? error.localizedDescription, isError: true)
    }

    /// Consulta la IP pública (solo cuando el usuario lo pide) y la compara con la lista del Bastion.
    func checkPublicIP(allowList: [String]? = nil, settings value: Settings? = nil) {
        if isDemo {
            publicIPReport = PublicIP.report(ip: "83.45.10.23", allowList: allowList ?? bastionDetails?.clientCidrBlockAllowList ?? [])
            return
        }
        let snapshot = value ?? settings
        isCheckingPublicIP = true
        Task {
            defer { isCheckingPublicIP = false }
            do {
                let proxy = try await resolvedProxy(for: snapshot)
                let ip = try await PublicIP.fetch(proxy: proxy)
                let report = PublicIP.report(ip: ip, allowList: allowList ?? bastionDetails?.clientCidrBlockAllowList ?? [])
                publicIPReport = report
                record("🌐 " + report)
            } catch { report(error) }
        }
    }

    // MARK: Conexiones guardadas

    var savedConnections: [SavedConnection] { settings.savedConnections ?? [] }

    var selectedConnection: SavedConnection? {
        savedConnections.first { $0.id == settings.selectedSavedConnectionID }
    }

    /// Guarda en disco y vuelca los cambios en la conexión seleccionada.
    func save() {
        guard !isDemo else { return }
        if let id = settings.selectedSavedConnectionID,
           var records = settings.savedConnections,
           let index = records.firstIndex(where: { $0.id == id }) {
            let snapshot = ConnectionSnapshot(settings: settings)
            if records[index].snapshot != snapshot {
                records[index].snapshot = snapshot
                settings.savedConnections = records
            }
        }
        do { try settings.save() }
        catch { report(BastionError.message(String(localized: "No se pudo guardar la configuración: \(error.localizedDescription)"))) }
    }

    @discardableResult
    func addConnection(named rawName: String, emoji: String, from draft: Settings) -> Bool {
        do {
            let name = try InputCheck.singleLine(rawName, name: "Nombre de conexión")
            guard !savedConnections.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
                throw BastionError.message(String(localized: "Ya existe una conexión llamada «\(name)»."))
            }
            guard !isRunning else { throw BastionError.message(String(localized: "Desconecta antes de cambiar de conexión.")) }
            let record = SavedConnection(id: UUID(), name: name, snapshot: ConnectionSnapshot(settings: draft), emoji: emoji)
            settings.savedConnections = savedConnections + [record]
            record.snapshot.apply(to: &settings)
            settings.selectedSavedConnectionID = record.id
            settings.hasCompletedOnboarding = true
            contextCache = nil
            save()
            self.record(String(localized: "✨ Conexión «\(name)» creada"))
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Sustituye la configuración de la conexión actual con lo que devuelve el asistente en modo edición.
    func applyDraft(_ draft: Settings) {
        guard !isRunning else { return report(BastionError.message(String(localized: "Desconecta antes de cambiar la configuración."))) }
        ConnectionSnapshot(settings: draft).apply(to: &settings)
        contextCache = nil
        save()
        record(String(localized: "🛠️ Configuración actualizada"))
    }

    func selectConnection(_ id: UUID?) {
        guard id != settings.selectedSavedConnectionID else { return }
        guard !isRunning else { return showToast(String(localized: "Desconecta antes de cambiar de conexión 🙏")) }
        save()
        guard let id, let record = savedConnections.first(where: { $0.id == id }) else {
            settings.selectedSavedConnectionID = nil
            save()
            return
        }
        record.snapshot.apply(to: &settings)
        settings.selectedSavedConnectionID = id
        portRunners = [:]
        socksRunner = nil
        contextCache = nil
        bastionDetails = nil
        publicIPReport = nil
        save()
    }

    func renameSelectedConnection(to rawName: String, emoji: String) {
        guard let id = settings.selectedSavedConnectionID else { return }
        renameConnection(id: id, to: rawName, emoji: emoji)
    }

    func renameConnection(id: UUID, to rawName: String, emoji: String) {
        do {
            let name = try InputCheck.singleLine(rawName, name: "Nombre de conexión")
            var records = savedConnections
            guard let index = records.firstIndex(where: { $0.id == id }) else { return }
            guard !records.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
                throw BastionError.message(String(localized: "Ya existe una conexión llamada «\(name)»."))
            }
            records[index].name = name
            records[index].emoji = emoji
            settings.savedConnections = records
            save()
        } catch { report(error) }
    }

    func duplicateSelectedConnection() {
        guard let id = settings.selectedSavedConnectionID else { return }
        duplicateConnection(id: id)
    }

    func duplicateConnection(id: UUID) {
        guard let selected = savedConnections.first(where: { $0.id == id }) else { return }
        var name = selected.name + " (copia)"
        var counter = 2
        while savedConnections.contains(where: { $0.name == name }) {
            name = "\(selected.name) (copia \(counter))"
            counter += 1
        }
        // La seleccionada se copia con lo que hay en pantalla; las demás, tal como están guardadas.
        var source = settings
        if id != settings.selectedSavedConnectionID { selected.snapshot.apply(to: &source) }
        addConnection(named: name, emoji: selected.displayEmoji, from: source)
    }

    func deleteSelectedConnection() {
        guard let id = settings.selectedSavedConnectionID else { return }
        deleteConnection(id: id)
    }

    /// Borra una conexión guardada. La activa solo se puede borrar desconectada.
    func deleteConnection(id: UUID) {
        guard let record = savedConnections.first(where: { $0.id == id }) else { return }
        let isSelected = id == settings.selectedSavedConnectionID
        guard !(isSelected && isRunning) else { return showToast(String(localized: "Desconecta antes de borrar esta conexión 🙏")) }
        settings.savedConnections = savedConnections.filter { $0.id != id }
        if isSelected {
            settings.selectedSavedConnectionID = nil
            if let next = savedConnections.first {
                selectConnection(next.id)
            } else {
                // Sin conexiones: vuelta al estado vacío, conservando cuenta, proxy y terminal.
                var fresh = Settings()
                fresh.configPath = settings.configPath
                fresh.profile = settings.profile
                fresh.proxyMode = settings.proxyMode
                fresh.proxyHost = settings.proxyHost
                fresh.proxyPort = settings.proxyPort
                fresh.terminalApp = settings.terminalApp
                fresh.accounts = settings.accounts
                fresh.accountID = settings.accountID
                fresh.hasCompletedOnboarding = true
                settings = fresh
                portRunners = [:]
                socksRunner = nil
                contextCache = nil
                bastionDetails = nil
                save()
            }
        } else {
            save()
        }
        self.record(String(localized: "🗑️ Conexión «\(record.name)» eliminada"))
    }

    func exportConfiguration(to url: URL, scope: ExportScope) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(ConfigurationArchive(settings: settings, scope: scope))
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            showToast(String(localized: "Exportado a \(url.lastPathComponent) 📦"))
        } catch { report(BastionError.message(String(localized: "No se pudo exportar: \(error.localizedDescription)"))) }
    }

    func prepareImport(from url: URL) -> ConfigurationImportPlan? {
        guard !isRunning else {
            showToast(String(localized: "Desconecta antes de importar 🙏"))
            return nil
        }
        do {
            let archive = try JSONDecoder().decode(ConfigurationArchive.self, from: Data(contentsOf: url))
            try archive.validate()
            return ConfigurationImportPlan(archive: archive, fileName: url.lastPathComponent,
                                           conflictingNames: archive.conflictingNames(with: settings))
        } catch {
            report(BastionError.message(String(localized: "No se pudo leer el archivo: \(error.localizedDescription)")))
            return nil
        }
    }

    func applyImport(_ plan: ConfigurationImportPlan) {
        guard !isRunning else { return }
        do {
            var imported = plan.archive.merged(into: settings)
            imported.hasCompletedOnboarding = true
            if imported.selectedSavedConnectionID == nil { imported.selectedSavedConnectionID = imported.savedConnections?.first?.id }
            if let id = imported.selectedSavedConnectionID,
               let selected = imported.savedConnections?.first(where: { $0.id == id }), plan.archive.current == nil {
                selected.snapshot.apply(to: &imported)
            }
            try imported.save()
            settings = imported
            contextCache = nil
            record(String(localized: "📥 Importadas \(plan.archive.savedConnections.count) conexión(es) de \(plan.fileName)"))
            showToast(String(localized: "¡Importación completada! 📥"))
        } catch { report(BastionError.message(String(localized: "No se pudo importar: \(error.localizedDescription)"))) }
    }

    // MARK: OCI

    func resolvedProxy(for value: Settings, fresh: Bool = false) async throws -> ProxyEndpoint? {
        let key = "\(value.effectiveProxyMode.rawValue)|\(value.proxyHost)|\(value.proxyPort)"
        if !fresh, let cachedProxy, cachedProxy.key == key { return cachedProxy.endpoint }
        let result = try await ProxyResolver.resolve(settings: value)
        cachedProxy = (key, result.endpoint, result.source)
        proxyDescription = result.endpoint.map { "\(result.source): \($0.address)" } ?? result.source
        return result.endpoint
    }

    var accounts: [OCIAccount] { settings.accounts ?? [] }

    /// Credenciales de OCI de una configuración: su cuenta guardada en la app, con la clave en el Llavero.
    func ociProfile(for value: Settings) throws -> OCIProfile {
        guard let id = value.accountID, let account = (value.accounts ?? accounts).first(where: { $0.id == id }) else {
            throw BastionError.message(String(localized: "Esta conexión no tiene cuenta de OCI. Elige una con el asistente ✨."))
        }
        return account.profile(privateKeyPEM: try APIKeyKeychain.load(for: id))
    }

    /// Guarda (o actualiza) una cuenta y, si viene, su clave privada en el Llavero.
    func saveAccount(_ account: OCIAccount, key: ImportedAPIKey?) throws {
        if let key { try APIKeyKeychain.save(key.pem, for: account.id) }
        contextCache = nil
        var all = accounts
        if let index = all.firstIndex(where: { $0.id == account.id }) { all[index] = account } else { all.append(account) }
        settings.accounts = all
        save()
    }

    /// Cliente de API para una configuración (también la del asistente, que aún no está guardada).
    func client(for value: Settings, profile override: OCIProfile? = nil) async throws -> OCIAPIClient {
        let profile = try override ?? ociProfile(for: value)
        let proxy = try await resolvedProxy(for: value)
        return try await OCIAPIClient.make(profile: profile, region: value.region, proxy: proxy)
    }

    struct SharedContext {
        let client: OCIAPIClient
        let bastion: BastionDetails
        let proxy: ProxyEndpoint?
    }

    /// Identifica lo que depende de la cuenta, la región, el Bastion y el proxy; el resto de ajustes no se cachea.
    nonisolated static func sharedContextKey(for snapshot: Settings) -> String {
        [snapshot.accountID?.uuidString ?? "", snapshot.region ?? "", snapshot.bastionID,
         snapshot.effectiveProxyMode.rawValue, snapshot.proxyHost, String(snapshot.proxyPort)].joined(separator: "|")
    }

    func context(for snapshot: Settings) async throws -> RunnerContext {
        let shared = try await sharedContext(for: snapshot)
        return RunnerContext(settings: snapshot, client: shared.client, bastion: shared.bastion, proxy: shared.proxy)
    }

    private func sharedContext(for snapshot: Settings) async throws -> SharedContext {
        let key = Self.sharedContextKey(for: snapshot)
        if let contextCache, contextCache.key == key {
            do { return try await contextCache.task.value } catch { self.contextCache = nil; throw error }
        }
        let task = Task { @MainActor in
            _ = try InputCheck.singleLine(snapshot.bastionID, name: "Bastion")
            let proxy = try await resolvedProxy(for: snapshot, fresh: true)
            let profile = try ociProfile(for: snapshot)
            let client = try await OCIAPIClient.make(profile: profile, region: snapshot.region, proxy: proxy)
            let bastion = try await client.getBastion(id: snapshot.bastionID)
            bastionDetails = bastion
            return SharedContext(client: client, bastion: bastion, proxy: proxy)
        }
        contextCache = (key, task)
        do { return try await task.value } catch { contextCache = nil; throw error }
    }

    /// Solo para tests: deja preparado lo costoso sin llamar a OCI.
    func primeSharedContext(_ shared: SharedContext, for snapshot: Settings) {
        contextCache = (Self.sharedContextKey(for: snapshot), Task { shared })
    }

    private func validate(_ value: Settings) throws {
        guard value.account != nil else {
            throw BastionError.message(String(localized: "Esta conexión no tiene cuenta de OCI. Elige una con el asistente ✨."))
        }
        _ = try InputCheck.singleLine(value.bastionID, name: "Bastion")
        if value.effectiveKeyMode == .custom {
            _ = try InputCheck.singleLine(value.publicKeyPath, name: "Clave pública")
            _ = try InputCheck.singleLine(value.privateKeyPath, name: "Clave privada")
        }
        try InputCheck.port(value.socksPort)
        guard (1800...10800).contains(value.ttlSeconds) else {
            throw BastionError.message(String(localized: "La duración de sesión debe estar entre 30 y 180 minutos."))
        }
        if value.effectiveProxyMode == .manual {
            _ = try InputCheck.sshToken(value.proxyHost, name: "Host del proxy")
            try InputCheck.port(value.proxyPort)
        }
    }

    // MARK: Túneles

    private func makeRunner(id: UUID, target: SessionTarget, label: String, snapshot: Settings,
                            fixedPort: Int? = nil) -> ForwardRunner {
        let runner = ForwardRunner(id: id, target: target, label: label, preferredPort: fixedPort ?? lastPorts[id],
                                   fixedPort: fixedPort != nil) { [weak self] in
            guard let self else { throw CancellationError() }
            await self.startup?.value
            return try await self.context(for: snapshot)
        }
        runner.onLog = { [weak self] in self?.record($0) }
        return runner
    }

    /// Conecta: en SOCKS5 abre el túnel común; en reenvío de puerto, uno por destino y túnel.
    func connect() {
        if isDemo { return demoConnectAll() }
        do { try validate(settings) } catch { return report(error) }
        publicIPReport = nil
        save()
        switch settings.effectiveSessionMode {
        case .socks:
            if socksRunner?.isActive == true { return }
            let runner = makeRunner(id: UUID(), target: .dynamic, label: String(localized: "SOCKS5"), snapshot: settings)
            socksRunner = runner
            runner.start()
        case .portForwarding:
            let tunnels = settings.tunnels ?? []
            guard !settings.destinations.isEmpty || !tunnels.isEmpty else {
                return showToast(String(localized: "Añade algún destino primero 🙂"))
            }
            for destination in settings.destinations {
                _ = ensurePortRunner(id: destination.id, host: destination.host, port: destination.port, name: destination.name)
            }
            for tunnel in tunnels { _ = ensureTunnelRunner(tunnel) }
        }
        record(String(localized: "🚀 Conectando «\(selectedConnection?.name ?? settings.bastionName ?? "Bastion")»"))
    }

    func disconnect() {
        if isDemo { return demoDisconnect() }
        for runner in allRunners {
            if let port = runner.localPort { lastPorts[runner.id] = port }
            runner.stop()
        }
        record(String(localized: "👋 Desconectado"))
    }

    func stopAllNow() {
        allRunners.forEach { $0.terminateNow() }
    }

    func disconnect(target id: UUID) {
        if isDemo { return demoDisconnect(id) }
        portRunners[id]?.stop()
    }

    /// Sesión de reenvío para un túnel: directa al puerto remoto o hacia su servidor SSH.
    private func ensureTunnelRunner(_ tunnel: LocalTunnel) -> ForwardRunner? {
        tunnel.isDirect
            ? ensurePortRunner(id: tunnel.id, host: tunnel.remoteHost, port: tunnel.remotePort, name: tunnel.name,
                               fixedLocalPort: tunnel.localPort)
            : ensurePortRunner(id: tunnel.id, host: tunnel.host, port: tunnel.sshPort, name: tunnel.name)
    }

    private func ensurePortRunner(id: UUID, host rawHost: String, port: Int, name: String,
                                  fixedLocalPort: Int? = nil) -> ForwardRunner? {
        do {
            let host = try InputCheck.sshToken(rawHost, name: "Host")
            try InputCheck.port(port)
            if let fixedLocalPort { try InputCheck.port(fixedLocalPort) }
            // Solo se reutiliza un túnel en marcha; uno parado se recrea para que tome la configuración actual.
            if let existing = portRunners[id], existing.isReusable(for: .portForward(host: host, port: port), fixedLocalPort: fixedLocalPort) {
                return existing
            }
            portRunners[id]?.stop()
            let runner = makeRunner(id: id, target: .portForward(host: host, port: port),
                                    label: name.isEmpty ? host : name, snapshot: settings, fixedPort: fixedLocalPort)
            portRunners[id] = runner
            runner.start()
            return runner
        } catch {
            report(error)
            return nil
        }
    }

    /// Ruta para un destino, conectando su sesión si hace falta (modo reenvío).
    private func route(id: UUID, host: String, port: Int, name: String, connectIfNeeded: Bool) async throws -> SSHRoute {
        switch settings.effectiveSessionMode {
        case .socks:
            guard let socksRunner, socksRunner.state.isConnected, let port = socksRunner.localPort else {
                if connectIfNeeded { throw BastionError.notConnected }
                return .socks(port: settings.socksPort)
            }
            return .socks(port: port)
        case .portForwarding:
            if let runner = portRunners[id], runner.state.isConnected, let localPort = runner.localPort {
                return .jump(localPort: localPort)
            }
            guard connectIfNeeded else { throw BastionError.message(String(localized: "Conecta primero este destino ▶︎")) }
            try validate(settings)
            guard let runner = ensurePortRunner(id: id, host: host, port: port, name: name) else { throw BastionError.notConnected }
            return .jump(localPort: try await runner.waitUntilConnected())
        }
    }

    func openDestination(_ destination: Destination) {
        if isDemo {
            let name = destination.name.isEmpty ? destination.host : destination.name
            return demoOpen(id: destination.id, host: destination.host, port: destination.port, name: destination.name, localPort: nil) { _ in
                String(localized: "🎮 Demo: aquí se abriría Terminal ya conectado a «\(name)»")
            }
        }
        let terminal = settings.effectiveTerminalApp
        Task {
            do {
                let route = try await route(id: destination.id, host: destination.host, port: destination.port,
                                            name: destination.name, connectIfNeeded: true)
                try await TerminalLauncher.open(command: SSHCommands.destination(destination, route: route), in: terminal)
                record(String(localized: "🖥️ Abriendo SSH a \(destination.name.isEmpty ? destination.host : destination.name)"))
            } catch { report(error) }
        }
    }

    func openLocalTunnel(_ tunnel: LocalTunnel) {
        if isDemo {
            let direct = tunnel.isDirect
            return demoOpen(id: tunnel.id, host: direct ? tunnel.remoteHost : tunnel.host, port: direct ? tunnel.remotePort : tunnel.sshPort,
                            name: tunnel.name, localPort: direct ? tunnel.localPort : nil) { _ in
                String(localized: "🎮 Demo: aquí tendrías localhost:\(String(tunnel.localPort)) → \(tunnel.remoteHost):\(String(tunnel.remotePort))")
            }
        }
        if tunnel.isDirect { return openDirectTunnel(tunnel) }
        let terminal = settings.effectiveTerminalApp
        Task {
            do {
                let route = try await route(id: tunnel.id, host: tunnel.host, port: tunnel.sshPort,
                                            name: tunnel.name, connectIfNeeded: true)
                try await TerminalLauncher.open(command: SSHCommands.localTunnel(tunnel, route: route), in: terminal)
                record(String(localized: "🚇 Túnel \(tunnel.name.isEmpty ? tunnel.host : tunnel.name) → 127.0.0.1:\(String(tunnel.localPort))"))
            } catch { report(error) }
        }
    }

    func copyDestinationCommand(_ destination: Destination) {
        Task {
            do {
                let route = try await route(id: destination.id, host: destination.host, port: destination.port,
                                            name: destination.name, connectIfNeeded: false)
                copy(try SSHCommands.destination(destination, route: route), message: "Comando SSH copiado 📋")
            } catch { report(error) }
        }
    }

    /// Túnel sin servidor SSH: basta con la sesión de reenvío del Bastion, sin abrir terminal.
    private func openDirectTunnel(_ tunnel: LocalTunnel) {
        guard settings.effectiveSessionMode == .portForwarding else {
            return report(BastionError.message(String(localized: "Un túnel sin servidor SSH necesita el modo «Reenvío de puerto». Cámbialo en Ajustes o indica un servidor SSH.")))
        }
        do { try validate(settings) } catch { return report(error) }
        guard let runner = ensureTunnelRunner(tunnel) else { return }
        let name = tunnel.name.isEmpty ? tunnel.remoteHost : tunnel.name
        Task {
            do {
                let port = try await runner.waitUntilConnected()
                record(String(localized: "🚇 Túnel \(name): localhost:\(String(port)) → \(tunnel.remoteHost):\(String(tunnel.remotePort))"))
                showToast(String(localized: "Túnel listo en localhost:\(String(port)) 🎉"))
            } catch { report(error) }
        }
    }

    func copyLocalTunnelCommand(_ tunnel: LocalTunnel) {
        if tunnel.isDirect {
            guard let command = portRunners[tunnel.id]?.bastionCommand else {
                return showToast(String(localized: "Abre el túnel primero para obtener su comando 🙂"))
            }
            return copy(command, message: "Comando del túnel copiado 📋")
        }
        Task {
            do {
                let route = try await route(id: tunnel.id, host: tunnel.host, port: tunnel.sshPort,
                                            name: tunnel.name, connectIfNeeded: false)
                copy(try SSHCommands.localTunnel(tunnel, route: route), message: "Comando del túnel copiado 📋")
            } catch { report(error) }
        }
    }

    func copyBastionCommand() {
        guard let command = socksRunner?.bastionCommand ?? portRunners.values.compactMap(\.bastionCommand).first else {
            return showToast(String(localized: "Conecta el Bastion para obtener el comando 🙂"))
        }
        copy(command, message: "Comando del Bastion copiado 📋")
    }

    private func copy(_ value: String, message: String.LocalizationValue) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        showToast(String(localized: message))
    }

    func removeDestination(_ id: UUID) {
        portRunners.removeValue(forKey: id)?.stop()
        settings.destinations.removeAll { $0.id == id }
        save()
    }

    func removeLocalTunnel(_ id: UUID) {
        portRunners.removeValue(forKey: id)?.stop()
        settings.tunnels?.removeAll { $0.id == id }
        save()
    }
}
