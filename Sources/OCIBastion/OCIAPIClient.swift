import Foundation

struct RegionSubscription: Decodable, Hashable {
    let regionName: String
    let isHomeRegion: Bool?
    let status: String?
}

struct CompartmentItem: Identifiable, Hashable {
    let id: String
    let label: String
}

struct CompartmentRecord: Decodable, Hashable {
    let id: String
    let name: String
    let compartmentId: String
    let lifecycleState: String?
}

struct BastionItem: Identifiable, Hashable {
    let id: String
    let name: String
    let compartmentID: String
}

struct BastionDetails: Decodable, Equatable {
    let id: String
    let name: String
    let compartmentId: String
    let lifecycleState: String?
    let dnsProxyStatus: String?
    let maxSessionTtlInSeconds: Int?
    let clientCidrBlockAllowList: [String]?

    var supportsSOCKS: Bool { dnsProxyStatus == "ENABLED" }
}

struct OCISession: Decodable, Equatable {
    struct Target: Codable, Equatable {
        var sessionType: String
        var targetResourcePrivateIpAddress: String?
        var targetResourcePort: Int?
        var targetResourceFqdn: String?
    }
    struct KeyDetails: Codable, Equatable {
        var publicKeyContent: String
    }

    let id: String
    let bastionId: String?
    let displayName: String?
    let lifecycleState: String
    let lifecycleDetails: String?
    let timeCreated: Date?
    let sessionTtlInSeconds: Int?
    let targetResourceDetails: Target?
    let keyDetails: KeyDetails?
    let sshMetadata: [String: String]?

    var expiresAt: Date? {
        guard let timeCreated, let sessionTtlInSeconds else { return nil }
        return timeCreated.addingTimeInterval(TimeInterval(sessionTtlInSeconds))
    }

    /// `usuario@host` del comando SSH que publica OCI.
    var sshTarget: String? {
        guard let command = sshMetadata?["command"] else { return nil }
        let regex = try? NSRegularExpression(pattern: #"[A-Za-z0-9._-]+@[A-Za-z0-9._-]+"#)
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        guard let match = regex?.matches(in: command, range: range).last,
              let matchRange = Range(match.range, in: command) else { return nil }
        return String(command[matchRange])
    }
}

private struct APIFailure: Decodable {
    let code: String?
    let message: String?
}

/// Dominio del realm de cada región (oc1 por defecto).
enum OCIRealm {
    static func domain(for region: String) -> String {
        switch region {
        case "us-langley-1", "us-luke-1", "us-gov-ashburn-1", "us-gov-chicago-1", "us-gov-phoenix-1":
            return "oraclegovcloud.com"
        case "uk-gov-london-1", "uk-gov-cardiff-1":
            return "oraclegovcloud.uk"
        case "eu-frankfurt-2", "eu-madrid-2":
            return "oraclecloud.eu"
        default:
            return "oraclecloud.com"
        }
    }

    static func host(_ service: String, region: String) -> String {
        "\(service).\(region).oci.\(domain(for: region))"
    }
}

/// Cliente REST mínimo de OCI: Identity, Search y Bastion.
struct OCIAPIClient {
    let profile: OCIProfile
    let region: String
    private let signer: OCIRequestSigner
    private let session: URLSession

    static func make(profile: OCIProfile, region: String? = nil, proxy: ProxyEndpoint?) async throws -> OCIAPIClient {
        let signer = try await OCIRequestSigner.make(profile: profile)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        if let proxy {
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable: 1, kCFNetworkProxiesHTTPProxy: proxy.host, kCFNetworkProxiesHTTPPort: proxy.port,
                kCFNetworkProxiesHTTPSEnable: 1, kCFNetworkProxiesHTTPSProxy: proxy.host, kCFNetworkProxiesHTTPSPort: proxy.port
            ]
        } else {
            configuration.connectionProxyDictionary = [:]
        }
        let chosen = region.flatMap { $0.isEmpty ? nil : $0 } ?? profile.region
        return OCIAPIClient(profile: profile, region: chosen, signer: signer, session: URLSession(configuration: configuration))
    }

    // MARK: Identity

    func regionSubscriptions() async throws -> [RegionSubscription] {
        try await get(OCIRealm.host("identity", region: profile.region),
                      "/20160918/tenancies/\(profile.tenancy)/regionSubscriptions")
    }

    func listCompartments() async throws -> [CompartmentRecord] {
        try await getAll(OCIRealm.host("identity", region: region), "/20160918/compartments", query: [
            URLQueryItem(name: "compartmentId", value: profile.tenancy),
            URLQueryItem(name: "compartmentIdInSubtree", value: "true"),
            URLQueryItem(name: "accessLevel", value: "ACCESSIBLE"),
            URLQueryItem(name: "limit", value: "1000")
        ]).filter { $0.lifecycleState == nil || $0.lifecycleState == "ACTIVE" }
    }

    static func compartmentItems(tenancyID: String, records: [CompartmentRecord]) -> [CompartmentItem] {
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func label(for record: CompartmentRecord) -> String {
            var parts: [String] = []
            var current = record
            var visited = Set<String>()
            while visited.insert(current.id).inserted {
                parts.append(current.name)
                guard current.compartmentId != tenancyID, let parent = byID[current.compartmentId] else { break }
                current = parent
            }
            return parts.reversed().joined(separator: " / ")
        }
        let children = records.map { CompartmentItem(id: $0.id, label: label(for: $0)) }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        return [CompartmentItem(id: tenancyID, label: "Tenancy (raíz)")] + children
    }

    // MARK: Search

    /// Todos los bastiones activos de la región en una sola consulta, sin recorrer compartimentos.
    func searchBastions() async throws -> [BastionItem] {
        struct Body: Encodable { let type = "Structured"; let query: String }
        struct Item: Decodable { let identifier: String; let displayName: String?; let compartmentId: String }
        struct Collection: Decodable { let items: [Item] }
        var items: [Item] = []
        var page: String?
        repeat {
            let query = page.map { [URLQueryItem(name: "page", value: $0)] } ?? []
            let (data, response) = try await send("POST", OCIRealm.host("query", region: region), "/20180409/resources",
                                                  query: query,
                                                  body: Body(query: "query bastion resources where lifecycleState = 'ACTIVE'"))
            items += try Self.decoder.decode(Collection.self, from: data).items
            page = response.value(forHTTPHeaderField: "opc-next-page")
        } while page != nil && items.count < 2000
        return items.map { BastionItem(id: $0.identifier, name: $0.displayName ?? $0.identifier, compartmentID: $0.compartmentId) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Bastion

    private var bastionHost: String { OCIRealm.host("bastion", region: region) }

    func listBastions(compartmentID: String) async throws -> [BastionItem] {
        struct Summary: Decodable { let id: String; let name: String; let compartmentId: String; let lifecycleState: String? }
        let items: [Summary] = try await getAll(bastionHost, "/20210331/bastions",
                                                query: [URLQueryItem(name: "compartmentId", value: compartmentID)])
        return items.filter { $0.lifecycleState == nil || $0.lifecycleState == "ACTIVE" }
            .map { BastionItem(id: $0.id, name: $0.name, compartmentID: $0.compartmentId) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func getBastion(id: String) async throws -> BastionDetails {
        do { return try await get(bastionHost, "/20210331/bastions/\(id)") }
        catch BastionError.api(404, _, _, _) { throw BastionError.bastionNotFound }
    }

    func listActiveSessions(bastionID: String) async throws -> [OCISession] {
        try await getAll(bastionHost, "/20210331/sessions", query: [
            URLQueryItem(name: "bastionId", value: bastionID),
            URLQueryItem(name: "sessionLifecycleState", value: "ACTIVE")
        ])
    }

    func getSession(id: String) async throws -> OCISession {
        try await get(bastionHost, "/20210331/sessions/\(id)")
    }

    func createSession(bastionID: String, displayName: String, publicKey: String,
                       target: OCISession.Target, ttlSeconds: Int) async throws -> OCISession {
        struct Body: Encodable {
            let bastionId: String
            let displayName: String
            let keyType = "PUB"
            let keyDetails: OCISession.KeyDetails
            let targetResourceDetails: OCISession.Target
            let sessionTtlInSeconds: Int
        }
        let body = Body(bastionId: bastionID, displayName: displayName,
                        keyDetails: .init(publicKeyContent: publicKey),
                        targetResourceDetails: target, sessionTtlInSeconds: ttlSeconds)
        let (data, _) = try await send("POST", bastionHost, "/20210331/sessions", body: body)
        return try Self.decoder.decode(OCISession.self, from: data)
    }

    // MARK: Transporte

    private func get<T: Decodable>(_ host: String, _ path: String, query: [URLQueryItem] = []) async throws -> T {
        let (data, _) = try await send("GET", host, path, query: query, body: Optional<String>.none)
        do { return try Self.decoder.decode(T.self, from: data) }
        catch { throw BastionError.message("Respuesta de OCI inesperada en \(path): \(error.localizedDescription)") }
    }

    private func getAll<T: Decodable>(_ host: String, _ path: String, query: [URLQueryItem]) async throws -> [T] {
        var results: [T] = []
        var page: String?
        repeat {
            let pageQuery = query + (page.map { [URLQueryItem(name: "page", value: $0)] } ?? [])
            let (data, response) = try await send("GET", host, path, query: pageQuery, body: Optional<String>.none)
            results += try Self.decoder.decode([T].self, from: data)
            page = response.value(forHTTPHeaderField: "opc-next-page")
        } while page != nil && results.count < 5000
        return results
    }

    private func send<B: Encodable>(_ method: String, _ host: String, _ path: String,
                                    query: [URLQueryItem] = [], body: B?) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw BastionError.message("URL de OCI no válida: \(host)\(path)") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("OCIBastion-macOS", forHTTPHeaderField: "user-agent")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        try signer.sign(&request)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw BastionError.network(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw BastionError.network("respuesta no HTTP") }
        guard (200..<300).contains(http.statusCode) else {
            let failure = try? JSONDecoder().decode(APIFailure.self, from: data)
            throw BastionError.api(status: http.statusCode, code: failure?.code ?? "Error",
                                   message: failure?.message ?? String(decoding: data.prefix(300), as: UTF8.self),
                                   requestID: http.value(forHTTPHeaderField: "opc-request-id"))
        }
        return (data, http)
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            if let date = parseDate(value) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Fecha no válida: \(value)"))
        }
        return decoder
    }()

    static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
