import Foundation
import Network

enum AgentHTTPError: Error, LocalizedError {
    case badURL
    case timeout
    case closed
    case socks(String)
    case proxy(String)
    case http(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Bad server URL"
        case .timeout: return "Connection timed out"
        case .closed: return "Connection closed"
        case let .socks(text): return "SOCKS proxy: \(text)"
        case let .proxy(text): return "HTTP proxy: \(text)"
        case let .http(text): return text
        }
    }
}

public enum AgentHTTP {
    public struct Reply {
        public var status: Int
        public var body: Data
        public var text: String { String(data: body, encoding: .utf8) ?? "" }
    }

    public static func perform(_ request: URLRequest) async throws -> Reply {
        guard let url = request.url, let host = url.host, !host.isEmpty else {
            throw AgentHTTPError.badURL
        }
        let tls = url.scheme?.lowercased() == "https"
        let port = UInt16(url.port ?? (tls ? 443 : 80))
        let method = request.httpMethod ?? "GET"
        var headers = request.allHTTPHeaderFields ?? [:]
        let body = request.httpBody ?? Data()
        if headers["Host"] == nil {
            headers["Host"] = (port == 80 && !tls) || (port == 443 && tls) ? host : "\(host):\(port)"
        }
        headers["Connection"] = "close"
        if body.isEmpty {
            headers.removeValue(forKey: "Content-Length")
        } else {
            headers["Content-Length"] = "\(body.count)"
        }

        let useProxy = AgentSettings.proxyEnabled && AgentSettings.proxyConfigured
        let proxyType = AgentSettings.proxyType
        let started = Date()

        let connection: NWConnection
        if useProxy {
            connection = try await connect(host: AgentSettings.proxyHost, port: UInt16(AgentSettings.proxyPort), tls: false)
        } else {
            connection = try await connect(host: host, port: port, tls: tls)
        }
        defer { connection.cancel() }

        if useProxy, proxyType == "socks5" {
            try await socks5Connect(connection, host: host, port: port)
        }

        let path: String
        if useProxy, proxyType == "http", !tls {
            path = url.absoluteString
            if !AgentSettings.proxyUser.isEmpty {
                headers["Proxy-Authorization"] = basicAuth(AgentSettings.proxyUser, AgentSettings.proxyPassword)
            }
        } else if useProxy, proxyType == "http", tls {
            try await httpConnect(connection, host: host, port: port)
            path = urlRequestPath(url)
        } else {
            path = urlRequestPath(url)
        }

        var packet = "\(method) \(path) HTTP/1.1\r\n"
        for (key, value) in headers {
            packet += "\(key): \(value)\r\n"
        }
        packet += "\r\n"
        var data = Data(packet.utf8)
        data.append(body)
        try await send(connection, data)
        let raw = try await receiveAll(connection, limit: 80_000_000)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        DiagnosticsLog.log("app", "http-ok", "status wait \(elapsed)ms")
        return try parseHTTP(raw)
    }

    public static func pingProxy() async throws -> Int {
        guard AgentSettings.proxyConfigured else {
            throw AgentHTTPError.proxy("Fill host and port first")
        }
        let started = Date()
        let connection = try await connect(host: AgentSettings.proxyHost, port: UInt16(AgentSettings.proxyPort), tls: false)
        defer { connection.cancel() }
        if AgentSettings.proxyType == "http" {
            try await httpConnect(connection, host: "1.1.1.1", port: 443)
        } else {
            try await socks5Connect(connection, host: "1.1.1.1", port: 443)
        }
        return Int(Date().timeIntervalSince(started) * 1000)
    }

    private static func urlRequestPath(_ url: URL) -> String {
        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty {
            path += "?\(query)"
        }
        return path
    }

    private static func basicAuth(_ user: String, _ password: String) -> String {
        let raw = "\(user):\(password)"
        return "Basic \(Data(raw.utf8).base64EncodedString())"
    }

    private static func connect(host: String, port: UInt16, tls: Bool) async throws -> NWConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw AgentHTTPError.badURL }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 12
        let params = tls
            ? NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)
            : NWParameters(tls: nil, tcp: tcp)
        params.preferNoProxies = true
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        try await waitReady(connection)
        return connection
    }

    private static func waitReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var finished = false
            func finish(_ result: Result<Void, Error>) {
                guard !finished else { return }
                finished = true
                continuation.resume(with: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.success(()))
                case let .failed(error):
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(AgentHTTPError.closed))
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 12) {
                finish(.failure(AgentHTTPError.timeout))
            }
        }
    }

    private static func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private static func receiveSome(_ connection: NWConnection, min: Int, max: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: min, maximumLength: max) { content, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let content, !content.isEmpty {
                    continuation.resume(returning: content)
                    return
                }
                if isComplete {
                    continuation.resume(throwing: AgentHTTPError.closed)
                    return
                }
                continuation.resume(returning: Data())
            }
        }
    }

    private static func receiveExact(_ connection: NWConnection, _ count: Int) async throws -> Data {
        var data = Data()
        while data.count < count {
            let chunk = try await receiveSome(connection, min: 1, max: count - data.count)
            if chunk.isEmpty { throw AgentHTTPError.closed }
            data.append(chunk)
        }
        return data
    }

    private static func receiveAll(_ connection: NWConnection, limit: Int) async throws -> Data {
        var data = Data()
        while data.count < limit {
            do {
                let chunk = try await receiveSome(connection, min: 1, max: min(64 * 1024, limit - data.count))
                if chunk.isEmpty { break }
                data.append(chunk)
            } catch AgentHTTPError.closed {
                break
            }
        }
        return data
    }

    private static func parseHTTP(_ raw: Data) throws -> Reply {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = raw.range(of: separator) else {
            throw AgentHTTPError.http("Incomplete HTTP reply")
        }
        let head = String(data: raw.subdata(in: raw.startIndex ..< range.lowerBound), encoding: .utf8) ?? ""
        let body = raw.subdata(in: range.upperBound ..< raw.endIndex)
        let first = head.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let parts = first.split(separator: " ")
        let status = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0
        return Reply(status: status, body: body)
    }

    private static func socks5Connect(_ connection: NWConnection, host: String, port: UInt16) async throws {
        let user = AgentSettings.proxyUser
        let password = AgentSettings.proxyPassword
        if user.isEmpty {
            try await send(connection, Data([0x05, 0x01, 0x00]))
        } else {
            try await send(connection, Data([0x05, 0x02, 0x00, 0x02]))
        }
        let hello = try await receiveExact(connection, 2)
        guard hello.count == 2, hello[0] == 0x05 else { throw AgentHTTPError.socks("bad greeting") }
        if hello[1] == 0x02 {
            guard !user.isEmpty else { throw AgentHTTPError.socks("server wants a login") }
            var auth = Data([0x01, UInt8(min(user.utf8.count, 255))])
            auth.append(Data(user.utf8.prefix(255)))
            auth.append(UInt8(min(password.utf8.count, 255)))
            auth.append(Data(password.utf8.prefix(255)))
            try await send(connection, auth)
            let reply = try await receiveExact(connection, 2)
            guard reply.count == 2, reply[1] == 0x00 else { throw AgentHTTPError.socks("login rejected") }
        } else if hello[1] != 0x00 {
            throw AgentHTTPError.socks("method \(hello[1]) not supported")
        }

        var request = Data([0x05, 0x01, 0x00])
        if let ip = ipv4(host) {
            request.append(0x01)
            request.append(contentsOf: ip)
        } else {
            let name = Data(host.utf8)
            request.append(0x03)
            request.append(UInt8(min(name.count, 255)))
            request.append(name.prefix(255))
        }
        request.append(UInt8(port >> 8))
        request.append(UInt8(port & 0xFF))
        try await send(connection, request)
        let reply = try await receiveExact(connection, 4)
        guard reply.count == 4, reply[0] == 0x05 else { throw AgentHTTPError.socks("bad connect reply") }
        guard reply[1] == 0x00 else { throw AgentHTTPError.socks(socksStatus(reply[1])) }
        let rest: Int
        switch reply[3] {
        case 0x01: rest = 4 + 2
        case 0x04: rest = 16 + 2
        case 0x03:
            let len = try await receiveExact(connection, 1)
            rest = Int(len[0]) + 2
        default:
            throw AgentHTTPError.socks("bad address type")
        }
        _ = try await receiveExact(connection, rest)
    }

    private static func httpConnect(_ connection: NWConnection, host: String, port: UInt16) async throws {
        var packet = "CONNECT \(host):\(port) HTTP/1.1\r\nHost: \(host):\(port)\r\n"
        if !AgentSettings.proxyUser.isEmpty {
            packet += "Proxy-Authorization: \(basicAuth(AgentSettings.proxyUser, AgentSettings.proxyPassword))\r\n"
        }
        packet += "Proxy-Connection: Keep-Alive\r\n\r\n"
        try await send(connection, Data(packet.utf8))
        let raw = try await receiveUntilHeaders(connection)
        let reply = try parseHTTP(raw)
        guard (200 ..< 300).contains(reply.status) else {
            throw AgentHTTPError.proxy("CONNECT http \(reply.status)")
        }
    }

    private static func receiveUntilHeaders(_ connection: NWConnection) async throws -> Data {
        var data = Data()
        let marker = Data("\r\n\r\n".utf8)
        while data.count < 16_384 {
            data.append(try await receiveSome(connection, min: 1, max: 2048))
            if data.range(of: marker) != nil {
                return data
            }
        }
        throw AgentHTTPError.proxy("CONNECT reply too long")
    }

    private static func ipv4(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard let value = UInt8(part) else { return nil }
            bytes.append(value)
        }
        return bytes
    }

    private static func socksStatus(_ code: UInt8) -> String {
        switch code {
        case 1: return "general failure"
        case 2: return "not allowed"
        case 3: return "network unreachable"
        case 4: return "host unreachable"
        case 5: return "connection refused"
        case 6: return "TTL expired"
        case 8: return "address type not supported"
        default: return "code \(code)"
        }
    }
}
