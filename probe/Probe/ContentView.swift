import SwiftUI
import UIKit

struct ContentView: View {
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
                    .buttonStyle(.borderedProminent)
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
