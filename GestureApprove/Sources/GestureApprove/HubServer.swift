import Foundation
import Network

/// Remote Hub 的 HTTP 引擎(Network.framework 手写,和 ApprovalServer 同路子)。
/// 只负责收发/解析/路由分发与静态回包;业务逻辑在 HubApp。
///
/// 单监听口,host 随「局域网访问」开关切换:
///   · 开 → `0.0.0.0:<port>`(同 Wi-Fi 的手机/设备可连)
///   · 关 → `127.0.0.1:<port>`(仅本机 loopback)
/// 切换用 rebind()(cancel 旧 listener + 用新 host 重起),不用像 Python 版那样 re-exec。
final class HubServer {
    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data
        let isLoopback: Bool
        func header(_ n: String) -> String? { headers[n.lowercased()] }
    }
    struct Response {
        var status: String = "200 OK"
        var contentType: String = "application/json; charset=utf-8"
        var body: Data = Data()
        var extraHeaders: [String: String] = [:]

        static func json(_ obj: Any, status: String = "200 OK") -> Response {
            let data = (try? JSONSerialization.data(withJSONObject: obj,
                        options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
            return Response(status: status, contentType: "application/json; charset=utf-8", body: data)
        }
        static func error(_ msg: String, _ status: String = "400 Bad Request") -> Response {
            json(["error": msg], status: status)
        }
        static func html(_ s: String) -> Response {
            Response(status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(s.utf8))
        }
        static func rawJSON(_ data: Data, status: String = "200 OK") -> Response {
            Response(status: status, contentType: "application/json; charset=utf-8", body: data)
        }
    }

    /// 路由:异步(有的端点要发网络请求/跑 osascript);实现方拿到 Request,填 Response 回调。
    typealias Router = (Request, @escaping (Response) -> Void) -> Void

    private let port: UInt16
    private let router: Router
    private let queue = DispatchQueue(label: "com.tankxu.gestureapprove.hub")
    private var listener: NWListener?
    private(set) var host: String

    init(port: UInt16, lan: Bool, router: @escaping Router) {
        self.port = port
        self.host = lan ? "0.0.0.0" : "127.0.0.1"
        self.router = router
    }

    var isRunning: Bool { queue.sync { listener != nil } }

    func start() {
        queue.async { [weak self] in self?.startLocked() }
    }

    /// 切换绑定地址(局域网开关)。同地址则忽略。
    func rebind(lan: Bool) {
        let newHost = lan ? "0.0.0.0" : "127.0.0.1"
        queue.async { [weak self] in
            guard let self, self.host != newHost else { return }
            self.host = newHost
            self.listener?.cancel(); self.listener = nil
            self.startLocked()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel(); self?.listener = nil
        }
    }

    // MARK: 监听

    private func startLocked() {
        listener?.cancel(); listener = nil
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        do {
            let l: NWListener
            if host == "0.0.0.0" {
                l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            } else {
                params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host),
                                                         port: NWEndpoint.Port(rawValue: port)!)
                l = try NWListener(using: params)
            }
            l.stateUpdateHandler = { [weak self] state in
                if case .failed(let err) = state {
                    GALog.log("Hub 监听失败(\(err)) \(self?.host ?? "?"):\(self?.port ?? 0),1s 后重试")
                    self?.queue.asyncAfter(deadline: .now() + 1.0) { self?.startLocked() }
                }
            }
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            l.start(queue: queue)
            listener = l
            GALog.log("Remote Hub 已监听 \(host):\(port)")
        } catch {
            GALog.log("Remote Hub 起监听失败: \(error);1s 后重试")
            queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.startLocked() }
        }
    }

    private func handle(_ conn: NWConnection) {
        // 判定 loopback:配置页等只给本机的端点据此放行。
        var isLoopback = false
        if case let .hostPort(host, _)? = conn.currentPath?.remoteEndpoint {
            isLoopback = Self.isLoopbackHost(host)
        }
        conn.start(queue: queue)
        receive(conn, buffer: Data(), isLoopback: isLoopback)
    }

    private static func isLoopbackHost(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let a): return a == .loopback || "\(a)".hasPrefix("127.")
        case .ipv6(let a): return a == .loopback
        case .name(let n, _): return n == "localhost"
        @unknown default: return false
        }
    }

    private func receive(_ conn: NWConnection, buffer: Data, isLoopback: Bool) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 262144) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let (headers, body) = Self.parseHTTP(buf) {
                self.dispatch(conn, headers: headers, body: body, isLoopback: isLoopback)
                return
            }
            if isComplete || error != nil {
                self.send(conn, Response.error("bad request", "400 Bad Request"))
                return
            }
            self.receive(conn, buffer: buf, isLoopback: isLoopback)
        }
    }

    private func dispatch(_ conn: NWConnection, headers: String, body: Data, isLoopback: Bool) {
        let lines = headers.split(separator: "\r\n", omittingEmptySubsequences: false)
        let reqLine = lines.first.map(String.init) ?? ""
        let parts = reqLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? "GET"
        let rawPath = parts.count > 1 ? String(parts[1]) : "/"
        let (path, query) = Self.splitQuery(rawPath)
        var hdrs: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let k = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { hdrs[k] = v }
        }
        let req = Request(method: method, path: path, query: query, headers: hdrs,
                          body: body, isLoopback: isLoopback)
        router(req) { [weak self] resp in self?.send(conn, resp) }
    }

    private func send(_ conn: NWConnection, _ r: Response) {
        var head = "HTTP/1.1 \(r.status)\r\nContent-Type: \(r.contentType)\r\nContent-Length: \(r.body.count)\r\nConnection: close\r\n"
        for (k, v) in r.extraHeaders { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var resp = Data(head.utf8)
        resp.append(r.body)
        conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: HTTP 解析(同 ApprovalServer 思路,支持大 body 如 ASR 音频)

    private static func parseHTTP(_ data: Data) -> (String, Data)? {
        let sep = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: sep) else { return nil }
        let headers = String(decoding: data.subdata(in: data.startIndex..<range.lowerBound), as: UTF8.self)
        let bodyStart = range.upperBound
        var contentLength = 0
        for line in headers.split(separator: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                contentLength = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let available = data.distance(from: bodyStart, to: data.endIndex)
        if available < contentLength { return nil }
        let body = data.subdata(in: bodyStart..<data.index(bodyStart, offsetBy: contentLength))
        return (headers, body)
    }

    private static func splitQuery(_ raw: String) -> (String, [String: String]) {
        guard let q = raw.firstIndex(of: "?") else { return (raw, [:]) }
        let path = String(raw[..<q])
        var params: [String: String] = [:]
        for pair in raw[raw.index(after: q)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let v = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            params[k] = v
        }
        return (path, params)
    }
}
