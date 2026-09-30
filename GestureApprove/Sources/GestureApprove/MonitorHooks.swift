import Foundation

enum MonitorHooks {
    static func capture(provider: String, statusLine: Bool = false) -> Never {
        let data=FileHandle.standardInput.readDataToEndOfFile()
        if var o=(try? JSONSerialization.jsonObject(with:data)) as? MObject {
            let env=ProcessInfo.processInfo.environment, parent=MonitorIO.providerParent()
            o["provider"]=provider; o["at"]=Date().timeIntervalSince1970
            o["profile"]=provider == "claude" ? MonitorIO.claude : MonitorIO.codex
            o["pid"]=parent.0; o["processStart"]=MonitorIO.birth(parent.0)
            o["surface"]=parent.1.contains(".app/") ? "desktop" : "cli"
            o["socketPath"]=env["CLAUDE_CODE_MESSAGING_SOCKET"]
            o["transcriptPath"]=o["transcript_path"]; o["turnId"]=o["turn_id"]
            if statusLine {
                o["hook_event_name"]="StatusLine"; o["engineVersion"]=o["version"]

            }
            // Whitelist: never persist prompts, tool inputs, environment, or messaging/auth tokens in the spool.
            let keys=["provider","at","profile","pid","processStart","surface","socketPath","transcriptPath","turnId","session_id","hook_event_name","notification_type","stop_hook_active","engineVersion","rate_limits","model","accountFingerprint","cwd"]
            let safe=o.filter { keys.contains($0.key) }
            let filename=String(format:"%.6f",Date().timeIntervalSince1970) + "-" + UUID().uuidString + ".json"
            try? MonitorIO.atomic(safe,MonitorIO.root + "/inbox/" + filename)
        }
        if statusLine {
            let saved=MonitorIO.read(MonitorIO.root + "/statusline-original.json")
            if let original=saved["original"] as? MObject, let command=original["command"] as? String, !command.isEmpty {
                let file=NSTemporaryDirectory()+"ga-statusline-"+UUID().uuidString
                try? data.write(to:URL(fileURLWithPath:file)); defer { try? FileManager.default.removeItem(atPath:file) }
                let p=Process();p.executableURL=URL(fileURLWithPath:"/bin/sh");p.arguments=["-c",command]
                p.standardInput=FileHandle(forReadingAtPath:file);p.standardOutput=FileHandle.standardOutput;p.standardError=FileHandle.standardError
                do { try p.run();p.waitUntilExit() } catch { }
            } else {
                // Installing the collector also gives a useful native footer without consuming tokens.
                let o=(try? JSONSerialization.jsonObject(with:data)) as? MObject ?? [:]
                let rate=o["rate_limits"] as? MObject ?? [:]
                let parts=[("five_hour","5h"),("seven_day","7d")].compactMap { key,label -> String? in
                    guard let w=rate[key] as? MObject, let p=w["used_percentage"] as? NSNumber else { return nil }
                    return label + " " + String(format: L("usage.remaining"), "\(Int(max(0,100-p.doubleValue)))")
                }
                print(parts.isEmpty ? L("monitor.statusline.waiting") : parts.joined(separator:" · "))
            }
        }
        exit(0)
    }
    // MARK: 调度

    /// 加一家工具 = 在 MonitorProviders.swift 里实现一个 MonitorCollector，再往这里加一行。
    static let collectors: [any MonitorCollector.Type] = [ClaudeCollector.self, CodexCollector.self]
    static var executablePath: String { Bundle.main.executablePath ?? CommandLine.arguments.first ?? "" }
    static func collector(_ id: String) -> (any MonitorCollector.Type)? { collectors.first { $0.id == id } }

    /// 每家的现状：装没装、装了是不是还有效、这台机器上有没有这家工具。
    /// UI 的开关状态、自愈判断、空状态文案都读这里，别再各自去翻配置文件。
    static func status(executable: String = executablePath) -> [MObject] {
        collectors.map { c in
            let state = c.state(executable)
            return ["id": c.id, "name": c.displayName, "present": c.isPresent(), "state": state.rawValue,
                    "collecting": state == .installed, "needsRepair": state == .stale, "config": c.configPath]
        }
    }
    static var allIDs: [String] { collectors.map { $0.id } }
    /// 开着但配置不在位（换过 app 路径、手改过配置、被别的工具覆盖）→ 需要补装的那几家。
    /// 机器上没有的工具不算"待修"——它本来就不该有配置。
    static func needingRepair(_ ids: [String] = allIDs, executable: String = executablePath) -> [String] {
        ids.compactMap { id in
            guard let c = collector(id), c.isPresent(), c.state(executable) != .installed else { return nil }
            return c.id
        }
    }

    /// 一家一个事务：各自备份、各自回滚、各自报结果。任何一家失败都不牵连别家。
    /// providers 传 nil = 对每一家都表态；跳过的也留一行说明为什么，别让 UI 只看到"少了一个"。
    /// lang 决定结果文案用哪种语言：app 界面用软件语言（6 种），Hub API 传 I18n.hubLang（zh/en）。
    @discardableResult
    static func apply(providers: [String]? = nil, uninstall: Bool, executable: String = executablePath,
                      lang: String = I18n.lang) -> MObject {
        let targets: [any MonitorCollector.Type] = collectors.filter { providers?.contains($0.id) ?? true }
        var results: [MObject] = []
        for c in targets {
            var row: MObject = ["id": c.id, "name": c.displayName, "config": c.configPath]
            // 没装这家工具就跳过，不报错也不建文件 —— 用户有什么就装什么。
            let skip = uninstall ? (c.state(executable) == .absent ? MonitorHookFile.text("monitor.skip.notConnected", lang: lang) : nil)
                                 : (c.isPresent() ? nil : MonitorHookFile.text("monitor.err.toolMissing", [c.displayName, c.configPath], lang: lang))
            if let skip {
                row["ok"] = true; row["skipped"] = true; row["reason"] = skip; row["state"] = c.state(executable).rawValue
                results.append(row); continue
            }
            do {
                if uninstall { try c.uninstall() } else { try c.install(executable) }
                row["ok"] = true
                if !uninstall, let key = c.postInstallNoteKey { row["note"] = MonitorHookFile.text(key, lang: lang) }
            } catch {
                row["ok"] = false
                row["error"] = MonitorHookFile.message(error, lang: lang)
            }
            row["state"] = c.state(executable).rawValue
            results.append(row)
        }
        if let providers {
            let known = Set(collectors.map { $0.id })
            for id in providers where !known.contains(id) { results.append(["id": id, "ok": false, "error": MonitorHookFile.text("monitor.err.unknownTarget", lang: lang)]) }
        }
        return ["action": uninstall ? "uninstall" : "install", "results": results,
                "ok": results.allSatisfy { $0["ok"] as? Bool == true },
                "hint": MonitorHookFile.text(uninstall ? "monitor.hint.uninstalled" : "monitor.hint.installed", lang: lang)]
    }
}
