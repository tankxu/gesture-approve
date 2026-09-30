import Foundation

/// Incremental local usage ledger. No authentication, network calls, or token estimation.
final class MonitorLedger {
    let db: MonitorDB
    var discovered = 0, scanned = 0, errors = 0
    var inventory: [(String, String, String)] = []
    var lastDiscovery = Date.distantPast
    var onSession: ((MObject) -> Void)?
    var onQuota: ((String, String, MObject, Double) -> Void)?
    init(_ db: MonitorDB) { self.db = db }
    func discover() {
        var roots = [("claude", MonitorIO.claude + "/projects", MonitorIO.claude), ("codex", MonitorIO.codex + "/sessions", MonitorIO.codex), ("codex", MonitorIO.codex + "/archived_sessions", MonitorIO.codex)]
        let settings = MonitorIO.read(MonitorIO.root + "/settings.json")
        for r in settings["roots"] as? [MObject] ?? [] {
            if let path = r["path"] as? String, let provider = r["provider"] as? String, ["claude", "codex"].contains(provider) { roots.append((provider,path,r["profile"] as? String ?? path)) }
        }
        // Desktop Code metadata maps to shared CLI transcripts on current builds. Older embedded Code roots are supported; Cowork is opt-in.
        let desktop = MonitorIO.home + "/Library/Application Support/Claude/claude-code-sessions"
        if let e = FileManager.default.enumerator(atPath: desktop) {
            while let rel = e.nextObject() as? String {
                if rel.hasSuffix(".claude/projects") { roots.append(("claude", desktop + "/" + rel, MonitorIO.claude)); e.skipDescendants() }
            }
        }
        var seen = Set<String>(); inventory = []
        for (provider, root, profile) in roots {
            guard let e = FileManager.default.enumerator(atPath: root) else { continue }
            while let rel = e.nextObject() as? String {
                guard rel.hasSuffix(".jsonl") else { continue }
                let path = root + "/" + rel
                if seen.insert(URL(fileURLWithPath: path).resolvingSymlinksInPath().path).inserted { inventory.append((provider,path,profile)) }
            }
        }
        inventory.sort { (attributes($0.1)[.modificationDate] as? Date ?? .distantPast) > (attributes($1.1)[.modificationDate] as? Date ?? .distantPast) }
        discovered = inventory.count; lastDiscovery = Date()
    }
    private func attributes(_ path: String) -> [FileAttributeKey: Any] { (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:] }
    func tick(budget: Double = 0.8) {
        if Date().timeIntervalSince(lastDiscovery) > 30 { discover() }
        let until = Date().addingTimeInterval(budget); scanned = 0; errors = 0
        for (provider,path,profile) in inventory {
            let a = attributes(path), old = db.get("file",path)
            let size = MonitorIO.number(a[.size]), inode = String(describing: a[.systemFileNumber] ?? "")
            let mtime = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            if size == MonitorIO.number(old["offset"]) && inode == old["inode"] as? String && mtime == MonitorIO.number(old["mtime"]) { scanned += 1; continue }
            if Date() >= until { continue }
            if scan(provider, path, profile, size: size, inode: inode, mtime: mtime) { scanned += 1 } else if db.get("file",path)["unaccountedReason"] != nil { errors += 1 }
        }
    }
    @discardableResult func scan(_ provider: String, _ path: String, _ profile: String, size: Double? = nil, inode: String? = nil, mtime: Double? = nil) -> Bool {
        let a = attributes(path); let length = size ?? MonitorIO.number(a[.size]); let identity = inode ?? String(describing: a[.systemFileNumber] ?? "")
        var state = db.get("file",path)
        if !state.isEmpty && (state["inode"] as? String != identity || MonitorIO.number(state["offset"]) > length || (MonitorIO.number(state["offset"]) == length && MonitorIO.number(state["mtime"]) != (mtime ?? (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0))) {
            // Replacing/truncating a file rebuilds this source; do not silently keep its old accounting.
            let oldIDs = db.rows("SELECT id,body FROM usage").filter { MonitorIO.object($0["body"] as? String ?? "")["file"] as? String == path }
            for row in oldIDs { db.execute("DELETE FROM usage WHERE id=?", [row["id"] as? String ?? ""]) }
            state = [:]
        }
        guard let f = FileHandle(forReadingAtPath: path) else { return false }; defer { try? f.close() }
        let start = Int(MonitorIO.number(state["offset"])); try? f.seek(toOffset: UInt64(start))
        // Bounded chunks, preserving the partial final line until the next append.
        var bytes = (try? f.read(upToCount: 4 * 1024 * 1024)) ?? Data()
        while !bytes.contains(10) && bytes.count < 64 * 1024 * 1024 && start + bytes.count < Int(length) {
            let next=(try? f.read(upToCount:4 * 1024 * 1024)) ?? Data();if next.isEmpty { break };bytes.append(next)
        }
        if !bytes.contains(10) && bytes.count >= 64 * 1024 * 1024 { state["unaccountedReason"]="OVERSIZED_LINE";db.put("file",path,state);return false }
        guard let last = bytes.lastIndex(of: 10) else { return length == Double(start) }
        let complete = bytes.prefix(through: last)
        db.execute("BEGIN IMMEDIATE")
        var sessionUpdates:[String:MObject]=[:]
        let callback=onSession
        onSession = { update in
            let id=update["id"] as? String ?? ""
            var row=sessionUpdates[id] ?? [:];row.merge(update) { _,new in new };sessionUpdates[id]=row
        }
        for line in complete.split(separator: 10) {
            let ordinal = Int(MonitorIO.number(state["ordinal"])); state["ordinal"] = ordinal + 1
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? MObject else { state["unaccountedReason"]="MALFORMED_JSONL";continue }
            ingest(provider, path, profile, obj, ordinal: ordinal, state: &state)
        }
        onSession=callback
        for row in sessionUpdates.values { callback?(row) }
        state["offset"] = start + complete.count; state["inode"] = identity
        state["mtime"] = mtime ?? (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        db.put("file",path,state); db.execute("COMMIT")
        return start + complete.count == Int(length)
    }
    func ingest(_ provider: String, _ path: String, _ profile: String, _ o: MObject, ordinal: Int, state: inout MObject) {
        let type = o["type"] as? String ?? "", p = o["payload"] as? MObject ?? [:]
        if provider == "codex" && type == "session_meta" {
            state["sid"] = p["id"]; state["cwd"] = p["cwd"]; state["surface"] = p["originator"]
            state["parent"] = p["forked_from_id"]
            state["inheritUntil"] = p["subagent_history_start_ordinal"]
            // Forked files without an explicit ownership boundary cannot safely be billed as new work.
            if p["forked_from_id"] != nil && p["subagent_history_start_ordinal"] == nil { state["ambiguousFork"] = true }
        }
        if provider == "codex" && type == "turn_context" { state["model"] = p["model"]; state["turn"] = p["turn_id"]; state["cwd"] = p["cwd"]; state["tier"] = p["service_tier"] }
        if provider == "claude" {
            if let sid = o["sessionId"] as? String { state["sid"] = sid }
            if let cwd = o["cwd"] as? String { state["cwd"] = cwd }
        }
        let sid = state["sid"] as? String ?? (URL(fileURLWithPath:path).deletingPathExtension().lastPathComponent)
        let key = LocalMonitor.sessionKey(provider, profile, sid)
        let at = MonitorIO.stamp(o["timestamp"])
        if !sid.isEmpty {
            var session: MObject = ["id":key,"provider":provider,"nativeSessionId":sid,"profileId":profile,"transcriptPath":path,"updatedAt":at,"source":"transcript"]
            session["cwd"] = state["cwd"]; session["model"] = state["model"]; session["parentSessionId"] = state["parent"]
            if (state["surface"] as? String ?? "").lowercased().contains("desktop") { session["surface"] = "desktop" }
            if type == "user", let msg = o["message"] as? MObject, o["isMeta"] as? Bool != true, state["title"] == nil {
                let t = Self.text(msg["content"]); if !t.isEmpty && !t.hasPrefix("<") { state["title"] = String(t.prefix(100)) }
            }
            if type == "event_msg" && p["type"] as? String == "user_message", state["title"] == nil { state["title"] = String((p["message"] as? String ?? "").prefix(100)) }
            session["title"] = state["title"]
            if provider == "codex", type == "event_msg" {
                let event=p["type"] as? String ?? ""
                if ["task_started","item_completed","task_complete","turn_aborted"].contains(event) {
                    session["activity"] = ["task_complete","turn_aborted"].contains(event) ? "idle" : "working"
                    session["runtimeAt"]=at;session["runtimeSource"]="rollout-event";session["turnId"]=p["turn_id"]
                    if event == "task_complete" { session["lastTurnOutcome"]="completed" }
                    if event == "turn_aborted" { session["lastTurnOutcome"]="interrupted" }
                }
            }
            if provider != "claude" || !path.contains("/subagents/") { onSession?(session) }
        }
        var usage: MObject = [:], eventID = "", model = state["model"] as? String ?? "unknown"
        var quality = "reported"
        if provider == "claude", type == "assistant", let msg = o["message"] as? MObject, let u = msg["usage"] as? MObject {
            usage = u; model = msg["model"] as? String ?? "unknown"; state["model"] = model
            let rid = o["requestId"] as? String ?? "", mid = msg["id"] as? String ?? ""
            guard !mid.isEmpty else { return }
            eventID = MonitorIO.hash(provider + profile + rid + mid)
            if rid.isEmpty { quality = "message_id_only" }
        } else if provider == "codex", type == "event_msg", p["type"] as? String == "token_count" {
            if let limits = p["rate_limits"] as? MObject { onQuota?(provider,profile,limits,at) }
            guard let info = p["info"] as? MObject, let total = info["total_token_usage"] as? MObject else { return }
            let previous = state["total"] as? MObject ?? [:]; state["total"] = total
            if MonitorIO.json(previous) == MonitorIO.json(total) { return }
            if let boundary = state["inheritUntil"], ordinal < Int(MonitorIO.number(boundary)) { return }
            if state["ambiguousFork"] as? Bool == true { state["unaccountedReason"] = "FORK_BOUNDARY_UNKNOWN"; return }
            let last = info["last_token_usage"] as? MObject ?? [:]
            if !previous.isEmpty && MonitorIO.number(total["total_tokens"]) >= MonitorIO.number(previous["total_tokens"]) {
                for field in ["input_tokens","cached_input_tokens","cache_write_input_tokens","output_tokens","reasoning_output_tokens"] { usage[field] = max(0,MonitorIO.number(total[field])-MonitorIO.number(previous[field])) }
            } else {
                usage = last
                if previous.isEmpty && MonitorIO.number(total["total_tokens"]) > MonitorIO.number(last["total_tokens"]) { state["unaccountedReason"]="INITIAL_COUNTER_BASELINE_UNKNOWN" }
                if !previous.isEmpty { quality = "counter_reset_last_request" }
            }
            eventID = MonitorIO.hash(provider + profile + sid + (state["turn"] as? String ?? "") + MonitorIO.json(total))
        } else { return }
        let input = MonitorIO.number(usage["input_tokens"]), output = MonitorIO.number(usage["output_tokens"])
        let read = MonitorIO.number(usage[provider == "claude" ? "cache_read_input_tokens" : "cached_input_tokens"])
        let write = MonitorIO.number(usage[provider == "claude" ? "cache_creation_input_tokens" : "cache_write_input_tokens"])
        let creation = usage["cache_creation"] as? MObject ?? [:]
        var row: MObject = ["id":eventID,"sessionId":key,"provider":provider,"model":model,"at":at,"file":path,"quality":quality,
            "input":provider == "claude" ? input : max(0,input-read-write),"cacheRead":read,"cacheWrite":write,"cacheWrite1h":MonitorIO.number(creation["ephemeral_1h_input_tokens"]),"output":output,
            "reasoning":MonitorIO.number(usage["reasoning_output_tokens"] ?? (usage["output_tokens_details"] as? MObject)?["thinking_tokens"]),
            "total": provider == "claude" ? input+read+write+output : input+output,
            "tier":usage["speed"] as? String ?? state["tier"] as? String ?? "standard"]
        if provider == "claude" && write > 0 && creation.isEmpty { row["cacheTTLUnknown"] = true }
        let old = db.rows("SELECT body FROM usage WHERE id=?", [eventID]).first.map { MonitorIO.object($0["body"] as? String ?? "") } ?? [:]
        // Claude streaming chunks may repeat a request. Keep the largest complete snapshot, and original ownership.
        if !old.isEmpty {
            guard MonitorIO.number(row["total"]) >= MonitorIO.number(old["total"]) else { return }
            if old["sessionId"] as? String != row["sessionId"] as? String { row["ownershipAmbiguous"]=true }
            for field in ["sessionId","at","file"] { row[field] = old[field] }
            if old["ownershipAmbiguous"] as? Bool == true { row["ownershipAmbiguous"]=true }
        }
        db.execute("INSERT INTO usage VALUES(?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET tokens=excluded.tokens,body=excluded.body", [eventID,row["sessionId"] ?? key,provider,model,row["at"] ?? at,row["total"] ?? 0,MonitorIO.json(row)])
    }
    static func text(_ content: Any?) -> String {
        if let s = content as? String { return s }
        return (content as? [MObject] ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator:"\n")
    }
    func report(period: String, session: String? = nil, timezone: String = "Asia/Bangkok") -> MObject {
        var cal = Calendar(identifier:.gregorian); cal.timeZone = TimeZone(identifier:timezone) ?? TimeZone(identifier:"Asia/Bangkok")!
        let now = Date(); let start: Date
        switch period { case "month": start = cal.dateInterval(of:.month,for:now)!.start; case "all": start = .distantPast; default: start = cal.startOfDay(for:now) }
        var args: [Any] = [start.timeIntervalSince1970,now.timeIntervalSince1970]
        var sql = "SELECT body FROM usage WHERE at>=? AND at<=?"
        if let session, !session.isEmpty { sql += " AND session=?"; args.append(session) }
        var groups: [String:MObject] = [:], total: MObject = [:]
        let pricing = MonitorIO.read(MonitorIO.root + "/pricing.json")
        for r in db.rows(sql,args) {
            let u = MonitorIO.object(r["body"] as? String ?? ""), model = u["model"] as? String ?? "unknown"
            var g = groups[model] ?? ["model":model]
            for field in ["input","cacheRead","cacheWrite","output","reasoning","total"] { let n = MonitorIO.number(u[field]); total[field] = MonitorIO.number(total[field])+n; g[field] = MonitorIO.number(g[field])+n }
            let cost = Self.cost(u, prices:pricing["models"] as? MObject ?? [:])
            for field in ["requests","unpricedRequests","ownershipAmbiguousRequests"] { let n = field == "requests" ? 1.0 : field == "ownershipAmbiguousRequests" ? (u["ownershipAmbiguous"] as? Bool == true ? 1.0 : 0.0) : cost == nil ? 1.0 : 0.0; total[field] = MonitorIO.number(total[field])+n; g[field] = MonitorIO.number(g[field])+n }
            total["pricedUSD"] = MonitorIO.number(total["pricedUSD"]) + (cost ?? 0); g["pricedUSD"] = MonitorIO.number(g["pricedUSD"]) + (cost ?? 0)
            groups[model] = g
        }
        return ["period":period,"timezone":cal.timeZone.identifier,"from":start.timeIntervalSince1970,"to":now.timeIntervalSince1970,"totals":total,"models":groups.values.sorted { MonitorIO.number($0["total"]) > MonitorIO.number($1["total"]) },
            "costBasis":"API-equivalent at price table date; not subscription charges","pricingVersion":pricing["version"] ?? "unavailable",
            "coverage":["scope":"configured local roots only; cloud and other hosts excluded","filesDiscovered":discovered,"filesComplete":scanned,"errors":errors,"complete":discovered == scanned && errors == 0 && !db.all("file").contains { $0["unaccountedReason"] != nil },"gaps":db.all("file").compactMap { $0["unaccountedReason"] as? String },"forksUnpriced":db.all("file").filter { $0["ambiguousFork"] as? Bool == true }.count]]
    }
    static func cost(_ u: MObject, prices: MObject) -> Double? {
        guard let p = prices[u["model"] as? String ?? ""] as? MObject, u["cacheTTLUnknown"] as? Bool != true else { return nil }
        let tier = u["tier"] as? String ?? "standard"
        let multiplier: Double
        if ["standard","default","auto",""].contains(tier) { multiplier=1 }
        else if ["priority","fast"].contains(tier), let fast=p["fastMultiplier"] { multiplier=MonitorIO.number(fast) }
        else { return nil }
        let input = MonitorIO.number(u["input"]), read = MonitorIO.number(u["cacheRead"]), write = MonitorIO.number(u["cacheWrite"]), hour = MonitorIO.number(u["cacheWrite1h"]), output = MonitorIO.number(u["output"])
        if let threshold = p["maxInput"], input+read+write > MonitorIO.number(threshold) { return nil }
        if write > 0 && p["cacheWrite"] == nil { return nil }
        if hour > 0 && p["cacheWrite1h"] == nil { return nil }
        return (input*MonitorIO.number(p["input"])+read*MonitorIO.number(p["cacheRead"])+max(0,write-hour)*MonitorIO.number(p["cacheWrite"])+hour*MonitorIO.number(p["cacheWrite1h"])+output*MonitorIO.number(p["output"]))/1e6 * multiplier
    }
}
