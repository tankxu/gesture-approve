import Foundation
import SQLite3

/// Agent 完成通知：Claude Code 的 `Stop` hook（agent 跑完一轮）打到本机 app
/// （loopback:47600 `POST /agent-event`），在这里统一分发：
///   · **桌面通知**——系统横幅「Agent 已完成 · <项目>」+ 最后一条回复摘要；
///   · **Remote Hub 接口**——写进 `AgentEventStore`，手机/设备走 `GET /events` 长轮询取。
///
/// 三个独立开关（设置窗）：总开关（同时决定 Stop hook 装不装）、桌面通知、推送到 Hub。
/// 总开关关 → hook 不安装、即使有请求也直接丢弃，绝不写状态、不发通知。
enum AgentNotify {
    // 两个来源各自一个开关（= 各自的 Stop hook 装没装）；默认都关，不擅自改用户的 CLI 配置。
    static let claudeKey = "agentNotifyEnabled"     // 历史键名，语义 = Claude Code 的 Stop hook
    static let codexKey = "agentNotifyCodex"        // Codex 的 Stop hook（"Right before Codex ends its turn"）
    static let desktopKey = "agentNotifyDesktop"    // 桌面系统通知（默认开）
    static let hubKey = "agentNotifyHub"            // 推送到 Remote Hub /events（默认开）

    static var claudeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: claudeKey) }
        set { UserDefaults.standard.set(newValue, forKey: claudeKey) }
    }
    static var codexEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: codexKey) }
        set { UserDefaults.standard.set(newValue, forKey: codexKey) }
    }
    /// 任一来源开着，功能就算开着（事件处理、/events 的 enabled 字段都看它）。
    static var isEnabled: Bool { claudeEnabled || codexEnabled }
    static var desktopEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: desktopKey) as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: desktopKey) }
    }
    static var hubEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: hubKey) as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: hubKey) }
    }

    /// 处理一条 hook 送来的事件。**文件读取（transcript 尾部）放后台线程**：
    /// Stop hook 是同步等我们回包的，别让它替我们扛 IO 延迟。
    static func handle(_ payload: [String: Any]) {
        guard isEnabled else { return }
        let session = payload["session"] as? String ?? ""
        let cwd = payload["cwd"] as? String ?? ""
        let transcript = payload["transcript"] as? String ?? ""
        let source = payload["source"] as? String ?? "claude"
        let kind = payload["kind"] as? String ?? "done"      // done = 跑完一轮；waiting = 在等你
        // Hub 代发的回复（手机 → claude --resume -p）：记事件但不弹桌面横幅
        let silent = (payload["silent"] as? Bool) ?? false
        // Codex 的 Stop hook 直接把最后一句话给了我们（last_assistant_message）；
        // Claude 的没有这个字段，得自己去 transcript 尾部捞。
        let given = (payload["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        DispatchQueue.global(qos: .utility).async {
            let project = (cwd as NSString).lastPathComponent
            let raw: String
            if !given.isEmpty {
                raw = given
            } else if source == "claude" {
                // 只对 Claude 解析：Codex 的 rollout jsonl 是另一套结构，硬套只会捞出乱七八糟的东西。
                let path = transcript.isEmpty ? (HubApp.transcriptPath(session) ?? "") : transcript
                raw = path.isEmpty ? "" : lastAssistantText(path)
            } else {
                raw = ""
            }
            // 事件流里存**原文**（markdown 原样，留给客户端自己决定怎么渲染，见 /events?plain=1）；
            // 桌面通知则用洗过的纯文本。先洗后截：反过来截断可能正好切在 `**` 中间，
            // 洗完还剩个孤零零的星号。
            let summary = String(raw.prefix(800))
            let clean = plainText(raw)
            let notifyBody = clean.count > 220 ? String(clean.prefix(220)) + "…" : clean
            // 标题按"信息量"逐级回退：
            //   Claude：aiTitle（客户端生成的那个）→ 第一条真实用户消息 → 项目名
            //   Codex ：它自己 state_5.sqlite 里的 title/name → 项目名
            // 只用项目名的话，同一个项目开几个会话，通知全长一个样。
            var title = ""
            if source == "claude", !session.isEmpty {
                title = HubApp.aiTitle(session)
                if title.isEmpty {
                    let p = transcript.isEmpty ? (HubApp.transcriptPath(session) ?? "") : transcript
                    if !p.isEmpty { title = firstUserTitle(p) }
                }
            } else if source == "codex", !session.isEmpty {
                title = codexThreadTitle(session) ?? ""
            }
            if title.isEmpty { title = project }
            let bridge = (source == "claude" && !session.isEmpty) ? HubApp.bridgeFor(session) : nil

            if hubEnabled {
                AgentEventStore.shared.append(kind: kind, source: source, sessionId: session,
                                              title: title, project: project, cwd: cwd,
                                              summary: summary,
                                              webUrl: bridge.map { "https://claude.ai/code/\($0)" })
            }
            if desktopEnabled, !silent {
                // 通知的三层结构按「一眼要认出哪个会话」来排：
                //   标题(最大) = 会话标题；副标题 = 状态或目录；正文 = 细节。
                // 以前把"Agent 已完成 · 项目"当标题、会话标题挤在正文第一行，
                // 结果几条通知堆一起时全长一个样，得逐条读正文才分得清是哪个。
                let head = title.isEmpty ? (project.isEmpty ? L("agent.notify.title") : project) : title
                var place = shortPath(cwd)
                if source == "codex" { place += place.isEmpty ? "Codex" : " · Codex" }
                let subtitle: String
                let body: String
                if kind == "waiting" {
                    // 「在等你」没有"最后说的话"可展示，状态本身才是重点 → 状态上提到副标题，目录退到正文。
                    subtitle = L("agent.notify.waiting")
                    body = place
                } else {
                    subtitle = place
                    body = notifyBody.isEmpty ? L("agent.notify.noSummary") : notifyBody
                }
                // 专属提示音（木琴"登登登·灯"）：菜单栏 app 的通知一天好几条，
                // 光看横幅要抬眼确认，一个不撞系统音的旋律能让你不看屏幕就知道是它。
                Notifier.post(title: head, subtitle: subtitle, body: body, sound: nil,
                              thread: project.isEmpty ? source : "\(source)/\(project)")
                Notifier.playAgentDone()   // 通知静音，这一声由我们自己放（见 Notifier.playAgentDone）
            }
            GALog.log("Agent 事件[\(kind)] source=\(source) session=\(session.prefix(8)) 项目=\(project) 摘要\(summary.count)字(纯文本\(clean.count)) 桌面=\(desktopEnabled ? (silent ? "抑制(Hub代发)" : "弹") : "关") hub=\(hubEnabled)")
        }
    }

    /// transcript 开头的第一条**真实**用户消息——没有 aiTitle 时拿它当会话标题。
    /// 得挑着看：转录里"长得像用户消息"的东西一大半是系统塞的（isMeta 标记、
    /// `<command-*>` 斜杠命令、`<environment_context>` 之类的信封、Caveat 开场白），
    /// 不过滤的话标题会变成一坨系统提示。斜杠命令则拼成 "/命令 参数" 这种能读的形式。
    static func firstUserTitle(_ path: String, maxLen: Int = 60) -> String {
        for line in headLines(path) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  (o["type"] as? String) == "user",
                  (o["isMeta"] as? Bool) != true,
                  let m = o["message"] as? [String: Any] else { continue }
            var text = ""
            if let c = m["content"] as? String {
                text = c
            } else if let parts = m["content"] as? [[String: Any]] {
                for part in parts where (part["type"] as? String) == "text" {
                    if let t = part["text"] as? String, !t.isEmpty { text = t; break }
                }
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let slash = slashCommandTitle(text) { return String(slash.prefix(maxLen)) }
            // 系统塞进来的信封 / 恢复会话时的开场白：不是用户说的话，跳过。
            let envelopes = ["<environment_context", "<user_instructions", "<system-reminder",
                             "<permissions", "<local-command", "<command-", "Caveat:", "# AGENTS.md", "# CLAUDE.md"]
            if envelopes.contains(where: { text.hasPrefix($0) }) { continue }
            let oneLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            return oneLine.count > maxLen ? String(oneLine.prefix(maxLen)) + "…" : oneLine
        }
        return ""
    }

    /// `<command-name>/foo</command-name><command-args>bar</command-args>` → `/foo bar`
    private static func slashCommandTitle(_ raw: String) -> String? {
        func tag(_ name: String) -> String? {
            guard let a = raw.range(of: "<\(name)>"), let b = raw.range(of: "</\(name)>"),
                  a.upperBound <= b.lowerBound else { return nil }
            let v = raw[a.upperBound..<b.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }
        guard let name = tag("command-name") else { return nil }
        var parts = [name]
        if let msg = tag("command-message"),
           msg.caseInsensitiveCompare(name) != .orderedSame,
           msg.caseInsensitiveCompare(String(name.dropFirst())) != .orderedSame {
            parts.append(msg)
        }
        if let args = tag("command-args") { parts.append(args) }
        return parts.joined(separator: " ")
    }

    /// Codex 会话标题：直接查它自己的 `~/.codex/state_5.sqlite`（threads 表里
    /// title/cwd/model 全是现成的，不用去啃 rollout jsonl）。只读打开，查不到就返回 nil。
    static func codexThreadTitle(_ sessionId: String) -> String? {
        guard !sessionId.isEmpty else { return nil }
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/state_5.sqlite")
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)      // Codex 正在写就等一下，等不到拉倒（标题不是必需品）
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name, title FROM threads WHERE id = ? LIMIT 1", -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            sqlite3_finalize(stmt)
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, sessionId, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        func column(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, i) else { return nil }
            // 有的 title 是多行（Codex 会把整段首条消息塞进去），只取第一行。
            let v = String(cString: c).split(whereSeparator: \.isNewline).first
                .map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return v.isEmpty ? nil : (v.count > 60 ? String(v.prefix(60)) + "…" : v)
        }
        return column(0) ?? column(1)      // name = 用户自己起的名字，优先于自动生成的 title
    }

    /// 读文件**开头**若干字节并按行切分（尾部版见 tailLines）。
    private static func headLines(_ path: String, bytes: Int = 262_144) -> [String] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: bytes) else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// 把 agent 的回复降级成"人话"：通知横幅是纯文本，markdown 原样塞进去就是一堆
    /// 星号、反引号和竖线（表格尤其惨）。这里不做完整解析，只把常见记号抹平、折行压成一行。
    static func plainText(_ md: String) -> String {
        var s = md
        let rules: [(String, String)] = [
            ("```[a-zA-Z0-9+-]*\\n", ""), ("```", ""),          // 代码围栏
            ("!\\[([^\\]]*)\\]\\([^)]*\\)", "$1"),            // 图片 → alt
            ("\\[([^\\]]+)\\]\\([^)]*\\)", "$1"),             // 链接 → 文字
            ("`([^`]+)`", "$1"),                              // 行内代码
            ("\\*\\*([^*]+)\\*\\*", "$1"),                      // 粗体
            ("__([^_]+)__", "$1"),
            ("(?m)^\\s{0,3}#{1,6}\\s+", ""),                  // 标题
            ("(?m)^\\s{0,3}>\\s?", ""),                       // 引用
            ("(?m)^\\s*[-*+]\\s+", "· "),                     // 无序列表
            ("(?m)^\\s*\\d+[.)]\\s+", "· "),                  // 有序列表
            ("(?m)^\\s*[-|:\\s]{4,}$", ""),                   // 分隔线 / 表格分隔行
            ("\\|", " "),                                     // 表格竖线
            ("\\s*\\n\\s*", " "),                             // 折行压平（横幅只有两三行）
            (" {2,}", " "),
        ]
        for (pattern, repl) in rules {
            s = s.replacingOccurrences(of: pattern, with: repl, options: .regularExpression)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 目录路径缩成通知副标题放得下的样子：家目录换成 `~`，太长就只留最后三段。
    static func shortPath(_ cwd: String) -> String {
        guard !cwd.isEmpty else { return "" }
        let home = NSHomeDirectory()
        var p = cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd[...]
        if p.count > 46 {
            let parts = p.split(separator: "/").suffix(3)
            p = ("…/" + parts.joined(separator: "/"))[...]
        }
        return String(p)
    }

    /// transcript 里最后一条 assistant 的**人类可读文本**。
    /// 只读文件尾部 256KB：transcript 动辄几 MB，每次完成都全量解析纯属浪费。
    /// 逐行往回找而不是只看最后几行：Claude Code 把每个内容块写成**独立一行**，
    /// 收尾前那串 thinking/tool_use 能轻松堆满上百行（messageParts 只取 text，
    /// thinking 与工具调用都不会被当成摘要）。
    static func lastAssistantText(_ path: String, maxLen: Int = 2000) -> String {
        for line in tailLines(path).reversed() {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  (o["type"] as? String) == "assistant",
                  let m = o["message"] as? [String: Any] else { continue }
            let (human, _) = HubApp.messageParts(m["content"])
            let t = human.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            return String(t.prefix(maxLen))
        }
        return ""
    }

    /// 读文件末尾若干字节并按行切分。首行可能被截断（不是从行首开始），直接丢掉。
    private static func tailLines(_ path: String, bytes: UInt64 = 262_144) -> [String] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }
        guard let end = try? fh.seekToEnd() else { return [] }
        let start = end > bytes ? end - bytes : 0
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd() else { return [] }
        var s = String(decoding: data, as: UTF8.self)
        if start > 0, let nl = s.firstIndex(of: "\n") { s = String(s[s.index(after: nl)...]) }
        return s.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}

/// 面向 Remote Hub 的**完成事件流**：环形缓冲 + 单调递增 version + 长轮询等待者。
/// 与 DeviceApprovalState 同一路子（version 游标不怕丢事件：客户端带旧 version 一问就补齐），
/// 区别是这里是**多条历史**而不是单值状态——手机可能离线一会儿再回来看。
///
/// 线程：append 在后台线程，读/等待在 Hub 的请求线程，全用一把 NSLock 串起来。
final class AgentEventStore: @unchecked Sendable {
    static let shared = AgentEventStore()

    struct Event {
        let seq: UInt64
        let id: String
        let kind: String        // 目前只有 "done"
        let source: String      // claude / …
        let sessionId: String
        let title: String
        let project: String
        let cwd: String
        let summary: String
        let webUrl: String?
        let ts: Int64           // 毫秒

        var json: [String: Any] {
            ["seq": seq, "id": id, "kind": kind, "source": source, "sessionId": sessionId,
             "title": title, "project": project, "cwd": cwd, "summary": summary,
             "webUrl": webUrl as Any, "ts": ts]
        }
    }

    private let lock = NSLock()
    private let capacity = 50
    private var version: UInt64 = 0
    private var events: [Event] = []
    private var waiters: [UInt64: ([String: Any]) -> Void] = [:]
    private var nextWaiter: UInt64 = 0

    // MARK: 写入

    func append(kind: String, source: String, sessionId: String, title: String,
                project: String, cwd: String, summary: String, webUrl: String?) {
        lock.lock()
        version &+= 1
        let e = Event(seq: version, id: UUID().uuidString, kind: kind, source: source,
                      sessionId: sessionId, title: title, project: project, cwd: cwd,
                      summary: summary, webUrl: webUrl, ts: Int64(Date().timeIntervalSince1970 * 1000))
        events.append(e)
        if events.count > capacity { events.removeFirst(events.count - capacity) }
        let snap = Self.json(version: version, events: [e])
        let woken = waiters; waiters = [:]
        lock.unlock()
        woken.values.forEach { $0(snap) }
    }

    // MARK: 读取

    var currentVersion: UInt64 { lock.lock(); defer { lock.unlock() }; return version }

    /// `since` 之后的事件；`since=0`（首次连接）回最近 limit 条历史，手机一打开就有东西看。
    func snapshot(since: UInt64, limit: Int) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return Self.json(version: version, events: fresh(since: since, limit: limit))
    }

    /// 调用方持锁。
    private func fresh(since: UInt64, limit: Int) -> [Event] {
        let n = max(1, min(limit, capacity))
        return Array(events.filter { $0.seq > since }.suffix(n))
    }

    /// 长轮询：有新事件立刻回；否则登记等待者，返回 waiter id（超时后调用方要 `cancel`）。
    func waitOrRegister(since: UInt64, limit: Int, _ reply: @escaping ([String: Any]) -> Void) -> UInt64? {
        lock.lock()
        if version > since {
            let snap = Self.json(version: version, events: fresh(since: since, limit: limit))
            lock.unlock()
            reply(snap)
            return nil
        }
        nextWaiter &+= 1
        let id = nextWaiter
        waiters[id] = reply
        lock.unlock()
        return id
    }

    func cancel(_ id: UInt64) {
        lock.lock(); waiters.removeValue(forKey: id); lock.unlock()
    }

    private static func json(version: UInt64, events: [Event]) -> [String: Any] {
        ["version": version, "events": events.map(\.json)]
    }
}
