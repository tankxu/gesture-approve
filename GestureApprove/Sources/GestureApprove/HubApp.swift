import Foundation
import Security

/// Remote Hub 的业务逻辑(原 hub/hub.py 的 Swift 移植)。
/// 读本地 ~/.claude 会话/记录、ASR(SiliconFlow)、回复注入(osascript 驱动 Chrome)、配置。
/// HTTP 收发在 HubServer;这里提供路由 `route(_:_)` 与各端点实现。集成进 GA 后:
///   · 设备口审批(47602)仍经 loopback 代理(同进程,零风险);
///   · 零外部依赖——不再需要 python3。
final class HubApp {
    static let claudeHome = (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
    static let configDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude-session-hub")
    static let configPath = (configDir as NSString).appendingPathComponent("config.json")
    static let gaDevPort = 47602
    static let sfURL = "https://api.siliconflow.cn/v1/audio/transcriptions"
    static let sfModel = "FunAudioLLM/SenseVoiceSmall"

    let port: Int
    /// 切换局域网开关时回调(HubController 去 rebind 服务)。
    var onSetLan: ((Bool) -> Void)?
    /// 停止 hub(配置页「停止」)。
    var onStop: (() -> Void)?

    init(port: Int) { self.port = port }

    // MARK: 配置(~/.claude-session-hub/config.json:token / siliconflow_key / lan)

    static func loadConfig() -> [String: Any] {
        guard let d = FileManager.default.contents(atPath: configPath),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }
    static func saveConfig(_ cfg: [String: Any]) {
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted]) {
            try? d.write(to: URL(fileURLWithPath: configPath))
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath)
        }
    }
    static func token() -> String {
        if let t = ProcessInfo.processInfo.environment["HUB_TOKEN"], !t.isEmpty { return t }
        var cfg = loadConfig()
        if let t = cfg["token"] as? String, !t.isEmpty { return t }
        var b = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &b)
        let t = b.map { String(format: "%02x", $0) }.joined()
        cfg["token"] = t; saveConfig(cfg)
        return t
    }
    static func siliconflowKey() -> String {
        if let k = ProcessInfo.processInfo.environment["SILICONFLOW_KEY"], !k.isEmpty { return k }
        return (loadConfig()["siliconflow_key"] as? String) ?? ""
    }
    static func lanEnabled() -> Bool {
        if let e = ProcessInfo.processInfo.environment["HUB_BIND"], !e.isEmpty { return e == "0.0.0.0" }
        if let v = loadConfig()["lan"] as? Bool { return v }
        return true   // 缺省开,保持现状
    }
    /// GA 设备口 token:同进程,直接取 DeviceApi.token。
    static func gaToken() -> String { DeviceApi.token }

    // MARK: 网卡 IPv4(过滤 ClashX TUN/link-local/回环)

    static func localIPs() -> [String] {
        var out: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return out }
        defer { freeifaddrs(head) }
        let bad = ["198.18.", "198.19.", "100.64.", "169.254.", "127."]
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let ifa = cur.pointee
            p = ifa.ifa_next
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            if !ip.isEmpty, !bad.contains(where: { ip.hasPrefix($0) }), !out.contains(ip) { out.append(ip) }
        }
        return out
    }

    func configData() -> [String: Any] {
        let ips = Self.localIPs()
        let lan = Self.lanEnabled()
        let key = Self.siliconflowKey()
        let tok = Self.token()
        let gaTok = Self.gaToken()
        let masked = key.count > 12 ? "\(key.prefix(6))…\(key.suffix(4))" : (key.isEmpty ? "" : "已设置")
        let baseUrls: [String]
        let phone: String
        if lan {
            baseUrls = ips.map { "http://\($0):\(port)" }
            phone = baseUrls.first.map { "\($0)/?token=\(tok)" } ?? ""
        } else {
            baseUrls = ["http://127.0.0.1:\(port)"]
            phone = ""
        }
        return [
            "port": port, "bind": lan ? "0.0.0.0" : "127.0.0.1", "lan": lan,
            "token": tok,
            "baseUrls": baseUrls, "phoneUrl": phone,
            "siliconflowKeySet": !key.isEmpty, "siliconflowKeyMasked": masked,
            "configPath": Self.configPath,
            "deviceApi": [
                "port": Self.gaDevPort, "token": gaTok,
                "tokenSet": !gaTok.isEmpty,
                "addresses": ips.map { "http://\($0):\(Self.gaDevPort)" },
            ],
        ]
    }

    // MARK: 读文件工具

    static func readText(_ path: String) -> String? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return String(decoding: d, as: UTF8.self)   // 有损解码,等价 Python errors="ignore"
    }
    static func jsonLines(_ path: String) -> [[String: Any]] {
        guard let s = readText(path) else { return [] }
        var out: [[String: Any]] = []
        for line in s.split(separator: "\n", omittingEmptySubsequences: true) {
            if let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] { out.append(o) }
        }
        return out
    }

    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    static func isoToMs(_ ts: Any?) -> Int64 {
        guard let s = ts as? String, !s.isEmpty else { return 0 }
        if let d = isoFrac.date(from: s) ?? isoPlain.date(from: s) { return Int64(d.timeIntervalSince1970 * 1000) }
        return 0
    }
    static func alive(_ pid: Int) -> Bool { pid > 0 && kill(pid_t(pid), 0) == 0 }

    // MARK: transcript 定位 / 标题

    static func transcriptPath(_ sid: String) -> String? {
        let projects = (claudeHome as NSString).appendingPathComponent("projects")
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: projects) else { return nil }
        for d in dirs {
            let sub = (projects as NSString).appendingPathComponent(d)
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: sub) else { continue }
            for f in files where f.hasPrefix(sid) && f.hasSuffix(".jsonl") {
                return (sub as NSString).appendingPathComponent(f)
            }
        }
        return nil
    }
    static func aiTitle(_ sid: String) -> String {
        guard let f = transcriptPath(sid), let s = readText(f) else { return "" }
        var t = ""
        for line in s.split(separator: "\n", omittingEmptySubsequences: true) where line.contains("\"aiTitle\"") {
            if let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let v = o["aiTitle"] as? String, !v.isEmpty { t = v }
        }
        return t
    }
    static func firstUserText(_ sid: String, maxLen: Int = 40) -> String {
        guard let f = transcriptPath(sid) else { return "" }
        for o in jsonLines(f) where (o["type"] as? String) == "user" {
            if let m = o["message"] as? [String: Any], let c = m["content"] as? String, !c.trimmingCharacters(in: .whitespaces).isEmpty {
                let t = c.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).joined(separator: " ")
                return t.count > maxLen ? String(t.prefix(maxLen)) + "…" : t
            }
        }
        return ""
    }

    // MARK: 会话状态(借鉴 taskhub:检测 AskUserQuestion,不用关键字)

    static let humanInputTools: Set<String> = ["AskUserQuestion"]
    static let terminalStops: Set<String> = ["end_turn", "stop_sequence", "max_tokens"]
    static let questionStaleMs: Int64 = 3600000

    static func scanState(_ sid: String) -> (state: String, waiting: Bool) {
        guard let f = transcriptPath(sid) else { return ("", false) }
        return scanStateFromLines(jsonLines(f))
    }

    /// 同上，但吃已经解析好的行——列表页只读 transcript 尾部若干 KB 就够判断状态，
    /// 犯不着为 75 个会话各解析一遍整份记录。
    static func scanStateFromLines(_ lines: [[String: Any]]) -> (state: String, waiting: Bool) {
        var latestUser: Int64 = 0, latestTerminal: Int64 = 0, latestHuman: Int64 = 0, latestTurn: Int64 = 0
        var latestTurnType = "", latestStop = ""
        for o in lines {
            guard let typ = o["type"] as? String, typ == "user" || typ == "assistant" else { continue }
            let ms = isoToMs(o["timestamp"])
            guard let m = o["message"] as? [String: Any] else { continue }
            if typ == "user" {
                if ms > 0 { latestUser = max(latestUser, ms); latestTurn = ms; latestTurnType = "user" }
            } else {
                let stop = (m["stop_reason"] as? String) ?? ""
                if ms > 0 { latestTurn = ms; latestTurnType = "assistant"; latestStop = stop }
                if let content = m["content"] as? [[String: Any]] {
                    let names = content.filter { ($0["type"] as? String) == "tool_use" }.compactMap { $0["name"] as? String }
                    if ms > 0 && names.contains(where: { humanInputTools.contains($0) }) { latestHuman = ms }
                }
                if ms > 0 && terminalStops.contains(stop) { latestTerminal = ms }
            }
        }
        let waiting = latestHuman > latestTerminal && latestHuman > latestUser && (nowMs() - latestHuman) <= questionStaleMs
        var activeTurn = false
        if latestTurn > 0 {
            if latestTurnType == "assistant" { activeTurn = !terminalStops.contains(latestStop) }
            else { activeTurn = latestTurn > latestTerminal }
        }
        let state: String
        if waiting { state = "wait" }
        else if activeTurn { state = latestStop == "tool_use" ? "tool" : "active" }
        else if terminalStops.contains(latestStop) { state = "done" }
        else { state = "" }
        return (state, waiting)
    }

    /// 归一到 web 用的 `session_<主体>` 形式(cse_ / 无前缀都转成 session_)。
    static func toWebSessionId(_ raw: String) -> String {
        if raw.hasPrefix("session_") { return raw }
        if let us = raw.firstIndex(of: "_") { return "session_" + raw[raw.index(after: us)...] }
        return "session_" + raw
    }
    /// 会话的 web 桥 id。**只信注册表 `bridgeSessionId`**(实测它 = 云端当前 cse,如 localdev-29
    /// 注册表 session_01VUVk84 = 云端 cse_01VUVk84)。转录里的 bridge-session 会堆积历史桥、resume 后
    /// 过时(本会话转录 cse_019fHjas ≠ 云端 cse_0159Wy),**不可用于派生**。
    /// 注册表没有值的会话(桌面会话、部分 cli)本地拿不到当前 web id —— 权威来源是云端
    /// `GET /v1/code/sessions`(见 HUB_API/待实现),不是本地文件。
    static func bridgeId(_ sid: String, registry: String?) -> String? {
        if let b = registry, !b.isEmpty { return toWebSessionId(b) }
        return nil
    }

    static func bridgeFor(_ sid: String) -> String? {
        let dir = (claudeHome as NSString).appendingPathComponent("sessions")
        var registry: String? = nil
        if let files = try? FileManager.default.contentsOfDirectory(atPath: dir) {
            for f in files where f.hasSuffix(".json") {
                let p = (dir as NSString).appendingPathComponent(f)
                guard let d = FileManager.default.contents(atPath: p),
                      let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                if "\(o["sessionId"] ?? "")" == sid { registry = o["bridgeSessionId"] as? String; break }
            }
        }
        return bridgeId(sid, registry: registry)
    }

    /// 一个会话从 transcript 里读出来的元数据（读文件是贵活，按 mtime 缓存）。
    struct SessionMeta {
        var cwd = ""
        var title = ""
        var titleSource = ""
        var state = ""
        var waiting = false
        var updatedAt: Int64 = 0
    }

    private static let metaLock = NSLock()
    nonisolated(unsafe) private static var metaCache: [String: (mtime: Date, meta: SessionMeta)] = [:]

    /// 读文件的头部或尾部若干字节并按行切分（尾部会丢掉可能被截断的首行）。
    static func chunkLines(_ path: String, fromStart: Bool, bytes: Int) -> [[String: Any]] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }
        var text: String
        if fromStart {
            text = String(decoding: (try? fh.read(upToCount: bytes)) ?? Data(), as: UTF8.self)
        } else {
            let end = (try? fh.seekToEnd()) ?? 0
            let from = end > UInt64(bytes) ? end - UInt64(bytes) : 0
            try? fh.seek(toOffset: from)
            text = String(decoding: (try? fh.readToEnd()) ?? Data(), as: UTF8.self)
            if from > 0, let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
        }
        var out: [[String: Any]] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] { out.append(o) }
        }
        return out
    }

    /// 一个会话的元数据：**只碰头尾**（头 64KB 拿 cwd，尾 256KB 拿状态与标题），按 mtime 缓存。
    /// 全量解析在这里是灾难——本机 75 份 transcript、最大的 1 MB+，每刷一次列表全读一遍
    /// 会让 /sessions 卡上好几秒。
    static func sessionMeta(path: String, sid: String) -> SessionMeta {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
        metaLock.lock()
        if let hit = metaCache[path], hit.mtime == mtime {
            metaLock.unlock()
            return hit.meta
        }
        metaLock.unlock()

        var meta = SessionMeta()
        meta.updatedAt = Int64(mtime.timeIntervalSince1970 * 1000)
        let head = chunkLines(path, fromStart: true, bytes: 65_536)
        let tail = chunkLines(path, fromStart: false, bytes: 262_144)
        // cwd 用 transcript 自己记的那个字段。**别拿目录名反解**：Claude 把 cwd 编成目录名是
        // `/`→`-`，路径本身带 `-` 就还原不回去（本机 21 个项目目录里 18 个会翻车）。
        for o in head {
            if let c = o["cwd"] as? String, !c.isEmpty { meta.cwd = c; break }
        }
        // aiTitle 是客户端生成后写进 transcript 的，取最后一个；尾部找不到再翻头部。
        var ai = ""
        for o in tail.reversed() {
            if let v = o["aiTitle"] as? String, !v.isEmpty { ai = v; break }
        }
        if ai.isEmpty {
            for o in head.reversed() {
                if let v = o["aiTitle"] as? String, !v.isEmpty { ai = v; break }
            }
        }
        let st = scanStateFromLines(tail)
        meta.state = st.state
        meta.waiting = st.waiting
        if !ai.isEmpty {
            meta.title = ai
            meta.titleSource = "aiTitle"
        } else {
            // 和通知那边同一套取标题的规则（跳过 isMeta / 信封 / Caveat，斜杠命令拼成人话）。
            let first = AgentNotify.firstUserTitle(path)
            meta.title = first
            meta.titleSource = first.isEmpty ? "" : "firstMsg"
        }
        metaLock.lock()
        if metaCache.count > 300 { metaCache.removeAll() }   // 粗暴但够用：这就是个加速表
        metaCache[path] = (mtime, meta)
        metaLock.unlock()
        return meta
    }

    /// 运行时注册表（`~/.claude/sessions/*.json`）按 sessionId 索引。
    /// **它不再是会话来源**，只用来补三件事：活没活着、有没有网页桥、从哪儿起的。
    static func sessionRegistry() -> [String: [String: Any]] {
        var reg: [String: [String: Any]] = [:]
        let dir = (claudeHome as NSString).appendingPathComponent("sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return reg }
        for f in files where f.hasSuffix(".json") {
            guard let d = FileManager.default.contents(atPath: (dir as NSString).appendingPathComponent(f)),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let sid = "\(o["sessionId"] ?? "")"
            if !sid.isEmpty { reg[sid] = o }
        }
        return reg
    }

    /// 会话列表。**来源是 transcript 目录，不是运行时注册表**——注册表只登记还活着的进程，
    /// 本机实测 6 条，而 `~/.claude/projects` 下躺着 75 个会话；关掉终端的会话以前就此消失，
    /// 手机上再也找不回来。现在全都列，注册表退居为"这条还活着吗"的补充。
    ///
    /// 按最后写入时间倒序，默认只给最近 `limit` 个（列表页要的是最近的，不是全部历史）。
    static func listSessions(limit: Int = 60, aliveOnly: Bool = false) -> [[String: Any]] {
        let reg = sessionRegistry()
        let projects = (claudeHome as NSString).appendingPathComponent("projects")
        let fm = FileManager.default
        var found: [(path: String, sid: String, mtime: Date, pid: Int)] = []
        for dir in (try? fm.contentsOfDirectory(atPath: projects)) ?? [] {
            let sub = (projects as NSString).appendingPathComponent(dir)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: sub, isDirectory: &isDir), isDir.boolValue else { continue }
            for f in (try? fm.contentsOfDirectory(atPath: sub)) ?? [] where f.hasSuffix(".jsonl") {
                let path = (sub as NSString).appendingPathComponent(f)
                let sid = String(f.dropLast(6))
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mtime = attrs[.modificationDate] as? Date else { continue }
                let o = reg[sid] ?? [:]
                let pid = (o["pid"] as? Int) ?? Int("\(o["pid"] ?? "")") ?? 0
                if aliveOnly && !alive(pid) { continue }
                found.append((path, sid, mtime, pid))
            }
        }
        // 先按时间排序取前 N，再去读文件：元数据是贵活，不该为看不到的行付钱。
        found.sort { $0.mtime > $1.mtime }
        var rows: [[String: Any]] = []
        for item in found.prefix(max(1, limit)) {
            let o = reg[item.sid] ?? [:]
            let meta = sessionMeta(path: item.path, sid: item.sid)
            let bridge = bridgeId(item.sid, registry: o["bridgeSessionId"] as? String)
            let isAlive = alive(item.pid)
            let name = (o["name"] as? String) ?? ""
            let title = meta.title.isEmpty ? name : meta.title
            rows.append([
                "sessionId": item.sid,
                "bridgeSessionId": bridge as Any,
                "title": title,
                "titleSource": meta.titleSource.isEmpty ? (name.isEmpty ? "" : "name") : meta.titleSource,
                "name": name,
                "entrypoint": (o["entrypoint"] as? String) ?? "",
                "status": (o["status"] as? String) ?? "",
                "state": meta.state,
                "waitingForUser": meta.waiting,
                "cwd": meta.cwd.isEmpty ? ((o["cwd"] as? String) ?? "") : meta.cwd,
                "pid": item.pid,
                "alive": isAlive,
                "updatedAt": meta.updatedAt,
                "webUrl": bridge.map { "https://claude.ai/code/\($0)" } as Any,
                // 手机端据此决定能不能回复：有桥走网页注入，没桥但已退出走 claude --resume -p，
                // 没桥又还开着 → 只能看（见 resumeReply 的 409）。
                "canReply": bridge != nil || !isAlive,
            ])
        }
        return rows
    }

    static func messageParts(_ content: Any?) -> (human: String, tools: [String]) {
        if let s = content as? String { return (s, []) }
        guard let arr = content as? [[String: Any]] else { return ("", []) }
        var human: [String] = [], tools: [String] = []
        for x in arr {
            switch x["type"] as? String {
            case "text": if let t = x["text"] as? String { human.append(t) }
            case "tool_use": tools.append("[工具: \(x["name"] as? String ?? "")]")
            case "tool_result": tools.append("[工具结果]")
            default: break
            }
        }
        return (human.filter { !$0.isEmpty }.joined(separator: "\n"), tools)
    }

    static func sessionMessages(_ sid: String, limit: Int, offset: Int, maxLen: Int, includeTools: Bool) -> [String: Any] {
        guard let f = transcriptPath(sid) else { return ["error": "transcript not found", "sessionId": sid] }
        var msgs: [[String: Any]] = []
        for o in jsonLines(f) {
            guard let typ = o["type"] as? String, typ == "user" || typ == "assistant",
                  let m = o["message"] as? [String: Any] else { continue }
            let (human, tools) = messageParts(m["content"])
            let text: String
            if !human.trimmingCharacters(in: .whitespaces).isEmpty { text = String(human.prefix(maxLen)) }
            else if includeTools && !tools.isEmpty { text = tools.joined(separator: " ") }
            else { continue }
            msgs.append(["role": (m["role"] as? String) ?? "", "text": text, "ts": o["timestamp"] as Any])
        }
        let total = msgs.count
        let end = total - offset
        let start = max(0, end - limit)
        let page = end > 0 ? Array(msgs[start..<end]) : []
        return ["sessionId": sid, "total": total, "offset": offset, "limit": limit,
                "title": aiTitle(sid), "messages": page]
    }

    // MARK: ASR(SiliconFlow SenseVoiceSmall)——同步(在后台线程调)

    static func transcribe(_ audio: Data, contentType: String, filename: String) -> (Int, [String: Any]) {
        let key = siliconflowKey()
        if key.isEmpty { return (400, ["error": "siliconflow_key 未配置(在配置页填 SiliconFlow key,或设 SILICONFLOW_KEY)"]) }
        let boundary = "----hubasr" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(sfModel)\r\n".utf8))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var req = URLRequest(url: URL(string: sfURL)!, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let sem = DispatchSemaphore(value: 0)
        var result: (Int, [String: Any]) = (599, ["error": "asr failed"])
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err { result = (599, ["error": "asr failed: \(err.localizedDescription)"]); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 599
            guard let data else { result = (code, ["error": "empty response"]); return }
            if code == 200, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                result = (200, ["text": (o["text"] as? String) ?? "", "model": sfModel])
            } else {
                result = (code, ["error": "siliconflow \(code)", "detail": String(decoding: data.prefix(300), as: UTF8.self)])
            }
        }.resume()
        sem.wait()
        return result
    }

    // MARK: 回复注入(osascript 驱动 Chrome,走订阅)——同步

    static func browserReply(_ bridge: String, text: String, send: Bool) -> (Int, [String: Any]) {
        let b64 = Data(text.utf8).base64EncodedString()
        let url = "https://claude.ai/code/\(bridge)"
        let fill = "(function(){var b='\(b64)';var t=decodeURIComponent(escape(atob(b)));"
            + "var eds=[].slice.call(document.querySelectorAll('.ProseMirror'));"
            + "eds.sort(function(a,b){return b.getBoundingClientRect().width-a.getBoundingClientRect().width});"
            + "var ed=eds[0];if(!ed)return 'NO_COMPOSER';ed.focus();"
            + "var s=window.getSelection();s.selectAllChildren(ed);"
            + "document.execCommand('insertText',false,t);"
            + "return (ed.innerText||'').slice(0,80)})()"
        let probe = "(function(){var e=document.querySelector('.ProseMirror');return e?'1':'0'})()"
        let click = "(function(){var b=document.querySelector('button[aria-label=Send]');"
            + "if(!b)return 'no_btn';if(b.disabled)return 'disabled';b.click();return 'clicked'})()"
        let tail = send
            ? "  delay 0.7\n  set clicked to execute found javascript \"\(click)\"\n  return \"SEND|\" & clicked & \"|\" & filled"
            : "  return \"FILL|\" & filled"
        let script = """
        tell application "Google Chrome"
          set target to "\(url)"
          set found to missing value
          repeat with w in windows
            repeat with t in tabs of w
              try
                if (URL of t) contains "claude.ai/code" then set found to t
              end try
            end repeat
          end repeat
          if found is missing value then
            if (count of windows) is 0 then make new window
            set found to make new tab at end of tabs of front window with properties {URL:target}
          else
            if (URL of found) does not contain "\(bridge)" then set URL of found to target
          end if
          set ok to false
          repeat 30 times
            delay 0.4
            try
              if (execute found javascript "\(probe)") is "1" then set ok to true
            end try
            if ok then exit repeat
          end repeat
          if not ok then return "NO_COMPOSER"
          set filled to execute found javascript "\(fill)"
        \(tail)
        end tell
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = Pipe()
        do { try p.run() } catch { return (500, ["error": "osascript failed: \(error.localizedDescription)"]) }
        inPipe.fileHandleForWriting.write(Data(script.utf8))
        inPipe.fileHandleForWriting.closeFile()
        p.waitUntilExit()
        let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if p.terminationStatus != 0 { return (500, ["error": "osascript error"]) }
        if out == "NO_COMPOSER" || out.hasSuffix("NO_COMPOSER") {
            return (504, ["error": "输入框未出现(页面没加载好 / 未登录 claude.ai / bridgeSessionId 不对)"])
        }
        if out.hasPrefix("SEND|") {
            let parts = out.components(separatedBy: "|")
            let clicked = parts.count > 1 ? parts[1] : ""
            return (200, ["ok": true, "sent": clicked == "clicked", "sendResult": clicked,
                          "readback": parts.count > 2 ? parts[2] : ""])
        }
        if out.hasPrefix("FILL|") {
            return (200, ["ok": true, "sent": false, "readback": String(out.dropFirst(5))])
        }
        return (200, ["ok": true, "sent": false, "readback": out])
    }

    // MARK: 无网页桥时的回复：claude --resume <id> -p <text>

    /// 注册表里这个会话的 (pid, cwd)。pid 用来判断它是否还开着。
    static func sessionProcess(_ sid: String) -> (pid: Int, cwd: String)? {
        let dir = (claudeHome as NSString).appendingPathComponent("sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        for f in files where f.hasSuffix(".json") {
            guard let d = FileManager.default.contents(atPath: (dir as NSString).appendingPathComponent(f)),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  "\(o["sessionId"] ?? "")" == sid else { continue }
            let pid = (o["pid"] as? Int) ?? Int("\(o["pid"] ?? "")") ?? 0
            return (pid, (o["cwd"] as? String) ?? "")
        }
        return nil
    }

    /// transcript 头部记着这条会话的 cwd —— 注册表里没这条（会话早退出了）时用它。
    /// 别拿目录名反解：Claude 把 cwd 编码成目录名是 `/`→`-`，路径本身带 `-` 就还原不回去
    /// （本机 21 个项目目录里有 18 个反解会失败）。
    static func sessionCwdFromTranscript(_ sid: String) -> String? {
        guard let path = transcriptPath(sid), let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 65_536) else { return nil }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(20) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let cwd = o["cwd"] as? String, !cwd.isEmpty else { continue }
            return cwd
        }
        return nil
    }

    /// `claude` 可执行文件。**不能指望 PATH**：GA 是 launchd 起的 app，PATH 只有 /usr/bin:/bin 那几项，
    /// 而 claude 通常在 homebrew / ~/.local/bin 里。先查常见位置，都没有再问一次登录 shell。
    static func claudeExecutable() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
            (home as NSString).appendingPathComponent(".local/bin/claude"),
            (home as NSString).appendingPathComponent(".claude/local/claude"),
            (home as NSString).appendingPathComponent(".bun/bin/claude"),
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", "command -v claude"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self)
            .split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// 往一个**没有网页桥**的会话里发消息：`claude --resume <id> -p <text>`。
    /// 实测（2026-08-17）会复用同一个 sessionId、续写同一份 transcript、上下文延续正常。
    ///
    /// 边界：
    ///   · **会话还开着就不能这么发**——终端里那个进程有自己的内存状态，从外面 resume 会起
    ///     第二个进程写同一份 transcript，两边历史打架，而且本人在终端里看不到这句话。
    ///     所以活着的会话直接拒（409），让调用方走网页那条路。
    ///   · 计费与在终端里敲同一条路（订阅额度）；为免误走按量付费，**显式清掉 API key 类环境变量**。
    ///   · agent 收到消息可能真的动手干活（调工具、等审批），耗时不可控 → 只同步等 60 秒，
    ///     超时就先回 `pending: true`，进程继续跑，结果照常由 Stop hook 走 /events 推出来。
    static func resumeReply(_ sid: String, text: String, timeout: TimeInterval = 60) -> (Int, [String: Any]) {
        if let proc = sessionProcess(sid), alive(proc.pid) {
            return (409, ["error": "该会话仍在运行（pid \(proc.pid)）：并发 resume 会和终端里那个进程抢同一份 transcript。请等它退出，或改用有 bridgeSessionId 的网页通道。",
                          "sessionAlive": true])
        }
        guard let exe = claudeExecutable() else {
            return (500, ["error": "找不到 claude 可执行文件（试过 homebrew / ~/.local/bin / ~/.claude/local，以及登录 shell 的 PATH）"])
        }
        let cwd = sessionProcess(sid)?.cwd.nilIfEmpty ?? sessionCwdFromTranscript(sid)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["--resume", sid, "-p", text, "--output-format", "json"]
        if let cwd, FileManager.default.fileExists(atPath: cwd) {
            p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        var env = ProcessInfo.processInfo.environment
        // 认证走已登录的订阅（oauthAccount）。留着 API key 会让这次调用变成按量付费。
        for k in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL"] { env.removeValue(forKey: k) }
        // 让自家 hook 知道这是"手机发来的回复"，别再往桌面弹一条"agent 已完成"自娱自乐；
        // 事件仍会进 /events（手机要靠它拿结果）。
        env["GA_HUB_REPLY"] = "1"
        env["PATH"] = ((env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin").trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return (500, ["error": "启动 claude 失败: \(error.localizedDescription)"]) }

        // 读输出要和等待分开：管道写满会让子进程卡死（output-format json 也可能上百 KB）。
        let box = Box()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            box.set(["stdout": String(decoding: data, as: UTF8.self)])
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline { usleep(100_000) }
        guard !p.isRunning else {
            GALog.log("Hub 回复(resume) session=\(sid.prefix(8)) 超过 \(Int(timeout))s 仍在跑，先回 pending")
            return (200, ["ok": true, "via": "resume", "pending": true, "sessionId": sid,
                          "note": "agent 还在干活，结果稍后由 /events 推出来"])
        }
        let stdout = (box.get()?["stdout"] as? String) ?? ""
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else {
            let detail = (stderr.isEmpty ? stdout : stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            GALog.log("Hub 回复(resume) 失败 session=\(sid.prefix(8)) 退出码=\(p.terminationStatus) \(detail.prefix(200))")
            // 会话不存在是最常见的一种失败（id 抄错、transcript 被清理），值得单独给个 404，
            // 免得客户端把它和"claude 崩了"混作一谈。
            if detail.contains("No conversation found") {
                return (404, ["error": "找不到这个会话（id 不对，或它的记录已被清理）", "sessionId": sid])
            }
            return (500, ["error": "claude 退出码 \(p.terminationStatus)", "detail": String(detail.prefix(500))])
        }
        // -p --output-format json 的返回里，result 就是 agent 这一轮的回答。
        var reply = ""
        if let d = stdout.data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            reply = (o["result"] as? String) ?? ""
        }
        GALog.log("Hub 回复(resume) session=\(sid.prefix(8)) 成功，回答 \(reply.count) 字")
        return (200, ["ok": true, "via": "resume", "sent": true, "sessionId": sid, "reply": reply])
    }

    // MARK: 云端会话(claude.ai)——osascript 在已登录的 Chrome 标签页里同源 XHR,cookie 鉴权,不碰 keychain

    /// 在任一 claude.ai 标签页里同步 GET,返回 responseText(或 "NOTAB" / "ERR:…")。
    /// JS 里只用单引号、无双引号/反斜杠,可安全嵌进 AppleScript 的双引号字符串。
    static func chromeClaudeGET(_ path: String) -> String {
        let js = "(function(){try{var x=new XMLHttpRequest();x.open('GET','https://claude.ai"
            + path + "',false);x.setRequestHeader('anthropic-version','2023-06-01');x.send();"
            + "return x.responseText}catch(e){return 'ERR:'+e}})()"
        return chromeClaudeEval(js)
    }

    /// 在已登录的 claude.ai 标签页里跑一段 JS（同源 XHR 走 cookie 鉴权，零 keychain/零弹窗）。
    /// 返回 "NOTAB" = 没有 claude.ai 标签页；"ERR:..." = osascript/JS 失败（含 Chrome 的
    /// 「允许通过 Apple 事件执行 JavaScript」没开的情况）。js 里不要出现未转义的双引号外层依赖。
    static func chromeClaudeEval(_ js: String) -> String { chromeEval(js, onHost: "claude.ai") }

    /// 在某个站点的标签页里跑 JS。同源 XHR 走浏览器自己的登录态与 Cloudflare 通行证——
    /// 这也是 chatgpt.com 那条路的唯一活路：curl / URLSession 直连会被 Cloudflare 403 掉。
    /// **JS 经 stdin 传给 osascript**，所以里面带 token 也不会出现在进程列表里。
    static func chromeEval(_ js: String, onHost host: String) -> String {
        // `is running` 不会启动 Chrome；少了这一句，光是点开菜单栏菜单就会把 Chrome 拉起来。
        let script = """
        if application "Google Chrome" is not running then return "NOTAB"
        tell application "Google Chrome"
          set found to missing value
          repeat with w in windows
            repeat with t in tabs of w
              try
                if (URL of t) contains "\(host)" then set found to t
              end try
            end repeat
          end repeat
          if found is missing value then return "NOTAB"
          return execute found javascript "\(js)"
        end tell
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        let inP = Pipe(), outP = Pipe(), errP = Pipe()
        p.standardInput = inP; p.standardOutput = outP; p.standardError = errP
        do { try p.run() } catch { return "ERR:osascript \(error.localizedDescription)" }
        inP.fileHandleForWriting.write(Data(script.utf8)); inP.fileHandleForWriting.closeFile()
        // 先读干两个管道再 wait：会话列表能到几十 KB，先 wait 会在管道写满时双向卡死。
        let out = outP.fileHandleForReading.readDataToEndOfFile()
        let err = errP.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        // osascript 自身报错（Chrome 没开、Apple 事件被拒、执行 JS 开关没开…）走 stderr。
        let e = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return e.isEmpty ? "" : "ERR:\(e)"
    }

    /// 激活 Chrome；没有 claude.ai 标签页就开一个（用量页，顺带能让用户核对登录态）。
    static func openClaudeTab() {
        let script = """
        tell application "Google Chrome"
          activate
          if (count of windows) is 0 then make new window
          set found to missing value
          repeat with w in windows
            repeat with t in tabs of w
              try
                if (URL of t) contains "claude.ai" then set found to t
              end try
            end repeat
          end repeat
          if found is missing value then
            tell front window to make new tab with properties {URL:"https://claude.ai/settings/usage"}
          end if
        end tell
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        let inP = Pipe()
        p.standardInput = inP; p.standardOutput = Pipe(); p.standardError = Pipe()
        guard (try? p.run()) != nil else { return }
        inP.fileHandleForWriting.write(Data(script.utf8)); inP.fileHandleForWriting.closeFile()
        p.waitUntilExit()
    }

    /// 拉云端会话列表(= web 的 Recents,含桌面会话),归一成和本地列表相近的行。
    static func cloudSessions() -> (ok: Bool, rows: [[String: Any]], error: String?) {
        let raw = chromeClaudeGET("/v1/code/sessions?statuses=active&statuses=paused&limit=50")
        if raw == "NOTAB" { return (false, [], "Chrome 里没有已登录的 claude.ai 标签页") }
        if raw.hasPrefix("ERR:") { return (false, [], String(raw.dropFirst(4))) }
        guard let d = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return (false, [], "解析失败")
        }
        if let err = obj["error"] as? [String: Any] {
            return (false, [], (err["message"] as? String) ?? "cloud error")
        }
        // 本地会话:注册表 bridge(session_<主体>)→ 本地 sessionId,给云端行匹配聊天记录来源。
        var localByWeb: [String: String] = [:]
        let sdir = (claudeHome as NSString).appendingPathComponent("sessions")
        if let files = try? FileManager.default.contentsOfDirectory(atPath: sdir) {
            for f in files where f.hasSuffix(".json") {
                guard let dd = FileManager.default.contents(atPath: (sdir as NSString).appendingPathComponent(f)),
                      let o = try? JSONSerialization.jsonObject(with: dd) as? [String: Any],
                      let sid = o["sessionId"] as? String else { continue }
                if let b = o["bridgeSessionId"] as? String, !b.isEmpty { localByWeb[toWebSessionId(b)] = sid }
            }
        }
        let data = obj["data"] as? [[String: Any]] ?? []
        var rows: [[String: Any]] = []
        for s in data {
            let cse = (s["id"] as? String) ?? ""
            let webId = toWebSessionId(cse)          // cse_<主体> → session_<主体>
            let cfg = s["config"] as? [String: Any] ?? [:]
            let ext = s["external_metadata"] as? [String: Any] ?? [:]
            let pts = ext["post_turn_summary"] as? [String: Any] ?? [:]
            let bucket = (s["status_bucket"] as? String) ?? ""
            rows.append([
                "sessionId": webId,
                "bridgeSessionId": webId,
                "webUrl": "https://claude.ai/code/\(webId)",
                "title": (s["title"] as? String) ?? "",
                "entrypoint": "cloud",
                "state": ((s["worker_status"] as? String) == "busy") ? "active" : "",
                "statusBucket": bucket,
                "connection": (s["connection_status"] as? String) ?? "",
                "waitingForUser": (bucket == "review_ready"),
                "unread": (s["unread"] as? Bool) ?? false,
                "model": (cfg["model"] as? String) ?? "",
                "summary": (pts["status_detail"] as? String) ?? "",
                "cwd": "",
                "updatedAt": Self.isoToMs(s["last_event_at"]),
                "localSessionId": localByWeb[webId] as Any,   // 有本地转录 → 点开能看聊天记录
            ])
        }
        return (true, rows, nil)
    }

    // MARK: 代理 GA 设备口(同进程 loopback:47602)——审批长轮询/裁决

    static func gaProxy(_ path: String, method: String = "GET", body: Data? = nil, timeout: TimeInterval = 35) -> (Int, Data) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(gaDevPort)\(path)")!, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let tok = gaToken()
        if !tok.isEmpty { req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization") }
        req.httpBody = body
        let sem = DispatchSemaphore(value: 0)
        var result: (Int, Data) = (599, Data("{\"error\":\"GA unreachable\"}".utf8))
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 599
            result = (code, data ?? Data())
        }.resume()
        sem.wait()
        return result
    }

    // MARK: 静态页面

    /// PWA manifest。`start_url` 必须带上当前 token：主屏图标点开走的是局域网地址，
    /// 没有 token 会被 403 挡在门外，用户看到的就是「装上了但打不开」。
    func manifest() -> HubServer.Response {
        let obj: [String: Any] = [
            "name": "Gesture Approve Hub",
            "short_name": "GA Hub",
            "description": "远程查看 Claude Code / Codex 会话、批准请求、看额度",
            "start_url": "/?token=" + Self.token(),
            "scope": "/",
            "display": "standalone",
            "orientation": "portrait-primary",
            "background_color": "#0f1116",
            "theme_color": "#0f1116",
            "icons": [
                ["src": "/icons/icon-192.png", "sizes": "192x192", "type": "image/png", "purpose": "any"],
                ["src": "/icons/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any"],
                ["src": "/icons/maskable-192.png", "sizes": "192x192", "type": "image/png", "purpose": "maskable"],
                ["src": "/icons/maskable-512.png", "sizes": "512x512", "type": "image/png", "purpose": "maskable"],
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        return HubServer.Response(status: "200 OK", contentType: "application/manifest+json; charset=utf-8", body: data)
    }

    func servePage(_ name: String, injectToken: Bool) -> HubServer.Response {
        let path = AppPaths.resource("hub/\(name)")
        guard var html = Self.readText(path) else {
            return .error("\(name) missing", "500 Internal Server Error")
        }
        html = html.replacingOccurrences(of: "__HUB_LANG__", with: I18n.lang)   // 跟随 GA 设置里的语言
        if injectToken { html = html.replacingOccurrences(of: "__HUB_TOKEN__", with: Self.token()) }
        return .html(html)
    }

    func authed(_ req: HubServer.Request) -> Bool {
        req.header("authorization") == "Bearer \(Self.token())"
    }

    // MARK: 路由(镜像 hub.py 的 do_GET/do_POST)

    func route(_ req: HubServer.Request, _ done: @escaping (HubServer.Response) -> Void) {
        // 有的端点要发网络/跑 osascript,统一丢后台线程,避免卡住 server queue。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            done(self.handle(req))
        }
    }

    private func handle(_ req: HubServer.Request) -> HubServer.Response {
        let p = req.path, m = req.method
        // ---- 免认证 / loopback 专属 ----
        if p == "/health" {
            return .json(["ok": true, "service": "claude-session-hub", "siliconflowKeySet": !Self.siliconflowKey().isEmpty])
        }
        // PWA 外壳资源：manifest / service worker / 图标。**必须免 token** —— 浏览器取 manifest
        // 和注册 sw 时不会带我们注入的 Authorization 头，403 的话主屏就装不上。
        // 这些文件里没有任何用户数据，放开的是外壳，不是内容。
        if m == "GET", p == "/manifest.webmanifest" { return manifest() }
        if m == "GET", p == "/sw.js" {
            guard let js = Self.readText(AppPaths.resource("hub/sw.js")) else { return .error("sw.js missing", "500 Internal Server Error") }
            // sw 要能控制根路径下的所有页面，Service-Worker-Allowed 明确这一点。
            return HubServer.Response(status: "200 OK", contentType: "text/javascript; charset=utf-8",
                                      body: Data(js.utf8), extraHeaders: ["Service-Worker-Allowed": "/", "Cache-Control": "no-cache"])
        }
        if m == "GET", p.hasPrefix("/icons/"), !p.contains("..") {
            let name = String(p.dropFirst("/icons/".count))
            guard name.hasSuffix(".png"), let data = FileManager.default.contents(atPath: AppPaths.resource("hub/icons/" + name)) else {
                return .error("icon not found", "404 Not Found")
            }
            return HubServer.Response(status: "200 OK", contentType: "image/png", body: data,
                                      extraHeaders: ["Cache-Control": "public, max-age=86400"])
        }
        if m == "GET", p == "/" || p == "/app" || p == "/monitor" || p == "/index.html" {
            if !req.isLoopback && req.query["token"] != Self.token() {
                return .error("从局域网访问请在 URL 后带 ?token=<你的token>", "403 Forbidden")
            }
            // `/` 是装得上主屏的 app；`/monitor` 是额度与会话面板。
            let page = p == "/monitor" ? "monitor.html" : "app.html"
            return servePage(page, injectToken: true)
        }
        if m == "GET", p == "/config" || p == "/config.html" {
            guard req.isLoopback else { return .error("config page is loopback-only", "403 Forbidden") }
            return servePage("config.html", injectToken: false)
        }
        if m == "GET", p == "/config/data" {
            guard req.isLoopback else { return .error("loopback-only", "403 Forbidden") }
            return .json(configData())
        }
        // ---- loopback 专属 POST(免 token,配置页在本机)----
        if m == "POST", p == "/config/set" {
            guard req.isLoopback else { return .error("loopback-only", "403 Forbidden") }
            let o = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
            var cfg = Self.loadConfig(); var changed: [String] = []
            if let v = (o["siliconflow_key"] as? String)?.trimmingCharacters(in: .whitespaces), !v.isEmpty {
                cfg["siliconflow_key"] = v; changed.append("siliconflow_key")
            }
            if !changed.isEmpty { Self.saveConfig(cfg) }
            return .json(["ok": true, "changed": changed])
        }
        if m == "POST", p == "/config/lan" {
            guard req.isLoopback else { return .error("loopback-only", "403 Forbidden") }
            let o = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
            let on = (o["on"] as? Bool) ?? true
            var cfg = Self.loadConfig(); cfg["lan"] = on; Self.saveConfig(cfg)
            onSetLan?(on)   // HubController 去 rebind
            return .json(["ok": true, "lan": on, "rebinding": true])
        }
        if m == "POST", p == "/config/stop" {
            guard req.isLoopback else { return .error("loopback-only", "403 Forbidden") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.onStop?() }
            return .json(["ok": true, "stopping": true])
        }
        // ---- 其余端点需 token ----
        // `<img src>` 发不出 Authorization 头，所以图片端点额外认 `?token=`。
        // 它只吐 transcript 里的图片字节，媒体类型有白名单，不会变成任意文件的出口。
        let imageByQuery = (p == "/v2/attachment" && req.query["token"] == Self.token())
        if !authed(req), !imageByQuery { return .error("unauthorized", "401 Unauthorized") }
        if p.hasPrefix("/v2/") { return MonitorAPI.handle(req) }

        if m == "GET", p == "/sessions" {
            let limit = Int(req.query["limit"] ?? "") ?? 60
            let aliveOnly = ["1", "true"].contains(req.query["alive"] ?? "0")
            return .json(["sessions": Self.listSessions(limit: limit, aliveOnly: aliveOnly)])
        }
        if m == "GET", p == "/pending" {
            return .json(["sessions": Self.listSessions(limit: 200).filter { ($0["waitingForUser"] as? Bool) == true }])
        }
        if m == "GET", p == "/cloud/sessions" {
            // 云端权威列表(含桌面会话,带 web 地址)。走 Chrome cookie,需要一个已登录的 claude.ai 标签页。
            let r = Self.cloudSessions()
            return .json(["sessions": r.rows, "ok": r.ok, "error": r.error as Any])
        }
        if m == "GET", p.hasPrefix("/session/"), p.hasSuffix("/messages") {
            let sid = String(p.dropFirst("/session/".count).dropLast("/messages".count))
            return .json(Self.sessionMessages(sid,
                limit: Int(req.query["limit"] ?? "") ?? 40,
                offset: Int(req.query["offset"] ?? "") ?? 0,
                maxLen: Int(req.query["max_len"] ?? "") ?? 4000,
                includeTools: ["1", "true"].contains(req.query["include_tools"] ?? "0")))
        }
        if m == "GET", p == "/events" {
            // agent 完成事件流（Stop hook → AgentNotify → AgentEventStore）。
            // 游标式长轮询：带上次的 version 来问，有新事件立刻回，否则挂到 wait 秒。
            // since=0（首次连接）回最近 limit 条历史，手机一打开就有东西看。
            let since = UInt64(req.query["since"] ?? "") ?? 0
            let limit = Int(req.query["limit"] ?? "") ?? 20
            // plain=1：把 summary 里的 markdown 记号洗掉（**粗体**、`代码`、表格竖线…），
            // 给只能显示纯文本的客户端（小屏设备、语音播报）用。默认给原文。
            let plain = ["1", "true"].contains(req.query["plain"] ?? "0")
            let wait = max(0, min(60, Double(req.query["wait"] ?? "") ?? 0))
            let store = AgentEventStore.shared
            var payload: [String: Any]
            if wait <= 0 {
                payload = store.snapshot(since: since, limit: limit)
            } else {
                // 这里已在后台线程（route 派发），阻塞等待安全；超时要摘掉等待者，否则会累积。
                let sem = DispatchSemaphore(value: 0)
                let box = Box()
                let waiterID = store.waitOrRegister(since: since, limit: limit) { snap in
                    box.set(snap); sem.signal()
                }
                if waiterID == nil { sem.signal() }
                if sem.wait(timeout: .now() + wait) == .timedOut, let waiterID {
                    store.cancel(waiterID)
                }
                payload = box.get() ?? store.snapshot(since: since, limit: limit)
            }
            if plain, let events = payload["events"] as? [[String: Any]] {
                payload["events"] = events.map { e -> [String: Any] in
                    var e = e
                    e["summary"] = AgentNotify.plainText(e["summary"] as? String ?? "")
                    return e
                }
            }
            payload["enabled"] = AgentNotify.isEnabled && AgentNotify.hubEnabled
            return .json(payload)
        }
        if m == "GET", p == "/ga/state" {
            let q = req.query.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
            let (code, data) = Self.gaProxy(q.isEmpty ? "/state" : "/state?\(q)")
            return .rawJSON(data, status: "\(code) ")
        }
        if m == "POST", p == "/asr" {
            let ct = req.header("content-type") ?? "audio/wav"
            let (contentType, fn): (String, String)
            if ct.contains("wav") { (contentType, fn) = ("audio/wav", "audio.wav") }
            else if ct.contains("mp4") || ct.contains("m4a") || ct.contains("aac") { (contentType, fn) = ("audio/m4a", "audio.m4a") }
            else if ct.contains("mpeg") || ct.contains("mp3") { (contentType, fn) = ("audio/mpeg", "audio.mp3") }
            else { (contentType, fn) = ("audio/wav", "audio.wav") }
            let (code, obj) = Self.transcribe(req.body, contentType: contentType, filename: fn)
            return .json(obj, status: httpStatus(code))
        }
        if m == "POST", p == "/reply" {
            let o = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
            let sid = (o["sessionId"] as? String) ?? ""
            let bridge = (o["bridgeSessionId"] as? String) ?? (sid.isEmpty ? nil : Self.bridgeFor(sid))
            let text = (o["text"] as? String) ?? ""
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return .error("text 为空", "400 Bad Request") }
            // 有 claude.ai 的桥就走网页注入（能落进用户正开着的那个会话，看得见）；
            // 没有桥的会话以前只能干瞪眼，现在退一步用 `claude --resume -p` 直接续那条会话。
            if let bridge, !bridge.isEmpty {
                let (code, obj) = Self.browserReply(bridge, text: text, send: (o["send"] as? Bool) ?? false)
                return .json(obj, status: httpStatus(code))
            }
            guard !sid.isEmpty else { return .error("缺 sessionId 或 bridgeSessionId", "400 Bad Request") }
            let (code, obj) = Self.resumeReply(sid, text: text)
            return .json(obj, status: httpStatus(code))
        }
        if m == "POST", p == "/ga/resolve" {
            let (code, data) = Self.gaProxy("/resolve", method: "POST", body: req.body, timeout: 10)
            return .rawJSON(data, status: "\(code) ")
        }
        return .error("not found: \(p)", "404 Not Found")
    }

    /// 长轮询与子进程输出共用的一次性结果盒：等待者回调与超时兜底可能撞车，用锁串起来。
    fileprivate final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String: Any]?
        func set(_ v: [String: Any]) { lock.lock(); if value == nil { value = v }; lock.unlock() }
        func get() -> [String: Any]? { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func httpStatus(_ code: Int) -> String {
        switch code {
        case 200: return "200 OK"
        case 400: return "400 Bad Request"
        case 404: return "404 Not Found"
        case 500: return "500 Internal Server Error"
        case 504: return "504 Gateway Timeout"
        default: return "\(code) "
        }
    }
}

extension String {
    /// 空串当作"没有"——注册表里的 cwd 字段可能是空字符串而不是缺字段。
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
