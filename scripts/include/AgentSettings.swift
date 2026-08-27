import Foundation
import Network
#if canImport(CFNetwork)
    import CFNetwork
#endif

public enum AgentSettings {
    private static var store: UserDefaults {
        UserDefaults(suiteName: FilePath.groupName) ?? .standard
    }

    public static var baseURL: String {
        get { store.string(forKey: "agent.baseURL") ?? "" }
        set { store.set(newValue, forKey: "agent.baseURL") }
    }

    public static var apiToken: String {
        get { store.string(forKey: "agent.token") ?? "" }
        set { store.set(newValue, forKey: "agent.token") }
    }

    public static var proxyEnabled: Bool {
        get { store.bool(forKey: "agent.proxyEnabled") }
        set { store.set(newValue, forKey: "agent.proxyEnabled") }
    }

    public static var proxyType: String {
        get { store.string(forKey: "agent.proxyType") ?? "socks5" }
        set { store.set(newValue, forKey: "agent.proxyType") }
    }

    public static var proxyHost: String {
        get { store.string(forKey: "agent.proxyHost") ?? "" }
        set { store.set(newValue, forKey: "agent.proxyHost") }
    }

    public static var proxyPort: Int {
        get {
            let value = store.integer(forKey: "agent.proxyPort")
            return value > 0 ? value : 1080
        }
        set { store.set(newValue, forKey: "agent.proxyPort") }
    }

    public static var proxyUser: String {
        get { store.string(forKey: "agent.proxyUser") ?? "" }
        set { store.set(newValue, forKey: "agent.proxyUser") }
    }

    public static var proxyPassword: String {
        get { store.string(forKey: "agent.proxyPassword") ?? "" }
        set { store.set(newValue, forKey: "agent.proxyPassword") }
    }

    public static var configured: Bool {
        let url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return (url.hasPrefix("http://") || url.hasPrefix("https://")) && !key.isEmpty
    }

    public static var proxyConfigured: Bool {
        !proxyHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && proxyPort > 0
    }
}

public enum AgentAPI {
    public static var configured: Bool { AgentSettings.configured }

    public static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        if AgentSettings.proxyEnabled, AgentSettings.proxyConfigured {
            config.connectionProxyDictionary = proxyDictionary()
        }
        return URLSession(configuration: config)
    }

    public static func request(_ action: String, query: [String: String] = [:], method: String = "GET", body: Data? = nil) throws -> URLRequest {
        let base = AgentSettings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: base) else {
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
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue(AgentSettings.apiToken.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "X-IPA-Token")
        request.httpBody = body
        return request
    }

    public static func tcpPing(host: String, port: Int) async throws -> Int {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw NSError(domain: "AgentAPI", code: -3, userInfo: [NSLocalizedDescriptionKey: "bad port"])
        }
        return try await withCheckedThrowingContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let started = Date()
            var finished = false
            func finish(_ result: Result<Int, Error>) {
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(with: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.success(Int(Date().timeIntervalSince(started) * 1000)))
                case let .failed(error):
                    finish(.failure(error))
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                finish(.failure(NSError(domain: "AgentAPI", code: -4, userInfo: [NSLocalizedDescriptionKey: "ping timeout"])))
            }
        }
    }

    private static func proxyDictionary() -> [AnyHashable: Any] {
        let host = AgentSettings.proxyHost
        let port = AgentSettings.proxyPort
        let user = AgentSettings.proxyUser
        let password = AgentSettings.proxyPassword
        if AgentSettings.proxyType == "http" {
            var dict: [AnyHashable: Any] = [
                kCFNetworkProxiesHTTPEnable: true,
                kCFNetworkProxiesHTTPProxy: host,
                kCFNetworkProxiesHTTPPort: port,
                kCFNetworkProxiesHTTPSEnable: true,
                kCFNetworkProxiesHTTPSProxy: host,
                kCFNetworkProxiesHTTPSPort: port,
            ]
            if !user.isEmpty {
                dict[kCFProxyUsernameKey] = user
                dict[kCFProxyPasswordKey] = password
            }
            return dict
        }
        var dict: [AnyHashable: Any] = [
            kCFStreamPropertySOCKSProxyHost: host,
            kCFStreamPropertySOCKSProxyPort: port,
            kCFStreamPropertySOCKSVersion: kCFStreamSocketSOCKSVersion5,
        ]
        if !user.isEmpty {
            dict[kCFStreamPropertySOCKSUser] = user
            dict[kCFStreamPropertySOCKSPassword] = password
        }
        return dict
    }
}
