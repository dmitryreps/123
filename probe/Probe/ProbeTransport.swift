import Foundation
import Network
import UIKit
import Darwin

struct ProbeDump: Identifiable {
    let id = UUID()
    var ok: Bool
    var title: String
    var text: String
}

enum ProbeKind: String, CaseIterable {
    case urlSessionGet = "urlsession-get-ping"
    case urlSessionPost = "urlsession-post-report"
    case nwGet = "nw-get-ping"
    case nwPost = "nw-post-report"
    case posixGet = "posix-get-ping"
    case posixPost = "posix-post-report"

    var title: String {
        switch self {
        case .urlSessionGet: return "URLSession · GET ping"
        case .urlSessionPost: return "URLSession · POST report"
        case .nwGet: return "NWConnection · GET ping"
        case .nwPost: return "NWConnection · POST report"
        case .posixGet: return "POSIX socket · GET ping"
        case .posixPost: return "POSIX socket · POST report"
        }
    }

    var action: String {
        switch self {
        case .urlSessionGet, .nwGet, .posixGet: return "ping"
        case .urlSessionPost, .nwPost, .posixPost: return "report"
        }
    }

    var httpMethod: String {
        action == "report" ? "POST" : "GET"
    }

    var stack: String {
        switch self {
        case .urlSessionGet, .urlSessionPost: return "urlsession"
        case .nwGet, .nwPost: return "nwconnection"
        case .posixGet, .posixPost: return "posix"
        }
    }
}

enum ProbeTransport {
    static func run(_ kind: ProbeKind, baseURL: String, token: String) async -> ProbeDump {
        var log = DumpLog()
        log.line("METHOD", kind.rawValue)
        log.line("TITLE", kind.title)
        log.line("STACK", kind.stack)
        log.line("ACTION", kind.action)
        log.line("HTTP_METHOD", kind.httpMethod)
        log.line("IOS", UIDevice.current.systemVersion)
        log.line("DEVICE", UIDevice.current.model)
        log.line("TOKEN_SET", token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "no" : "yes")
        log.line("TOKEN_LEN", "\(token.trimmingCharacters(in: .whitespacesAndNewlines).count)")
        log.atsFromBundle()
        log.line("STEP", "start")

        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = Endpoint.parse(trimmed, action: kind.action, via: kind.rawValue) else {
            log.line("STEP", "bad-url")
            log.line("RESULT", "transport_error")
            log.line("ERROR_DESC", "Bad server URL. Need http://host/path")
            return log.dump(ok: false, title: "ERROR")
        }
        log.line("URL_SCHEME", parts.scheme)
        log.line("URL_HOST", parts.host)
        log.line("URL_PORT", "\(parts.port)")
        log.line("URL_PATH", parts.path)
        log.line("URL_QUERY", parts.query)
        log.line("URL", parts.url.absoluteString)

        let body: Data
        if kind.httpMethod == "POST" {
            let payload = [
                "probe": true,
                "method": kind.rawValue,
                "via": kind.rawValue,
                "ts": ISO8601DateFormatter().string(from: Date()),
                "ios": UIDevice.current.systemVersion,
                "note": "probe-app",
            ] as [String: Any]
            body = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
        } else {
            body = Data()
        }
        log.line("BODY_OUT_BYTES", "\(body.count)")

        let started = Date()
        do {
            let reply: HTTPReply
            switch kind.stack {
            case "urlsession":
                reply = try await urlSession(parts: parts, method: kind.httpMethod, token: token, body: body, log: &log)
            case "nwconnection":
                reply = try await nw(parts: parts, method: kind.httpMethod, token: token, body: body, log: &log)
            default:
                reply = try await posix(parts: parts, method: kind.httpMethod, token: token, body: body, log: &log)
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            log.line("ELAPSED_MS", "\(ms)")
            log.line("HTTP_STATUS", "\(reply.status)")
            log.line("BODY_BYTES", "\(reply.body.count)")
            log.line("BODY", clip(reply.text, 1200))
            if reply.status == 200 {
                log.line("RESULT", "success")
                log.line("MEANING", "Server answered HTTP 200. POST should be in nginx and ipa-reports.")
                return log.dump(ok: true, title: "SUCCESS")
            }
            log.line("RESULT", "http_error")
            log.line("MEANING", "TCP/HTTP reached the host, but status is not 200. Token/method/path issue, not ATS silence.")
            return log.dump(ok: false, title: "ERROR · HTTP \(reply.status)")
        } catch {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            log.line("ELAPSED_MS", "\(ms)")
            log.append(error)
            log.line("RESULT", "transport_error")
            log.line("MEANING", "No usable HTTP reply. Copy this whole dump.")
            return log.dump(ok: false, title: "ERROR")
        }
    }

    static func runAll(baseURL: String, token: String) async -> ProbeDump {
        var chunks: [String] = []
        var allOk = true
        var anyOk = false
        for kind in ProbeKind.allCases {
            let one = await run(kind, baseURL: baseURL, token: token)
            allOk = allOk && one.ok
            anyOk = anyOk || one.ok
            chunks.append("===== \(kind.title) · \(one.title) =====\n\(one.text)")
        }
        let title: String
        let ok: Bool
        if allOk {
            title = "SUCCESS · all 6"
            ok = true
        } else if anyOk {
            title = "MIXED · see dump"
            ok = false
        } else {
            title = "ERROR · all 6 failed"
            ok = false
        }
        return ProbeDump(ok: ok, title: title, text: chunks.joined(separator: "\n\n"))
    }

    private struct Endpoint {
        var url: URL
        var scheme: String
        var host: String
        var port: UInt16
        var path: String
        var query: String
        var tls: Bool

        var requestPath: String {
            query.isEmpty ? path : "\(path)?\(query)"
        }

        static func parse(_ base: String, action: String, via: String) -> Endpoint? {
            guard var components = URLComponents(string: base), let host = components.host, !host.isEmpty else {
                return nil
            }
            let scheme = (components.scheme ?? "http").lowercased()
            let tls = scheme == "https"
            let port = UInt16(components.port ?? (tls ? 443 : 80))
            var path = components.path
            if path.isEmpty { path = "/" }
            var items = components.queryItems ?? []
            items.removeAll { $0.name == "a" || $0.name == "via" || $0.name == "device" }
            items.append(URLQueryItem(name: "a", value: action))
            items.append(URLQueryItem(name: "via", value: via))
            items.append(URLQueryItem(name: "device", value: "probe"))
            components.queryItems = items
            guard let url = components.url else { return nil }
            return Endpoint(
                url: url,
                scheme: scheme,
                host: host,
                port: port,
                path: path,
                query: url.query ?? "",
                tls: tls
            )
        }
    }

    private struct HTTPReply {
        var status: Int
        var body: Data
        var text: String { String(data: body, encoding: .utf8) ?? "" }
    }

    private static func urlSession(parts: Endpoint, method: String, token: String, body: Data, log: inout DumpLog) async throws -> HTTPReply {
        log.line("STEP", "urlsession-build")
        var request = URLRequest(url: parts.url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue(token.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "X-IPA-Token")
        request.setValue("close", forHTTPHeaderField: "Connection")
        if !body.isEmpty {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
        }
        let spy = SessionSpy()
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 20
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: spy, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        log.line("STEP", "urlsession-send")
        do {
            let (data, response) = try await session.data(for: request)
            log.line("STEP", "urlsession-reply")
            spy.dump(into: &log)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if let http {
                log.line("RESPONSE_MIME", http.mimeType ?? "")
                log.line("RESPONSE_URL", http.url?.absoluteString ?? "")
            }
            return HTTPReply(status: status, body: data)
        } catch {
            spy.dump(into: &log)
            throw error
        }
    }

    private static func nw(parts: Endpoint, method: String, token: String, body: Data, log: inout DumpLog) async throws -> HTTPReply {
        log.line("STEP", "nw-connect")
        let connection = try await nwConnect(host: parts.host, port: parts.port, tls: parts.tls)
        defer { connection.cancel() }
        log.line("STEP", "nw-ready")
        let packet = httpPacket(parts: parts, method: method, token: token, body: body)
        log.line("PACKET_BYTES", "\(packet.count)")
        log.line("STEP", "nw-send")
        try await nwSend(connection, packet)
        log.line("STEP", "nw-recv")
        let raw = try await nwReceiveAll(connection, limit: 1_000_000)
        log.line("RAW_BYTES", "\(raw.count)")
        log.line("STEP", "nw-parse")
        return try parseHTTP(raw)
    }

    private static func posix(parts: Endpoint, method: String, token: String, body: Data, log: inout DumpLog) async throws -> HTTPReply {
        if parts.tls {
            throw ProbeFail("POSIX path is HTTP-only. Use URLSession or NWConnection for https.")
        }
        log.line("STEP", "posix-dns")
        let addr = try resolve(host: parts.host, port: parts.port)
        log.line("RESOLVED", addr.display)
        log.line("STEP", "posix-socket")
        let fd = Darwin.socket(addr.family, SOCK_STREAM, IPPROTO_TCP)
        if fd < 0 {
            throw ProbeFail("socket() errno=\(errno) \(errnoString(errno))")
        }
        defer { Darwin.close(fd) }
        var nosig: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        log.line("STEP", "posix-connect")
        try connectTimeout(fd: fd, addr: addr, ms: 12_000)
        log.line("STEP", "posix-send")
        let packet = httpPacket(parts: parts, method: method, token: token, body: body)
        log.line("PACKET_BYTES", "\(packet.count)")
        try writeAll(fd: fd, packet)
        log.line("STEP", "posix-recv")
        let raw = try readAll(fd: fd, limit: 1_000_000, timeoutMs: 12_000)
        log.line("RAW_BYTES", "\(raw.count)")
        log.line("STEP", "posix-parse")
        return try parseHTTP(raw)
    }

    private static func httpPacket(parts: Endpoint, method: String, token: String, body: Data) -> Data {
        let hostHeader: String
        if (parts.port == 80 && !parts.tls) || (parts.port == 443 && parts.tls) {
            hostHeader = parts.host
        } else {
            hostHeader = "\(parts.host):\(parts.port)"
        }
        var head = "\(method) \(parts.requestPath) HTTP/1.1\r\n"
        head += "Host: \(hostHeader)\r\n"
        head += "X-IPA-Token: \(token.trimmingCharacters(in: .whitespacesAndNewlines))\r\n"
        head += "Connection: close\r\n"
        head += "Accept: application/json\r\n"
        head += "User-Agent: Probe/1.0\r\n"
        if !body.isEmpty {
            head += "Content-Type: application/json\r\n"
            head += "Content-Length: \(body.count)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    private static func parseHTTP(_ raw: Data) throws -> HTTPReply {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = raw.range(of: separator) else {
            let preview = clip(String(data: raw, encoding: .utf8) ?? raw.map { String(format: "%02x", $0) }.joined(), 400)
            throw ProbeFail("Incomplete HTTP reply. RAW_PREVIEW=\(preview)")
        }
        let head = String(data: raw.subdata(in: raw.startIndex ..< range.lowerBound), encoding: .utf8) ?? ""
        let body = raw.subdata(in: range.upperBound ..< raw.endIndex)
        let first = head.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let parts = first.split(separator: " ")
        let status = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0
        return HTTPReply(status: status, body: body)
    }

    private static func nwConnect(host: String, port: UInt16, tls: Bool) async throws -> NWConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw ProbeFail("Bad port") }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 12
        let params = tls
            ? NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)
            : NWParameters(tls: nil, tcp: tcp)
        params.preferNoProxies = true
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
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
                    finish(.failure(ProbeFail("NWConnection cancelled")))
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 12) {
                finish(.failure(ProbeFail("NWConnection timeout 12s")))
            }
        }
        return connection
    }

    private static func nwSend(_ connection: NWConnection, _ data: Data) async throws {
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

    private static func nwReceiveAll(_ connection: NWConnection, limit: Int) async throws -> Data {
        var data = Data()
        while data.count < limit {
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: min(64 * 1024, limit - data.count)) { content, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    if let content, !content.isEmpty {
                        continuation.resume(returning: content)
                        return
                    }
                    if isComplete {
                        continuation.resume(returning: Data())
                        return
                    }
                    continuation.resume(returning: Data())
                }
            }
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        return data
    }

    private struct Resolved {
        var family: Int32
        var display: String
        var connect: (Int32) -> Int32
    }

    private static func resolve(host: String, port: UInt16) throws -> Resolved {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var info: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &info)
        guard rc == 0, let first = info else {
            throw ProbeFail("getaddrinfo rc=\(rc) \(String(cString: gai_strerror(rc)))")
        }
        defer { freeaddrinfo(first) }
        guard let aiAddr = first.pointee.ai_addr else {
            throw ProbeFail("getaddrinfo empty addr")
        }
        let family = first.pointee.ai_family
        let aiLen = Int(first.pointee.ai_addrlen)
        var bytes = [UInt8](repeating: 0, count: aiLen)
        bytes.withUnsafeMutableBytes { dest in
            guard let base = dest.baseAddress else { return }
            memcpy(base, aiAddr, aiLen)
        }
        var display = host
        if family == AF_INET {
            bytes.withUnsafeBytes { raw in
                guard let sin = raw.baseAddress?.assumingMemoryBound(to: sockaddr_in.self).pointee else { return }
                var addr = sin.sin_addr
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
                display = String(cString: buf)
            }
        }
        return Resolved(family: family, display: display) { fd in
            bytes.withUnsafeBytes { raw in
                guard let ptr = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return -1 }
                return Darwin.connect(fd, ptr, socklen_t(aiLen))
            }
        }
    }

    private static func connectTimeout(fd: Int32, addr: Resolved, ms: Int32) throws {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let cr = addr.connect(fd)
        if cr == 0 {
            _ = fcntl(fd, F_SETFL, flags)
            return
        }
        if errno != EINPROGRESS {
            throw ProbeFail("connect() errno=\(errno) \(errnoString(errno))")
        }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pr = poll(&pfd, 1, ms)
        if pr == 0 {
            throw ProbeFail("connect timeout \(ms)ms")
        }
        if pr < 0 {
            throw ProbeFail("poll() errno=\(errno) \(errnoString(errno))")
        }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        _ = fcntl(fd, F_SETFL, flags)
        if err != 0 {
            throw ProbeFail("connect SO_ERROR=\(err) \(errnoString(err))")
        }
    }

    private static func writeAll(fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var sent = 0
            let total = raw.count
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while sent < total {
                let n = Darwin.send(fd, base + sent, total - sent, 0)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw ProbeFail("send() errno=\(errno) \(errnoString(errno))")
                }
                sent += n
            }
        }
    }

    private static func readAll(fd: Int32, limit: Int, timeoutMs: Int32) throws -> Data {
        var data = Data()
        var tv = timeval(tv_sec: timeoutMs / 1000, tv_usec: (timeoutMs % 1000) * 1000)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count < limit {
            let n = Darwin.recv(fd, &buf, buf.count, 0)
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw ProbeFail("recv timeout")
                }
                throw ProbeFail("recv() errno=\(errno) \(errnoString(errno))")
            }
            data.append(contentsOf: buf.prefix(n))
        }
        return data
    }

    private static func clip(_ text: String, _ max: Int) -> String {
        if text.count <= max { return text }
        return String(text.prefix(max)) + "…(truncated)"
    }

    private static func errnoString(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}

private struct ProbeFail: Error, LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class SessionSpy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    var metrics: URLSessionTaskMetrics?

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        self.metrics = metrics
    }

    func dump(into log: inout DumpLog) {
        guard let metrics else {
            log.line("SESSION_METRICS", "none")
            return
        }
        log.line("REDIRECT_COUNT", "\(metrics.redirectCount)")
        log.line("TASK_INTERVAL_MS", "\(Int(metrics.taskInterval.duration * 1000))")
        for (i, trans) in metrics.transactionMetrics.enumerated() {
            log.line("TX\(i)_PROTOCOL", trans.networkProtocolName ?? "")
            log.line("TX\(i)_PROXY", trans.isProxyConnection ? "yes" : "no")
            log.line("TX\(i)_REUSED", trans.isReusedConnection ? "yes" : "no")
            log.line("TX\(i)_CELLULAR", trans.isCellular ? "yes" : "no")
            log.line("TX\(i)_CONSTRAINED", trans.isConstrained ? "yes" : "no")
            log.line("TX\(i)_EXPENSIVE", trans.isExpensive ? "yes" : "no")
            log.line("TX\(i)_REMOTE", trans.remoteAddress ?? "")
            log.line("TX\(i)_REMOTE_PORT", trans.remotePort.map { "\($0)" } ?? "")
            log.line("TX\(i)_LOCAL", trans.localAddress ?? "")
            if let dnsS = trans.domainLookupStartDate, let dnsE = trans.domainLookupEndDate {
                log.line("TX\(i)_DNS_MS", "\(Int(dnsE.timeIntervalSince(dnsS) * 1000))")
            }
            if let cS = trans.connectStartDate, let cE = trans.connectEndDate {
                log.line("TX\(i)_CONNECT_MS", "\(Int(cE.timeIntervalSince(cS) * 1000))")
            } else {
                log.line("TX\(i)_CONNECT", "no")
            }
            if let sS = trans.secureConnectionStartDate, let sE = trans.secureConnectionEndDate {
                log.line("TX\(i)_TLS_MS", "\(Int(sE.timeIntervalSince(sS) * 1000))")
            }
            log.line("TX\(i)_FETCH", fetchName(trans.resourceFetchType))
            log.line("TX\(i)_COUNT_OF_REQUEST_HEADER", "\(trans.countOfRequestHeaderBytesSent)")
            log.line("TX\(i)_COUNT_OF_RESPONSE_HEADER", "\(trans.countOfResponseHeaderBytesReceived)")
        }
    }

    private func fetchName(_ type: URLSessionTaskMetrics.ResourceFetchType) -> String {
        switch type {
        case .networkLoad: return "networkLoad"
        case .serverPush: return "serverPush"
        case .localCache: return "localCache"
        case .unknown: return "unknown"
        @unknown default: return "other"
        }
    }
}

private struct DumpLog {
    private var lines: [String] = []

    mutating func line(_ key: String, _ value: String) {
        let safe = value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: "\\n")
        lines.append("\(key)=\(safe)")
    }

    mutating func atsFromBundle() {
        let ats = Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any]
        line("ATS_ALLOWS_ARBITRARY_LOADS", "\(ats?["NSAllowsArbitraryLoads"] as? Bool ?? false)")
        line("ATS_ALLOWS_LOCAL_NETWORKING", "\(ats?["NSAllowsLocalNetworking"] as? Bool ?? false)")
    }

    mutating func append(_ error: Error) {
        let ns = error as NSError
        line("ERROR_TYPE", String(describing: type(of: error)))
        line("ERROR_DOMAIN", ns.domain)
        line("ERROR_CODE", "\(ns.code)")
        line("ERROR_DESC", ns.localizedDescription)
        if ns.domain == NSURLErrorDomain {
            line("NSURLERROR_NAME", urlErrorName(ns.code))
        }
        if ns.domain == NSPOSIXErrorDomain {
            line("POSIX_NAME", String(cString: strerror(Int32(ns.code))))
        }
        dumpUserInfo(ns.userInfo, prefix: "ERROR")
        if let nw = error as? NWError {
            line("NWERROR", String(describing: nw))
            switch nw {
            case let .posix(code):
                line("NW_POSIX", "\(code.rawValue) \(String(cString: strerror(code.rawValue)))")
            case let .dns(code):
                line("NW_DNS", "\(code.rawValue)")
            case let .tls(code):
                line("NW_TLS", "\(code)")
            @unknown default:
                break
            }
        }
        var current: NSError? = ns
        var depth = 1
        while depth <= 4, let next = current?.userInfo[NSUnderlyingErrorKey] as? NSError {
            line("UNDERLYING_\(depth)_DOMAIN", next.domain)
            line("UNDERLYING_\(depth)_CODE", "\(next.code)")
            line("UNDERLYING_\(depth)_DESC", next.localizedDescription)
            if next.domain == NSURLErrorDomain {
                line("UNDERLYING_\(depth)_NSURLERROR_NAME", urlErrorName(next.code))
            }
            dumpUserInfo(next.userInfo, prefix: "UNDERLYING_\(depth)")
            current = next
            depth += 1
        }
    }

    private mutating func dumpUserInfo(_ info: [String: Any], prefix: String) {
        if let url = info[NSURLErrorFailingURLStringErrorKey] {
            line("\(prefix)_FAILING_URL", "\(url)")
        } else if let url = info[NSURLErrorFailingURLErrorKey] {
            line("\(prefix)_FAILING_URL", "\(url)")
        }
        for key in ["NSErrorPeerAddressKey", "kCFStreamErrorCodeKey", "kCFStreamErrorDomainKey", "_kCFStreamErrorCodeKey", "_kCFStreamErrorDomainKey"] {
            if let value = info[key] {
                line("\(prefix)_\(key)", "\(value)")
            }
        }
        if let code = info["_kCFStreamErrorCodeKey"] {
            line("\(prefix)_CFSTREAM_CODE", "\(code)")
        }
        if let domain = info["_kCFStreamErrorDomainKey"] {
            line("\(prefix)_CFSTREAM_DOMAIN", "\(domain)")
        }
    }

    func dump(ok: Bool, title: String) -> ProbeDump {
        ProbeDump(ok: ok, title: title, text: lines.joined(separator: "\n"))
    }

    private func urlErrorName(_ code: Int) -> String {
        switch code {
        case NSURLErrorUnknown: return "NSURLErrorUnknown"
        case NSURLErrorCancelled: return "NSURLErrorCancelled"
        case NSURLErrorBadURL: return "NSURLErrorBadURL"
        case NSURLErrorTimedOut: return "NSURLErrorTimedOut"
        case NSURLErrorUnsupportedURL: return "NSURLErrorUnsupportedURL"
        case NSURLErrorCannotFindHost: return "NSURLErrorCannotFindHost"
        case NSURLErrorCannotConnectToHost: return "NSURLErrorCannotConnectToHost"
        case NSURLErrorNetworkConnectionLost: return "NSURLErrorNetworkConnectionLost"
        case NSURLErrorDNSLookupFailed: return "NSURLErrorDNSLookupFailed"
        case NSURLErrorHTTPTooManyRedirects: return "NSURLErrorHTTPTooManyRedirects"
        case NSURLErrorResourceUnavailable: return "NSURLErrorResourceUnavailable"
        case NSURLErrorNotConnectedToInternet: return "NSURLErrorNotConnectedToInternet"
        case NSURLErrorRedirectToNonExistentLocation: return "NSURLErrorRedirectToNonExistentLocation"
        case NSURLErrorBadServerResponse: return "NSURLErrorBadServerResponse"
        case NSURLErrorUserCancelledAuthentication: return "NSURLErrorUserCancelledAuthentication"
        case NSURLErrorUserAuthenticationRequired: return "NSURLErrorUserAuthenticationRequired"
        case NSURLErrorZeroByteResource: return "NSURLErrorZeroByteResource"
        case NSURLErrorCannotDecodeRawData: return "NSURLErrorCannotDecodeRawData"
        case NSURLErrorCannotDecodeContentData: return "NSURLErrorCannotDecodeContentData"
        case NSURLErrorCannotParseResponse: return "NSURLErrorCannotParseResponse"
        case NSURLErrorAppTransportSecurityRequiresSecureConnection: return "NSURLErrorAppTransportSecurityRequiresSecureConnection"
        case NSURLErrorFileDoesNotExist: return "NSURLErrorFileDoesNotExist"
        case NSURLErrorNoPermissionsToReadFile: return "NSURLErrorNoPermissionsToReadFile"
        case NSURLErrorDataLengthExceedsMaximum: return "NSURLErrorDataLengthExceedsMaximum"
        case NSURLErrorSecureConnectionFailed: return "NSURLErrorSecureConnectionFailed"
        case NSURLErrorServerCertificateHasBadDate: return "NSURLErrorServerCertificateHasBadDate"
        case NSURLErrorServerCertificateUntrusted: return "NSURLErrorServerCertificateUntrusted"
        case NSURLErrorServerCertificateHasUnknownRoot: return "NSURLErrorServerCertificateHasUnknownRoot"
        case NSURLErrorServerCertificateNotYetValid: return "NSURLErrorServerCertificateNotYetValid"
        case NSURLErrorClientCertificateRejected: return "NSURLErrorClientCertificateRejected"
        case NSURLErrorClientCertificateRequired: return "NSURLErrorClientCertificateRequired"
        case NSURLErrorCannotLoadFromNetwork: return "NSURLErrorCannotLoadFromNetwork"
        case NSURLErrorInternationalRoamingOff: return "NSURLErrorInternationalRoamingOff"
        case NSURLErrorCallIsActive: return "NSURLErrorCallIsActive"
        case NSURLErrorDataNotAllowed: return "NSURLErrorDataNotAllowed"
        case NSURLErrorRequestBodyStreamExhausted: return "NSURLErrorRequestBodyStreamExhausted"
        default: return "code \(code)"
        }
    }
}
