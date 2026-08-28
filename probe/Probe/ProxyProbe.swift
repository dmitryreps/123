import Foundation
import Network
import UIKit

enum ProxyKind: String {
    case socks5
    case http
}

enum ProxyWrap: String {
    case none
    case tls
}

enum ProxyTest: String {
    case handshake
    case whoami
    case compare
    case stability
    case chunk
}

struct ProxyInput {
    var kind: ProxyKind
    var host: String
    var port: UInt16
    var user: String
    var password: String
    var wrap: ProxyWrap
    var targetURL: String
}

enum ProxyProbe {
    static func run(_ test: ProxyTest, input: ProxyInput) async -> ProbeDump {
        let log = ProxyLog()
        log.line("TEST", test.rawValue)
        log.line("PROXY_TYPE", input.kind.rawValue)
        log.line("PROXY_HOST", input.host)
        log.line("PROXY_PORT", "\(input.port)")
        log.line("PROXY_USER_SET", input.user.isEmpty ? "no" : "yes")
        log.line("PROXY_USER_LEN", "\(input.user.count)")
        log.line("WRAP", input.wrap.rawValue)
        log.line("TARGET", input.targetURL)
        let iosVersion = await MainActor.run { UIDevice.current.systemVersion }
        log.line("IOS", iosVersion)
        log.line("STEP", "start")

        guard !input.host.isEmpty, input.port > 0 else {
            log.line("STEP", "bad-proxy")
            log.line("RESULT", "error")
            log.line("ERROR_DESC", "Fill proxy host and port.")
            return log.dump(ok: false, title: "ERROR")
        }

        do {
            switch test {
            case .handshake:
                return try await handshake(input: input, log: log)
            case .whoami:
                return try await whoami(input: input, log: log)
            case .compare:
                return await compare(input: input, log: log)
            case .stability:
                return await stability(input: input, log: log)
            case .chunk:
                return try await chunk(input: input, log: log)
            }
        } catch {
            log.append(error)
            log.line("RESULT", "error")
            log.line("MEANING", "Copy this dump.")
            return log.dump(ok: false, title: "ERROR")
        }
    }

    private static func handshake(input: ProxyInput, log: ProxyLog) async throws -> ProbeDump {
        let target = try parseTarget(input.targetURL, fallbackHost: "api.ipify.org", fallbackPort: 80)
        log.line("CONNECT_HOST", target.host)
        log.line("CONNECT_PORT", "\(target.port)")
        let started = Date()
        let connection = try await openTunnel(input: input, dest: target, log: log)
        connection.cancel()
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        log.line("ELAPSED_MS", "\(ms)")
        log.line("RESULT", "success")
        log.line("MEANING", "Proxy login and CONNECT succeeded. This is not a full-page download.")
        return log.dump(ok: true, title: "SUCCESS · handshake \(ms) ms")
    }

    private static func whoami(input: ProxyInput, log: ProxyLog) async throws -> ProbeDump {
        let target = try parseTarget(input.targetURL, fallbackHost: "api.ipify.org", fallbackPort: 80)
        log.line("WHOAMI_HOST", target.host)
        log.line("WHOAMI_PORT", "\(target.port)")
        log.line("WHOAMI_TLS", target.tls ? "yes" : "no")
        let started = Date()
        let reply: (status: Int, body: String, rawBytes: Int)
        if target.tls {
            log.line("STACK", "urlsession-https")
            log.line("STEP", "https-via-proxy")
            let got = try await urlSessionViaProxy(input: input, target: target)
            reply = (got.status, got.text, got.body.count)
            log.line("STEP", "https-reply")
        } else {
            log.line("STACK", "connect-http")
            let connection = try await openTunnel(input: input, dest: target, log: log)
            defer { connection.cancel() }
            let packet = httpGet(host: target.host, port: target.port, path: target.path)
            log.line("PACKET_BYTES", "\(packet.count)")
            log.line("STEP", "http-send")
            try await send(connection, packet)
            log.line("STEP", "http-recv")
            let raw = try await receiveAll(connection, limit: 64_000)
            let parsed = try parseHTTP(raw)
            reply = (parsed.status, parsed.text, raw.count)
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let ip = extractIP(reply.body)
        log.line("ELAPSED_MS", "\(ms)")
        log.line("RAW_BYTES", "\(reply.rawBytes)")
        log.line("HTTP_STATUS", "\(reply.status)")
        log.line("BODY", clip(reply.body.trimmingCharacters(in: .whitespacesAndNewlines), 400))
        log.line("SEEN_IP", ip)
        if reply.status == 200, !ip.isEmpty {
            log.line("RESULT", "success")
            log.line("MEANING", "Traffic went through the proxy. SEEN_IP is the egress address.")
            return log.dump(ok: true, title: "SUCCESS · \(ip)")
        }
        log.line("RESULT", "http_error")
        return log.dump(ok: false, title: "ERROR · HTTP \(reply.status)")
    }

    private static func compare(input: ProxyInput, log: ProxyLog) async -> ProbeDump {
        var directIP = ""
        var directMS = 0
        var proxyIP = ""
        var proxyMS = 0
        var proxyOK = false

        log.line("STEP", "direct")
        let directStarted = Date()
        do {
            let target = try parseTarget(input.targetURL, fallbackHost: "api.ipify.org", fallbackPort: 80)
            if target.tls {
                log.line("DIRECT_STACK", "urlsession-https")
                let got = try await urlSessionDirect(target: target)
                directMS = Int(Date().timeIntervalSince(directStarted) * 1000)
                directIP = extractIP(got.text)
                log.line("DIRECT_MS", "\(directMS)")
                log.line("DIRECT_STATUS", "\(got.status)")
                log.line("DIRECT_IP", directIP)
                log.line("DIRECT_BODY", clip(got.text.trimmingCharacters(in: .whitespacesAndNewlines), 200))
            } else {
                let raw = try await directGET(target)
                let reply = try parseHTTP(raw)
                directMS = Int(Date().timeIntervalSince(directStarted) * 1000)
                directIP = extractIP(reply.text)
                log.line("DIRECT_MS", "\(directMS)")
                log.line("DIRECT_STATUS", "\(reply.status)")
                log.line("DIRECT_IP", directIP)
                log.line("DIRECT_BODY", clip(reply.text.trimmingCharacters(in: .whitespacesAndNewlines), 200))
            }
        } catch {
            directMS = Int(Date().timeIntervalSince(directStarted) * 1000)
            log.line("DIRECT_MS", "\(directMS)")
            log.append(error, prefix: "DIRECT")
        }

        log.line("STEP", "proxy")
        let proxyStarted = Date()
        do {
            let dump = try await whoamiInner(input: input)
            proxyMS = dump.ms
            proxyIP = dump.ip
            proxyOK = dump.ok
            log.line("PROXY_MS", "\(proxyMS)")
            log.line("PROXY_STATUS", "\(dump.status)")
            log.line("PROXY_IP", proxyIP)
            log.line("PROXY_BODY", clip(dump.body, 200))
        } catch {
            proxyMS = Int(Date().timeIntervalSince(proxyStarted) * 1000)
            log.line("PROXY_MS", "\(proxyMS)")
            log.append(error, prefix: "PROXY")
        }

        let same = !directIP.isEmpty && directIP == proxyIP
        log.line("IP_SAME", same ? "yes" : "no")
        if proxyOK, !proxyIP.isEmpty, !same {
            log.line("RESULT", "success")
            log.line("MEANING", "Proxy egress IP differs from the phone IP. Tunnel is in use.")
            return log.dump(ok: true, title: "SUCCESS · proxy \(proxyIP)")
        }
        if proxyOK, same {
            log.line("RESULT", "warn")
            log.line("MEANING", "Proxy answered, but IP matches direct. The proxy may be leaking or unused.")
            return log.dump(ok: false, title: "WARN · same IP")
        }
        log.line("RESULT", "error")
        return log.dump(ok: false, title: "ERROR · compare")
    }

    private static func stability(input: ProxyInput, log: ProxyLog) async -> ProbeDump {
        let rounds = 20
        log.line("ROUNDS", "\(rounds)")
        var okCount = 0
        var times: [Int] = []
        var fails: [String] = []
        for index in 1 ... rounds {
            let started = Date()
            do {
                let dump = try await whoamiInner(input: input)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                times.append(ms)
                if dump.ok {
                    okCount += 1
                    log.line("R\(index)", "ok \(ms)ms ip=\(dump.ip)")
                } else {
                    fails.append("R\(index) http \(dump.status)")
                    log.line("R\(index)", "http \(dump.status) \(ms)ms")
                }
            } catch {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                let text = (error as NSError).localizedDescription
                fails.append("R\(index) \(text)")
                log.line("R\(index)", "fail \(ms)ms \(text)")
            }
        }
        times.sort()
        log.line("OK", "\(okCount)/\(rounds)")
        log.line("FAIL", "\(rounds - okCount)")
        if let first = times.first, let last = times.last {
            log.line("MS_MIN", "\(first)")
            log.line("MS_P50", "\(percentile(times, 50))")
            log.line("MS_P95", "\(percentile(times, 95))")
            log.line("MS_MAX", "\(last)")
        }
        if !fails.isEmpty {
            log.line("FAIL_SAMPLE", fails.prefix(5).joined(separator: " | "))
        }
        let ok = okCount >= 18
        log.line("RESULT", ok ? "success" : "unstable")
        log.line("MEANING", ok ? "At least 18/20 whoami calls succeeded." : "Too many drops. Copy this dump.")
        return log.dump(ok: ok, title: ok ? "SUCCESS · \(okCount)/20" : "UNSTABLE · \(okCount)/20")
    }

    private static func chunk(input: ProxyInput, log: ProxyLog) async throws -> ProbeDump {
        let sizes = [512, 1400, 4096]
        let target = try parseTarget(input.targetURL, fallbackHost: "example.com", fallbackPort: 80)
        if target.tls {
            throw ProxyFail("Chunk test is HTTP-only.")
        }
        log.line("CHUNK_HOST", target.host)
        var allOK = true
        for size in sizes {
            log.line("STEP", "chunk-\(size)")
            let started = Date()
            do {
                let connection = try await openTunnel(input: input, dest: target, log: log)
                defer { connection.cancel() }
                let body = Data(repeating: 0x78, count: 12_000)
                var head = "POST \(target.path) HTTP/1.0\r\n"
                head += "Host: \(target.host)\r\n"
                head += "Content-Type: application/octet-stream\r\n"
                head += "Content-Length: \(body.count)\r\n"
                head += "Connection: close\r\n\r\n"
                var packet = Data(head.utf8)
                packet.append(body)
                log.line("CHUNK_\(size)_PACKET", "\(packet.count)")
                var offset = 0
                var writes = 0
                while offset < packet.count {
                    let end = min(offset + size, packet.count)
                    try await send(connection, packet.subdata(in: offset ..< end))
                    offset = end
                    writes += 1
                }
                log.line("CHUNK_\(size)_WRITES", "\(writes)")
                let raw = try await receiveAll(connection, limit: 64_000)
                let reply = try? parseHTTP(raw)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                log.line("CHUNK_\(size)_MS", "\(ms)")
                log.line("CHUNK_\(size)_RAW", "\(raw.count)")
                log.line("CHUNK_\(size)_STATUS", "\(reply?.status ?? 0)")
                log.line("CHUNK_\(size)_RESULT", raw.isEmpty ? "empty" : "ok")
                if raw.isEmpty { allOK = false }
            } catch {
                allOK = false
                log.line("CHUNK_\(size)_RESULT", "fail")
                log.append(error, prefix: "CHUNK_\(size)")
            }
        }
        log.line("RESULT", allOK ? "success" : "error")
        log.line("MEANING", "Sends a 12KB POST in 512 / 1400 / 4096 byte TCP writes through the proxy.")
        return log.dump(ok: allOK, title: allOK ? "SUCCESS · chunk" : "ERROR · chunk")
    }

    private struct WhoamiDump {
        var ok: Bool
        var status: Int
        var ip: String
        var body: String
        var ms: Int
    }

    private static func whoamiInner(input: ProxyInput) async throws -> WhoamiDump {
        let target = try parseTarget(input.targetURL, fallbackHost: "api.ipify.org", fallbackPort: 80)
        let started = Date()
        if target.tls {
            let got = try await urlSessionViaProxy(input: input, target: target)
            let ip = extractIP(got.text)
            return WhoamiDump(
                ok: got.status == 200 && !ip.isEmpty,
                status: got.status,
                ip: ip,
                body: got.text.trimmingCharacters(in: .whitespacesAndNewlines),
                ms: Int(Date().timeIntervalSince(started) * 1000)
            )
        }
        let connection = try await openTunnel(input: input, dest: target, log: ProxyLog())
        defer { connection.cancel() }
        try await send(connection, httpGet(host: target.host, port: target.port, path: target.path))
        let raw = try await receiveAll(connection, limit: 64_000)
        let reply = try parseHTTP(raw)
        let ip = extractIP(reply.text)
        return WhoamiDump(
            ok: reply.status == 200 && !ip.isEmpty,
            status: reply.status,
            ip: ip,
            body: reply.text.trimmingCharacters(in: .whitespacesAndNewlines),
            ms: Int(Date().timeIntervalSince(started) * 1000)
        )
    }

    private struct Target {
        var host: String
        var port: UInt16
        var path: String
        var tls: Bool
    }

    private static func parseTarget(_ raw: String, fallbackHost: String, fallbackPort: UInt16) throws -> Target {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return Target(host: fallbackHost, port: fallbackPort, path: "/", tls: fallbackPort == 443)
        }
        if !trimmed.contains("://") {
            return Target(host: trimmed, port: fallbackPort, path: "/", tls: false)
        }
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else {
            throw ProxyFail("Bad target URL")
        }
        let tls = (url.scheme ?? "http").lowercased() == "https"
        let port = UInt16(url.port ?? (tls ? 443 : 80))
        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty {
            path += "?\(query)"
        }
        return Target(host: host, port: port, path: path, tls: tls)
    }

    private static func openTunnel(input: ProxyInput, dest: Target, log: ProxyLog) async throws -> NWConnection {
        log.line("STEP", "tcp-connect")
        let connection = try await connect(
            host: input.host,
            port: input.port,
            tls: input.wrap == .tls,
            timeout: 10
        )
        log.line("STEP", "tcp-ready")
        if input.kind == .http {
            log.line("STEP", "http-connect")
            try await httpConnect(connection, host: dest.host, port: dest.port, user: input.user, password: input.password)
        } else {
            log.line("STEP", "socks5")
            try await socks5Connect(connection, host: dest.host, port: dest.port, user: input.user, password: input.password)
        }
        log.line("STEP", "tunnel-up")
        return connection
    }

    private static func connect(host: String, port: UInt16, tls: Bool, timeout: TimeInterval) async throws -> NWConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw ProxyFail("Bad port") }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(max(2, timeout))
        tcp.noDelay = true
        let params = tls
            ? NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)
            : NWParameters(tls: nil, tcp: tcp)
        params.preferNoProxies = true
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var finished = false
            @Sendable func finish(_ result: Result<Void, Error>) {
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
                    finish(.failure(ProxyFail("cancelled")))
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(.failure(ProxyFail("timeout \(Int(timeout))s")))
            }
        }
        return connection
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
                    continuation.resume(throwing: ProxyFail("closed"))
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
            if chunk.isEmpty { throw ProxyFail("closed") }
            data.append(chunk)
        }
        return data
    }

    private static func receiveAll(_ connection: NWConnection, limit: Int) async throws -> Data {
        var data = Data()
        let deadline = Date().addingTimeInterval(12)
        while data.count < limit {
            if Date() > deadline {
                if data.isEmpty { throw ProxyFail("recv timeout") }
                break
            }
            do {
                let chunk = try await receiveSome(connection, min: 1, max: min(16 * 1024, limit - data.count))
                if chunk.isEmpty { break }
                data.append(chunk)
                if looksCompleteHTTP(data) { break }
            } catch {
                if data.isEmpty { throw error }
                break
            }
        }
        return data
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
        throw ProxyFail("CONNECT reply too long")
    }

    private static func socks5Connect(_ connection: NWConnection, host: String, port: UInt16, user: String, password: String) async throws {
        if user.isEmpty {
            try await send(connection, Data([0x05, 0x01, 0x00]))
        } else {
            try await send(connection, Data([0x05, 0x02, 0x00, 0x02]))
        }
        let hello = try await receiveExact(connection, 2)
        guard hello.count == 2, hello[0] == 0x05 else { throw ProxyFail("SOCKS bad greeting") }
        if hello[1] == 0x02 {
            guard !user.isEmpty else { throw ProxyFail("SOCKS server wants a login") }
            var auth = Data([0x01, UInt8(min(user.utf8.count, 255))])
            auth.append(Data(user.utf8.prefix(255)))
            auth.append(UInt8(min(password.utf8.count, 255)))
            auth.append(Data(password.utf8.prefix(255)))
            try await send(connection, auth)
            let reply = try await receiveExact(connection, 2)
            guard reply.count == 2, reply[1] == 0x00 else { throw ProxyFail("SOCKS login rejected") }
        } else if hello[1] != 0x00 {
            throw ProxyFail("SOCKS method \(hello[1]) not supported")
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
        guard reply.count == 4, reply[0] == 0x05 else { throw ProxyFail("SOCKS bad connect reply") }
        guard reply[1] == 0x00 else { throw ProxyFail("SOCKS \(socksStatus(reply[1]))") }
        let rest: Int
        switch reply[3] {
        case 0x01: rest = 4 + 2
        case 0x04: rest = 16 + 2
        case 0x03:
            let len = try await receiveExact(connection, 1)
            rest = Int(len[0]) + 2
        default:
            throw ProxyFail("SOCKS bad address type")
        }
        _ = try await receiveExact(connection, rest)
    }

    private static func httpConnect(_ connection: NWConnection, host: String, port: UInt16, user: String, password: String) async throws {
        var packet = "CONNECT \(host):\(port) HTTP/1.1\r\nHost: \(host):\(port)\r\n"
        if !user.isEmpty {
            let raw = "\(user):\(password)"
            packet += "Proxy-Authorization: Basic \(Data(raw.utf8).base64EncodedString())\r\n"
        }
        packet += "Proxy-Connection: Keep-Alive\r\n\r\n"
        try await send(connection, Data(packet.utf8))
        let raw = try await receiveUntilHeaders(connection)
        let reply = try parseHTTP(raw)
        guard (200 ..< 300).contains(reply.status) else {
            throw ProxyFail("HTTP CONNECT \(reply.status)")
        }
    }

    private static func directGET(_ target: Target) async throws -> Data {
        let connection = try await connect(host: target.host, port: target.port, tls: false, timeout: 10)
        defer { connection.cancel() }
        try await send(connection, httpGet(host: target.host, port: target.port, path: target.path))
        return try await receiveAll(connection, limit: 64_000)
    }

    private static func urlSessionViaProxy(input: ProxyInput, target: Target) async throws -> HTTPReply {
        if input.wrap == .tls {
            throw ProxyFail("HTTPS whoami needs Wrap=None")
        }
        guard let url = absoluteURL(target) else { throw ProxyFail("Bad HTTPS URL") }
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 12
        config.connectionProxyDictionary = proxyDictionary(input)
        let auth = ProxyAuthDelegate(user: input.user, password: input.password)
        let session = URLSession(configuration: config, delegate: auth, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.setValue("Probe/1.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return HTTPReply(status: status, body: data)
    }

    private static func urlSessionDirect(target: Target) async throws -> HTTPReply {
        guard let url = absoluteURL(target) else { throw ProxyFail("Bad HTTPS URL") }
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 12
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Probe/1.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return HTTPReply(status: status, body: data)
    }

    private static func absoluteURL(_ target: Target) -> URL? {
        var parts = URLComponents()
        parts.scheme = target.tls ? "https" : "http"
        parts.host = target.host
        let implicit = (target.tls && target.port == 443) || (!target.tls && target.port == 80)
        if !implicit {
            parts.port = Int(target.port)
        }
        let split = target.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        parts.path = split.first?.isEmpty == true ? "/" : (split.first ?? "/")
        if split.count == 2 {
            parts.query = split[1]
        }
        return parts.url
    }

    private static func proxyDictionary(_ input: ProxyInput) -> [AnyHashable: Any] {
        if input.kind == .http {
            return [
                "HTTPEnable": 1,
                "HTTPProxy": input.host,
                "HTTPPort": Int(input.port),
                "HTTPSEnable": 1,
                "HTTPSProxy": input.host,
                "HTTPSPort": Int(input.port),
            ]
        }
        var dict: [AnyHashable: Any] = [
            "SOCKSEnable": 1,
            "SOCKSProxy": input.host,
            "SOCKSPort": Int(input.port),
        ]
        if !input.user.isEmpty {
            dict["SOCKSUser"] = input.user
            dict["SOCKSPassword"] = input.password
        }
        return dict
    }

    private static func httpGet(host: String, port: UInt16, path: String) -> Data {
        let hostHeader = port == 80 ? host : "\(host):\(port)"
        var head = "GET \(path) HTTP/1.0\r\n"
        head += "Host: \(hostHeader)\r\n"
        head += "Connection: close\r\n"
        head += "User-Agent: Probe/1.1\r\n\r\n"
        return Data(head.utf8)
    }

    private struct HTTPReply {
        var status: Int
        var body: Data
        var text: String { String(data: body, encoding: .utf8) ?? "" }
    }

    private static func parseHTTP(_ raw: Data) throws -> HTTPReply {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = raw.range(of: separator) else {
            throw ProxyFail("Incomplete HTTP reply")
        }
        let head = String(data: raw.subdata(in: raw.startIndex ..< range.lowerBound), encoding: .utf8) ?? ""
        let body = raw.subdata(in: range.upperBound ..< raw.endIndex)
        let first = head.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let parts = first.split(separator: " ")
        let status = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0
        return HTTPReply(status: status, body: body)
    }

    private static func looksCompleteHTTP(_ raw: Data) -> Bool {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = raw.range(of: separator) else { return false }
        let head = String(data: raw.subdata(in: raw.startIndex ..< range.lowerBound), encoding: .utf8) ?? ""
        let body = raw.subdata(in: range.upperBound ..< raw.endIndex)
        let lower = head.lowercased()
        if let line = lower.split(separator: "\r\n").first(where: { $0.hasPrefix("content-length:") }) {
            let n = Int(line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") ?? -1
            return n >= 0 && body.count >= n
        }
        return !body.isEmpty
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

    private static func extractIP(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = trimmed.range(of: #"\b\d{1,3}(?:\.\d{1,3}){3}\b"#, options: .regularExpression) {
            return String(trimmed[match])
        }
        return trimmed.count <= 64 ? trimmed : ""
    }

    private static func percentile(_ values: [Int], _ p: Int) -> Int {
        guard !values.isEmpty else { return 0 }
        let idx = min(values.count - 1, max(0, Int((Double(p) / 100.0) * Double(values.count - 1))))
        return values[idx]
    }

    private static func clip(_ text: String, _ max: Int) -> String {
        if text.count <= max { return text }
        return String(text.prefix(max)) + "…(truncated)"
    }
}

private final class ProxyAuthDelegate: NSObject, URLSessionTaskDelegate, URLSessionDelegate {
    let user: String
    let password: String

    init(user: String, password: String) {
        self.user = user
        self.password = password
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge, completionHandler: completionHandler)
    }

    private func handle(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.isProxy {
            if user.isEmpty {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(
                .useCredential,
                URLCredential(user: user, password: password, persistence: .forSession)
            )
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

private struct ProxyFail: Error, LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class ProxyLog {
    private var lines: [String] = []

    func line(_ key: String, _ value: String) {
        let safe = value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: "\\n")
        lines.append("\(key)=\(safe)")
    }

    func append(_ error: Error, prefix: String = "ERROR") {
        let ns = error as NSError
        line("\(prefix)_TYPE", String(describing: type(of: error)))
        line("\(prefix)_DOMAIN", ns.domain)
        line("\(prefix)_CODE", "\(ns.code)")
        line("\(prefix)_DESC", ns.localizedDescription)
        if let nw = error as? NWError {
            line("\(prefix)_NW", String(describing: nw))
        }
    }

    func dump(ok: Bool, title: String) -> ProbeDump {
        ProbeDump(ok: ok, title: title, text: lines.joined(separator: "\n"))
    }
}
