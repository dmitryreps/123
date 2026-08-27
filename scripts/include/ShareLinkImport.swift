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
}
