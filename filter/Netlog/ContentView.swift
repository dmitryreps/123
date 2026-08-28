import SwiftUI
import NetworkExtension
import UIKit

struct ContentView: View {
    @State private var enabled = false
    @State private var status = "Filter off. Tap Start watch."
    @State private var logText = ""
    @State private var dump: DumpItem?
    @State private var busy = false
    @State private var appBundleID = Bundle.main.bundleIdentifier ?? "unknown.bundle"
    @State private var dataBundleID = ""
    @State private var controlBundleID = ""

    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(bundleInfoText())
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
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
                HStack {
                    Button("Install profile (app)") {
                        Task { await saveProfile(pluginBundleID: appBundleID, label: "app") }
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy)

                    Button("Install profile (data)") {
                        let fallback = dataBundleID.isEmpty ? appBundleID : dataBundleID
                        Task { await saveProfile(pluginBundleID: fallback, label: "data") }
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy)

                    Button("Reload state") { Task { await loadState() } }
                        .buttonStyle(.bordered)
                        .disabled(busy)
                }
                Text("If Start watch says permission denied, install app-profile first. If still denied, install data-profile and retry.")
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
                discoverExtensionBundleIDs()
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

    private func bundleInfoText() -> String {
        let dataID = dataBundleID.isEmpty ? "-" : dataBundleID
        let controlID = controlBundleID.isEmpty ? "-" : controlBundleID
        return "APP=\(appBundleID)\nDATA=\(dataID)\nCTRL=\(controlID)"
    }

    private func discoverExtensionBundleIDs() {
        guard let pluginsURL = Bundle.main.builtInPlugInsURL else { return }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: pluginsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in urls where url.pathExtension == "appex" {
            guard let bundle = Bundle(url: url) else { continue }
            guard let bundleID = bundle.bundleIdentifier else { continue }
            guard let ext = bundle.infoDictionary?["NSExtension"] as? [String: Any] else { continue }
            guard let point = ext["NSExtensionPointIdentifier"] as? String else { continue }

            if point == "com.apple.networkextension.filter-data" {
                dataBundleID = bundleID
            } else if point == "com.apple.networkextension.filter-control" {
                controlBundleID = bundleID
            }
        }
    }

    private func loadState() async {
        do {
            let manager = NEFilterManager.shared()
            try await manager.loadFromPreferences()
            enabled = manager.isEnabled
            let hasConfig = manager.providerConfiguration != nil
            status = "prefs enabled=\(enabled ? "yes" : "no") has_config=\(hasConfig ? "yes" : "no")"
            if enabled {
                status += ". Watching in background. Open other apps, then look at APP= lines."
            }
        } catch {
            status = "Load failed: \(error.localizedDescription)"
        }
    }

    private func startWatch() async {
        busy = true
        defer { busy = false }
        do {
            let manager = NEFilterManager.shared()
            try await manager.loadFromPreferences()
            let config = NEFilterProviderConfiguration()
            config.filterSockets = true
            config.filterBrowsers = true
            config.username = "Netlog"
            config.organization = "Netlog"
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
            if ns.domain == NEFilterErrorDomain || ns.domain == "NEConfigurationErrorDomain" {
                status += " Try Install profile (app), then Start watch; if still denied, try Install profile (data)."
            }
            dump = DumpItem(title: "ERROR", text: status)
        }
    }

    private func saveProfile(pluginBundleID: String, label: String) async {
        busy = true
        defer { busy = false }
        let payloadUUID = UUID().uuidString
        let contentUUID = UUID().uuidString
        let baseID = appBundleID.replacingOccurrences(of: " ", with: "-")
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
        			<string>\(baseID).profile.webcontent.\(label)</string>
        			<key>PayloadUUID</key>
        			<string>\(payloadUUID)</string>
        			<key>PayloadDisplayName</key>
        			<string>Netlog Filter (\(label))</string>
        			<key>FilterType</key>
        			<string>Plugin</string>
        			<key>FilterSockets</key>
        			<true/>
        			<key>FilterBrowsers</key>
        			<true/>
        			<key>UserDefinedName</key>
        			<string>Netlog</string>
        			<key>PluginBundleID</key>
        			<string>\(pluginBundleID)</string>
        			<key>ContentFilterUUID</key>
        			<string>\(contentUUID)</string>
        		</dict>
        	</array>
        	<key>PayloadDisplayName</key>
        	<string>Netlog Filter Profile (\(label))</string>
        	<key>PayloadIdentifier</key>
        	<string>\(baseID).profile.\(label)</string>
        	<key>PayloadType</key>
        	<string>Configuration</string>
        	<key>PayloadUUID</key>
        	<string>\(UUID().uuidString)</string>
        	<key>PayloadVersion</key>
        	<integer>1</integer>
        </dict>
        </plist>
        """
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let file = dir.appendingPathComponent("Netlog-\(label).mobileconfig")
        do {
            try plist.write(to: file, atomically: true, encoding: .utf8)
            FlowLog.appendSystem("profile-saved label=\(label) plugin=\(pluginBundleID)")
            let opened = await UIApplication.shared.open(file)
            if opened {
                status = "Profile saved (\(file.lastPathComponent)). Install it in Settings, then tap Start watch."
            } else {
                UIPasteboard.general.string = plist
                status = "Profile saved to \(file.lastPathComponent). Open Files and install. XML copied to clipboard."
            }
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
