import Foundation

/// Datos de un perfil de `~/.oci/config` necesarios para firmar peticiones.
struct OCIProfile: Equatable {
    var name: String
    var tenancy: String
    var user: String
    var fingerprint: String
    var keyFile: String
    var region: String
    var passPhrase: String?
    var securityTokenFile: String?
    /// Clave privada ya cargada (cuentas guardadas en la app); si está, se ignora `keyFile`.
    var keyPEM: String? = nil
}

enum OCIConfig {
    static var defaultPath: String {
        if let value = ProcessInfo.processInfo.environment["OCI_CLI_CONFIG_FILE"], !value.isEmpty {
            return expand(value)
        }
        return NSHomeDirectory() + "/.oci/config"
    }

    static func profiles(at path: String) throws -> [String] {
        Array(try sections(at: path).keys).sorted()
    }

    static func tenancyID(at path: String, profile: String) throws -> String {
        try load(at: path, profile: profile).tenancy
    }

    static func load(at path: String, profile name: String) throws -> OCIProfile {
        let all = try sections(at: path)
        guard let own = all[name] else { throw BastionError.profileNotFound(name) }
        // Igual que los SDK de OCI: los valores de DEFAULT se heredan en el resto de perfiles.
        let values = (all["DEFAULT"] ?? [:]).merging(own) { _, profileValue in profileValue }
        func required(_ key: String) throws -> String {
            guard let value = values[key], !value.isEmpty else {
                throw BastionError.profileMissingField(profile: name, field: key)
            }
            return value
        }
        let token = values["security_token_file"].map(expand)
        return OCIProfile(
            name: name,
            tenancy: try required("tenancy"),
            user: token == nil ? try required("user") : (values["user"] ?? ""),
            fingerprint: token == nil ? try required("fingerprint") : (values["fingerprint"] ?? ""),
            keyFile: expand(try required("key_file")),
            region: try required("region"),
            passPhrase: values["pass_phrase"].flatMap { $0.isEmpty ? nil : $0 },
            securityTokenFile: token
        )
    }

    static func sections(at path: String) throws -> [String: [String: String]] {
        let expanded = expand(path)
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw BastionError.configNotFound(path: expanded)
        }
        return parse(try String(contentsOfFile: expanded, encoding: .utf8))
    }

    static func parse(_ contents: String) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        var current: String?
        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") { continue }
            if trimmed.first == "[", trimmed.last == "]" {
                let name = String(trimmed.dropFirst().dropLast())
                current = name
                result[name, default: [:]] = result[name] ?? [:]
                continue
            }
            guard let current, let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            result[current]?[key] = value
        }
        return result
    }

    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
