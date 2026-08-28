import SwiftUI
import NetworkExtension
import UIKit

struct ContentView: View {
    @State private var enabled = false
    @State private var status = "Filter off. Tap Start watch."
    @State private var logText = ""
    @State private var dump: DumpItem?
    @State private var busy = false

    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Start watch") { Task { await startWatch() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                    Button("Stop") { Task { await stopWatch() } }
                        .buttonStyle(.bordered)
                        .disabled(busy)
                    Button("Copy") {
                        UIPasteboard.general.string = logText
                        dump = DumpItem(title: "COPIED", text: logText)
                    }
                    .buttonStyle(.bordered)
                    Button("Clear") {
                        FlowLog.clear()
                        refresh()
                    }
                    .buttonStyle(.bordered)
                }
                Button("Install profile") { Task { await saveProfile() } }
                    .buttonStyle(.bordered)
                    .disabled(busy)
                Text("If Start watch says permission denied, tap Install profile, install it in Settings, then tap Start watch again.")
                Text("Leave this screen. Open Telegram, Safari, YouTube. Come back — APP= is the bundle id. Traffic is allowed, not blocked.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(logText.isEmpty ? "Waiting…" : logText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
            .navigationTitle("Netlog")
            .onAppear {
                refresh()
                Task { await loadState() }
            }
            .onReceive(tick) { _ in refresh() }
            .sheet(item: $dump) { item in
                NavigationStack {
                    ScrollView {
                        Text(item.text)
                            .font(.system(.footnote, design: .monospaced))
                            .padding()
                    }
                    .navigationTitle(item.title)
                    .toolbar { Button("Close") { dump = nil } }
                }
            }
        }
    }

    private func refresh() {
        logText = FlowLog.text()
    }

    private func loadState() async {
        do {
            try await NEFilterManager.shared().loadFromPreferences()
            enabled = NEFilterManager.shared().isEnabled
            if enabled {
                status = "Watching in background. Open other apps, then look at APP= lines."
            }
        } catch {
            status = "Load failed: \(error.localizedDescription)"
        }
    }

    private func startWatch() async {
        busy = true
        defer { busy = false }
        do {
            try await NEFilterManager.shared().loadFromPreferences()
            let config = NEFilterProviderConfiguration()
            config.filterSockets = true
            config.username = "Netlog"
            config.organization = "Netlog"
            let manager = NEFilterManager.shared()
            manager.providerConfiguration = config
            manager.isEnabled = true
            try await manager.saveToPreferences()
            enabled = true
            FlowLog.appendSystem("app-enabled")
            status = "Watching in background. Open other apps. This screen can stay or you can leave it."
            refresh()
        } catch {
            let ns = error as NSError
            status = "SAVE_FAIL domain=\(ns.domain) code=\(ns.code) \(ns.localizedDescription). Distribution/ESign often gets permission denied without supervised device + get-task-allow."
            dump = DumpItem(title: "ERROR", text: status)
        }
    }

    private func saveProfile() async {
        busy = true
        defer { busy = false }
        let uuid = UUID().uuidString
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        	<key>PayloadContent</key>
        	<array>
        		<dict>
        			<key>PayloadType</key>
        			<string>com.apple.webcontent-filter</string>
        			<key>PayloadVersion</key>
        			<integer>1</integer>
        			<key>PayloadIdentifier</key>
        			<string>app.local.netlog.profile.\(uuid)</string>
        			<key>PayloadUUID</key>
        			<string>\(uuid)</string>
        			<key>PayloadDisplayName</key>
        			<string>Netlog Filter</string>
        			<key>FilterType</key>
        			<string>Plugin</string>
        			<key>FilterSockets</key>
        			<true/>
        			<key>FilterBrowsers</key>
        			<true/>
        			<key>UserDefinedName</key>
        			<string>Netlog</string>
        			<key>PluginBundleID</key>
        			<string>app.local.netlog</string>
        			<key>ContentFilterUUID</key>
        			<string>\(uuid)</string>
        		</dict>
        	</array>
        	<key>PayloadDisplayName</key>
        	<string>Netlog Filter</string>
        	<key>PayloadIdentifier</key>
        	<string>app.local.netlog.profile</string>
        	<key>PayloadType</key>
        	<string>Configuration</string>
        	<key>PayloadUUID</key>
        	<string>\(uuid)</string>
        	<key>PayloadVersion</key>
        	<integer>1</integer>
        </dict>
        </plist>
        """
        let dir = FileManager.default.temporaryDirectory
        let file = dir.appendingPathComponent("Netlog.mobileconfig")
        do {
            try plist.write(to: file, atomically: true, encoding: .utf8)
            status = "Profile saved. Opening Settings… install it, then come back and tap Start watch."
            UIApplication.shared.open(file)
        } catch {
            status = "Profile save failed: \(error.localizedDescription)"
        }
    }

    private func stopWatch() async {
        busy = true
        defer { busy = false }
        do {
            try await NEFilterManager.shared().loadFromPreferences()
            NEFilterManager.shared().isEnabled = false
            try await NEFilterManager.shared().saveToPreferences()
            enabled = false
            FlowLog.appendSystem("app-disabled")
            status = "Filter off."
            refresh()
        } catch {
            status = "Stop failed: \(error.localizedDescription)"
        }
    }
}

struct DumpItem: Identifiable {
    let id = UUID()
    var title: String
    var text: String
}
