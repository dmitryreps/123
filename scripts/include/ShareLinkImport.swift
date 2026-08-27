import Foundation
import Libbox
import Library

enum ShareLinkImport {
    static func save(name: String, json: String, environments: ExtensionEnvironments) async throws {
        var error: NSError?
        LibboxCheckConfig(json, &error)
        if let error {
            throw error
        }
        if let existing = try await ProfileManager.get(by: name) {
            try await existing.writeAsync(json)
            existing.lastUpdated = Date()
            try await ProfileManager.update(existing)
        } else {
            let next = try await ProfileManager.nextID()
            let path = "configs/config_\(next).json"
            let directory = FilePath.sharedDirectory.appendingPathComponent("configs", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let profile = Profile(name: name, type: .local, path: path, lastUpdated: Date())
            try await ProfileManager.create(profile)
            try await profile.writeAsync(json)
        }
        await MainActor.run {
            environments.postReload()
            environments.profileUpdate.send()
        }
    }

    static func saveProxy(
        name: String,
        type: String,
        host: String,
        port: Int,
        username: String,
        password: String,
        environments: ExtensionEnvironments
    ) async throws {
        let outboundType = type == "http" ? "http" : "socks"
        var outbound: [String: Any] = [
            "type": outboundType,
            "tag": "proxy",
            "server": host,
            "server_port": port,
        ]
        if !username.isEmpty {
            outbound["username"] = username
            outbound["password"] = password
        }
        let config: [String: Any] = [
            "log": ["level": "info"],
            "inbounds": [[
                "type": "tun",
                "tag": "tun-in",
                "address": ["172.19.0.1/30"],
                "auto_route": true,
                "strict_route": true,
                "stack": "system",
            ]],
            "outbounds": [
                outbound,
                ["type": "direct", "tag": "direct"],
            ],
            "route": ["final": "proxy"],
        ]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "ShareLinkImport", code: -1, userInfo: [NSLocalizedDescriptionKey: "bad proxy json"])
        }
        try await save(name: name, json: json, environments: environments)
    }
}
