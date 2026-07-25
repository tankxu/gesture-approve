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
        var latestUser: Int64 = 0, latestTerminal: Int64 = 0, latestHuman: Int64 = 0, latestTurn: Int64 = 0
        var latestTurnType = "", latestStop = ""
        for o in jsonLines(f) {
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

    static func bridgeFor(_ sid: String) -> String? {
        let dir = (claudeHome as NSString).appendingPathComponent("sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        for f in files where f.hasSuffix(".json") {
            let p = (dir as NSString).appendingPathComponent(f)
            guard let d = FileManager.default.contents(atPath: p),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if "\(o["sessionId"] ?? "")" == sid { return o["bridgeSessionId"] as? String }
        }
        return nil
    }

    static func listSessions() -> [[String: Any]] {
        let dir = (claudeHome as NSString).appendingPathComponent("sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        var rows: [[String: Any]] = []
        for f in files where f.hasSuffix(".json") {
            let p = (dir as NSString).appendingPathComponent(f)
            guard let d = FileManager.default.contents(atPath: p),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let sid = "\(o["sessionId"] ?? "")"
            let st = scanState(sid)
            let ai = aiTitle(sid), firstMsg = firstUserText(sid)
            let bridge = o["bridgeSessionId"] as? String
            let pid = (o["pid"] as? Int) ?? Int("\(o["pid"] ?? "")") ?? 0
            rows.append([
                "sessionId": sid,
                "bridgeSessionId": bridge as Any,
                "title": ai.isEmpty ? (firstMsg.isEmpty ? ((o["name"] as? String) ?? "") : firstMsg) : ai,
                "titleSource": !ai.isEmpty ? "aiTitle" : (!firstMsg.isEmpty ? "firstMsg" : "name"),
                "name": (o["name"] as? String) ?? "",
                "entrypoint": (o["entrypoint"] as? String) ?? "",
                "status": (o["status"] as? String) ?? "",
                "state": st.state,
                "waitingForUser": st.waiting,
                "cwd": (o["cwd"] as? String) ?? "",
                "pid": pid,
                "alive": alive(pid),
                "updatedAt": (o["updatedAt"] as? Int) ?? 0,
                "webUrl": bridge.map { "https://claude.ai/code/\($0)" } as Any,
            ])
        }
        rows.sort { (($0["updatedAt"] as? Int) ?? 0) > (($1["updatedAt"] as? Int) ?? 0) }
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
        if m == "GET", p == "/" || p == "/demo" || p == "/index.html" {
            if !req.isLoopback && req.query["token"] != Self.token() {
                return .error("从局域网访问请在 URL 后带 ?token=<你的token>", "403 Forbidden")
            }
            return servePage("demo.html", injectToken: true)
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
        if !authed(req) { return .error("unauthorized", "401 Unauthorized") }

        if m == "GET", p == "/sessions" { return .json(["sessions": Self.listSessions()]) }
        if m == "GET", p == "/pending" {
            return .json(["sessions": Self.listSessions().filter { ($0["waitingForUser"] as? Bool) == true }])
        }
        if m == "GET", p.hasPrefix("/session/"), p.hasSuffix("/messages") {
            let sid = String(p.dropFirst("/session/".count).dropLast("/messages".count))
            return .json(Self.sessionMessages(sid,
                limit: Int(req.query["limit"] ?? "") ?? 40,
                offset: Int(req.query["offset"] ?? "") ?? 0,
                maxLen: Int(req.query["max_len"] ?? "") ?? 4000,
                includeTools: ["1", "true"].contains(req.query["include_tools"] ?? "0")))
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
            let bridge = (o["bridgeSessionId"] as? String) ?? (o["sessionId"] as? String).flatMap { Self.bridgeFor($0) }
            let text = (o["text"] as? String) ?? ""
            guard let bridge, !bridge.isEmpty else { return .error("缺 bridgeSessionId(或可解析的 sessionId)", "400 Bad Request") }
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return .error("text 为空", "400 Bad Request") }
            let (code, obj) = Self.browserReply(bridge, text: text, send: (o["send"] as? Bool) ?? false)
            return .json(obj, status: httpStatus(code))
        }
        if m == "POST", p == "/ga/resolve" {
            let (code, data) = Self.gaProxy("/resolve", method: "POST", body: req.body, timeout: 10)
            return .rawJSON(data, status: "\(code) ")
        }
        return .error("not found: \(p)", "404 Not Found")
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
