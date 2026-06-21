import Foundation

/// 自动接入/移除 Claude Code / Codex / Gemini CLI / Kimi CLI 的 hook，免用户手敲命令。
/// 四家 hook 的 stdin 字段名(tool_name/tool_input/cwd)一致，输出格式各异，由 hooks/gesture_hook.py 适配。
enum HookInstaller {
    // MARK: 路径

    static func repoRoot() -> String {
        if let r = Bundle.main.object(forInfoDictionaryKey: "RepoRoot") as? String,
           FileManager.default.fileExists(atPath: r) {
            return r
        }
        var p = Bundle.main.bundlePath
        for _ in 0..<4 { p = (p as NSString).deletingLastPathComponent }
        return p
    }

    static func hookScript() -> String {
        // 优先用打包进 .app 的脚本（release 下载即用，零仓库依赖）；源码开发回退仓库。
        AppPaths.resource("hooks/gesture_hook.py")
    }

    /// hook 命令 = app 二进制自己 `--hook <target>`（零 Python 依赖，见 HookCLI）。
    private static var execPath: String { Bundle.main.executablePath ?? "" }
    private static func jsonHookCommand(_ target: String) -> String { "'\(execPath)' --hook \(target)" }       // JSON(Claude/Gemini)
    private static func tomlHookCommand(_ target: String) -> String { "\"\(execPath)\" --hook \(target)" }      // TOML(Codex/Kimi，放进 ''' 内)
    /// 兼容旧的 gesture_hook.py 写法，便于卸载/重装识别。
    private static func isOurHook(_ cmd: String) -> Bool {
        cmd.contains("--hook") || cmd.contains("gesture_hook.py")
    }

    private static var claudeSettings: URL {
        URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json"))
    }
    private static var codexConfig: URL {
        URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent(".codex/config.toml"))
    }

    private static func backup(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let stamp = Int(ProcessInfo.processInfo.systemUptime)
        try? FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: url.path + ".bak.\(stamp)"))
    }

    private static func ensureDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
    }

    // MARK: Claude Code（JSON）

    private static func claudeCommand() -> String { jsonHookCommand("claude") }

    static func isClaudeInstalled() -> Bool {
        guard let data = try? Data(contentsOf: claudeSettings),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = obj["hooks"] as? [String: Any],
              let pre = hooks["PreToolUse"] as? [[String: Any]] else { return false }
        for entry in pre {
            for h in (entry["hooks"] as? [[String: Any]] ?? []) {
                if let c = h["command"] as? String, isOurHook(c) { return true }
            }
        }
        return false
    }

    static func installClaude() throws {
        var dict: [String: Any] = [:]
        if let data = try? Data(contentsOf: claudeSettings),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = obj
        }
        backup(claudeSettings)
        var hooks = dict["hooks"] as? [String: Any] ?? [:]
        var pre = hooks["PreToolUse"] as? [[String: Any]] ?? []
        pre.removeAll { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).contains {
                isOurHook($0["command"] as? String ?? "")
            }
        }
        pre.append([
            "matcher": "Bash|Edit|Write|MultiEdit|NotebookEdit",
            "hooks": [["type": "command", "timeout": 120, "command": claudeCommand()]],
        ])
        hooks["PreToolUse"] = pre
        dict["hooks"] = hooks
        try ensureDir(claudeSettings)
        let out = try JSONSerialization.data(withJSONObject: dict,
                                             options: [.prettyPrinted, .withoutEscapingSlashes])
        try out.write(to: claudeSettings)
    }

    static func uninstallClaude() throws {
        guard let data = try? Data(contentsOf: claudeSettings),
              var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        backup(claudeSettings)
        guard var hooks = dict["hooks"] as? [String: Any] else { return }
        var pre = hooks["PreToolUse"] as? [[String: Any]] ?? []
        pre.removeAll { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).contains {
                isOurHook($0["command"] as? String ?? "")
            }
        }
        if pre.isEmpty { hooks.removeValue(forKey: "PreToolUse") } else { hooks["PreToolUse"] = pre }
        if hooks.isEmpty { dict.removeValue(forKey: "hooks") } else { dict["hooks"] = hooks }
        let out = try JSONSerialization.data(withJSONObject: dict,
                                             options: [.prettyPrinted, .withoutEscapingSlashes])
        try out.write(to: claudeSettings)
    }

    // MARK: Gemini CLI（JSON，BeforeTool）

    private static var geminiSettings: URL {
        URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent(".gemini/settings.json"))
    }
    private static func geminiCommand() -> String { jsonHookCommand("gemini") }

    static func isGeminiInstalled() -> Bool {
        guard let data = try? Data(contentsOf: geminiSettings),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = obj["hooks"] as? [String: Any],
              let arr = hooks["BeforeTool"] as? [[String: Any]] else { return false }
        for entry in arr {
            for h in (entry["hooks"] as? [[String: Any]] ?? []) {
                if let c = h["command"] as? String, isOurHook(c) { return true }
            }
        }
        return false
    }

    static func installGemini() throws {
        var dict: [String: Any] = [:]
        if let data = try? Data(contentsOf: geminiSettings),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { dict = obj }
        backup(geminiSettings)
        var hooks = dict["hooks"] as? [String: Any] ?? [:]
        var arr = hooks["BeforeTool"] as? [[String: Any]] ?? []
        arr.removeAll { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).contains {
                isOurHook($0["command"] as? String ?? "")
            }
        }
        arr.append([
            "matcher": "run_shell_command|write_file|replace",          // 有副作用的 Gemini 工具
            "hooks": [["type": "command", "timeout": 120000, "command": geminiCommand()]],  // Gemini timeout 单位毫秒
        ])
        hooks["BeforeTool"] = arr
        dict["hooks"] = hooks
        try ensureDir(geminiSettings)
        let out = try JSONSerialization.data(withJSONObject: dict,
                                             options: [.prettyPrinted, .withoutEscapingSlashes])
        try out.write(to: geminiSettings)
    }

    static func uninstallGemini() throws {
        guard let data = try? Data(contentsOf: geminiSettings),
              var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        backup(geminiSettings)
        guard var hooks = dict["hooks"] as? [String: Any] else { return }
        var arr = hooks["BeforeTool"] as? [[String: Any]] ?? []
        arr.removeAll { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).contains {
                isOurHook($0["command"] as? String ?? "")
            }
        }
        if arr.isEmpty { hooks.removeValue(forKey: "BeforeTool") } else { hooks["BeforeTool"] = arr }
        if hooks.isEmpty { dict.removeValue(forKey: "hooks") } else { dict["hooks"] = hooks }
        let out = try JSONSerialization.data(withJSONObject: dict,
                                             options: [.prettyPrinted, .withoutEscapingSlashes])
        try out.write(to: geminiSettings)
    }

    // MARK: Codex（TOML，用标记块管理）

    private static let codexBegin = "# >>> gesture-approve (managed) >>>"
    private static let codexEnd = "# <<< gesture-approve (managed) <<<"

    private static func codexBlock() -> String {
        """
        \(codexBegin)
        [[hooks.PermissionRequest]]
        matcher = "Bash|apply_patch"

        [[hooks.PermissionRequest.hooks]]
        type = "command"
        timeout = 120
        command = '''\(tomlHookCommand("codex"))'''
        \(codexEnd)
        """
    }

    static func isCodexInstalled() -> Bool {
        guard let s = try? String(contentsOf: codexConfig, encoding: .utf8) else { return false }
        return s.contains(codexBegin)
    }

    private static func stripCodexBlock(_ s: String) -> String {
        guard let r1 = s.range(of: codexBegin), let r2 = s.range(of: codexEnd) else { return s }
        var out = s
        out.removeSubrange(r1.lowerBound..<r2.upperBound)
        return out.replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }

    static func installCodex() throws {
        var content = (try? String(contentsOf: codexConfig, encoding: .utf8)) ?? ""
        backup(codexConfig)
        content = stripCodexBlock(content)
        if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
        content += "\n" + codexBlock() + "\n"
        try ensureDir(codexConfig)
        try content.write(to: codexConfig, atomically: true, encoding: .utf8)
    }

    static func uninstallCodex() throws {
        guard let content = try? String(contentsOf: codexConfig, encoding: .utf8) else { return }
        backup(codexConfig)
        try stripCodexBlock(content).write(to: codexConfig, atomically: true, encoding: .utf8)
    }

    // MARK: Kimi CLI（TOML，PreToolUse，复用同一 managed 标记块）

    private static var kimiConfig: URL {
        URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent(".kimi/config.toml"))
    }

    private static func kimiBlock() -> String {
        """
        \(codexBegin)
        [[hooks]]
        event = "PreToolUse"
        matcher = "Shell|WriteFile|StrReplaceFile"
        timeout = 120
        command = '''\(tomlHookCommand("kimi"))'''
        \(codexEnd)
        """
    }

    static func isKimiInstalled() -> Bool {
        guard let s = try? String(contentsOf: kimiConfig, encoding: .utf8) else { return false }
        return s.contains(codexBegin)
    }

    static func installKimi() throws {
        var content = (try? String(contentsOf: kimiConfig, encoding: .utf8)) ?? ""
        backup(kimiConfig)
        content = stripCodexBlock(content)
        if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
        content += "\n" + kimiBlock() + "\n"
        try ensureDir(kimiConfig)
        try content.write(to: kimiConfig, atomically: true, encoding: .utf8)
    }

    static func uninstallKimi() throws {
        guard let content = try? String(contentsOf: kimiConfig, encoding: .utf8) else { return }
        backup(kimiConfig)
        try stripCodexBlock(content).write(to: kimiConfig, atomically: true, encoding: .utf8)
    }
}
