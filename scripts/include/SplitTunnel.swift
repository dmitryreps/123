import Foundation

public struct SplitApp: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let domains: [String]
    public let cidrs: [String]
}

public enum SplitTunnel {
    public static let apps: [SplitApp] = [
        SplitApp(
            id: "telegram",
            title: "Telegram",
            domains: ["telegram.org", "telegram.me", "t.me", "tdesktop.com", "telegra.ph"],
            cidrs: ["149.154.160.0/20", "91.108.4.0/22", "91.108.8.0/22", "91.108.12.0/22", "91.108.16.0/22", "91.108.56.0/22"]
        ),
        SplitApp(
            id: "whatsapp",
            title: "WhatsApp",
            domains: ["whatsapp.com", "whatsapp.net"],
            cidrs: []
        ),
        SplitApp(
            id: "instagram",
            title: "Instagram",
            domains: ["instagram.com", "cdninstagram.com", "facebook.com", "fbcdn.net"],
            cidrs: []
        ),
        SplitApp(
            id: "youtube",
            title: "YouTube",
            domains: ["youtube.com", "youtu.be", "ytimg.com", "googlevideo.com", "ggpht.com"],
            cidrs: []
        ),
        SplitApp(
            id: "tiktok",
            title: "TikTok",
            domains: ["tiktok.com", "tiktokcdn.com", "tiktokv.com", "musical.ly"],
            cidrs: []
        ),
        SplitApp(
            id: "x",
            title: "X / Twitter",
            domains: ["x.com", "twitter.com", "twimg.com", "t.co"],
            cidrs: []
        ),
        SplitApp(
            id: "discord",
            title: "Discord",
            domains: ["discord.com", "discordapp.com", "discord.gg"],
            cidrs: []
        ),
        SplitApp(
            id: "google",
            title: "Google",
            domains: ["google.com", "googleapis.com", "gstatic.com", "googleusercontent.com"],
            cidrs: []
        ),
        SplitApp(
            id: "apple",
            title: "Apple",
            domains: ["apple.com", "icloud.com", "icloud-content.com", "cdn-apple.com", "apple-dns.net", "mzstatic.com", "itunes.com"],
            cidrs: ["17.0.0.0/8"]
        ),
    ]

    public static func apply(_ json: String) throws -> String {
        guard let data = json.data(using: .utf8),
              var config = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw NSError(domain: "SplitTunnel", code: -1, userInfo: [NSLocalizedDescriptionKey: "profile is not JSON"])
        }
        let proxyTag = firstProxyTag(config)
        var inbounds = config["inbounds"] as? [[String: Any]] ?? []
        for index in inbounds.indices where inbounds[index]["type"] as? String == "tun" {
            let exclude = unique((inbounds[index]["route_exclude_address"] as? [String] ?? []) + tunExcludeCIDRs())
            if !exclude.isEmpty {
                inbounds[index]["route_exclude_address"] = exclude
            }
        }
        config["inbounds"] = inbounds
        migrateDNS(&config, proxyTag: proxyTag)

        var route = config["route"] as? [String: Any] ?? [:]
        route["rules"] = buildRules(proxyTag: proxyTag)
        route["final"] = AgentSettings.splitMode == "whitelist" ? "direct" : proxyTag
        config["route"] = route

        let out = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        guard let text = String(data: out, encoding: .utf8) else {
            throw NSError(domain: "SplitTunnel", code: -2, userInfo: [NSLocalizedDescriptionKey: "could not write profile"])
        }
        return text
    }

    private static func firstProxyTag(_ config: [String: Any]) -> String {
        let outbounds = config["outbounds"] as? [[String: Any]] ?? []
        for outbound in outbounds {
            let type = outbound["type"] as? String ?? ""
            if type != "direct", type != "block", type != "dns" {
                return outbound["tag"] as? String ?? "proxy"
            }
        }
        return "proxy"
    }

    private static func buildRules(proxyTag: String) -> [[String: Any]] {
        var rules: [[String: Any]] = [
            ["action": "sniff"],
            ["protocol": "dns", "action": "hijack-dns"],
            ["ip_is_private": true, "outbound": "direct"],
        ]
        if let host = optionalIPv4(AgentSettings.serverHost) {
            rules.append(["ip_cidr": ["\(host)/32"], "outbound": "direct"])
        }
        let selected = apps.filter { AgentSettings.splitApps.contains($0.id) }
        var domains: [String] = extraDomains()
        var cidrs: [String] = []
        for app in selected {
            domains.append(contentsOf: app.domains)
            cidrs.append(contentsOf: app.cidrs)
        }
        domains = unique(domains)
        cidrs = unique(cidrs)
        let mode = AgentSettings.splitMode
        if mode == "whitelist" {
            if !domains.isEmpty {
                rules.append(["domain_suffix": domains, "outbound": proxyTag])
            }
            if !cidrs.isEmpty {
                rules.append(["ip_cidr": cidrs, "outbound": proxyTag])
            }
        } else if mode == "blacklist" || mode == "smart" {
            var directDomains = domains
            var directCidrs = cidrs
            if mode == "smart" {
                if let apple = apps.first(where: { $0.id == "apple" }) {
                    directDomains.append(contentsOf: apple.domains)
                    directCidrs.append(contentsOf: apple.cidrs)
                }
                directDomains.append(contentsOf: [
                    "captive.apple.com",
                    "push.apple.com",
                    "gateway.icloud.com",
                ])
            }
            directDomains = unique(directDomains)
            directCidrs = unique(directCidrs)
            if !directDomains.isEmpty {
                rules.append(["domain_suffix": directDomains, "outbound": "direct"])
            }
            if !directCidrs.isEmpty {
                rules.append(["ip_cidr": directCidrs, "outbound": "direct"])
            }
        }
        return rules
    }

    /// sing-box 1.12 deprecates `{ "address": "8.8.8.8" }`; 1.14 removes it.
    private static func migrateDNS(_ config: inout [String: Any], proxyTag: String) {
        var dns = config["dns"] as? [String: Any] ?? [:]
        var servers: [[String: Any]] = []
        if let list = dns["servers"] as? [Any] {
            for item in list {
                if let migrated = migrateDNSServer(item) {
                    servers.append(migrated)
                }
            }
        }
        if servers.isEmpty {
            servers = [
                ["type": "udp", "tag": "remote", "server": "8.8.8.8", "detour": proxyTag],
                ["type": "local", "tag": "local"],
            ]
        }
        attachDomainResolver(&servers)
        dns["servers"] = servers
        dns.removeValue(forKey: "independent_cache")
        if dns["strategy"] == nil {
            dns["strategy"] = "ipv4_only"
        }
        config["dns"] = dns
    }

    private static func migrateDNSServer(_ raw: Any) -> [String: Any]? {
        if let address = raw as? String {
            return migrateDNSServer(["address": address])
        }
        guard var server = raw as? [String: Any] else { return nil }
        if let type = server["type"] as? String, !type.isEmpty {
            return server
        }
        guard let address = server["address"] as? String, !address.isEmpty else {
            return nil
        }
        server.removeValue(forKey: "address")
        server.removeValue(forKey: "address_resolver")
        server.removeValue(forKey: "address_strategy")
        server.removeValue(forKey: "strategy")
        if address == "local" || address.hasPrefix("local://") {
            server["type"] = "local"
            return server
        }
        if address.hasPrefix("rcode://") {
            return nil
        }
        var type = "udp"
        var rest = address
        if let range = address.range(of: "://") {
            type = String(address[..<range.lowerBound]).lowercased()
            rest = String(address[range.upperBound...])
            if type == "tcp+udp" { type = "udp" }
        }
        if type == "dhcp" {
            server["type"] = "dhcp"
            return server
        }
        if type == "https" || type == "h3", let slash = rest.firstIndex(of: "/") {
            rest = String(rest[..<slash])
        }
        if rest.contains(":"), !rest.hasPrefix("[") {
            let parts = rest.split(separator: ":", maxSplits: 1)
            if parts.count == 2, let port = Int(parts[1]), (1 ... 65535).contains(port) {
                rest = String(parts[0])
                if server["server_port"] == nil {
                    server["server_port"] = port
                }
            }
        }
        server["type"] = type
        server["server"] = rest
        return server
    }

    private static func attachDomainResolver(_ servers: inout [[String: Any]]) {
        let needs = servers.contains { server in
            let type = server["type"] as? String ?? ""
            if type == "local" || type == "dhcp" { return false }
            if server["domain_resolver"] != nil { return false }
            return optionalIPv4(server["server"] as? String) == nil && !(server["server"] as? String ?? "").isEmpty
        }
        guard needs else { return }
        if !servers.contains(where: { ($0["tag"] as? String) == "dns-bootstrap" }) {
            servers.insert(["type": "udp", "tag": "dns-bootstrap", "server": "8.8.8.8"], at: 0)
        }
        for index in servers.indices {
            let type = servers[index]["type"] as? String ?? ""
            if type == "local" || type == "dhcp" { continue }
            if (servers[index]["tag"] as? String) == "dns-bootstrap" { continue }
            if servers[index]["domain_resolver"] != nil { continue }
            if optionalIPv4(servers[index]["server"] as? String) == nil {
                servers[index]["domain_resolver"] = "dns-bootstrap"
            }
        }
    }

    /// Destinations that skip the tunnel at the kernel (physical interface).
    /// Stronger than a sing-box “direct” rule: packets never enter the extension.
    private static func tunExcludeCIDRs() -> [String] {
        var cidrs = [
            "10.0.0.0/8",
            "172.16.0.0/12",
            "192.168.0.0/16",
            "169.254.0.0/16",
        ]
        if let host = optionalIPv4(AgentSettings.serverHost) {
            cidrs.append("\(host)/32")
        }
        let mode = AgentSettings.splitMode
        let appleOffTunnel = mode == "smart" || (mode == "blacklist" && AgentSettings.splitApps.contains("apple"))
        if appleOffTunnel {
            cidrs.append("17.0.0.0/8")
        }
        return cidrs
    }

    private static func extraDomains() -> [String] {
        AgentSettings.splitExtra
            .split(whereSeparator: { ",;\n ".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
            .filter { $0.contains(".") }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func optionalIPv4(_ host: String?) -> String? {
        guard let host, !host.isEmpty else { return nil }
        let parts = host.split(separator: ".")
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return nil }
        return host
    }
}
