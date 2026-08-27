#if os(iOS)
    import Library
    import SwiftUI
    import UIKit

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

        @Published var serverURL = AgentSettings.baseURL
        @Published var serverToken = AgentSettings.apiToken
        @Published var proxyEnabled = AgentSettings.proxyEnabled
        @Published var proxyType = AgentSettings.proxyType
        @Published var proxyHost = AgentSettings.proxyHost
        @Published var proxyPort = String(AgentSettings.proxyPort)
        @Published var proxyUser = AgentSettings.proxyUser
        @Published var proxyPassword = AgentSettings.proxyPassword
        @Published var proxyName = "proxy-1"

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

        func saveServer() {
            AgentSettings.baseURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            AgentSettings.apiToken = serverToken.trimmingCharacters(in: .whitespacesAndNewlines)
            ok("server-saved", "Server settings saved.")
        }

        func testServer() async {
            saveServerQuiet()
            guard AgentAPI.configured else { return fail("server-test-skip", "Fill URL (http/https) and token, then Save.") }
            busy = true
            defer { busy = false }
            let started = Date()
            do {
                let request = try AgentAPI.request("ping")
                let (data, response) = try await AgentAPI.session().data(for: request)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                let text = String(data: data, encoding: .utf8) ?? ""
                if code == 200 {
                    ok("server-test-ok", "Server reachable in \(ms) ms.")
                } else {
                    fail("server-test-fail", "Test failed: http \(code) \(text)")
                }
            } catch {
                fail("server-test-error", "Test failed: \(error.localizedDescription)")
            }
        }

        func saveProxy() {
            persistProxy()
            ok("proxy-saved", "Proxy settings saved. Enable Use proxy to send reports through it.")
        }

        func pingProxy() async {
            persistProxy()
            let host = AgentSettings.proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
            let port = AgentSettings.proxyPort
            guard !host.isEmpty, port > 0 else { return fail("proxy-ping-skip", "Fill proxy host and port.") }
            busy = true
            defer { busy = false }
            do {
                let ms = try await AgentAPI.tcpPing(host: host, port: port)
                ok("proxy-ping-ok", "Proxy \(host):\(port) reachable in \(ms) ms.")
            } catch {
                fail("proxy-ping-error", "Proxy ping failed: \(error.localizedDescription)")
            }
        }

        func importProxy(environments: ExtensionEnvironments) async {
            persistProxy()
            let host = AgentSettings.proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
            let port = AgentSettings.proxyPort
            let name = proxyName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty, port > 0 else { return fail("proxy-import-skip", "Fill proxy host and port.") }
            guard !name.isEmpty else { return fail("proxy-import-skip", "Fill profile name.") }
            busy = true
            defer { busy = false }
            do {
                try await ShareLinkImport.saveProxy(
                    name: name,
                    type: AgentSettings.proxyType,
                    host: host,
                    port: port,
                    username: AgentSettings.proxyUser,
                    password: AgentSettings.proxyPassword,
                    environments: environments
                )
                ok("proxy-imported", "Profile \(name) imported. Open Dashboard and start it.")
            } catch {
                fail("proxy-import-error", error.localizedDescription)
            }
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
                ok("share-imported", "Profile \(parsed.name) imported. Open Dashboard and start it.")
            } catch {
                fail("share-error", error.localizedDescription)
            }
        }

        func sendDiagnostics() async {
            saveServerQuiet()
            persistProxy()
            guard AgentAPI.configured else { return fail("send-report-skip", "Fill server URL and token, then Save and Test.") }
            busy = true
            defer { busy = false }
            DiagnosticsLog.log("app", "send-report-tap")
            var log = DiagnosticsLog.readAll()
            if log.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                log = "event=empty-log\n"
            }
            do {
                let request = try AgentAPI.request("report", query: ["device": "iphone"], method: "POST", body: Data(log.utf8))
                let (data, response) = try await AgentAPI.session().data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if code == 200 {
                    ok("send-report-ok", "Diagnostics sent. Tell the agent the report left the phone.")
                } else {
                    fail("send-report-fail", "report failed: http \(code) \(text)")
                }
            } catch {
                fail("send-report-error", "report error: \(error.localizedDescription)")
            }
        }

        func reloadManifest(userInitiated: Bool = false) async {
            guard AgentAPI.configured else {
                if userInitiated { fail("manifest-skip", "Fill server URL and token first.") }
                return
            }
            do {
                let request = try AgentAPI.request("manifest")
                let (data, response) = try await AgentAPI.session().data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    let message = "manifest http \((response as? HTTPURLResponse)?.statusCode ?? -1)"
                    if userInitiated { fail("manifest-fail", message) } else { DiagnosticsLog.log("app", "manifest-fail", message) }
                    return
                }
                let manifest = try JSONDecoder().decode(AgentManifest.self, from: data)
                profiles = manifest.profiles ?? []
                DiagnosticsLog.log("app", "manifest-ok", "count=\(profiles.count)")
                if userInitiated {
                    ok("manifest-ok", profiles.isEmpty ? "No profiles on server yet." : "Loaded \(profiles.count) profile(s).")
                }
            } catch {
                if userInitiated {
                    fail("manifest-error", "manifest error: \(error.localizedDescription)")
                } else {
                    DiagnosticsLog.log("app", "manifest-error", error.localizedDescription)
                }
            }
        }

        func importProfile(_ entry: AgentManifest.Entry, environments: ExtensionEnvironments) async {
            guard AgentAPI.configured else { return fail("profile-skip", "Fill server URL and token first.") }
            busy = true
            defer { busy = false }
            DiagnosticsLog.log("app", "fetch-profile", entry.name)
            do {
                let request = try AgentAPI.request("config", query: ["name": entry.name])
                let (data, response) = try await AgentAPI.session().data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    return fail("profile-fail", "\(entry.name): http \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                }
                guard let content = String(data: data, encoding: .utf8), content.contains("{") else {
                    return fail("profile-fail", "\(entry.name): empty or not json")
                }
                try await ShareLinkImport.save(name: entry.name, json: content, environments: environments)
                ok("profile-imported", "Imported \(entry.name). Start it from Dashboard.")
            } catch {
                fail("profile-error", "\(entry.name): \(error.localizedDescription)")
            }
        }

        func checkBuild(userInitiated: Bool = false) async {
            guard AgentAPI.configured else {
                if userInitiated { fail("build-skip", "Fill server URL and token first.") }
                return
            }
            do {
                let request = try AgentAPI.request("build")
                let (data, response) = try await AgentAPI.session().data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    let message = "build info http \((response as? HTTPURLResponse)?.statusCode ?? -1)"
                    if userInitiated { fail("build-fail", message) } else { DiagnosticsLog.log("app", "build-fail", message) }
                    return
                }
                buildInfo = try JSONDecoder().decode(AgentBuildInfo.self, from: data)
                DiagnosticsLog.log("app", "build-info", buildInfo?.version ?? "?")
                if userInitiated {
                    let installed = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                    ok("build-info", "Server build: \(buildInfo?.version ?? "?"). Installed: \(installed)")
                }
            } catch {
                if userInitiated {
                    fail("build-error", "build info error: \(error.localizedDescription)")
                } else {
                    DiagnosticsLog.log("app", "build-error", error.localizedDescription)
                }
            }
        }

        func downloadBuild() async {
            guard AgentAPI.configured else { return fail("download-skip", "Fill server URL and token first.") }
            guard let info = buildInfo, let file = info.file, !file.isEmpty else {
                return fail("download-skip", "no build on server")
            }
            busy = true
            defer { busy = false }
            DiagnosticsLog.log("app", "download-build", info.version ?? "?")
            do {
                let request = try AgentAPI.request("build-file")
                let (tmpURL, response) = try await AgentAPI.session().download(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    return fail("download-fail", "download http \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                }
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(file)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmpURL, to: dest)
                downloadedFile = dest
                showShare = true
                ok("build-downloaded", "Downloaded \(file). Share the file into ESign.")
            } catch {
                fail("download-error", "download error: \(error.localizedDescription)")
            }
        }

        private func saveServerQuiet() {
            AgentSettings.baseURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            AgentSettings.apiToken = serverToken.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func persistProxy() {
            AgentSettings.proxyEnabled = proxyEnabled
            AgentSettings.proxyType = proxyType
            AgentSettings.proxyHost = proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
            AgentSettings.proxyPort = Int(proxyPort) ?? 1080
            AgentSettings.proxyUser = proxyUser.trimmingCharacters(in: .whitespacesAndNewlines)
            AgentSettings.proxyPassword = proxyPassword
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
                Section("Agent server") {
                    TextField("http://host/ipa-api.php", text: $viewModel.serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("token", text: $viewModel.serverToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    FormButton {
                        viewModel.saveServer()
                    } label: {
                        Label("Save server", systemImage: "square.and.arrow.down")
                    }
                    FormButton {
                        Task { await viewModel.testServer() }
                    } label: {
                        Label("Test server", systemImage: "checkmark.circle")
                    }
                    .disabled(viewModel.busy)
                }
                Section("Proxy") {
                    Toggle("Use proxy for agent", isOn: $viewModel.proxyEnabled)
                    Picker("Type", selection: $viewModel.proxyType) {
                        Text("SOCKS5").tag("socks5")
                        Text("HTTP").tag("http")
                    }
                    TextField("host", text: $viewModel.proxyHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("port", text: $viewModel.proxyPort)
                        .keyboardType(.numberPad)
                    TextField("username", text: $viewModel.proxyUser)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("password", text: $viewModel.proxyPassword)
                    TextField("profile name", text: $viewModel.proxyName)
                        .textInputAutocapitalization(.never)
                    FormButton {
                        viewModel.saveProxy()
                    } label: {
                        Label("Save proxy", systemImage: "square.and.arrow.down")
                    }
                    FormButton {
                        Task { await viewModel.pingProxy() }
                    } label: {
                        Label("Ping proxy", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(viewModel.busy)
                    FormButton {
                        Task { await viewModel.importProxy(environments: environments) }
                    } label: {
                        Label("Import proxy as profile", systemImage: "plus.circle")
                    }
                    .disabled(viewModel.busy)
                }
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
                        Text("server: \(version) / installed: \(installedVersion)")
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
                if AgentAPI.configured {
                    Task {
                        await viewModel.reloadManifest()
                        await viewModel.checkBuild()
                    }
                }
            }
        }
    }
#endif
