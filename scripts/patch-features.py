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


def main() -> None:
    include = Path(__file__).resolve().parent / "include"
    write_file(ROOT / "Library" / "Shared" / "DiagnosticsLog.swift", DIAGNOSTICS_LOG)
    write_file(ROOT / "Library" / "Shared" / "VLESSImport.swift", (include / "VLESSImport.swift").read_text(encoding="utf-8"))
    write_file(ROOT / "Library" / "Shared" / "AgentSettings.swift", (include / "AgentSettings.swift").read_text(encoding="utf-8"))
    write_file(
        ROOT / "ApplicationLibrary" / "Views" / "Profile" / "ShareLinkImport.swift",
        (include / "ShareLinkImport.swift").read_text(encoding="utf-8"),
    )
    write_file(
        ROOT / "ApplicationLibrary" / "Views" / "Tools" / "AgentCenterView.swift",
        (include / "AgentCenterView.swift").read_text(encoding="utf-8"),
    )
    print("FEATURES copied from scripts/include")

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
