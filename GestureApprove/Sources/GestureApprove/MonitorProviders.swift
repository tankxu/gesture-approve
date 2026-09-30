import Foundation

/// 采集器在用户配置文件里的实际状态。
/// `stale` = 配置里确实是我们的命令，但指向另一个 app 路径（从 build/ 搬进 /Applications、
/// 自动更新换了目录）——文件里"看着装了"，每次执行其实都失败。它必须和"没装"一样触发重装，
/// 否则自愈逻辑会被自己骗过去。半装（hook 在、statusLine 没了）同理归到这里。
enum MonitorInstallState: String { case absent, installed, stale }

/// 每家 AI 工具一个采集器。加一家（grok、gemini、kimi…）= 写一个 enum 实现本协议，
/// 再往 `MonitorHooks.collectors` 里加一行，装卸载/状态/自愈全部自动覆盖。
protocol MonitorCollector {
    static var id: String { get }
    static var displayName: String { get }
    static var configPath: String { get }
    /// 装完之后要对用户说的那句话的**文案键**（Codex 需要在 /hooks 里确认信任）。没有就 nil。
    static var postInstallNoteKey: String? { get }
    /// 这台机器上到底有没有这家工具。没有就一个字节都别写 ——
    /// 给没装 Codex 的用户凭空造一个 ~/.codex/config.toml，会让他以为自己装了 Codex。
    static func isPresent() -> Bool
    static func state(_ executable: String) -> MonitorInstallState
    static func install(_ executable: String) throws
    static func uninstall() throws
}

extension MonitorCollector { static var postInstallNoteKey: String? { nil } }

/// 各家共用的落盘规矩：认领自己的命令、只在内容真的要变时写、写之前留一份备份。
enum MonitorHookFile {
    static let marker = "--monitor-hook", statusMarker = "--monitor-statusline"
    /// 错误**带着键走**，渲染留到边界：同一个错误在 app 设置里要按软件语言（6 种），
    /// 在 Hub API 里要按 Hub 语言（zh/en）。提前渲染成字符串，就没法再二选一了。
    static func err(_ key: String, _ code: Int = 1, _ args: [String] = []) -> NSError {
        NSError(domain: "MonitorInstall", code: code,
                userInfo: [NSLocalizedDescriptionKey: text(key, args), "gaKey": key, "gaArgs": args])
    }
    static func text(_ key: String, _ args: [String] = [], lang: String = I18n.lang) -> String {
        let s = I18n.string(key, lang: lang)
        return args.isEmpty ? s : String(format: s, arguments: args)
    }
    /// 把 install/uninstall 抛出的错误按指定语言渲染。不是我们抛的（文件系统等）就用系统描述。
    static func message(_ error: Error, lang: String) -> String {
        let e = error as NSError
        guard let key = e.userInfo["gaKey"] as? String else { return e.localizedDescription }
        return text(key, e.userInfo["gaArgs"] as? [String] ?? [], lang: lang)
    }
    static func quote(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    /// 只认本 app 写的命令。认的是我们自己发明的那两个 flag，并且要求它以独立参数的形式出现 ——
    /// 裸 contains 会把用户自己命令里撞上这几个字的（`my-guard --not-monitor-hooked`）一起删掉。
    /// 不拿「路径里有没有 GestureApprove」当身份：app 一改名，我们写的 hook 就自己认不出来了，
    /// 卸载留垃圾、重装叠条目。
    static func isOurs(_ command: String) -> Bool {
        [marker, statusMarker].contains { command.contains(" " + $0 + " ") || command.hasSuffix(" " + $0) }
    }
    /// 命令是我们的，但前缀不是当前这个可执行文件 —— 路径漂移，按"没装"处理。
    static func points(_ executable: String, _ command: String) -> Bool { command.hasPrefix(quote(executable) + " ") }

    /// 固定名 + 覆盖。原来每次调用按 UUID 留一份，一旦接上"打开设置就自愈"的重装，
    /// 用户的 ~/.claude 里会堆一地备份。覆盖是安全的：只有内容真要变时才走到这里，
    /// 所以备份里永远是"上一次生效的配置"，而不会被一次空转刷成我们自己的产物。
    static func backup(_ path: String) {
        guard let data = FileManager.default.contents(atPath: path) else { return }
        try? data.write(to: URL(fileURLWithPath: path + ".ga-monitor-backup"), options: .atomic)
    }
    /// 比的是解析后的 JSON，不是文件字节 —— 否则用户的缩进风格会让每次安装都判定"变了"。
    @discardableResult static func writeJSONIfChanged(_ value: MObject, _ path: String) throws -> Bool {
        if FileManager.default.fileExists(atPath: path), MonitorIO.json(MonitorIO.read(path)) == MonitorIO.json(value) { return false }
        backup(path)
        try MonitorIO.atomic(value, path)
        return true
    }
    @discardableResult static func writeTextIfChanged(_ text: String, _ path: String) throws -> Bool {
        let fm = FileManager.default
        if let old = fm.contents(atPath: path), String(data: old, encoding: .utf8) == text { return false }
        backup(path)
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return true
    }
}

// MARK: - Claude Code（JSON settings + statusLine 包装）

enum ClaudeCollector: MonitorCollector {
    static let id = "claude", displayName = "Claude Code"
    static var configPath: String { MonitorIO.claude + "/settings.json" }
    static var originalPath: String { MonitorIO.root + "/statusline-original.json" }
    static let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "Stop", "Notification"]

    static func isPresent() -> Bool {
        FileManager.default.fileExists(atPath: MonitorIO.claude) || MonitorIO.executable("claude") != nil
    }

    private static func load() throws -> MObject {
        let fm = FileManager.default
        guard fm.fileExists(atPath: configPath) else { return [:] }
        guard let d = fm.contents(atPath: configPath), let o = (try? JSONSerialization.jsonObject(with: d)) as? MObject else {
            throw MonitorHookFile.err("monitor.err.claudeUnreadable")
        }
        return o
    }
    private static func strip(_ entry: MObject) -> MObject? {
        var entry = entry
        let kept = (entry["hooks"] as? [MObject] ?? []).filter { !MonitorHookFile.isOurs($0["command"] as? String ?? "") }
        guard !kept.isEmpty else { return nil }
        entry["hooks"] = kept
        return entry
    }

    static func state(_ executable: String) -> MonitorInstallState {
        let c = (try? load()) ?? [:]
        let hooks = c["hooks"] as? MObject ?? [:]
        var hookSeen = false, drifted = false
        for event in events {
            for entry in hooks[event] as? [MObject] ?? [] {
                for h in entry["hooks"] as? [MObject] ?? [] {
                    let cmd = h["command"] as? String ?? ""
                    guard MonitorHookFile.isOurs(cmd) else { continue }
                    hookSeen = true
                    if !MonitorHookFile.points(executable, cmd) { drifted = true }
                }
            }
        }
        // statusLine 是 Claude 额度的唯一来源（transcript 里没有 rate_limits）。
        // 9 个 hook 都在、statusLine 被别人换掉了 —— 会话看得见、额度永远是空的，所以算没装全。
        let status = (c["statusLine"] as? MObject)?["command"] as? String ?? ""
        let statusOurs = MonitorHookFile.isOurs(status)
        if statusOurs, !MonitorHookFile.points(executable, status) { drifted = true }
        guard hookSeen, statusOurs else { return hookSeen || statusOurs ? .stale : .absent }
        return drifted ? .stale : .installed
    }

    static func install(_ executable: String) throws {
        var c = try load()
        let command = MonitorHookFile.quote(executable)
        var hooks = c["hooks"] as? MObject ?? [:]
        for event in events {
            // 先摘掉我们自己的（含指向旧路径的那些），再按当前路径补一条 —— 重装即修复漂移。
            var entries = (hooks[event] as? [MObject] ?? []).compactMap(strip)
            entries.append(["hooks": [["type": "command", "command": command + " " + MonitorHookFile.marker + " " + id, "timeout": 5]]])
            hooks[event] = entries
        }
        c["hooks"] = hooks
        let current = c["statusLine"] as? MObject
        let isOurs = MonitorHookFile.isOurs(current?["command"] as? String ?? "")
        // 已知局限：用户原来的 statusLine 命令只存在这一份外部副本里，这个目录被清掉之后
        // 卸载就还原不回去了。修法（把原命令也写进 wrapper 自身）留到下一步，这里保持既有行为。
        if !isOurs { try MonitorIO.atomic(["original": current as Any? ?? NSNull()], originalPath) }
        var wrapper = current ?? [:]
        wrapper["type"] = "command"
        wrapper["command"] = command + " " + MonitorHookFile.statusMarker
        c["statusLine"] = wrapper
        try MonitorHookFile.writeJSONIfChanged(c, configPath)
    }

    static func uninstall() throws {
        guard FileManager.default.fileExists(atPath: configPath) else { return }
        var c = try load()
        var hooks = c["hooks"] as? MObject ?? [:]
        for event in events {
            let entries = (hooks[event] as? [MObject] ?? []).compactMap(strip)
            if entries.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = entries }
        }
        if hooks.isEmpty { c.removeValue(forKey: "hooks") } else { c["hooks"] = hooks }
        let status = (c["statusLine"] as? MObject)?["command"] as? String ?? ""
        if MonitorHookFile.isOurs(status) {
            c["statusLine"] = MonitorIO.read(originalPath)["original"]
            if c["statusLine"] == nil || c["statusLine"] is NSNull { c.removeValue(forKey: "statusLine") }
        }
        try MonitorHookFile.writeJSONIfChanged(c, configPath)
    }
}

// MARK: - Codex（TOML 配置块）

enum CodexCollector: MonitorCollector {
    static let id = "codex", displayName = "Codex"
    static var configPath: String { MonitorIO.codex + "/config.toml" }
    static var postInstallNoteKey: String? { "monitor.note.codexTrust" }
    static let begin = "# >>> gesture-approve monitor v2 >>>", end = "# <<< gesture-approve monitor v2 <<<"
    static let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "Interrupt", "SubagentStart", "SubagentStop"]

    static func isPresent() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: configPath) || fm.fileExists(atPath: MonitorIO.codex) || MonitorIO.executable("codex") != nil
    }

    private static func text() throws -> String? {
        guard let d = FileManager.default.contents(atPath: configPath) else { return nil }
        guard let s = String(data: d, encoding: .utf8) else { throw MonitorHookFile.err("monitor.err.codexNotUTF8", 3) }
        return s
    }
    private static func stripped(_ toml: String) throws -> String {
        var toml = toml
        while let a = toml.range(of: begin) {
            guard let b = toml.range(of: end, range: a.upperBound..<toml.endIndex) else {
                throw MonitorHookFile.err("monitor.err.codexBlockBroken", 2)
            }
            toml.removeSubrange(a.lowerBound..<b.upperBound)
        }
        return toml
    }
    private static func block(_ toml: String) -> String? {
        guard let a = toml.range(of: begin), let b = toml.range(of: end, range: a.upperBound..<toml.endIndex) else { return nil }
        return String(toml[a.lowerBound..<b.upperBound])
    }

    static func state(_ executable: String) -> MonitorInstallState {
        guard let toml = try? text() ?? "", let ours = block(toml) else { return .absent }
        return ours.contains(MonitorHookFile.quote(executable) + " " + MonitorHookFile.marker + " " + id) ? .installed : .stale
    }

    static func install(_ executable: String) throws {
        guard isPresent() else {
            throw MonitorHookFile.err("monitor.err.toolMissing", 5, [displayName, MonitorIO.codex])
        }
        let old = try text()
        var toml = try stripped(old ?? "")
        toml += "\n\(begin)\n"
        for event in events {
            // 同步、短小的本地落盘，保住事件顺序。不参与审批决策。
            let cmd = MonitorHookFile.quote(executable) + " " + MonitorHookFile.marker + " " + id
            toml += "[[hooks.\(event)]]\n[[hooks.\(event).hooks]]\ntype = \"command\"\ntimeout = 5\ncommand = \(MonitorIO.json([cmd]).dropFirst().dropLast())\n"
        }
        toml += end + "\n"
        let baseline = probe()
        guard try MonitorHookFile.writeTextIfChanged(toml, configPath) else { return }
        try verify(baseline, rollbackTo: old)
    }

    static func uninstall() throws {
        guard let old = try text() else { return }
        let toml = try stripped(old)
        let baseline = probe()
        guard try MonitorHookFile.writeTextIfChanged(toml, configPath) else { return }
        try verify(baseline, rollbackTo: old)
    }

    /// 让 Codex 自己加载一遍配置。PATH 上没有 codex 就没法问，返回 nil。
    private static func probe() -> Int32? {
        guard let codex = MonitorIO.executable("codex") else { return nil }
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = MonitorIO.codex
        return MonitorIO.run(codex, ["features", "list"], timeout: 5, env: env).0
    }
    /// 只有「改之前能跑、改之后跑不动」才算我们弄坏的，这时**只回滚 Codex 自己** ——
    /// 以前 Claude 和 Codex 共用一次事务，Codex 版本不认 hooks 会把 Claude 的采集一起撤掉。
    /// 反过来，PATH 上摆着一个本来就跑不起来的 codex（壳脚本、装了一半、换了 PATH）时，
    /// 把它原有的毛病算到这次安装头上，会让 Codex 永远装不上且看不出为什么。
    private static func verify(_ baseline: Int32?, rollbackTo old: String?) throws {
        guard baseline == 0, let after = probe(), after != 0 else { return }
        if let old { try? old.write(toFile: configPath, atomically: true, encoding: .utf8) }
        else { try? FileManager.default.removeItem(atPath: configPath) }
        throw MonitorHookFile.err("monitor.err.codexRejected", 4)
    }
}
