#if os(iOS)
    import Libbox
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
        @Published var splitMode = AgentSettings.splitMode
        @Published var splitApps = AgentSettings.splitApps
        @Published var splitExtra = AgentSettings.splitExtra

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
            persistServer()
            ok("server-saved", "Server saved.")
        }

        func testServer() async {
            persistServer()
            persistProxy()
            guard AgentAPI.configured else { return fail("server-test-skip", "Fill URL (http/https) and token first.") }
            busy = true
            defer { busy = false }
            do {
                let reply = try await AgentAPI.send("ping")
                if reply.status == 200 {
                    ok("server-test-ok", "Server reachable. HTTP \(reply.status).")
                } else {
                    fail("server-test-fail", "Test failed: http \(reply.status) \(reply.text)")
                }
            } catch {
                fail("server-test-error", "Test failed: \(error.localizedDescription)")
            }
        }

        func saveProxy() {
            persistProxy()
            ok("proxy-saved", "Proxy saved. Ping checks login, not only the port.")
        }

        func pingProxy() async {
            persistProxy()
            guard AgentSettings.proxyConfigured else { return fail("proxy-ping-skip", "Fill proxy host and port.") }
            busy = true
            defer { busy = false }
            do {
                let ms = try await AgentHTTP.pingProxy()
                ok("proxy-ping-ok", "Proxy login OK in \(ms) ms. You can turn on “Use proxy for agent”.")
            } catch {
                fail("proxy-ping-error", "Proxy handshake failed: \(error.localizedDescription)")
            }
        }

        func importProxy(environments: ExtensionEnvironments) async {
            persistProxy()
            persistSplit()
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
                ok("proxy-imported", "Profile “\(name)” saved. Open Dashboard, start it, then stop/start if it was already running.")
            } catch {
                fail("proxy-import-error", error.localizedDescription)
            }
        }

        func applySplit(environments: ExtensionEnvironments) async {
            persistSplit()
            busy = true
            defer { busy = false }
            do {
                let id = await SharedPreferences.selectedProfileID.get()
                guard id > 0, let profile = try await ProfileManager.get(id) else {
                    return fail("split-skip", "Open Dashboard and select a profile first.")
                }
                let json = try await profile.readAsync()
                let patched = try SplitTunnel.apply(json)
                var error: NSError?
                LibboxCheckConfig(patched, &error)
                if let error { throw error }
                try await profile.writeAsync(patched)
                profile.lastUpdated = Date()
                try await ProfileManager.update(profile)
                environments.postReload()
                environments.profileUpdate.send()
                ok("split-applied", "Split tunnel saved on “\(profile.name)”. Stop and start the tunnel once.")
            } catch {
                fail("split-error", error.localizedDescription)
            }
        }

        func importShareLink(_ raw: String, environments: ExtensionEnvironments) async {
            persistSplit()
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return fail("share-empty", "Paste a share link first.") }
            busy = true
            defer { busy = false }
            do {
                let parsed = try VLESSImport.profile(from: text)
                try await ShareLinkImport.save(name: parsed.name, json: parsed.json, environments: environments)
                shareLink = ""
                ok("share-imported", "Profile “\(parsed.name)” imported. Start it from Dashboard.")
            } catch {
                fail("share-error", error.localizedDescription)
            }
        }

        func sendDiagnostics() async {
            persistServer()
            persistProxy()
            guard AgentAPI.configured else { return fail("send-report-skip", "Fill server URL and token, then Test.") }
            busy = true
            defer { busy = false }
            DiagnosticsLog.log("app", "send-report-tap")
            var log = DiagnosticsLog.readAll()
            if log.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                log = "event=empty-log\n"
            }
            do {
                let reply = try await AgentAPI.send("report", query: ["device": "iphone"], method: "POST", body: Data(log.utf8))
                if reply.status == 200 {
                    ok("send-report-ok", "Diagnostics sent.")
                } else {
                    fail("send-report-fail", "report failed: http \(reply.status) \(reply.text)")
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
                let reply = try await AgentAPI.send("manifest")
                guard reply.status == 200 else {
                    let message = "manifest http \(reply.status)"
                    if userInitiated { fail("manifest-fail", message) } else { DiagnosticsLog.log("app", "manifest-fail", message) }
                    return
                }
                let manifest = try JSONDecoder().decode(AgentManifest.self, from: reply.body)
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
            persistSplit()
            guard AgentAPI.configured else { return fail("profile-skip", "Fill server URL and token first.") }
            busy = true
            defer { busy = false }
            DiagnosticsLog.log("app", "fetch-profile", entry.name)
            do {
                let reply = try await AgentAPI.send("config", query: ["name": entry.name])
                guard reply.status == 200 else {
                    return fail("profile-fail", "\(entry.name): http \(reply.status)")
                }
                guard let content = String(data: reply.body, encoding: .utf8), content.contains("{") else {
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
                let reply = try await AgentAPI.send("build")
                guard reply.status == 200 else {
                    let message = "build info http \(reply.status)"
                    if userInitiated { fail("build-fail", message) } else { DiagnosticsLog.log("app", "build-fail", message) }
                    return
                }
                buildInfo = try JSONDecoder().decode(AgentBuildInfo.self, from: reply.body)
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
                let reply = try await AgentAPI.send("build-file")
                guard reply.status == 200 else {
                    return fail("download-fail", "download http \(reply.status)")
                }
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(file)
                try? FileManager.default.removeItem(at: dest)
                try reply.body.write(to: dest)
                downloadedFile = dest
                showShare = true
                ok("build-downloaded", "Downloaded \(file). Share the file into ESign.")
            } catch {
                fail("download-error", "download error: \(error.localizedDescription)")
            }
        }

        func appBinding(_ id: String) -> Binding<Bool> {
            Binding(
                get: { self.splitApps.contains(id) },
                set: { on in
                    if on {
                        if !self.splitApps.contains(id) { self.splitApps.append(id) }
                    } else {
                        self.splitApps.removeAll { $0 == id }
                    }
                }
            )
        }

        private func persistServer() {
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

        private func persistSplit() {
            AgentSettings.splitMode = splitMode
            AgentSettings.splitApps = splitApps
            AgentSettings.splitExtra = splitExtra
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
                if !viewModel.status.isEmpty {
                    Section {
                        Text(viewModel.status)
                            .font(.footnote)
                    }
                }
                Section {
                    TextField("http://host/ipa-api.php", text: $viewModel.serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Token", text: $viewModel.serverToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    FormButton {
                        viewModel.saveServer()
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                    FormButton {
                        Task { await viewModel.testServer() }
                    } label: {
                        Label("Test connection", systemImage: "checkmark.circle")
                    }
                    .disabled(viewModel.busy)
                } header: {
                    Text("1. Server")
                } footer: {
                    Text("Plain HTTP is allowed. Test does not use Apple’s URLSession, so ATS will not block it.")
                }
                Section {
                    Toggle("Use proxy for Test and reports", isOn: $viewModel.proxyEnabled)
                    Picker("Type", selection: $viewModel.proxyType) {
                        Text("SOCKS5").tag("socks5")
                        Text("HTTP").tag("http")
                    }
                    TextField("Host", text: $viewModel.proxyHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $viewModel.proxyPort)
                        .keyboardType(.numberPad)
                    TextField("Username", text: $viewModel.proxyUser)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $viewModel.proxyPassword)
                    TextField("Profile name", text: $viewModel.proxyName)
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
                        Label("Make a tunnel profile", systemImage: "plus.circle")
                    }
                    .disabled(viewModel.busy)
                } header: {
                    Text("2. Proxy")
                } footer: {
                    Text("Ping now does a real SOCKS/HTTP login. “Make a tunnel profile” puts this proxy on the Dashboard so apps can use it. Then start that profile instead of the old one.")
                }
                Section {
                    Picker("Mode", selection: $viewModel.splitMode) {
                        Text("All").tag("all")
                        Text("Only listed").tag("whitelist")
                        Text("All except listed").tag("blacklist")
                    }
                    .pickerStyle(.segmented)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 8)], spacing: 8) {
                        ForEach(SplitTunnel.apps) { app in
                            Toggle(app.title, isOn: viewModel.appBinding(app.id))
                                .toggleStyle(.button)
                                .font(.subheadline)
                        }
                    }
                    .padding(.vertical, 4)
                    TextField("Extra domains, comma separated", text: $viewModel.splitExtra)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    FormButton {
                        Task { await viewModel.applySplit(environments: environments) }
                    } label: {
                        Label("Apply to current profile", systemImage: "arrow.triangle.branch")
                    }
                    .disabled(viewModel.busy)
                } header: {
                    Text("3. Split tunnel")
                } footer: {
                    Text("iPhone cannot attach other App Store apps to a personal VPN. These buttons match each app’s sites and IPs. All = everything through the tunnel. Only listed = those apps through the tunnel. All except listed = those apps go direct. Apply, then stop and start the tunnel.")
                }
                Section("Share link") {
                    TextField("vless://…", text: $viewModel.shareLink)
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
