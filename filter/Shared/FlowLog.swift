import Foundation
import NetworkExtension

enum FlowLog {
    static let suiteName = "group.a05b266105020512.1"
    static let key = "netlog.lines"
    static let maxLines = 500

    static var store: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func lines() -> [String] {
        store.stringArray(forKey: key) ?? []
    }

    static func text() -> String {
        let all = lines()
        if all.isEmpty { return "LOG_EMPTY=yes\nMEANING=No flows yet, or the filter is off, or the app group is missing after ESign." }
        return all.joined(separator: "\n")
    }

    static func clear() {
        store.removeObject(forKey: key)
        store.synchronize()
    }

    static func appendSystem(_ event: String) {
        appendRaw("TIME=\(stamp()) EVENT=\(event)")
    }

    static func append(flow: NEFilterFlow) {
        var parts = [
            "TIME=\(stamp())",
            "APP=\(flow.sourceAppIdentifier ?? "")",
            "APP_VER=\(flow.sourceAppVersion ?? "")",
            "DIR=\(dirName(flow.direction))",
        ]
        if let uid = flow.sourceAppUniqueIdentifier {
            parts.append("APP_UUID=\(uid.base64EncodedString())")
        }
        if let browser = flow as? NEFilterBrowserFlow {
            parts.append("KIND=browser")
            parts.append("URL=\(browser.url?.absoluteString ?? "")")
            parts.append("HOST=\(browser.url?.host ?? "")")
        } else if let socket = flow as? NEFilterSocketFlow {
            parts.append("KIND=socket")
            parts.append("HOST=\(socket.remoteHostname ?? "")")
            if let endpoint = socket.remoteEndpoint {
                parts.append("REMOTE=\(String(describing: endpoint))")
            }
            parts.append("FAMILY=\(socket.socketFamily)")
            parts.append("PROTO=\(socket.socketProtocol)")
        } else {
            parts.append("KIND=other")
        }
        appendRaw(parts.map(safe).joined(separator: " "))
    }

    private static func appendRaw(_ line: String) {
        var all = lines()
        all.append(line)
        if all.count > maxLines {
            all = Array(all.suffix(maxLines))
        }
        store.set(all, forKey: key)
        store.synchronize()
        if let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName) {
            let file = dir.appendingPathComponent("netlog.txt")
            let blob = (all.joined(separator: "\n") + "\n").data(using: .utf8)
            try? blob?.write(to: file, options: .atomic)
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    private static func dirName(_ direction: NETrafficDirection) -> String {
        switch direction {
        case .outbound: return "out"
        case .inbound: return "in"
        case .any: return "any"
        @unknown default: return "\(direction.rawValue)"
        }
    }

    private static func safe(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "")
    }
}
