import Foundation
import Network

/// 极简 HTTP 服务。两个监听口：
///   · `127.0.0.1:<port>`（trusted）——CLI hook 走这里，POST /approve，免认证。
///   · `0.0.0.0:<devicePort>`（非 trusted，可选）——网络审批设备（ESP32 等）走这里，强制 Bearer token。
///
/// hook: POST /approve {"operation":..} 阻塞直到 {"decision":"allow|deny|ask","reason":..}。
/// 设备下行: GET /state?since=&wait= —— 长轮询"审批动态"（见 DeviceApprovalState）。
/// 设备上行: POST /resolve {"id":..,"decision":"allow|deny"} —— 提交裁决，效果同热键/点击。
struct ApprovalRequest {
    let operation: String
    let cwd: String
    let tool: String
    let session: String   // 会话 ID（Claude session_id；其它 CLI 可能为空）
}

final class ApprovalServer {
    private struct Bind { let host: String; let port: UInt16; let trusted: Bool }

    private let loopbackBind: Bind
    private let deviceBind: Bind?          // 设备口的绑定描述（nil 表示从未配置设备参数）
    private var deviceEnabled: Bool        // 运行时开关：设置窗可即时起停设备监听
    private var listeners: [NWListener] = []
    private let queue = DispatchQueue(label: "com.tankxu.gestureapprove.server")

    /// 当前应处于活动的绑定：loopback 始终有；设备口在配置且开关打开时才有。
    private func activeBinds() -> [Bind] {
        var b = [loopbackBind]
        if deviceEnabled, let d = deviceBind { b.append(d) }
        return b
    }

    /// (request) -> 异步回调 (decision, reason)。decision ∈ {"allow","deny","ask"}。实现方负责切主线程跑 UI。
    private let onApprove: (ApprovalRequest, @escaping (String, String) -> Void) -> Void
    /// 设备提交裁决：(id, decision) -> 异步回 是否生效（id 不匹配当前 pending 则 false）。
    private let onResolve: ((String, String, @escaping (Bool) -> Void) -> Void)?
    /// 设备下行状态源（长轮询）。
    private let deviceState: DeviceApprovalState?
    /// 设备口的 Bearer token；非 trusted 连接必须匹配。
    private let deviceToken: String?

    init(port: UInt16,
         devicePort: UInt16? = nil,
         deviceToken: String? = nil,
         deviceState: DeviceApprovalState? = nil,
         deviceEnabled: Bool = false,
         onResolve: ((String, String, @escaping (Bool) -> Void) -> Void)? = nil,
         onApprove: @escaping (ApprovalRequest, @escaping (String, String) -> Void) -> Void) {
        self.loopbackBind = Bind(host: "127.0.0.1", port: port, trusted: true)
        self.deviceBind = devicePort.map { Bind(host: "0.0.0.0", port: $0, trusted: false) }
        self.deviceEnabled = deviceEnabled
        self.deviceToken = deviceToken
        self.deviceState = deviceState
        self.onResolve = onResolve
        self.onApprove = onApprove
    }

    func start() throws { try startAll() }

    /// 运行时起停设备监听（设置窗切换设备口开关时调用）。串行到 queue，幂等。
    func setDeviceEnabled(_ on: Bool) {
        queue.async { [weak self] in
            guard let self, self.deviceEnabled != on else { return }
            self.deviceEnabled = on
            self.cancelAll()
            do { try self.startAll() } catch { self.scheduleRestart() }
        }
    }

    /// 主动重启所有监听（睡眠唤醒后调用）。串行到 queue，幂等。
    func restart() {
        queue.async { [weak self] in
            guard let self else { return }
            self.cancelAll()
            do { try self.startAll() } catch { self.scheduleRestart() }
        }
    }

    private func cancelAll() {
        listeners.forEach { $0.cancel() }
        listeners = []
    }

    private func startAll() throws {
        cancelAll()
        for bind in activeBinds() { try startOne(bind) }
    }

    private func startOne(_ bind: Bind) throws {
        let params = NWParameters.tcp
        // 重启（唤醒/自愈）时旧 listener 端口可能还没释放，允许复用避免 "Address already in use"。
        params.allowLocalEndpointReuse = true
        let listener: NWListener
        if bind.host == "0.0.0.0" {
            // 绑所有接口（设备口）：用 on:port，不设 requiredLocalEndpoint（那样会被限到单地址）。
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: bind.port)!)
        } else {
            params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bind.host),
                                                     port: NWEndpoint.Port(rawValue: bind.port)!)
            listener = try NWListener(using: params)
        }
        listener.stateUpdateHandler = { [weak self] state in
            // 睡眠/网络栈重置后 listener 可能静默 .failed —— 自动重建，否则端口悄悄死掉。
            // .cancelled 只在主动 restart 时出现，不重启（避免循环）。
            if case .failed(let err) = state {
                GALog.log("监听失败(\(err)) \(bind.host):\(bind.port)，准备自愈重启")
                self?.scheduleRestart()
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn, trusted: bind.trusted)
        }
        listener.start(queue: queue)
        listeners.append(listener)
        GALog.log("审批服务已监听 \(bind.host):\(bind.port) trusted=\(bind.trusted)")
    }

    /// 延迟重启（带退避，避免端口未释放时疯狂重试）。
    private func scheduleRestart() {
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.cancelAll()
            do { try self.startAll() } catch { self.scheduleRestart() }
        }
    }

    private func handle(_ conn: NWConnection, trusted: Bool) {
        conn.start(queue: queue)
        receiveRequest(conn, buffer: Data(), trusted: trusted)
    }

    private func receiveRequest(_ conn: NWConnection, buffer: Data, trusted: Bool) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }

            if let (headers, body) = Self.parseHTTP(buf) {
                self.route(conn, headers: headers, body: body, trusted: trusted)
                return
            }
            if isComplete || error != nil {
                self.respondJSON(conn, obj: ["decision": "ask", "reason": "请求不完整"])
                return
            }
            self.receiveRequest(conn, buffer: buf, trusted: trusted)
        }
    }

    // MARK: 路由

    private func route(_ conn: NWConnection, headers: String, body: Data, trusted: Bool) {
        let reqLine = headers.split(separator: "\r\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let parts = reqLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? ""
        let rawPath = parts.count > 1 ? String(parts[1]) : "/"
        let (path, query) = Self.splitQuery(rawPath)

        // hook 的信任通道：只在 loopback 上提供，且保持原有"body 即审批请求"的宽松兼容
        // （老 hook 不带 path/固定 /approve 都照收）。
        if trusted, path == "/approve" || path == "/" {
            process(conn, body: body)
            return
        }

        // 设备通道：非 trusted 一律先验 token（trusted 上也开放 /state、/resolve 便于本地 curl 调试）。
        if !trusted {
            guard let token = deviceToken, !token.isEmpty,
                  Self.headerValue(headers, "authorization") == "Bearer \(token)" else {
                respondJSON(conn, status: "401 Unauthorized", obj: ["error": "unauthorized"])
                return
            }
        }

        switch (method, path) {
        case ("GET", "/state"):
            handleState(conn, query: query)
        case ("POST", "/resolve"):
            handleResolve(conn, body: body)
        default:
            respondJSON(conn, status: "404 Not Found", obj: ["error": "not found"])
        }
    }

    /// hook 审批：交给 onApprove，拿到 decision 再回包（这一路会阻塞连接直到用户裁决/超时）。
    private func process(_ conn: NWConnection, body: Data) {
        let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let req = ApprovalRequest(
            operation: obj?["operation"] as? String ?? "",
            cwd: obj?["cwd"] as? String ?? "",
            tool: obj?["tool"] as? String ?? "",
            session: obj?["session"] as? String ?? "")
        onApprove(req) { [weak self] decision, reason in
            self?.respondJSON(conn, obj: ["decision": decision, "reason": reason])
        }
    }

    /// 设备下行：长轮询审批动态。version 更新即回，否则挂起到 wait 秒兜底回当前快照。
    private func handleState(_ conn: NWConnection, query: [String: String]) {
        guard let state = deviceState else {
            respondJSON(conn, obj: ["version": 0, "state": "idle"]); return
        }
        let since = UInt64(query["since"] ?? "") ?? 0
        let wait = max(0, min(60, Double(query["wait"] ?? "") ?? 25))

        // wait<=0：不挂起，直接回当前快照（一次性查询）。
        if wait <= 0 {
            respondJSON(conn, obj: state.snapshotJSON()); return
        }

        // 等待者回调与超时兜底可能都触发，只允许第一个回包（后到者在已关闭连接上 send 无害，但要防重复）。
        var responded = false
        let respondOnce: ([String: Any]) -> Void = { [weak self] obj in
            self?.queue.async {
                guard let self, !responded else { return }
                responded = true
                self.respondJSON(conn, obj: obj)
            }
        }

        state.waitOrRegister(since: since) { obj in respondOnce(obj) }
        if wait > 0 {
            queue.asyncAfter(deadline: .now() + wait) {
                respondOnce(state.snapshotJSON())
            }
        }
    }

    /// 设备上行：提交裁决。id 必须匹配当前 pending，否则 409（防旧按键误批到新命令）。
    private func handleResolve(_ conn: NWConnection, body: Data) {
        let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let id = obj?["id"] as? String ?? ""
        let decision = obj?["decision"] as? String ?? ""
        guard decision == "allow" || decision == "deny" else {
            respondJSON(conn, status: "400 Bad Request", obj: ["ok": false, "error": "decision must be allow|deny"])
            return
        }
        guard let onResolve else {
            respondJSON(conn, status: "503 Service Unavailable", obj: ["ok": false, "error": "resolve unavailable"])
            return
        }
        onResolve(id, decision) { [weak self] ok in
            self?.respondJSON(conn, status: ok ? "200 OK" : "409 Conflict",
                              obj: ["ok": ok, "reason": ok ? "applied" : "no matching pending approval"])
        }
    }

    private func respondJSON(_ conn: NWConnection, status: String = "200 OK", obj: [String: Any]) {
        let json = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        var resp = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
        resp.append(json)
        conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: 解析

    /// 解析 HTTP 请求，拿到 (headers, body)。需收到完整 body 才返回非 nil。
    private static func parseHTTP(_ data: Data) -> (String, Data)? {
        let sep = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: sep) else { return nil }
        let headerData = data.subdata(in: data.startIndex..<range.lowerBound)
        let headers = String(decoding: headerData, as: UTF8.self)
        let bodyStart = range.upperBound

        var contentLength = 0
        for line in headers.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                contentLength = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let available = data.distance(from: bodyStart, to: data.endIndex)
        if available < contentLength { return nil }  // body 还没收全
        let body = data.subdata(in: bodyStart..<data.index(bodyStart, offsetBy: contentLength))
        return (headers, body)
    }

    /// 拆 `/path?a=1&b=2` -> ("/path", ["a":"1","b":"2"])。
    private static func splitQuery(_ raw: String) -> (String, [String: String]) {
        guard let q = raw.firstIndex(of: "?") else { return (raw, [:]) }
        let path = String(raw[..<q])
        var params: [String: String] = [:]
        for pair in raw[raw.index(after: q)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            params[String(kv[0])] = kv.count > 1 ? String(kv[1]) : ""
        }
        return (path, params)
    }

    /// 取某个 header 值（大小写不敏感匹配名字）。
    private static func headerValue(_ headers: String, _ name: String) -> String? {
        for line in headers.split(separator: "\r\n") {
            guard let idx = line.firstIndex(of: ":") else { continue }
            if line[..<idx].trimmingCharacters(in: .whitespaces).lowercased() == name.lowercased() {
                return line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
