import Foundation
import Network

/// 极简本地 HTTP 服务，监听 127.0.0.1:<port>。
/// hook 脚本 POST /approve {"operation":"..."}，阻塞直到返回 {"decision":"allow|deny","reason":"..."}。
final class ApprovalServer {
    private let port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "xyz.anome.gestureapprove.server")

    /// (operation) -> 异步回调 (decision, reason)。decision ∈ {"allow","deny","ask"}。
    /// 实现方负责切到主线程跑 UI。
    private let onApprove: (String, @escaping (String, String) -> Void) -> Void

    init(port: UInt16, onApprove: @escaping (String, @escaping (String, String) -> Void) -> Void) {
        self.port = port
        self.onApprove = onApprove
    }

    func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.start(queue: queue)
        self.listener = listener
        NSLog("GestureApprove: 审批服务已监听 127.0.0.1:\(port)")
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
        var operation = ""
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let op = obj["operation"] as? String {
            operation = op
        }
        onApprove(operation) { [weak self] decision, reason in
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
