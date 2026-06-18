import Foundation

/// 自动接入/移除 Claude Code 与 Codex 的 hook，免用户手敲命令。
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
        (repoRoot() as NSString).appendingPathComponent("hooks/gesture_hook.py")
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

    private static func claudeCommand() -> String {
        "/usr/bin/python3 '\(hookScript())' claude"
    }

    static func isClaudeInstalled() -> Bool {
        guard let data = try? Data(contentsOf: claudeSettings),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = obj["hooks"] as? [String: Any],
              let pre = hooks["PreToolUse"] as? [[String: Any]] else { return false }
        for entry in pre {
            for h in (entry["hooks"] as? [[String: Any]] ?? []) {
                if let c = h["command"] as? String, c.contains("gesture_hook.py") { return true }
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
                ($0["command"] as? String)?.contains("gesture_hook.py") == true
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
                ($0["command"] as? String)?.contains("gesture_hook.py") == true
            }
        }
        if pre.isEmpty { hooks.removeValue(forKey: "PreToolUse") } else { hooks["PreToolUse"] = pre }
        if hooks.isEmpty { dict.removeValue(forKey: "hooks") } else { dict["hooks"] = hooks }
        let out = try JSONSerialization.data(withJSONObject: dict,
                                             options: [.prettyPrinted, .withoutEscapingSlashes])
        try out.write(to: claudeSettings)
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
        command = '''/usr/bin/python3 "\(hookScript())" codex'''
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
}
