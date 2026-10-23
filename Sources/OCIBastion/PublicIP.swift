import Foundation

/// Comprobación, a petición del usuario, de si su IP pública está en la lista de IPs permitidas del Bastion.
enum PublicIP {
    static func fetch(proxy: ProxyEndpoint?) async throws -> String {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        if let proxy {
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPSEnable: 1, kCFNetworkProxiesHTTPSProxy: proxy.host, kCFNetworkProxiesHTTPSPort: proxy.port
            ]
        }
        let (data, _) = try await URLSession(configuration: configuration)
            .data(from: URL(string: "https://checkip.amazonaws.com")!)
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard InputCheck.isIPAddress(value) else { throw BastionError.network(String(localized: "respuesta inesperada al consultar la IP pública")) }
        return value
    }

    /// `true` si `ip` (IPv4) está dentro de algún bloque CIDR; `nil` si no se puede decidir (IPv6, formato raro).
    static func isAllowed(_ ip: String, by cidrs: [String]) -> Bool? {
        guard let address = ipv4(ip) else { return nil }
        var undecidable = false
        for cidr in cidrs {
            let parts = cidr.split(separator: "/")
            guard let network = ipv4(String(parts[0])),
                  let bits = parts.count == 2 ? Int(parts[1]) : 32, (0...32).contains(bits) else {
                undecidable = true
                continue
            }
            let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << (32 - bits)
            if address & mask == network & mask { return true }
        }
        return undecidable ? nil : false
    }

    private static func ipv4(_ value: String) -> UInt32? {
        var address = in_addr()
        guard inet_pton(AF_INET, value, &address) == 1 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    /// Texto para el usuario con el resultado.
    static func report(ip: String, allowList: [String]) -> String {
        guard !allowList.isEmpty else { return String(localized: "Tu IP pública es \(ip). El Bastion no tiene lista de IPs permitidas.") }
        switch isAllowed(ip, by: allowList) {
        case true?: return String(localized: "✅ Tu IP pública \(ip) está permitida en el Bastion.")
        case false?: return String(localized: "❌ Tu IP pública \(ip) NO está en la lista del Bastion (\(allowList.joined(separator: ", "))). Añádela en la consola de OCI.")
        case nil: return String(localized: "Tu IP pública es \(ip). Compárala con la lista del Bastion: \(allowList.joined(separator: ", ")).")
        }
    }
}
