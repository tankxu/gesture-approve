import Foundation

/// 一次审批是经由哪道闸做出的判定（决定卡片上展示的彩色标签）。
enum ApproveGate: String, Codable {
    case allowlist   // 白名单整条/前缀命中 → 自动放行
    case smartgate   // 本地 LLM 守门员判定 safe → 自动放行
    case gesture     // 弹卡片比手势裁决（通过/拒绝）
    case alwaysAllow // 卡片上点「总是允许」→ 通过并写入信任命令
    case timeout     // 手势超时未识别 → 交回终端
    case suspended   // 锁屏/睡眠 → 交回终端
    case gatingOff   // 审批总开关关闭 → 交回终端
}

/// 一条审批记录。time 用 epoch 秒存，跨进程/版本稳定，便于排序。
struct ApproveLogEntry: Codable, Identifiable {
    let time: Double          // Unix epoch 秒
    let operation: String     // "<tool>: <detail>" 操作串
    let cwd: String           // 发起项目目录
    let tool: String          // 工具名 Bash/Edit/…
    let session: String       // 会话 ID（Claude session_id；其它 CLI 可能为空）
    let decision: String      // allow / deny / ask
    let gate: String          // ApproveGate.rawValue
    let dangerous: Bool       // 是否命中黑名单（危险规则）

    var id: String { "\(time)-\(session)-\(operation.hashValue)" }
    var date: Date { Date(timeIntervalSince1970: time) }
    var gateKind: ApproveGate? { ApproveGate(rawValue: gate) }
}

/// 审批日志：每次接管的判定都追加一行 JSONL，持久化到 Application Support，
/// 供「审批日志」窗口回看。/tmp 会被系统清理，所以落在可写数据根而非 GALog 那种诊断日志。
enum ApproveLog {
    /// 文件封顶条数：超过则截掉最旧的，避免无限增长。
    private static let maxEntries = 3000
    private static let io = DispatchQueue(label: "com.tankxu.gestureapprove.approvelog")

    static var path: String { AppPaths.supportPath("approve-log.jsonl") }

    /// 追加一条记录。调用方多在主线程，文件 IO 切到串行队列，不阻塞 UI。
    static func record(_ req: ApprovalRequest, decision: String, gate: ApproveGate, dangerous: Bool) {
        let entry = ApproveLogEntry(
            time: Date().timeIntervalSince1970,
            operation: req.operation,
            cwd: req.cwd,
            tool: req.tool,
            session: req.session,
            decision: decision,
            gate: gate.rawValue,
            dangerous: dangerous)
        io.async {
            guard let data = try? JSONEncoder().encode(entry),
                  let line = String(data: data, encoding: .utf8) else { return }
            ensureDir()
            let p = path
            if let h = FileHandle(forWritingAtPath: p) {
                h.seekToEndOfFile()
                h.write(Data((line + "\n").utf8))
                try? h.close()
            } else {
                try? Data((line + "\n").utf8).write(to: URL(fileURLWithPath: p))
            }
            trimIfNeeded()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .gaApproveLogged, object: nil)
            }
        }
    }

    /// 读取全部记录，按时间倒序（新→旧）。解析失败的行跳过。
    static func recent() -> [ApproveLogEntry] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        let entries = text.split(separator: "\n").compactMap { line -> ApproveLogEntry? in
            guard let d = line.data(using: .utf8) else { return nil }
            return try? dec.decode(ApproveLogEntry.self, from: d)
        }
        return entries.sorted { $0.time > $1.time }
    }

    static func clear() {
        io.async { try? FileManager.default.removeItem(atPath: path) }
    }

    // MARK: 内部

    private static func ensureDir() {
        let dir = AppPaths.support
        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }

    /// 超过封顶则只保留最近 maxEntries 行重写。已在 io 队列内调用。
    private static func trimIfNeeded() {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count > maxEntries else { return }
        lines = Array(lines.suffix(maxEntries))
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
