import Foundation
import SQLite3

final class LocalMonitor {
    static let shared = LocalMonitor()
    let queue = DispatchQueue(label:"com.gestureapprove.monitor",qos:.utility)
    let db: MonitorDB
    let ledger: MonitorLedger
    private var timer: DispatchSourceTimer?
    private var nextLive = Date.distantPast
    private var nextLedger = Date.distantPast
    private var liveError = "not yet sampled"
    static func sessionKey(_ provider: String, _ profile: String, _ sid: String) -> String { provider + ":" + MonitorIO.hash(profile).prefix(12) + ":" + sid }
    init(root: String = MonitorIO.root) {
        // A failed store must be visible and must never silently overwrite history.
        do { db = try MonitorDB(root + "/monitor.sqlite") } catch { fatalError("Cannot open monitor database: \(error)") }
        let pricingPath = root + "/pricing.json"
        if !FileManager.default.fileExists(atPath:pricingPath) {
            let bundled = MonitorIO.read(AppPaths.resource("config/monitor-pricing.json"))
            if !bundled.isEmpty { try? MonitorIO.atomic(bundled,pricingPath) }
        }
        ledger = MonitorLedger(db)
        ledger.onSession = { [weak self] in self?.merge($0) }
        ledger.onQuota = { [weak self] in self?.quota($0,$1,$2,$3) }
        // Claude subagent files share the parent sessionId; they contribute usage but cannot replace the parent's conversation.
        for var row in db.all("session") {
            guard let path=row["transcriptPath"] as? String,path.contains("/subagents/"),row["provider"] as? String == "claude",let id=row["id"] as? String,let sid=row["nativeSessionId"] as? String else { continue }
            let project=URL(fileURLWithPath:path).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let parent=project.appendingPathComponent(sid+".jsonl").path
            if FileManager.default.fileExists(atPath:parent) { row["transcriptPath"]=parent } else { row.removeValue(forKey:"transcriptPath") }
            db.put("session",id,row)
        }
    }
    func start() {
        queue.async {
            guard self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue:self.queue)
            t.schedule(deadline:.now(),repeating:1)
            t.setEventHandler { [weak self] in self?.tick() }; self.timer = t; t.resume()
        }
    }
    func tick() {
        drain()
        if Date() >= nextLive { discoverLive(); nextLive = Date().addingTimeInterval(5) }
        if Date() >= nextLedger { ledger.tick(budget:0.65); nextLedger = Date().addingTimeInterval(ledger.scanned < ledger.discovered ? 0 : 3) }
    }
    func merge(_ update: MObject) {
        guard let id = update["id"] as? String else { return }
        var row = db.get("session",id)
        let oldActivity = row["activity"] as? String
        let oldRuntime = MonitorIO.number(row["runtimeAt"])
        for (k,v) in update {
            if k == "title", !(row["title"] as? String ?? "").isEmpty, update["source"] as? String == "transcript" { continue }
            if k == "updatedAt" && MonitorIO.number(v) < MonitorIO.number(row[k]) { continue }
            if ["activity","lastTurnOutcome","turnId","runtimeAt"].contains(k), MonitorIO.number(update["runtimeAt"]) < oldRuntime { continue }
            if k == "surface", row["surface"] as? String == "desktop" { continue }
            row[k] = v
        }
        if row["surface"] == nil { row["surface"] = "unknown" }
        if row["activity"] == nil { row["activity"] = "unknown" }
        if row["lastTurnOutcome"] == nil { row["lastTurnOutcome"] = "none" }
        db.put("session",id,row)
        if oldActivity != row["activity"] as? String && (update["activity"] != nil) {
            db.event(["type":"session.updated","sessionId":id,"activity":row["activity"] ?? "unknown","at":row["runtimeAt"] ?? 0])
        }
    }
    func drain() {
        let dir = MonitorIO.root + "/inbox"
        let paths = ((try? FileManager.default.contentsOfDirectory(atPath:dir)) ?? []).filter { $0.hasSuffix(".json") }.sorted().prefix(500)
        for file in paths {
            let path = dir + "/" + file, o = MonitorIO.read(path)
            if !o.isEmpty { ingest(o) }
            try? FileManager.default.removeItem(atPath:path)
        }
    }
    func ingest(_ o: MObject) {
        guard let provider = o["provider"] as? String, ["claude","codex"].contains(provider), let sid = o["session_id"] as? String, !sid.isEmpty else { return }
        let profile = o["profile"] as? String ?? (provider == "claude" ? MonitorIO.claude : MonitorIO.codex)
        let id = Self.sessionKey(provider,profile,sid), event = o["hook_event_name"] as? String ?? ""
        let at = MonitorIO.stamp(o["at"]), existing = db.get("session",id)
        var row: MObject = ["id":id,"provider":provider,"nativeSessionId":sid,"profileId":profile,"updatedAt":at,"source":"hook"]
        for k in ["cwd","pid","processStart","socketPath","engineVersion","surface","transcriptPath","turnId"] { if let v = o[k] { row[k] = v } }
        if o["pid"] != nil { row["runId"] = MonitorIO.hash("\(o["pid"]!)\(o["processStart"] ?? "")") }
        if event == "StatusLine" {
            if let limits = o["rate_limits"] as? MObject { quota(provider,profile,limits,at,account:o["accountFingerprint"] as? String) }
            if let model = (o["model"] as? MObject)?["id"] { row["model"] = model }
        } else {
            var activity: String?
            switch event {
            case "SessionStart": activity = "idle"
            case "UserPromptSubmit","PreToolUse","PostToolUse","PostToolUseFailure": activity = "working"
            case "PermissionRequest": activity = "waiting_approval"
            case "Stop": if o["stop_hook_active"] as? Bool != true { activity = "idle"; row["lastTurnOutcome"] = "completed" }
            case "Interrupt": activity = "idle"; row["lastTurnOutcome"] = "interrupted"
            case "SessionEnd": activity = "idle"; row["exited"] = true
            case "Notification":
                let t = o["notification_type"] as? String ?? ""
                if t == "permission_prompt" { activity = "waiting_approval" }
                else if t == "elicitation_dialog" { activity = "waiting_input" }
            default: break
            }
            // A late Stop from an older known turn cannot finish a newer one.
            if let oldTurn = existing["turnId"] as? String, let turn = row["turnId"] as? String, oldTurn != turn && ["Stop","Interrupt"].contains(event) { activity = nil; row.removeValue(forKey:"lastTurnOutcome"); row.removeValue(forKey:"turnId") }
            if let activity { row["activity"] = activity; row["runtimeAt"] = at }
        }
        merge(row)
    }
    func quota(_ provider: String, _ profile: String, _ raw: MObject, _ at: Double, account: String? = nil) {
        guard at > 0 else { return }
        let bucket = provider + ":" + MonitorIO.hash(profile).prefix(12) + ":" + (account ?? "profile-unverified")
        var windows: [MObject] = []
        if provider == "claude" {
            for (name, minutes) in [("five_hour",300),("seven_day",10080)] {
                guard let w = raw[name] as? MObject, let p = w["used_percentage"] as? NSNumber else { continue }
                windows.append(["name":name,"usedPercent":p.doubleValue,"windowMinutes":minutes,"resetsAt":MonitorIO.stamp(w["resets_at"])])
            }
        } else {
            for name in ["primary","secondary"] {
                guard let w = raw[name] as? MObject, let p = w["used_percent"] as? NSNumber else { continue }
                windows.append(["name":name,"usedPercent":p.doubleValue,"windowMinutes":MonitorIO.number(w["window_minutes"]),"resetsAt":MonitorIO.stamp(w["resets_at"])])
            }
        }
        guard !windows.isEmpty else { return }
        let limit = raw["limit_id"] as? String ?? "subscription", key = bucket + ":" + limit, old = db.get("quota",key)
        guard at >= MonitorIO.number(old["receivedAt"]) else { return }
        // Redraws with identical values preserve the first receipt, not a fabricated server refresh.
        let changed = MonitorIO.json(old["windows"] ?? []) != MonitorIO.json(windows)
        let row: MObject = ["id":key,"provider":provider,"profileId":profile,"accountFingerprint":account ?? "unverified","limitId":limit,"limitName":raw["limit_name"] ?? limit,"windows":windows,"receivedAt":at,
            "lastChangedAt":changed ? at : old["lastChangedAt"] ?? at,"source":provider == "claude" ? "statusLine" : "rollout",
            "freshnessBasis":"last changed local observation; not a forced account refresh"]
        db.put("quota",key,row)
        if changed { db.event(["type":"quota.updated","quotaId":key,"at":at]) }
    }
    /// Pools reported in the same client response share a receipt time; this tolerance absorbs clock jitter only.
    static let sameReportSeconds: Double = 600
    func quotas() -> MObject {
        let now = Date().timeIntervalSince1970
        var rows = db.all("quota").map { q -> MObject in
            var q=q
            q["windows"] = (q["windows"] as? [MObject] ?? []).map { w -> MObject in
                var w=w; let p=MonitorIO.number(w["usedPercent"]), reset=MonitorIO.number(w["resetsAt"])
                let valid=reset>now && p>=0 && p<=100
                w["remainingPercent"] = valid ? max(0,100-p) as Any : NSNull(); w["expired"] = !valid
                return w
            }
            q["ageSeconds"] = max(0,now-MonitorIO.number(q["lastChangedAt"])); return q
        }
        // A client reports every pool it currently has, so pools absent from the newest receipt are history
        // (a former plan, a retired model allowance), not a second live pool. Rows stay; `current` marks the live set.
        for provider in Set(rows.compactMap { $0["provider"] as? String }) {
            let mine = rows.indices.filter { rows[$0]["provider"] as? String == provider }
            let newest = mine.map { MonitorIO.number(rows[$0]["receivedAt"]) }.max() ?? 0
            for i in mine {
                let live = (rows[i]["windows"] as? [MObject] ?? []).contains { $0["expired"] as? Bool == false }
                rows[i]["current"] = live && MonitorIO.number(rows[i]["receivedAt"]) >= newest - Self.sameReportSeconds
            }
        }
        return ["accounts":rows,"mode":"local-only","note":LHub("hubapi.note.quotas")]
    }
    func discoverLive() {
        if let executable = MonitorIO.executable("claude") {
            let (code,data) = MonitorIO.run(executable,["agents","--json","--all"],timeout:3)
            if code == 0, let live = (try? JSONSerialization.jsonObject(with:data)) as? [MObject] {
                liveError = ""
                for o in live {
                    guard let sid=o["sessionId"] as? String, !sid.isEmpty else { continue }
                    let state=o["state"] as? String ?? "", status=o["status"] as? String ?? ""
                    let waiting=o["waitingFor"] as? String ?? ""
                    let activity = status == "busy" ? "working" : state == "working" ? "waiting_external" : status == "waiting" || state == "blocked" ? (waiting.lowercased().contains("permission") || waiting.lowercased().contains("approval") ? "waiting_approval" : "waiting_input") : "idle"
                    var row: MObject = ["id":Self.sessionKey("claude",MonitorIO.claude,sid),"nativeSessionId":sid,"provider":"claude","profileId":MonitorIO.claude,"surface":"cli","activity":activity,"runtimeAt":Date().timeIntervalSince1970,"source":"claude-agents","exited":o["pid"] == nil]
                    for (a,b) in [("pid","pid"),("name","title"),("cwd","cwd")] { row[b]=o[a] }
                    if state == "done" { row["lastTurnOutcome"]="completed" }; if state == "failed" { row["lastTurnOutcome"]="failed" }
                    merge(row)
                }
            } else { liveError="Claude agents unavailable (\(code))" }
        }
        // Registry is used only to bind an exact live process/socket, never as the history source.
        for name in (try? FileManager.default.contentsOfDirectory(atPath:MonitorIO.claude + "/sessions")) ?? [] where name.hasSuffix(".json") {
            let o=MonitorIO.read(MonitorIO.claude + "/sessions/" + name)
            guard let sid=o["sessionId"] as? String else { continue }
            let pid=Int(MonitorIO.number(o["pid"])); guard MonitorIO.alive(pid), let expected=o["procStart"] as? String, !expected.isEmpty, expected == MonitorIO.birth(pid) else { continue }
            var row: MObject = ["id":Self.sessionKey("claude",MonitorIO.claude,sid),"nativeSessionId":sid,"provider":"claude","profileId":MonitorIO.claude,"pid":pid,"exited":false]
            row["socketPath"]=o["messagingSocketPath"] ?? ""; row["engineVersion"]=o["version"] ?? ""; row["cwd"]=o["cwd"]
            row["peerProtocol"]=o["peerProtocol"] ?? 0; row["peerFeatures"]=o["peerFeatures"] ?? [String]()
            row["processStart"] = expected
            row["runId"]=MonitorIO.hash("\(pid)\(row["processStart"] ?? "")")
            merge(row)
        }
        desktopMetadata()
        codexMetadata()
    }
    func desktopMetadata() {
        let root=MonitorIO.home + "/Library/Application Support/Claude/claude-code-sessions"
        guard let e=FileManager.default.enumerator(atPath:root) else { return }
        while let rel=e.nextObject() as? String {
            if rel.hasSuffix("projects") || rel.hasSuffix("node_modules") { e.skipDescendants(); continue }
            guard rel.hasSuffix(".json") else { continue }
            let o=MonitorIO.read(root + "/" + rel)
            guard let sid=o["cliSessionId"] as? String, !sid.isEmpty else { continue }
            var row: MObject = ["id":Self.sessionKey("claude",MonitorIO.claude,sid),"provider":"claude","nativeSessionId":sid,"profileId":MonitorIO.claude,"surface":"desktop"]
            row["desktopSessionId"]=o["sessionId"]; row["title"]=o["title"]; row["cwd"]=o["cwd"]; row["archived"]=o["isArchived"]
            merge(row)
        }
    }
    func codexMetadata() {
        let path=MonitorIO.codex+"/state_5.sqlite"
        guard FileManager.default.fileExists(atPath:path) else { return }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path,&handle,SQLITE_OPEN_READONLY|SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK else { if let handle { sqlite3_close(handle) };return }
        defer { sqlite3_close(handle) }; sqlite3_busy_timeout(handle,100)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle,"SELECT id,rollout_path,cwd,title,archived,updated_at,source FROM threads ORDER BY updated_at DESC LIMIT 2000",-1,&stmt,nil)==SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt)==SQLITE_ROW {
            func str(_ i:Int32)->String { sqlite3_column_text(stmt,i).map { String(cString:$0) } ?? "" }
            let sid=str(0)
            merge(["id":Self.sessionKey("codex",MonitorIO.codex,sid),"provider":"codex","nativeSessionId":sid,"profileId":MonitorIO.codex,"transcriptPath":str(1),"cwd":str(2),"title":String(str(3).prefix(140)),"archived":sqlite3_column_int(stmt,4) != 0,"updatedAt":Double(sqlite3_column_int64(stmt,5)),"source":"codex-local-index","origin":str(6)])
            codexTail(sid,path:str(1))
        }
    }
    // Runtime evidence is read independently of the multi-GB history backfill.
    func codexTail(_ sid: String, path: String) {
        guard let a=try? FileManager.default.attributesOfItem(atPath:path) else { return }
        let size=MonitorIO.number(a[.size]),modified=(a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let old=db.get("runtime-file",path)
        if MonitorIO.number(old["size"])==size && MonitorIO.number(old["modified"])==modified { return }
        guard let f=FileHandle(forReadingAtPath:path) else { return };defer { try? f.close() }
        try? f.seek(toOffset:UInt64(max(0,size-262144)))
        let bytes=(try? f.readToEnd()) ?? Data()
        for line in bytes.split(separator:10).reversed() {
            guard let o=(try? JSONSerialization.jsonObject(with:Data(line))) as? MObject, o["type"] as? String == "event_msg",let p=o["payload"] as? MObject,let event=p["type"] as? String,["task_started","item_completed","task_complete","turn_aborted"].contains(event) else { continue }
            var row:MObject=["id":Self.sessionKey("codex",MonitorIO.codex,sid),"runtimeAt":MonitorIO.stamp(o["timestamp"]),"runtimeSource":"rollout-tail","activity":["task_complete","turn_aborted"].contains(event) ? "idle" : "working"]
            row["turnId"]=p["turn_id"]
            if event=="task_complete" { row["lastTurnOutcome"]="completed" };if event=="turn_aborted" { row["lastTurnOutcome"]="interrupted" }
            merge(row);break
        }
        db.put("runtime-file",path,["size":size,"modified":modified])
    }
    func sessions(limit: Int = 200) -> MObject {
        let now=Date().timeIntervalSince1970
        let rows=db.all("session").sorted { MonitorIO.number($0["updatedAt"]) > MonitorIO.number($1["updatedAt"]) }.prefix(max(1,min(limit,1000))).map { row -> MObject in
            var row=row; let pid=Int(MonitorIO.number(row["pid"])), alive=MonitorIO.alive(pid)
            let ownedThread = row["provider"] as? String != "codex"
            row["connection"] = alive ? (ownedThread ? "online" : "owner_alive") : "unknown"; row["lifecycle"] = row["archived"] as? Bool == true ? "archived" : row["exited"] as? Bool == true ? "exited" : alive && ownedThread ? "loaded" : "unknown"
            if (!alive || !ownedThread) && now-MonitorIO.number(row["runtimeAt"]) > (ownedThread ? 15 : 90) && ["working","waiting_approval","waiting_input"].contains(row["activity"] as? String ?? "") { row["activity"]="unknown" }
            row["capabilities"]=MonitorControl.capabilities(row)
            row.removeValue(forKey:"socketPath"); row.removeValue(forKey:"processStart")
            return row
        }
        return ["sessions":rows,"coverage":["scope":"local configured profiles","claudeLiveError":liveError,"cloud":"not connected","codexRuntime":"hooks; no claim of attaching to another app-server"],"cursor":cursor()]
    }
    func cursor() -> Int64 { db.rows("SELECT MAX(seq) AS n FROM events").first?["n"] as? Int64 ?? 0 }
    func events(since: Int64, limit: Int = 200) -> MObject {
        let rows=db.rows("SELECT seq,body FROM events WHERE seq>? ORDER BY seq LIMIT ?",[since,max(1,min(limit,1000))])
        let events=rows.map { r -> MObject in var o=MonitorIO.object(r["body"] as? String ?? "");o["seq"]=r["seq"];return o }
        return ["events":events,"cursor":rows.last?["seq"] ?? since,"latestCursor":cursor()]
    }
}
