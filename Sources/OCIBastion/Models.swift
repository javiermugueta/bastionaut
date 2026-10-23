import Foundation

struct Destination: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String = ""
    var host: String = ""
    var user: String = "opc"
    var port: Int = 22
    var privateKeyPath: String = ""
}

struct LocalTunnel: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String = ""
    var host: String = ""
    var user: String = "opc"
    var sshPort: Int = 22
    var privateKeyPath: String = ""
    var localPort: Int = 0
    var remoteHost: String = "127.0.0.1"
    var remotePort: Int = 0

    /// Sin servidor SSH intermedio: el Bastion lleva el puerto directamente (solo en reenvío de puerto).
    var isDirect: Bool { host.trimmingCharacters(in: .whitespaces).isEmpty }
}

struct Settings: Codable {
    var configPath: String = ""
    var profile: String = "DEFAULT"
    var compartmentID: String = ""
    var bastionID: String = ""
    var publicKeyPath: String = ""
    var privateKeyPath: String = ""
    var socksPort: Int = 2222
    var ttlSeconds: Int = 10800
    var proxyHost: String = ""
    var proxyPort: Int = 0
    var proxyMode: ProxyMode? = nil
    var terminalApp: TerminalApp? = nil
    var destinations: [Destination] = []
    var tunnels: [LocalTunnel]? = nil
    var region: String? = nil
    var bastionName: String? = nil
    var sessionMode: SessionMode? = nil
    var keyMode: KeyMode? = nil
    var renewMarginMinutes: Int? = nil
    var savedConnections: [SavedConnection]? = nil
    var selectedSavedConnectionID: UUID? = nil
    var hasCompletedOnboarding: Bool? = nil

    var effectiveProxyMode: ProxyMode {
        proxyMode ?? (proxyHost.isEmpty ? .automatic : .manual)
    }

    var effectiveTerminalApp: TerminalApp { terminalApp ?? .terminal }
    var effectiveSessionMode: SessionMode { sessionMode ?? .socks }
    /// Las configuraciones antiguas que ya tenían claves siguen usándolas.
    var effectiveKeyMode: KeyMode { keyMode ?? (publicKeyPath.isEmpty ? .ephemeral : .custom) }
    var effectiveRenewMargin: TimeInterval {
        let configured = TimeInterval((renewMarginMinutes ?? 30) * 60)
        return max(120, min(configured, TimeInterval(ttlSeconds) / 3))
    }

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OCIBastion/settings.json")
    }

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: fileURL),
              let value = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return value
    }

    func save() throws {
        let url = Self.fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum ProxyMode: String, Codable, CaseIterable {
    case automatic
    case manual
    case direct
}

enum TerminalApp: String, Codable, CaseIterable {
    case terminal
    case iterm
}

enum SessionMode: String, Codable, CaseIterable {
    /// Una sesión SOCKS5 (reenvío dinámico) para todos los destinos.
    case socks
    /// Una sesión de reenvío de puerto gestionado por destino.
    case portForwarding
}

enum KeyMode: String, Codable, CaseIterable {
    /// La app crea una clave por sesión y la borra al caducar.
    case ephemeral
    /// El usuario aporta su par de claves.
    case custom
}

struct ConnectionSnapshot: Codable, Equatable {
    var configPath: String
    var profile: String
    var compartmentID: String
    var bastionID: String
    var publicKeyPath: String
    var privateKeyPath: String
    var socksPort: Int
    var ttlSeconds: Int
    var proxyHost: String
    var proxyPort: Int
    var proxyMode: ProxyMode?
    var terminalApp: TerminalApp?
    var destinations: [Destination]
    var tunnels: [LocalTunnel]?
    var region: String?
    var bastionName: String?
    var sessionMode: SessionMode?
    var keyMode: KeyMode?
    var renewMarginMinutes: Int?

    init(settings: Settings) {
        configPath = settings.configPath
        profile = settings.profile
        compartmentID = settings.compartmentID
        bastionID = settings.bastionID
        publicKeyPath = settings.publicKeyPath
        privateKeyPath = settings.privateKeyPath
        socksPort = settings.socksPort
        ttlSeconds = settings.ttlSeconds
        proxyHost = settings.proxyHost
        proxyPort = settings.proxyPort
        proxyMode = settings.proxyMode
        terminalApp = settings.terminalApp
        destinations = settings.destinations
        tunnels = settings.tunnels
        region = settings.region
        bastionName = settings.bastionName
        sessionMode = settings.sessionMode
        keyMode = settings.keyMode
        renewMarginMinutes = settings.renewMarginMinutes
    }

    func apply(to settings: inout Settings) {
        settings.configPath = configPath
        settings.profile = profile
        settings.compartmentID = compartmentID
        settings.bastionID = bastionID
        settings.publicKeyPath = publicKeyPath
        settings.privateKeyPath = privateKeyPath
        settings.socksPort = socksPort
        settings.ttlSeconds = ttlSeconds
        settings.proxyHost = proxyHost
        settings.proxyPort = proxyPort
        settings.proxyMode = proxyMode
        settings.terminalApp = terminalApp
        settings.destinations = destinations
        settings.tunnels = tunnels
        settings.region = region
        settings.bastionName = bastionName
        settings.sessionMode = sessionMode
        settings.keyMode = keyMode
        settings.renewMarginMinutes = renewMarginMinutes
    }
}

struct SavedConnection: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var snapshot: ConnectionSnapshot
    var emoji: String? = nil

    var displayEmoji: String { emoji ?? "🏰" }
}

enum ExportScope {
    case all
    case active
}

struct ConfigurationArchive: Codable {
    let formatVersion: Int
    let current: ConnectionSnapshot?
    let savedConnections: [SavedConnection]
    let selectedSavedConnectionID: UUID?

    init(settings: Settings, scope: ExportScope) {
        formatVersion = 2
        let active = ConnectionSnapshot(settings: settings)
        switch scope {
        case .all:
            current = active
            savedConnections = settings.savedConnections ?? []
            selectedSavedConnectionID = settings.selectedSavedConnectionID
        case .active:
            if let selected = (settings.savedConnections ?? []).first(where: { $0.id == settings.selectedSavedConnectionID }) {
                current = nil
                savedConnections = [SavedConnection(id: selected.id, name: selected.name, snapshot: active, emoji: selected.emoji)]
            } else {
                current = active
                savedConnections = []
            }
            selectedSavedConnectionID = nil
        }
    }

    func validate() throws {
        guard formatVersion == 1 || formatVersion == 2 else {
            throw BastionError.message(String(localized: "Versión de archivo no compatible: \(formatVersion)."))
        }
        guard current != nil || !savedConnections.isEmpty else {
            throw BastionError.message(String(localized: "El archivo no contiene ninguna configuración."))
        }
        let ids = Set(savedConnections.map(\.id))
        let names = Set(savedConnections.map { Self.normalizedName($0.name) })
        guard ids.count == savedConnections.count, names.count == savedConnections.count,
              savedConnections.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw BastionError.message(String(localized: "El archivo contiene conexiones duplicadas o sin nombre."))
        }
        if let selectedSavedConnectionID, !ids.contains(selectedSavedConnectionID) {
            throw BastionError.message(String(localized: "La conexión seleccionada no existe en el archivo."))
        }
    }

    func conflictingNames(with settings: Settings) -> [String] {
        let existing = Set((settings.savedConnections ?? []).map { Self.normalizedName($0.name) })
        return savedConnections.filter { existing.contains(Self.normalizedName($0.name)) }.map(\.name)
    }

    func merged(into settings: Settings) -> Settings {
        var result = settings
        var records = settings.savedConnections ?? []
        var importedIDs: [UUID: UUID] = [:]
        for imported in savedConnections {
            if let index = records.firstIndex(where: { Self.normalizedName($0.name) == Self.normalizedName(imported.name) }) {
                records[index].name = imported.name
                records[index].snapshot = imported.snapshot
                records[index].emoji = imported.emoji ?? records[index].emoji
                importedIDs[imported.id] = records[index].id
            } else {
                let id = records.contains(where: { $0.id == imported.id }) ? UUID() : imported.id
                records.append(SavedConnection(id: id, name: imported.name, snapshot: imported.snapshot, emoji: imported.emoji))
                importedIDs[imported.id] = id
            }
        }
        result.savedConnections = records
        if let current {
            current.apply(to: &result)
            result.selectedSavedConnectionID = selectedSavedConnectionID.flatMap { importedIDs[$0] }
        }
        return result
    }

    private static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

struct ConfigurationImportPlan {
    let archive: ConfigurationArchive
    let fileName: String
    let conflictingNames: [String]

    var needsConfirmation: Bool { archive.current != nil || !conflictingNames.isEmpty }
}

enum InputCheck {
    static func singleLine(_ value: String, name: String.LocalizationValue) throws -> String {
        let name = String(localized: name)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n"), !trimmed.contains("\r") else {
            throw BastionError.message(String(localized: "\(name) no puede estar vacío ni contener saltos de línea."))
        }
        return trimmed
    }

    static func sshToken(_ value: String, name: String.LocalizationValue) throws -> String {
        let checked = try singleLine(value, name: name)
        let name = String(localized: name)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
        guard !checked.hasPrefix("-"), checked.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw BastionError.message(String(localized: "\(name) contiene caracteres no admitidos."))
        }
        return checked
    }

    static func port(_ value: Int) throws {
        guard (1...65535).contains(value) else { throw BastionError.message(String(localized: "El puerto debe estar entre 1 y 65535.")) }
    }

    static func isIPAddress(_ value: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, value, &v4) == 1 || inet_pton(AF_INET6, value, &v6) == 1
    }
}
