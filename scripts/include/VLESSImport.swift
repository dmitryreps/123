import Foundation

public enum VLESSImportError: Error, LocalizedError {
    case notShareLink
    case badURL
    case missingHost
    case missingUUID

    public var errorDescription: String? {
        switch self {
        case .notShareLink:
            return "Not a vless share link"
        case .badURL:
            return "Could not parse share link"
        case .missingHost:
            return "Share link has no server"
        case .missingUUID:
            return "Share link has no id"
        }
    }
}

public enum VLESSImport {
    public static func looksLike(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("vless://")
    }

    public static func profile(from raw: String) throws -> (name: String, json: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLike(trimmed) else { throw VLESSImportError.notShareLink }
        guard let url = URL(string: trimmed) else { throw VLESSImportError.badURL }
        let uuid = url.user ?? ""
        let host = url.host ?? ""
        let port = url.port ?? 443
        guard !host.isEmpty else { throw VLESSImportError.missingHost }
        guard !uuid.isEmpty else { throw VLESSImportError.missingUUID }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func query(_ key: String) -> String {
            items.first(where: { $0.name == key })?.value ?? ""
        }

        let remark = url.fragment?.removingPercentEncoding ?? ""
        let name = remark.isEmpty ? host : remark
        let security = query("security")
        let flow = query("flow")
        let sni = query("sni")
        let fingerprint = query("fp").isEmpty ? "chrome" : query("fp")
        let publicKey = query("pbk")
        let shortID = query("sid")
        let network = query("type").isEmpty ? "tcp" : query("type")

        var tls: [String: Any] = [:]
        if security == "reality" || security == "tls" {
            tls["enabled"] = true
            if !sni.isEmpty {
                tls["server_name"] = sni
            }
            tls["utls"] = [
                "enabled": true,
                "fingerprint": fingerprint,
            ]
            if security == "reality" {
                tls["reality"] = [
                    "enabled": true,
                    "public_key": publicKey,
                    "short_id": shortID,
                ]
            }
        }

        var outbound: [String: Any] = [
            "type": "vless",
            "tag": "proxy",
            "server": host,
            "server_port": port,
            "uuid": uuid,
            "packet_encoding": "xudp",
        ]
        if !flow.isEmpty {
            outbound["flow"] = flow
        }
        if !tls.isEmpty {
            outbound["tls"] = tls
        }
        let obfuscation = AgentSettings.obfuscation
        if obfuscation == "shadowtls", tls.isEmpty {
            outbound["tls"] = [
                "enabled": true,
                "server_name": "www.apple.com",
                "utls": ["enabled": true, "fingerprint": "chrome"],
            ]
        }
        if network == "ws" {
            var transport: [String: Any] = [
                "type": "ws",
                "path": query("path").isEmpty ? "/" : query("path"),
            ]
            let hostHeader = query("host")
            if !hostHeader.isEmpty {
                transport["headers"] = ["Host": hostHeader]
            }
            outbound["transport"] = transport
        } else if network == "grpc" {
            let service = query("serviceName").isEmpty ? query("service") : query("serviceName")
            outbound["transport"] = [
                "type": "grpc",
                "service_name": service,
            ]
        }

        let config: [String: Any] = [
            "log": ["level": "info"],
            "inbounds": [[
                "type": "tun",
                "tag": "tun-in",
                "address": ["172.19.0.1/30"],
                "auto_route": true,
                "strict_route": true,
                "stack": AgentSettings.tunStack,
                "mtu": AgentSettings.tunMTU,
            ]],
            "outbounds": [
                outbound,
                ["type": "direct", "tag": "direct"],
            ],
            "route": ["final": "proxy"],
        ]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw VLESSImportError.badURL
        }
        return (name, try SplitTunnel.apply(json))
    }
}
