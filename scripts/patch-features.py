#!/usr/bin/env python3
"""Add agent bridge features: diagnostics ring log, agent center UI, tunnel events.

Files land in file-system synchronized groups, so Xcode picks them up with no
pbxproj edits. API URL/token come from env (CI secrets); placeholders left in
place disable the feature at runtime.
"""

from __future__ import annotations

import os
from pathlib import Path

ROOT = Path(os.environ.get("SIDELOAD_SRC", "sing-box-for-apple"))


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    if old not in text:
        if new.strip() in text:
            print("ALREADY", path)
            return
        raise SystemExit(f"pattern not found in {path}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print("PATCH", path)


def write_file(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    print("WRITE", path)


DIAGNOSTICS_LOG = '''import Foundation

public enum DiagnosticsLog {
    private static let maxBytes = 400_000
    private static let trimToBytes = 200_000
    private static let queue = DispatchQueue(label: "sfi.diagnostics.log")
    private static let formatter = ISO8601DateFormatter()

    private static var fileURL: URL {
        FilePath.sharedDirectory.appendingPathComponent("diagnostics.jsonl")
    }

    public static func log(_ proc: String, _ event: String, _ detail: String = "") {
        queue.async {
            var object: [String: String] = [
                "ts": formatter.string(from: Date()),
                "proc": proc,
                "event": event,
            ]
            if !detail.isEmpty {
                object["detail"] = String(detail.prefix(300))
            }
            guard let data = try? JSONSerialization.data(withJSONObject: object),
                  let text = String(data: data, encoding: .utf8)
            else { return }
            append(text + "\\n")
        }
    }

    public static func readAll() -> String {
        queue.sync {
            (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        }
    }

    public static func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private static func append(_ text: String) {
        let url = fileURL
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            if let data = text.data(using: .utf8) {
                handle.write(data)
            }
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        trimIfNeeded(url)
    }

    private static func trimIfNeeded(_ url: URL) {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size > maxBytes
        else { return }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = content.split(separator: "\\n", omittingEmptySubsequences: false)
        var kept: [Substring] = []
        var total = 0
        for line in lines.reversed() {
            total += line.count + 1
            if total > trimToBytes {
                break
            }
            kept.append(line)
        }
        let trimmed = kept.reversed().joined(separator: "\\n")
        try? trimmed.write(to: url, atomically: true, encoding: .utf8)
    }
}
'''

AGENT_CENTER = '''#if os(iOS)
    import Library
    import SwiftUI
    import UIKit

    enum AgentAPI {
        static let baseURL = "%%IPA_API_URL%%"
        static let token = "%%IPA_API_TOKEN%%"

        static var configured: Bool {
            baseURL.hasPrefix("http") && !baseURL.contains("%%") && !token.isEmpty && !token.contains("%%")
        }

        static func request(_ action: String, query: [String: String] = [:], method: String = "GET", body: Data? = nil) throws -> URLRequest {
            guard var components = URLComponents(string: baseURL) else {
                throw NSError(domain: "AgentAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "bad base url"])
            }
            var items = [URLQueryItem(name: "a", value: action)]
            for (key, value) in query {
                items.append(URLQueryItem(name: key, value: value))
            }
            components.queryItems = items
            guard let url = components.url else {
                throw NSError(domain: "AgentAPI", code: -2, userInfo: [NSLocalizedDescriptionKey: "bad url"])
            }
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.httpMethod = method
            request.setValue(token, forHTTPHeaderField: "X-IPA-Token")
            request.httpBody = body
            return request
        }
    }

    struct AgentManifest: Decodable {
        struct Entry: Decodable, Identifiable {
            let name: String
            let updated: String?
            let note: String?
            var id: String { name }
        }

        let ok: Bool?
        let profiles: [Entry]?
    }

    struct AgentBuildInfo: Decodable {
        let ok: Bool?
        let version: String?
        let file: String?
        let notes: String?
    }

    @MainActor
    final class AgentCenterViewModel: ObservableObject {
        @Published var status = ""
        @Published var busy = false
        @Published var profiles: [AgentManifest.Entry] = []
        @Published var buildInfo: AgentBuildInfo?
        @Published var downloadedFile: URL?
        @Published var showShare = false

        private func fail(_ event: String, _ message: String) {
            status = message
            DiagnosticsLog.log("app", event, message)
        }

        func sendDiagnostics() async {
            guard AgentAPI.configured else { return fail("send-report-skip", "agent api not configured") }
            busy = true
            defer { busy = false }
            DiagnosticsLog.log("app", "send-report-tap")
            let log = DiagnosticsLog.readAll()
            do {
                let request = try AgentAPI.request("report", query: ["device": "iphone"], method: "POST", body: Data(log.utf8))
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if code == 200 {
                    status = "report sent: \\(text)"
                    DiagnosticsLog.log("app", "send-report-ok", text)
                } else {
                    fail("send-report-fail", "report failed: http \\(code)")
                }
            } catch {
                fail("send-report-error", "report error: \\(error.localizedDescription)")
            }
        }

        func reloadManifest() async {
            guard AgentAPI.configured else { return fail("manifest-skip", "agent api not configured") }
            do {
                let request = try AgentAPI.request("manifest")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    return fail("manifest-fail", "manifest http \\((response as? HTTPURLResponse)?.statusCode ?? -1)")
                }
                let manifest = try JSONDecoder().decode(AgentManifest.self, from: data)
                profiles = manifest.profiles ?? []
                DiagnosticsLog.log("app", "manifest-ok", "count=\\(profiles.count)")
            } catch {
                fail("manifest-error", "manifest error: \\(error.localizedDescription)")
            }
        }

        func importProfile(_ entry: AgentManifest.Entry, environments: ExtensionEnvironments) async {
            guard AgentAPI.configured else { return fail("profile-skip", "agent api not configured") }
            busy = true
            defer { busy = false }
            DiagnosticsLog.log("app", "fetch-profile", entry.name)
            do {
                let request = try AgentAPI.request("config", query: ["name": entry.name])
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    return fail("profile-fail", "\\(entry.name): http \\((response as? HTTPURLResponse)?.statusCode ?? -1)")
                }
                guard let content = String(data: data, encoding: .utf8), content.contains("{") else {
                    return fail("profile-fail", "\\(entry.name): empty or not json")
                }
                if let existing = try await ProfileManager.get(by: entry.name) {
                    try await existing.writeAsync(content)
                    existing.lastUpdated = Date()
                    try await ProfileManager.update(existing)
                    status = "updated: \\(entry.name)"
                    DiagnosticsLog.log("app", "profile-updated", entry.name)
                } else {
                    let profile = Profile(name: entry.name, type: .local, path: "agent-\\(entry.name).json", lastUpdated: Date())
                    try await ProfileManager.create(profile)
                    try await profile.writeAsync(content)
                    status = "imported: \\(entry.name)"
                    DiagnosticsLog.log("app", "profile-imported", entry.name)
                }
                environments.postReload()
            } catch {
                fail("profile-error", "\\(entry.name): \\(error.localizedDescription)")
            }
        }

        func checkBuild() async {
            guard AgentAPI.configured else { return fail("build-skip", "agent api not configured") }
            do {
                let request = try AgentAPI.request("build")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    return fail("build-fail", "build info http \\((response as? HTTPURLResponse)?.statusCode ?? -1)")
                }
                buildInfo = try JSONDecoder().decode(AgentBuildInfo.self, from: data)
                DiagnosticsLog.log("app", "build-info", buildInfo?.version ?? "?")
            } catch {
                fail("build-error", "build info error: \\(error.localizedDescription)")
            }
        }

        func downloadBuild() async {
            guard AgentAPI.configured else { return fail("download-skip", "agent api not configured") }
            guard let info = buildInfo, let file = info.file, !file.isEmpty else {
                return fail("download-skip", "no build on server")
            }
            busy = true
            defer { busy = false }
            DiagnosticsLog.log("app", "download-build", info.version ?? "?")
            do {
                let request = try AgentAPI.request("build-file")
                let (tmpURL, response) = try await URLSession.shared.download(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    return fail("download-fail", "download http \\((response as? HTTPURLResponse)?.statusCode ?? -1)")
                }
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(file)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmpURL, to: dest)
                downloadedFile = dest
                showShare = true
                status = "downloaded: \\(file)"
                DiagnosticsLog.log("app", "build-downloaded", file)
            } catch {
                fail("download-error", "download error: \\(error.localizedDescription)")
            }
        }
    }

    struct ActivityShareSheet: UIViewControllerRepresentable {
        let activityItems: [Any]

        func makeUIViewController(context _: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        }

        func updateUIViewController(_: UIActivityViewController, context _: Context) {}
    }

    public struct AgentCenterView: View {
        @EnvironmentObject private var environments: ExtensionEnvironments
        @StateObject private var viewModel = AgentCenterViewModel()

        public init() {}

        private var installedVersion: String {
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        }

        public var body: some View {
            FormView {
                if !AgentAPI.configured {
                    Section {
                        Text("agent api not configured")
                    }
                } else {
                    Section("Diagnostics") {
                        FormButton {
                            Task { await viewModel.sendDiagnostics() }
                        } label: {
                            Label("Send diagnostics", systemImage: "square.and.arrow.up")
                        }
                        .disabled(viewModel.busy)
                    }
                    Section("Profiles from agent") {
                        if viewModel.profiles.isEmpty {
                            Text("empty")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(viewModel.profiles) { entry in
                            Button {
                                Task { await viewModel.importProfile(entry, environments: environments) }
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(entry.name)
                                        .foregroundStyle(.primary)
                                    if let note = entry.note, !note.isEmpty {
                                        Text(note)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(viewModel.busy)
                        }
                        FormButton {
                            Task { await viewModel.reloadManifest() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(viewModel.busy)
                    }
                    Section("Build") {
                        if let info = viewModel.buildInfo, let version = info.version {
                            Text("server: \\(version) / installed: \\(installedVersion)")
                                .font(.footnote)
                            FormButton {
                                Task { await viewModel.downloadBuild() }
                            } label: {
                                Label("Download build", systemImage: "arrow.down.doc")
                            }
                            .disabled(viewModel.busy)
                        }
                        FormButton {
                            Task { await viewModel.checkBuild() }
                        } label: {
                            Label("Check for build", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(viewModel.busy)
                    }
                    if !viewModel.status.isEmpty {
                        Section {
                            Text(viewModel.status)
                                .font(.footnote)
                        }
                    }
                }
            }
            .navigationTitle("Agent")
            .sheet(isPresented: $viewModel.showShare) {
                if let url = viewModel.downloadedFile {
                    ActivityShareSheet(activityItems: [url])
                }
            }
            .onAppear {
                DiagnosticsLog.log("app", "agent-center-open")
                Task {
                    await viewModel.reloadManifest()
                    await viewModel.checkBuild()
                }
            }
        }
    }
#endif
'''


def main() -> None:
    api_url = os.environ.get("IPA_API_URL", "").strip()
    api_token = os.environ.get("IPA_API_TOKEN", "").strip()
    agent_center = AGENT_CENTER.replace("%%IPA_API_URL%%", api_url or "%%IPA_API_URL%%")
    agent_center = agent_center.replace("%%IPA_API_TOKEN%%", api_token or "%%IPA_API_TOKEN%%")

    write_file(ROOT / "Library" / "Shared" / "DiagnosticsLog.swift", DIAGNOSTICS_LOG)
    write_file(ROOT / "ApplicationLibrary" / "Views" / "Tools" / "AgentCenterView.swift", agent_center)
    print("CONFIG", "api url set" if api_url else "api url MISSING (feature disabled at runtime)")

    replace_once(
        ROOT / "ApplicationLibrary" / "Views" / "Tools" / "ToolsView.swift",
        '            Section("Network") {',
        '''            #if os(iOS)
                Section("Agent") {
                    FormNavigationLink {
                        AgentCenterView()
                    } label: {
                        Label("Agent", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
            #endif

            Section("Network") {''',
    )

    provider = ROOT / "Library" / "Network" / "ExtensionProvider.swift"
    replace_once(
        provider,
        "        LibboxReinstallCrashSignalHandlers()\n        super.init()\n    }",
        "        LibboxReinstallCrashSignalHandlers()\n        super.init()\n        DiagnosticsLog.log(\"tunnel\", \"provider-init\")\n    }",
    )
    replace_once(
        provider,
        "    override open func startTunnel(options startOptions: [String: NSObject]?) async throws {\n",
        "    override open func startTunnel(options startOptions: [String: NSObject]?) async throws {\n        DiagnosticsLog.log(\"tunnel\", \"startTunnel-begin\")\n",
    )
    replace_once(
        provider,
        '            throw ExtensionStartupError("(packet-tunnel) error: setup service: \\(setupError.localizedDescription)")',
        '            DiagnosticsLog.log("tunnel", "setup-fail", setupError.localizedDescription)\n            throw ExtensionStartupError("(packet-tunnel) error: setup service: \\(setupError.localizedDescription)")',
    )
    replace_once(
        provider,
        '            throw ExtensionStartupError("(packet-tunnel) error: start service: \\(error.localizedDescription)")',
        '            DiagnosticsLog.log("tunnel", "service-fail", error.localizedDescription)\n            throw ExtensionStartupError("(packet-tunnel) error: start service: \\(error.localizedDescription)")',
    )
    replace_once(
        provider,
        '        writeMessage("(packet-tunnel): Here I stand")',
        '        writeMessage("(packet-tunnel): Here I stand")\n        DiagnosticsLog.log("tunnel", "service-started")',
    )
    replace_once(
        provider,
        '        writeMessage("(packet-tunnel) stopping, reason: \\(reason)")',
        '        writeMessage("(packet-tunnel) stopping, reason: \\(reason)")\n        DiagnosticsLog.log("tunnel", "stopTunnel", "reason=\\(reason.rawValue)")',
    )

    replace_once(
        ROOT / "SFI" / "ApplicationDelegate.swift",
        '        NSLog("Here I stand")\n',
        '        NSLog("Here I stand")\n        DiagnosticsLog.log("app", "launch")\n',
    )

    profile = ROOT / "Library" / "Network" / "ExtensionProfile.swift"
    replace_once(
        profile,
        "    public func start() async throws {\n",
        "    public func start() async throws {\n        DiagnosticsLog.log(\"app\", \"vpn-start-request\")\n",
    )
    replace_once(
        profile,
        "    public func stop() async throws {\n",
        "    public func stop() async throws {\n        DiagnosticsLog.log(\"app\", \"vpn-stop-request\")\n",
    )
    replace_once(
        profile,
        "        try await manager.saveToPreferences()\n        let options = try await prepareStartOptions()\n        try manager.connection.startVPNTunnel(options: options)\n",
        "        try await manager.saveToPreferences()\n        let options = try await prepareStartOptions()\n        do {\n            try manager.connection.startVPNTunnel(options: options)\n        } catch {\n            DiagnosticsLog.log(\"app\", \"vpn-start-fail\", error.localizedDescription)\n            throw error\n        }\n",
    )


if __name__ == "__main__":
    main()
