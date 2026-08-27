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
        @Published var showQR = false
        @Published var shareLink = ""
        @Published var alert: AlertState?

        func fail(_ event: String, _ message: String) {
            status = message
            alert = AlertState(errorMessage: message)
            DiagnosticsLog.log("app", event, message)
        }

        func ok(_ event: String, _ message: String) {
            status = message
            alert = AlertState(title: "OK", message: message)
            DiagnosticsLog.log("app", event, message)
        }

        func importShareLink(_ raw: String, environments: ExtensionEnvironments) async {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return fail("share-empty", "Paste a vless share link first") }
            busy = true
            defer { busy = false }
            do {
                let parsed = try VLESSImport.profile(from: text)
                try await ShareLinkImport.save(name: parsed.name, json: parsed.json, environments: environments)
                shareLink = ""
                ok("share-imported", "Profile \\(parsed.name) imported. Open Dashboard and start it.")
            } catch {
                fail("share-error", error.localizedDescription)
            }
        }

        func sendDiagnostics() async {
            guard AgentAPI.configured else { return fail("send-report-skip", "agent api not configured") }
            busy = true
            defer { busy = false }
            DiagnosticsLog.log("app", "send-report-tap")
            var log = DiagnosticsLog.readAll()
            if log.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                log = "event=empty-log\\n"
            }
            do {
                let request = try AgentAPI.request("report", query: ["device": "iphone"], method: "POST", body: Data(log.utf8))
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if code == 200 {
                    ok("send-report-ok", "Diagnostics sent. Tell the agent the report left the phone.")
                } else {
                    fail("send-report-fail", "report failed: http \\(code) \\(text)")
                }
            } catch {
                fail("send-report-error", "report error: \\(error.localizedDescription)")
            }
        }

        func reloadManifest(userInitiated: Bool = false) async {
            guard AgentAPI.configured else {
                if userInitiated { fail("manifest-skip", "agent api not configured") }
                return
            }
            do {
                let request = try AgentAPI.request("manifest")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    let message = "manifest http \\((response as? HTTPURLResponse)?.statusCode ?? -1)"
                    if userInitiated { fail("manifest-fail", message) } else { DiagnosticsLog.log("app", "manifest-fail", message) }
                    return
                }
                let manifest = try JSONDecoder().decode(AgentManifest.self, from: data)
                profiles = manifest.profiles ?? []
                DiagnosticsLog.log("app", "manifest-ok", "count=\\(profiles.count)")
                if userInitiated {
                    ok("manifest-ok", profiles.isEmpty ? "No profiles on server yet." : "Loaded \\(profiles.count) profile(s).")
                }
            } catch {
                if userInitiated {
                    fail("manifest-error", "manifest error: \\(error.localizedDescription)")
                } else {
                    DiagnosticsLog.log("app", "manifest-error", error.localizedDescription)
                }
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
                    ok("profile-updated", "Updated \\(entry.name). Start it from Dashboard.")
                } else {
                    let profile = Profile(name: entry.name, type: .local, path: "agent-\\(entry.name).json", lastUpdated: Date())
                    try await ProfileManager.create(profile)
                    try await profile.writeAsync(content)
                    status = "imported: \\(entry.name)"
                    ok("profile-imported", "Imported \\(entry.name). Start it from Dashboard.")
                }
                environments.postReload()
            } catch {
                fail("profile-error", "\\(entry.name): \\(error.localizedDescription)")
            }
        }

        func checkBuild(userInitiated: Bool = false) async {
            guard AgentAPI.configured else {
                if userInitiated { fail("build-skip", "agent api not configured") }
                return
            }
            do {
                let request = try AgentAPI.request("build")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    let message = "build info http \\((response as? HTTPURLResponse)?.statusCode ?? -1)"
                    if userInitiated { fail("build-fail", message) } else { DiagnosticsLog.log("app", "build-fail", message) }
                    return
                }
                buildInfo = try JSONDecoder().decode(AgentBuildInfo.self, from: data)
                DiagnosticsLog.log("app", "build-info", buildInfo?.version ?? "?")
                if userInitiated {
                    ok("build-info", "Server build: \\(buildInfo?.version ?? "?"). Installed: \\(Bundle.main.infoDictionary?[\"CFBundleShortVersionString\"] as? String ?? \"?\")")
                }
            } catch {
                if userInitiated {
                    fail("build-error", "build info error: \\(error.localizedDescription)")
                } else {
                    DiagnosticsLog.log("app", "build-error", error.localizedDescription)
                }
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
                ok("build-downloaded", "Downloaded \\(file). Share the file into ESign.")
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
                Section("Share link") {
                    TextField("vless://...", text: $viewModel.shareLink)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    FormButton {
                        Task { await viewModel.importShareLink(viewModel.shareLink, environments: environments) }
                    } label: {
                        Label("Import share link", systemImage: "link")
                    }
                    .disabled(viewModel.busy)
                    FormButton {
                        if let text = UIPasteboard.general.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            viewModel.shareLink = text
                            Task { await viewModel.importShareLink(text, environments: environments) }
                        } else {
                            viewModel.fail("clipboard-empty", "Clipboard is empty")
                        }
                    } label: {
                        Label("Paste and import", systemImage: "doc.on.clipboard")
                    }
                    .disabled(viewModel.busy)
                    FormButton {
                        viewModel.showQR = true
                    } label: {
                        Label("Scan QR", systemImage: "qrcode.viewfinder")
                    }
                    .disabled(viewModel.busy)
                }
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
                            Task { await viewModel.reloadManifest(userInitiated: true) }
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
                            Task { await viewModel.checkBuild(userInitiated: true) }
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
            .alert($viewModel.alert)
            .sheet(isPresented: $viewModel.showQR) {
                QRScannerView { result in
                    viewModel.showQR = false
                    if let text = result.string {
                        viewModel.shareLink = text
                        Task { await viewModel.importShareLink(text, environments: environments) }
                    }
                }
            }
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
    include = Path(__file__).resolve().parent / "include"
    write_file(ROOT / "Library" / "Shared" / "VLESSImport.swift", (include / "VLESSImport.swift").read_text(encoding="utf-8"))
    write_file(
        ROOT / "ApplicationLibrary" / "Views" / "Profile" / "ShareLinkImport.swift",
        (include / "ShareLinkImport.swift").read_text(encoding="utf-8"),
    )
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

    # iOS ATS blocks cleartext HTTP to a public IP. Exception domains do not
    # apply to numeric hosts; NSAllowsArbitraryLoads is required for this drop.
    replace_once(
        ROOT / "SFI" / "Info.plist",
        """	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsLocalNetworking</key>
		<true/>
	</dict>""",
        """	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsArbitraryLoads</key>
		<true/>
		<key>NSAllowsLocalNetworking</key>
		<true/>
	</dict>""",
    )

    replace_once(
        ROOT / "ApplicationLibrary" / "Views" / "Profile" / "NewProfileMenuView.swift",
        "import SwiftUI\nimport UniformTypeIdentifiers\n",
        "import SwiftUI\nimport UniformTypeIdentifiers\n#if canImport(UIKit)\n    import UIKit\n#endif\n",
    )
    replace_once(
        ROOT / "ApplicationLibrary" / "Views" / "Profile" / "NewProfileMenuView.swift",
        '''                #if !os(tvOS)
                    FormButton {
                        showQRScanner = true
                    } label: {
                        Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                    }
                #endif
''',
        '''                #if !os(tvOS)
                    FormButton {
                        showQRScanner = true
                    } label: {
                        Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                    }
                    #if os(iOS)
                        FormButton {
                            if let text = UIPasteboard.general.string {
                                handleQRCodeString(text)
                            } else {
                                alert = AlertState(errorMessage: String(localized: "Clipboard is empty"))
                            }
                        } label: {
                            Label("Paste share link", systemImage: "doc.on.clipboard")
                        }
                    #endif
                #endif
''',
    )
    replace_once(
        ROOT / "ApplicationLibrary" / "Views" / "Profile" / "NewProfileMenuView.swift",
        '''        private func handleQRCodeString(_ string: String) {
            var error: NSError?
            let remoteProfile = LibboxParseRemoteProfileImportLink(string, &error)
''',
        '''        private func handleQRCodeString(_ string: String) {
            if VLESSImport.looksLike(string) {
                Task {
                    do {
                        let parsed = try VLESSImport.profile(from: string)
                        try await ShareLinkImport.save(name: parsed.name, json: parsed.json, environments: environments)
                        alert = AlertState(
                            title: String(localized: "Imported"),
                            message: "Profile \\(parsed.name) is ready. Start it from Dashboard."
                        )
                    } catch {
                        alert = AlertState(action: "import share link", error: error)
                    }
                }
                return
            }
            var error: NSError?
            let remoteProfile = LibboxParseRemoteProfileImportLink(string, &error)
''',
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
