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
        @Published var showAddProxy = false
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
        @Published var tunMTU = String(AgentSettings.tunMTU)
        @Published var tunStack = AgentSettings.tunStack
        @Published var obfuscation = AgentSettings.obfuscation

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

        func saveAddedProxy(host: String, port: String, login: String, password: String, type: String, environments: ExtensionEnvironments) async {
            proxyHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            proxyPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
            proxyUser = login.trimmingCharacters(in: .whitespacesAndNewlines)
            proxyPassword = password
            proxyType = type
            let trimmedName = proxyName.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedName.isEmpty || trimmedName == "proxy-1" {
                proxyName = proxyHost.isEmpty ? "proxy-1" : proxyHost
            }
            DiagnosticsLog.log("app", "add-proxy-save")
            await importProxy(environments: environments)
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
                    if reply.via.isEmpty || reply.via == "nw" {
                        ok("send-report-ok", "Diagnostics sent.")
                    } else {
                        ok("send-report-ok", "Diagnostics sent via backup (\(reply.via)).")
                    }
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
            AgentSettings.tunMTU = Int(tunMTU) ?? 1400
            AgentSettings.tunStack = tunStack
            AgentSettings.obfuscation = obfuscation
        }

        func applyRecipe(_ recipe: TrafficRecipe) {
            splitMode = recipe.mode
            if recipe.id == "apps", !splitApps.isEmpty {
                // keep the user’s current app chips
            } else if !recipe.apps.isEmpty {
                splitApps = recipe.apps
            } else {
                splitApps = []
            }
        }

        func autoSetup(recipe: TrafficRecipe, environments: ExtensionEnvironments) async {
            persistServer()
            guard AgentAPI.configured else { return fail("auto-setup-skip", "Save server URL and token first.") }
            busy = true
            defer { busy = false }
            proxyEnabled = false
            persistProxy()
            applyRecipe(recipe)
            persistSplit()
            DiagnosticsLog.log("app", "auto-setup", recipe.id)
            var lines = [
                recipe.title,
                "Control channel: direct, not through a proxy.",
            ]
            do {
                let id = await SharedPreferences.selectedProfileID.get()
                guard id > 0, let profile = try await ProfileManager.get(id) else {
                    return fail("auto-setup-skip", "Open Dashboard, select a profile, then run Auto setup.")
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
                lines.append("Routing saved on “\(profile.name)”.")
            } catch {
                return fail("auto-setup-split", error.localizedDescription)
            }
            do {
                let reply = try await AgentAPI.send("ping")
                if reply.status == 200 {
                    lines.append("Server test: HTTP 200.")
                    lines.append("Stop and start the tunnel once so routing applies.")
                    ok("auto-setup-ok", lines.joined(separator: "\n"))
                } else {
                    lines.append("Server test: HTTP \(reply.status).")
                    fail("auto-setup-test", lines.joined(separator: "\n"))
                }
            } catch {
                lines.append("Server test failed. Start the tunnel, then tap Auto setup again.")
                lines.append(error.localizedDescription)
                fail("auto-setup-test", lines.joined(separator: "\n"))
            }
        }
    }

    struct TrafficRecipe: Identifiable, Hashable {
        let id: String
        let title: String
        let summary: String
        let mode: String
        let apps: [String]

        static let all: [TrafficRecipe] = [
            TrafficRecipe(
                id: "smart",
                title: "Smart",
                summary: "Apple, local network and this app’s server stay direct. Everything else uses the tunnel. Best default.",
                mode: "smart",
                apps: ["apple"]
            ),
            TrafficRecipe(
                id: "full",
                title: "Everything",
                summary: "All internet through the tunnel. Local network still direct. Strongest cover, heavier on battery.",
                mode: "all",
                apps: []
            ),
            TrafficRecipe(
                id: "apps",
                title: "Only selected apps",
                summary: "Only the chips you tap (Telegram, YouTube…) use the tunnel. The rest of the phone stays direct.",
                mode: "whitelist",
                apps: ["telegram", "youtube", "instagram"]
            ),
            TrafficRecipe(
                id: "except",
                title: "All except selected",
                summary: "Tunnel for almost everything. Tapped apps (Apple, bank sites…) stay direct.",
                mode: "blacklist",
                apps: ["apple"]
            ),
        ]

        static func matching(_ mode: String) -> TrafficRecipe {
            all.first(where: { $0.mode == mode }) ?? all[0]
        }
    }

    struct ActivityShareSheet: UIViewControllerRepresentable {
        let activityItems: [Any]

        func makeUIViewController(context _: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        }

        func updateUIViewController(_: UIActivityViewController, context _: Context) {}
    }

    struct TelegramLineField: View {
        let title: String
        @Binding var text: String
        var keyboard: UIKeyboardType = .default
        var isSecure = false
        @FocusState private var focused: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(focused ? Color.accentColor : Color.secondary)
                Group {
                    if isSecure {
                        SecureField("", text: $text)
                    } else {
                        TextField("", text: $text)
                            .keyboardType(keyboard)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                Rectangle()
                    .fill(focused ? Color.accentColor : Color.secondary.opacity(0.45))
                    .frame(height: focused ? 2 : 1)
            }
        }
    }

    struct AddProxySheet: View {
        @Environment(\.dismiss) private var dismiss
        @State private var host: String
        @State private var port: String
        @State private var login: String
        @State private var password: String
        @State private var type: String
        let onSave: (String, String, String, String, String) -> Void

        init(host: String, port: String, login: String, password: String, type: String, onSave: @escaping (String, String, String, String, String) -> Void) {
            _host = State(initialValue: host)
            _port = State(initialValue: port.isEmpty ? "1080" : port)
            _login = State(initialValue: login)
            _password = State(initialValue: password)
            _type = State(initialValue: type.isEmpty ? "socks5" : type)
            self.onSave = onSave
        }

        private var canSave: Bool {
            !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (Int(port) ?? 0) > 0
        }

        var body: some View {
            NavigationView {
                VStack(alignment: .leading, spacing: 0) {
                    Picker("Type", selection: $type) {
                        Text("SOCKS5").tag("socks5")
                        Text("HTTP").tag("http")
                        Text("HTTPS").tag("https")
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)

                    Text("Адрес сокета")
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.top, 22)
                    HStack(alignment: .bottom, spacing: 20) {
                        TelegramLineField(title: "Хост", text: $host)
                        TelegramLineField(title: "Порт", text: $port, keyboard: .numberPad)
                            .frame(width: 88)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                    Text("Учётные данные (необязательно)")
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.top, 28)
                    TelegramLineField(title: "Логин", text: $login)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                    TelegramLineField(title: "Пароль", text: $password, isSecure: true)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)

                    Spacer()

                    HStack {
                        Spacer()
                        Button("Отмена") { dismiss() }
                            .font(.body.weight(.medium))
                        Button("Сохранить") {
                            onSave(host, port, login, password, type)
                            dismiss()
                        }
                        .font(.body.weight(.semibold))
                        .disabled(!canSave)
                        .padding(.leading, 20)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                    .padding(.top, 8)
                }
                .navigationTitle("Добавить прокси")
                .navigationBarTitleDisplayMode(.inline)
            }
            .navigationViewStyle(.stack)
        }
    }

    public struct AgentCenterView: View {
        @EnvironmentObject private var environments: ExtensionEnvironments
        @StateObject private var viewModel = AgentCenterViewModel()
        @State private var selectedRecipe = TrafficRecipe.matching(AgentSettings.splitMode)
        @State private var showAdvanced = false

        public init() {}

        private var installedVersion: String {
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        }

        private var showAppChips: Bool {
            viewModel.splitMode == "whitelist" || viewModel.splitMode == "blacklist"
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
                    Picker("Recipe", selection: $selectedRecipe) {
                        ForEach(TrafficRecipe.all) { recipe in
                            Text(recipe.title).tag(recipe)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedRecipe, perform: { recipe in
                        viewModel.applyRecipe(recipe)
                    })
                    Text(selectedRecipe.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    FormButton {
                        Task { await viewModel.autoSetup(recipe: selectedRecipe, environments: environments) }
                    } label: {
                        Label("Auto setup", systemImage: "wand.and.stars")
                    }
                    .disabled(viewModel.busy)
                } header: {
                    Text("Auto setup")
                } footer: {
                    Text("Picks routing, keeps this app’s server off the proxy, writes it to the Dashboard profile, then tests the server. Restart the tunnel after it finishes.")
                }
                Section {
                    FormButton {
                        viewModel.showAddProxy = true
                    } label: {
                        Label("Добавить прокси", systemImage: "plus")
                    }
                    .disabled(viewModel.busy)
                } header: {
                    Text("Добавить прокси")
                } footer: {
                    Text("Host, port and optional login, like Telegram. Saves a Dashboard profile. SOCKS5 by default.")
                }
                Section {
                    Picker("Mode", selection: $viewModel.splitMode) {
                        Text("Smart").tag("smart")
                        Text("All").tag("all")
                        Text("Only listed").tag("whitelist")
                        Text("All except").tag("blacklist")
                    }
                    .pickerStyle(.segmented)
                    if showAppChips {
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
                    } else if viewModel.splitMode == "smart" {
                        Text("Apple, LAN and the control server stay direct. No chips to tap.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    FormButton {
                        Task { await viewModel.applySplit(environments: environments) }
                    } label: {
                        Label("Apply to current profile", systemImage: "arrow.triangle.branch")
                    }
                    .disabled(viewModel.busy)
                } header: {
                    Text("Traffic")
                } footer: {
                    Text("iPhone cannot pin other App Store apps to a personal tunnel. These chips match sites and IPs. Apply, then stop and start the tunnel.")
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
                    FormButton {
                        Task { await viewModel.sendDiagnostics() }
                    } label: {
                        Label("Send diagnostics", systemImage: "square.and.arrow.up")
                    }
                    .disabled(viewModel.busy)
                } header: {
                    Text("Server")
                } footer: {
                    Text("Same URL and token as before. Test and Send use a POSIX socket first, then TCP if that fails.")
                }
                Section {
                    Picker("Stack", selection: $viewModel.tunStack) {
                        Text("gVisor (fast)").tag("gvisor")
                        Text("System (stable)").tag("system")
                        Text("Mixed").tag("mixed")
                    }
                    .pickerStyle(.menu)
                    TextField("MTU", text: $viewModel.tunMTU)
                        .keyboardType(.numberPad)
                    Picker("Masking", selection: $viewModel.obfuscation) {
                        Text("TLS (HTTPS look)").tag("tls")
                        Text("ShadowTLS (Apple)").tag("shadowtls")
                        Text("None").tag("none")
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Network")
                } footer: {
                    Text("gVisor + MTU 1400 is the default for iOS. Lower MTU (1280) if the tunnel drops. Masking wraps the proxy in TLS so it looks like HTTPS.")
                }
                Section {
                    Toggle("Show advanced", isOn: $showAdvanced)
                }
                if showAdvanced {
                    Section {
                        Toggle("Use proxy for Test and reports", isOn: $viewModel.proxyEnabled)
                        Picker("Type", selection: $viewModel.proxyType) {
                            Text("SOCKS5").tag("socks5")
                            Text("HTTP").tag("http")
                            Text("HTTPS").tag("https")
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
                        Text("Proxy")
                    } footer: {
                        Text("Leave this off for Auto setup. Ping is a real SOCKS/HTTP login. “Make a tunnel profile” puts a SOCKS/HTTP outbound on Dashboard — not the same as a share link.")
                    }
                    Section("Share link") {
                        TextField("Paste share link", text: $viewModel.shareLink)
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
            }
            .navigationTitle("Agent")
            .alert($viewModel.alert)
            .sheet(isPresented: $viewModel.showAddProxy) {
                AddProxySheet(
                    host: viewModel.proxyHost,
                    port: viewModel.proxyPort,
                    login: viewModel.proxyUser,
                    password: viewModel.proxyPassword,
                    type: viewModel.proxyType
                ) { host, port, login, password, type in
                    Task {
                        await viewModel.saveAddedProxy(
                            host: host,
                            port: port,
                            login: login,
                            password: password,
                            type: type,
                            environments: environments
                        )
                    }
                }
            }
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
