import SwiftUI
import UIKit

struct ContentView: View {
    var body: some View {
        TabView {
            HTTPProbePage()
                .tabItem { Label("HTTP", systemImage: "globe") }
            ProxyProbePage()
                .tabItem { Label("Proxy", systemImage: "network") }
        }
    }
}

struct HTTPProbePage: View {
    @AppStorage("probe.baseURL") private var baseURL = ""
    @AppStorage("probe.token") private var token = ""
    @State private var showToken = false
    @State private var busy = false
    @State private var dump: ProbeDump?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("HTTP probe")
                        .font(.title2.bold())
                    Text("Fill URL and token, tap a method. A popup shows success or the full error — copy it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    TextField("http://host/ipa-api.php", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Group {
                            if showToken {
                                TextField("token", text: $token)
                            } else {
                                SecureField("token", text: $token)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        Button(showToken ? "Hide" : "Show") { showToken.toggle() }
                            .font(.footnote)
                    }

                    Button(action: saveSettings) {
                        label("Save URL and token", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || !ready)

                    section("URLSession") {
                        row(.urlSessionGet)
                        row(.urlSessionPost)
                    }
                    section("NWConnection") {
                        row(.nwGet)
                        row(.nwPost)
                    }
                    section("POSIX socket") {
                        row(.posixGet)
                        row(.posixPost)
                    }

                    Button(action: { goAll() }) {
                        label("Run all 6", systemImage: "square.stack.3d.up")
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy || !ready)

                    if busy {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Sending…")
                        }
                        .font(.footnote)
                    }
                }
                .padding()
            }
            .navigationTitle("Probe")
        }
        .sheet(item: $dump) { item in
            ResultSheet(dump: item)
        }
    }

    private var ready: Bool {
        let url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return (url.hasPrefix("http://") || url.hasPrefix("https://")) && !key.isEmpty
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(.top, 4)
    }

    private func row(_ kind: ProbeKind) -> some View {
        Button(action: { go(kind) }) {
            label(kind.title, systemImage: kind.action == "ping" ? "dot.radiowaves.left.and.right" : "square.and.arrow.up")
        }
        .buttonStyle(.bordered)
        .disabled(busy || !ready)
    }

    private func label(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }

    private func saveSettings() {
        baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(baseURL, forKey: "probe.baseURL")
        UserDefaults.standard.set(token, forKey: "probe.token")
        UserDefaults.standard.synchronize()
        let host = URL(string: baseURL)?.host ?? ""
        dump = ProbeDump(
            ok: true,
            title: "SAVED",
            text: [
                "RESULT=saved",
                "URL=\(baseURL)",
                "URL_HOST=\(host)",
                "TOKEN_SET=yes",
                "TOKEN_LEN=\(token.count)",
                "MEANING=URL and token stored on this phone. Token is not shown here. Close the app and reopen — fields should still be filled.",
            ].joined(separator: "\n")
        )
    }

    private func go(_ kind: ProbeKind) {
        busy = true
        Task {
            let result = await ProbeTransport.run(kind, baseURL: baseURL, token: token)
            await MainActor.run {
                busy = false
                dump = result
            }
        }
    }

    private func goAll() {
        busy = true
        Task {
            let result = await ProbeTransport.runAll(baseURL: baseURL, token: token)
            await MainActor.run {
                busy = false
                dump = result
            }
        }
    }
}

struct ProxyProbePage: View {
    @AppStorage("probe.proxyType") private var proxyType = "socks5"
    @AppStorage("probe.proxyHost") private var host = ""
    @AppStorage("probe.proxyPort") private var port = "1080"
    @AppStorage("probe.proxyUser") private var login = ""
    @AppStorage("probe.proxyPassword") private var password = ""
    @AppStorage("probe.proxyWrap") private var wrap = "none"
    @AppStorage("probe.proxyTarget") private var target = "http://api.ipify.org"
    @State private var showPassword = false
    @State private var busy = false
    @State private var dump: ProbeDump?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Proxy probe")
                        .font(.title2.bold())
                    Text("Does not wrap the whole phone. Tests this proxy: login, egress IP, drops, small TCP writes. Copy the dump if it fails.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Picker("Type", selection: $proxyType) {
                        Text("SOCKS5").tag("socks5")
                        Text("HTTP").tag("http")
                    }
                    .pickerStyle(.segmented)

                    HStack(alignment: .bottom, spacing: 12) {
                        field("Host", text: $host)
                        field("Port", text: $port, keyboard: .numberPad)
                            .frame(width: 88)
                    }

                    field("Login (optional)", text: $login)
                    HStack {
                        Group {
                            if showPassword {
                                TextField("Password", text: $password)
                            } else {
                                SecureField("Password", text: $password)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        Button(showPassword ? "Hide" : "Show") { showPassword.toggle() }
                            .font(.footnote)
                    }

                    Picker("Wrap", selection: $wrap) {
                        Text("None").tag("none")
                        Text("TLS").tag("tls")
                    }
                    .pickerStyle(.segmented)
                    Text("TLS only if the proxy itself speaks TLS (stunnel / nginx stream). Raw SOCKS on TLS will fail — that is the test.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    field("Whoami URL", text: $target)
                    Text("HTTP only, default http://api.ipify.org")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button { go(.handshake) } label: { rowLabel("Handshake", "antenna.radiowaves.left.and.right") }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || !ready)

                    Button { go(.whoami) } label: { rowLabel("Whoami (IP via proxy)", "globe") }
                        .buttonStyle(.bordered)
                        .disabled(busy || !ready)

                    Button { go(.compare) } label: { rowLabel("Direct vs proxy", "arrow.left.arrow.right") }
                        .buttonStyle(.bordered)
                        .disabled(busy || !ready)

                    Button { go(.stability) } label: { rowLabel("Stability 20×", "repeat") }
                        .buttonStyle(.bordered)
                        .disabled(busy || !ready)

                    Button { go(.chunk) } label: { rowLabel("Chunk 512 / 1400 / 4096", "square.split.2x1") }
                        .buttonStyle(.bordered)
                        .disabled(busy || !ready)

                    if busy {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Testing…")
                        }
                        .font(.footnote)
                    }
                }
                .padding()
            }
            .navigationTitle("Proxy")
        }
        .sheet(item: $dump) { item in
            ResultSheet(dump: item)
        }
    }

    private var ready: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (UInt16(port) ?? 0) > 0
    }

    private func field(_ title: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
        }
    }

    private func rowLabel(_ title: String, _ image: String) -> some View {
        Label(title, systemImage: image)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }

    private func go(_ test: ProxyTest) {
        busy = true
        let input = ProxyInput(
            kind: ProxyKind(rawValue: proxyType) ?? .socks5,
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: UInt16(port) ?? 1080,
            user: login.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password,
            wrap: ProxyWrap(rawValue: wrap) ?? .none,
            targetURL: target.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        Task {
            let result = await ProxyProbe.run(test, input: input)
            await MainActor.run {
                busy = false
                dump = result
            }
        }
    }
}

struct ResultSheet: View {
    let dump: ProbeDump
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text(dump.title)
                    .font(.title3.bold())
                    .foregroundStyle(dump.ok ? Color.green : Color.red)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(dump.ok ? Color.green.opacity(0.12) : Color.red.opacity(0.12))

                ScrollView {
                    Text(dump.text)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
            .navigationTitle(dump.ok ? "Success" : "Error")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(copied ? "Copied" : "Copy") {
                        UIPasteboard.general.string = "\(dump.title)\n\n\(dump.text)"
                        copied = true
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
