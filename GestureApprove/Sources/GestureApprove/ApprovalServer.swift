import Foundation
import Network

/// 极简本地 HTTP 服务，监听 127.0.0.1:<port>。
/// hook 脚本 POST /approve {"operation":"..."}，阻塞直到返回 {"decision":"allow|deny","reason":"..."}。
/// 一次审批请求的上下文：操作串 + 发起项目目录 + 工具名（cwd/tool 可空）。
struct ApprovalRequest {
    let operation: String
    let cwd: String
    let tool: String
    let session: String   // 会话 ID（Claude session_id；其它 CLI 可能为空）
}

final class ApprovalServer {
    private let port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.tankxu.gestureapprove.server")

    /// (request) -> 异步回调 (decision, reason)。decision ∈ {"allow","deny","ask"}。
    /// 实现方负责切到主线程跑 UI。
    private let onApprove: (ApprovalRequest, @escaping (String, String) -> Void) -> Void

    init(port: UInt16, onApprove: @escaping (ApprovalRequest, @escaping (String, String) -> Void) -> Void) {
        self.port = port
        self.onApprove = onApprove
    }

    func start() throws {
        try startListener()
    }

    /// 主动重启监听（睡眠唤醒后调用）。串行到 queue，幂等。
    func restart() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            do { try self.startListener() }
            catch { self.scheduleRestart() }
        }
    }

    private func startListener() throws {
        let params = NWParameters.tcp
        // 重启（唤醒/自愈）时旧 listener 端口可能还没释放，允许复用避免 "Address already in use"。
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: params)
        listener.stateUpdateHandler = { [weak self] state in
            // 睡眠/网络栈重置后 listener 可能静默 .failed —— 自动重建，否则端口悄悄死掉、approve 不再走 app。
            // .cancelled 只在我们主动 restart 时出现，不重启（避免循环）。
            if case .failed(let err) = state {
                GALog.log("监听失败(\(err))，准备自愈重启")
                self?.scheduleRestart()
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.start(queue: queue)
        self.listener = listener
        GALog.log("审批服务已监听 127.0.0.1:\(port)")
    }

    /// 延迟重启（带退避，避免端口未释放时疯狂重试）。
    private func scheduleRestart() {
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            do { try self.startListener() }
            catch { self.scheduleRestart() }
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveRequest(conn, buffer: Data())
    }

    private func receiveRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }

            if let (_, body) = Self.parseHTTP(buf) {
                self.process(conn, body: body)
                return
            }
            if isComplete || error != nil {
                self.respond(conn, decision: "ask", reason: "请求不完整")
                return
            }
            self.receiveRequest(conn, buffer: buf)
        }
    }

    private func process(_ conn: NWConnection, body: Data) {
        let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let req = ApprovalRequest(
            operation: obj?["operation"] as? String ?? "",
            cwd: obj?["cwd"] as? String ?? "",
            tool: obj?["tool"] as? String ?? "",
            session: obj?["session"] as? String ?? "")
        onApprove(req) { [weak self] decision, reason in
            self?.respond(conn, decision: decision, reason: reason)
        }
    }

    private func respond(_ conn: NWConnection, decision: String, reason: String) {
        let payload: [String: Any] = ["decision": decision, "reason": reason]
        let json = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        var resp = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
        resp.append(json)
        conn.send(content: resp, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

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
}
