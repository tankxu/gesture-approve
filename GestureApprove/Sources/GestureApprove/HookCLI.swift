import Foundation

/// 命令行 hook：`GestureApprove --hook <claude|codex|gemini|kimi>`。
/// 取代旧的 gesture_hook.py，让核心审批**零 Python 依赖**（同一个 app 二进制兼当 hook）。
///
/// 流程：从 stdin 读 hook JSON → POST 操作到本地 app(127.0.0.1:47600) → 拿 allow/deny/ask
/// → 按目标 CLI 的格式写 stdout。app 不可达/超时/异常 → ask（交回终端）+ stderr 提示，失败安全。
enum HookCLI {
    static func run(target: String) -> Never {
        let payload = readStdinJSON()
        let tool = payload["tool_name"] as? String ?? ""
        let cwd = payload["cwd"] as? String ?? ""
        let session = payload["session_id"] as? String ?? ""
        // 权限模式感知(仅 Claude/Kimi 的 PreToolUse 有 permission_mode):Claude 本来就不会弹窗的
        // 场景直接 defer(输出空、连 app 都不惊动),把判断交回 Claude 自己更聪明的 auto——
        // 这才是"审批来源=hook"该有的行为:只在 Claude 本来要问你时才接管。见 shouldDefer。
        let mode = payload["permission_mode"] as? String ?? "default"
        if shouldDefer(target: target, mode: mode, tool: tool) { exit(0) }
        let ti = payload["tool_input"] as? [String: Any] ?? [:]
        let detail = (ti["command"] as? String) ?? (ti["file_path"] as? String) ?? (ti["description"] as? String) ?? ""
        var op = "\(tool): \(detail)".trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            .trimmingCharacters(in: .whitespaces)
        // 判定必须看到完整命令：截断会把尾部危险藏起来（"<600 字安全前缀> && rm -rf ~" 截断后
        // deny-list 看不到 rm、前缀白名单却命中 → 放行）。只设防病态输入的超大上限；
        // 卡片显示的截断由 NotchCardView 自己做（lineLimit）。
        op = String(op.prefix(100_000))

        let decision: String
        let reason: String
        if let (d, r) = ask(operation: op, cwd: cwd, tool: tool, session: session) {
            decision = d
            reason = "手势审批: \(r)"
        } else {
            // app 没开/不可达：回退终端正常审批，并在终端提示一行（不影响 stdout 协议）。
            decision = "ask"
            reason = "手势审批不可用，交回终端"
            FileHandle.standardError.write(Data("⚠️  Gesture Approve 离线（未运行或端口不可达），本次交回终端正常审批。\n".utf8))
        }
        emit(target: target, decision: decision, reason: reason)
        exit(0)
    }

    /// 是否把这次判定直接交回 Claude(输出空 = defer),不让 GA 接管。
    /// 原则:GA 只在 **Claude Code 本来就会弹权限确认框** 的时刻介入;Claude 自己已"自动放行"的
    /// 场景一律 defer——否则就是拿更笨的规则去盖 Claude 更聪明的 auto,把每个编辑都变成手动审批。
    ///   · bypassPermissions / dontAsk:Claude 什么都不问 → 全 defer。
    ///   · auto:Claude 自己按智能判断决定放行还是弹窗。hook 在此判断之前触发、无法"只截风险项"
    ///     (要么全盖要么全放),而用户看重的正是 auto 的智能 → 全 defer,GA 不插手。
    ///     ⇒ 设备/手势审批定位成 **default 模式**的能力:想让 GA/设备接管,就用 default。
    ///   · plan:计划模式不执行工具(靠 ExitPlanMode 收口)→ defer,别注入 allow。
    ///   · acceptEdits:文件编辑被自动接受、不弹窗 → 对 Edit/Write/MultiEdit/NotebookEdit defer;
    ///     但 Bash 等仍会被 Claude 弹窗,继续交给 GA。
    ///   · default(及未知模式):Claude 会照常弹窗 → 全部交给 GA(app 侧再按 Allowlist 自动放行/弹卡)。
    ///
    /// **仅对 claude 生效**:permission_mode 是 Claude Code 独有的 hook 负载字段。已查证(2026-07-25):
    ///   · Kimi `PreToolUse` 的 stdin 只有 hook_event_name/session_id/cwd + tool_*,**不带 permission_mode**
    ///     (它只是输出借用了 Claude 的 permissionDecision 风格,输入并不对齐)→ 纳入也永远读不到,反成误导。
    ///   · Gemini `BeforeTool` 同样**不带** permission_mode(CLI 有 --yolo/approval-mode 但不下发给 hook)。
    ///   · Codex `PermissionRequest` 只在它自己要问时才触发,天生只截真提示、已等价"智能 hook",误 defer
    ///     反会跳过真实审批。
    ///   ⇒ 三家都不 gate;它们维持"每次触发都路由给 GA"的原有行为(Codex 因事件语义本就只在该问时触发)。
    static func shouldDefer(target: String, mode: String, tool: String) -> Bool {
        guard target == "claude" else { return false }
        switch mode {
        case "bypassPermissions", "dontAsk", "plan", "auto":
            return true
        case "acceptEdits":
            return ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(tool)
        default:
            return false
        }
    }

    private static func readStdinJSON() -> [String: Any] {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// 同步 POST /approve，返回 (decision, reason)；失败返回 nil。
    private static func ask(operation: String, cwd: String, tool: String, session: String) -> (String, String)? {
        let port = ProcessInfo.processInfo.environment["GESTURE_APPROVE_PORT"] ?? "47600"
        guard let url = URL(string: "http://127.0.0.1:\(port)/approve") else { return nil }
        let timeout = Double(ProcessInfo.processInfo.environment["GESTURE_APPROVE_HTTP_TIMEOUT"] ?? "") ?? 100
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["operation": operation, "cwd": cwd, "tool": tool, "session": session])

        let sem = DispatchSemaphore(value: 0)
        var result: (String, String)? = nil
        URLSession.shared.dataTask(with: req) { data, _, _ in
            defer { sem.signal() }
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let d = obj["decision"] as? String ?? "ask"
            let r = obj["reason"] as? String ?? ""
            result = ((["allow", "deny", "ask"].contains(d) ? d : "ask"), r)
        }.resume()
        sem.wait()
        return result
    }

    /// 按目标 CLI 的格式写 stdout（与各家 hook 协议一致）。
    private static func emit(target: String, decision: String, reason: String) {
        let out: [String: Any]
        switch target {
        case "codex":
            // Codex PermissionRequest：ask 不返回 decision -> 走正常审批。
            var inner: [String: Any] = ["hookEventName": "PermissionRequest"]
            if decision == "allow" { inner["decision"] = ["behavior": "allow"] }
            else if decision == "deny" { inner["decision"] = ["behavior": "deny", "message": reason] }
            out = ["hookSpecificOutput": inner]
        case "gemini":
            // Gemini BeforeTool：顶层 decision；ask -> 空对象（不干预）。
            if decision == "allow" { out = ["decision": "allow"] }
            else if decision == "deny" { out = ["decision": "deny", "reason": reason] }
            else { out = [:] }
        default:
            // claude / kimi：hookSpecificOutput.permissionDecision（Kimi 只认 deny，其余放行，兼容）。
            // 关键：Claude Code 里 permissionDecision:"ask" 会「强制弹确认框并覆盖 auto-mode」——
            // 它盖过 acceptEdits 模式、permissions.allow 白名单，甚至 --dangerously-skip-permissions，
            // 导致 app 离线/超时/未介入时每个 Edit 都要手动点。真正的「交回 Claude 默认权限判定」
            // 是 exit 0 不输出任何东西（等价 permissionDecision:"defer"）。所以只有 allow/deny 才发
            // 决策，ask 保持沉默——与上面 codex/gemini 分支的处理一致。
            guard decision == "allow" || decision == "deny" else { return }
            out = ["hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": decision,
                "permissionDecisionReason": reason,
            ]]
        }
        if let data = try? JSONSerialization.data(withJSONObject: out) {
            FileHandle.standardOutput.write(data)
        }
    }
}
