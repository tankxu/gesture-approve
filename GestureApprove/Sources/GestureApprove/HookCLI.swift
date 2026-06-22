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
        let ti = payload["tool_input"] as? [String: Any] ?? [:]
        let detail = (ti["command"] as? String) ?? (ti["file_path"] as? String) ?? (ti["description"] as? String) ?? ""
        var op = "\(tool): \(detail)".trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            .trimmingCharacters(in: .whitespaces)
        op = String(op.prefix(600))

        let decision: String
        let reason: String
        if let (d, r) = ask(operation: op, cwd: cwd, tool: tool, session: session) {
            decision = d
            reason = "手势审批: \(r)"
        } else {
            // app 没开/不可达：回退终端正常审批，并在终端提示一行（不影响 stdout 协议）。
            decision = "ask"
            reason = "手势审批不可用，交回终端"
            FileHandle.standardError.write(Data("⚠️  GestureApprove 离线（未运行或端口不可达），本次交回终端正常审批。\n".utf8))
        }
        emit(target: target, decision: decision, reason: reason)
        exit(0)
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
