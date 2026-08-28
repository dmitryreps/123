import Foundation
import Network
import Darwin

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
        public var via: String
        public var text: String { String(data: body, encoding: .utf8) ?? "" }

        public init(status: Int, body: Data, via: String = "") {
            self.status = status
            self.body = body
            self.via = via
        }
    }

    public static func perform(_ request: URLRequest) async throws -> Reply {
        var lastError: Error = AgentHTTPError.timeout
        let tls = request.url?.scheme?.lowercased() == "https"
        let steps: [(name: String, posix: Bool, prohibitOther: Bool)] = [
            ("posix", true, false),
            ("nw-any", false, false),
            ("nw", false, true),
        ]
        for step in steps {
            if step.posix, tls {
                DiagnosticsLog.log("app", "http-skip", "posix https")
                continue
            }
            do {
                DiagnosticsLog.log("app", "http-try", step.name)
                var reply: Reply
                if step.posix {
                    reply = try await performPOSIX(request)
                } else {
                    let useProxy = step.name == "nw" && AgentSettings.proxyEnabled && AgentSettings.proxyConfigured
                    let timeout: TimeInterval = step.prohibitOther ? 4 : 8
                    reply = try await performNW(request, prohibitOther: step.prohibitOther, useProxy: useProxy, timeout: timeout)
                }
                reply.via = step.name
                DiagnosticsLog.log("app", "http-via", step.name)
                return reply
            } catch {
                lastError = error
                DiagnosticsLog.log("app", "http-try-fail", "\(step.name) \(error.localizedDescription)")
                if !shouldRetry(error) { throw error }
            }
        }
        throw lastError
    }

    private static func shouldRetry(_ error: Error) -> Bool {
        if let http = error as? AgentHTTPError {
            switch http {
            case .timeout, .closed, .socks, .proxy:
                return true
            case .http(let text):
                return text.lowercased().contains("incomplete")
            case .badURL:
                return false
            }
        }
        if isStreamEOF(error) { return true }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return true }
        if ns.domain == NSURLErrorDomain { return true }
        return true
    }

    private static func performNW(_ request: URLRequest, prohibitOther: Bool, useProxy: Bool, timeout: TimeInterval = 8) async throws -> Reply {
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
        headers["Accept-Encoding"] = "identity"
        if body.isEmpty {
            headers.removeValue(forKey: "Content-Length")
        } else {
            headers["Content-Length"] = "\(body.count)"
        }

        let proxyType = AgentSettings.proxyType
        let started = Date()
        DiagnosticsLog.log("app", "http-start", "\(method) \(host):\(port) proxy=\(useProxy ? proxyType : "off") utun=\(prohibitOther ? "off" : "any")")

        let connection: NWConnection
        if useProxy {
            connection = try await connect(host: AgentSettings.proxyHost, port: UInt16(AgentSettings.proxyPort), tls: false, prohibitOther: prohibitOther, timeout: timeout)
        } else {
            connection = try await connect(host: host, port: port, tls: tls, prohibitOther: prohibitOther, timeout: timeout)
        }
        defer { connection.cancel() }
        DiagnosticsLog.log("app", "http-connect", "ok")

        if useProxy, proxyType == "socks5" {
            try await socks5Connect(connection, host: host, port: port)
            DiagnosticsLog.log("app", "http-socks", "ok")
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

        var packet = "\(method) \(path) HTTP/1.0\r\n"
        for (key, value) in headers {
            packet += "\(key): \(value)\r\n"
        }
        packet += "\r\n"
        var data = Data(packet.utf8)
        data.append(body)
        try await send(connection, data)
        DiagnosticsLog.log("app", "http-sent", "bytes=\(data.count)")
        let raw = try await receiveAll(connection, limit: 80_000_000, deadline: Date().addingTimeInterval(25))
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        let reply = try parseHTTP(raw)
        DiagnosticsLog.log("app", "http-reply", "status=\(reply.status) bytes=\(reply.body.count) \(elapsed)ms")
        return reply
    }

    private static func performPOSIX(_ request: URLRequest) async throws -> Reply {
        guard let url = request.url, let host = url.host, !host.isEmpty else {
            throw AgentHTTPError.badURL
        }
        let tls = url.scheme?.lowercased() == "https"
        if tls { throw AgentHTTPError.http("POSIX fallback is HTTP-only") }
        let port = UInt16(url.port ?? 80)
        let method = request.httpMethod ?? "GET"
        var headers = request.allHTTPHeaderFields ?? [:]
        let body = request.httpBody ?? Data()
        if headers["Host"] == nil {
            headers["Host"] = port == 80 ? host : "\(host):\(port)"
        }
        headers["Connection"] = "close"
        headers["Accept-Encoding"] = "identity"
        if !body.isEmpty {
            headers["Content-Length"] = "\(body.count)"
        }
        headers["User-Agent"] = "SFI-Agent/posix"
        let path = urlRequestPath(url)
        var packet = "\(method) \(path) HTTP/1.0\r\n"
        for (key, value) in headers {
            packet += "\(key): \(value)\r\n"
        }
        packet += "\r\n"
        var data = Data(packet.utf8)
        data.append(body)
        DiagnosticsLog.log("app", "http-start", "\(method) \(host):\(port) posix")
        let raw: Data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try posixRequest(host: host, port: port, packet: data))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        DiagnosticsLog.log("app", "http-recv", "posix bytes=\(raw.count)")
        return try parseHTTP(raw)
    }

    private static func posixRequest(host: String, port: UInt16, packet: Data) throws -> Data {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var info: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &info)
        guard rc == 0, let first = info else {
            throw AgentHTTPError.timeout
        }
        defer { freeaddrinfo(first) }
        guard let aiAddr = first.pointee.ai_addr else { throw AgentHTTPError.timeout }
        let fd = Darwin.socket(first.pointee.ai_family, SOCK_STREAM, IPPROTO_TCP)
        if fd < 0 { throw AgentHTTPError.closed }
        defer { Darwin.close(fd) }
        var nosig: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let cr = Darwin.connect(fd, aiAddr, first.pointee.ai_addrlen)
        if cr != 0, errno != EINPROGRESS {
            throw AgentHTTPError.timeout
        }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pr = poll(&pfd, 1, 12_000)
        if pr <= 0 { throw AgentHTTPError.timeout }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        _ = fcntl(fd, F_SETFL, flags)
        if err != 0 { throw AgentHTTPError.timeout }
        try packet.withUnsafeBytes { raw in
            var sent = 0
            let total = raw.count
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while sent < total {
                let n = Darwin.send(fd, base + sent, total - sent, 0)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw AgentHTTPError.closed
                }
                sent += n
            }
        }
        var tv = timeval(tv_sec: 20, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        while out.count < 80_000_000 {
            let n = Darwin.recv(fd, &buf, buf.count, 0)
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                throw AgentHTTPError.closed
            }
            out.append(contentsOf: buf.prefix(n))
            if looksCompleteHTTP(out) { break }
        }
        return out
    }

    public static func pingProxy() async throws -> Int {
        guard AgentSettings.proxyConfigured else {
            throw AgentHTTPError.proxy("Fill host and port first")
        }
        let started = Date()
        let connection = try await connect(host: AgentSettings.proxyHost, port: UInt16(AgentSettings.proxyPort), tls: false, prohibitOther: true, timeout: 8)
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

    private static func connect(host: String, port: UInt16, tls: Bool, prohibitOther: Bool, timeout: TimeInterval) async throws -> NWConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw AgentHTTPError.badURL }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(max(2, timeout))
        let params = tls
            ? NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)
            : NWParameters(tls: nil, tcp: tcp)
        params.preferNoProxies = true
        if prohibitOther {
            params.prohibitedInterfaceTypes = [.other]
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        try await waitReady(connection, seconds: timeout)
        return connection
    }

    private static func waitReady(_ connection: NWConnection, seconds: TimeInterval) async throws {
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
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
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

    private static func isStreamEOF(_ error: Error) -> Bool {
        if case AgentHTTPError.closed = error { return true }
        if let nw = error as? NWError, case let .posix(code) = nw {
            switch code {
            case .ENODATA, .ECONNRESET, .ENOTCONN, .EPIPE, .ETIMEDOUT:
                return true
            default:
                break
            }
        }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain && [54, 57, 60, 96].contains(ns.code) {
            return true
        }
        return false
    }

    private static func receiveAll(_ connection: NWConnection, limit: Int, deadline: Date = Date().addingTimeInterval(25)) async throws -> Data {
        var data = Data()
        while data.count < limit {
            if Date() > deadline {
                if data.isEmpty { throw AgentHTTPError.timeout }
                break
            }
            do {
                let chunk = try await receiveSome(connection, min: 1, max: min(64 * 1024, limit - data.count))
                if chunk.isEmpty { break }
                data.append(chunk)
                if looksCompleteHTTP(data) { break }
            } catch {
                if isStreamEOF(error) { break }
                DiagnosticsLog.log("app", "http-recv-error", "bytes=\(data.count) \(error.localizedDescription)")
                throw error
            }
        }
        DiagnosticsLog.log("app", "http-recv", "bytes=\(data.count)")
        return data
    }

    private static func looksCompleteHTTP(_ raw: Data) -> Bool {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = raw.range(of: separator) else { return false }
        let head = String(data: raw.subdata(in: raw.startIndex ..< range.lowerBound), encoding: .utf8) ?? ""
        let body = raw.subdata(in: range.upperBound ..< raw.endIndex)
        let lower = head.lowercased()
        if lower.contains("transfer-encoding: chunked") {
            return body.range(of: Data("0\r\n\r\n".utf8)) != nil || body.range(of: Data("0\n\n".utf8)) != nil
        }
        if let line = lower.split(separator: "\r\n").first(where: { $0.hasPrefix("content-length:") }) {
            let n = Int(line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") ?? -1
            return n >= 0 && body.count >= n
        }
        return !body.isEmpty
    }

    private static func parseHTTP(_ raw: Data) throws -> Reply {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = raw.range(of: separator) else {
            throw AgentHTTPError.http("Incomplete HTTP reply")
        }
        let head = String(data: raw.subdata(in: raw.startIndex ..< range.lowerBound), encoding: .utf8) ?? ""
        let first = head.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let parts = first.split(separator: " ")
        let status = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0
        var body = raw.subdata(in: range.upperBound ..< raw.endIndex)
        if head.lowercased().contains("transfer-encoding: chunked") {
            body = dechunk(body) ?? body
        }
        return Reply(status: status, body: body)
    }

    private static func dechunk(_ data: Data) -> Data? {
        var index = data.startIndex
        var out = Data()
        let crlf = Data("\r\n".utf8)
        let lf = Data("\n".utf8)
        while index < data.endIndex {
            let rest = data[index...]
            guard let lineEnd = rest.range(of: crlf) ?? rest.range(of: lf) else { return nil }
            let line = String(data: data[index ..< lineEnd.lowerBound], encoding: .utf8) ?? ""
            let hex = line.split(separator: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let size = Int(hex, radix: 16) else { return nil }
            index = lineEnd.upperBound
            if size == 0 { return out }
            guard let end = data.index(index, offsetBy: size, limitedBy: data.endIndex) else { return nil }
            out.append(data[index ..< end])
            index = end
            if index < data.endIndex, data[index] == 13 {
                index = data.index(after: index)
            }
            if index < data.endIndex, data[index] == 10 {
                index = data.index(after: index)
            }
        }
        return out
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
