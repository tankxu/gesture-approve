import Foundation

enum MonitorAPI {
    static var approvalSnapshot: () -> MObject = { [:] }
    static var resolveApproval: (String, Bool) -> Bool = { _,_ in false }
    static func handle(_ req: HubServer.Request) -> HubServer.Response {
        let monitor=LocalMonitor.shared
        // 采集器状态（装没装 / 是不是指着旧路径 / 这台机器上有没有这家工具）。
        if req.method == "GET", req.path == "/v2/collectors" { return .json(["collectors":MonitorHooks.status()]) }
        if req.method == "POST", req.path == "/v2/install" {
            guard req.isLoopback else { return .error("loopback-only","403 Forbidden") }
            let input=MonitorIO.object(String(data:req.body,encoding:.utf8) ?? "")
            let ids=(input["providers"] as? [String])?.filter { !$0.isEmpty }
            // 一家失败不影响另一家：整体 ok=false 也照样把每家的结果交回去，别让 UI 只看到一句"失败"。
            return .json(MonitorHooks.apply(providers:(ids?.isEmpty ?? true) ? nil : ids,uninstall:input["uninstall"] as? Bool == true,lang:I18n.hubLang))
        }
        // Codex 的回复要起子进程，几秒起步。放进监控队列会把 Hub 的其他请求一起堵住，
        // 而 MonitorDB 是 FULLMUTEX，action() 自己访问它本来就是安全的。
        if req.method == "POST", req.path == "/v2/actions" {
            let input=MonitorIO.object(String(data:req.body,encoding:.utf8) ?? "")
            let provider=monitor.queue.sync { monitor.db.get("session",input["sessionId"] as? String ?? "")["provider"] as? String }
            if input["action"] as? String == "reply", provider == "codex" { return .json(action(input,monitor)) }
        }
        return monitor.queue.sync {
            switch (req.method,req.path) {
            case ("GET","/v2/quotas"): return .json(monitor.quotas())
            case ("GET","/v2/usage"): return .json(monitor.ledger.report(period:req.query["period"] ?? "day",session:req.query["session"],timezone:req.query["timezone"] ?? TimeZone.current.identifier))
            case ("GET","/v2/events"): return .json(monitor.events(since:Int64(req.query["since"] ?? "0") ?? 0))
            case ("GET","/v2/sessions"):
                var result=monitor.sessions(limit:Int(req.query["limit"] ?? "200") ?? 200)
                let pending=approvalSnapshot()
                result["sessions"]=(result["sessions"] as? [MObject] ?? []).map { r -> MObject in
                    var r=r
                    if matches(pending,r) { var caps=r["capabilities"] as? MObject ?? [:];caps["approve"]=MonitorControl.capability(true,"",LHub("hubapi.cap.approvePending"),via:"gesture-hook");r["capabilities"]=caps;r["pendingApproval"]=pending;r["activity"]="waiting_approval" }
                    return r
                }
                return .json(result)
            case ("GET","/v2/attachment"):
                // 只在队列里取路径（快），解码留到外面做 —— 一张 600KB 的图不该卡住监控队列。
                let path=monitor.db.get("session",req.query["session"] ?? "")["transcriptPath"] as? String ?? ""
                guard !path.isEmpty else { return .error("session not found","404 Not Found") }
                guard let hit=attachment(path,req.query["message"] ?? "",Int(req.query["index"] ?? "") ?? -1) else {
                    return .error("attachment not found","404 Not Found")
                }
                // transcript 里的图片是不可变的，可以让浏览器长期缓存，省掉每次重绘的重复下载。
                return HubServer.Response(status:"200 OK",contentType:hit.1,body:hit.0,
                                          extraHeaders:["Cache-Control":"private, max-age=31536000","Content-Disposition":"inline"])
            case ("GET","/v2/messages"):
                let row=monitor.db.get("session",req.query["session"] ?? "")
                guard !row.isEmpty else { return .error("session not found","404 Not Found") }
                return .json(["messages":messages(row),"scope":"local transcript tail; tool payloads omitted"])
            case ("GET","/v2/actions"):
                let id=req.query["id"] ?? "", old=monitor.db.get("action",id)
                guard !old.isEmpty else { return .error("action not found","404 Not Found") }
                var action=old
                if old["status"] as? String == "unconfirmed", let mid=old["messageId"] as? String {
                    let row=monitor.db.get("session",old["sessionId"] as? String ?? "")
                    if messages(row).contains(where: { $0["id"] as? String == mid }) { action["status"]="delivered";action["reasonCode"]="";action["reason"]=LHub("hubapi.ok.confirmedInLog");monitor.db.put("action",id,action) }
                }
                return .json(action)
            case ("POST","/v2/actions"):
                return .json(action(MonitorIO.object(String(data:req.body,encoding:.utf8) ?? ""),monitor))
            default: return .error("not found","404 Not Found")
            }
        }
    }
    static func matches(_ p: MObject, _ row: MObject) -> Bool {
        p["profileId"] as? String == row["profileId"] as? String && p["state"] as? String == "pending" && MonitorIO.number(p["deadline_ms"]) > 0 && !(row["nativeSessionId"] as? String ?? "").isEmpty && p["sessionId"] as? String == row["nativeSessionId"] as? String && p["provider"] as? String == row["provider"] as? String
    }
    static func action(_ input: MObject, _ m: LocalMonitor) -> MObject {
        guard let id=input["idempotencyKey"] as? String,UUID(uuidString:id) != nil else { return ["status":"rejected","reasonCode":"IDEMPOTENCY_KEY_REQUIRED"] }
        let digest=MonitorIO.hash(MonitorIO.json(input)), old=m.db.get("action",id)
        if !old.isEmpty { return old["digest"] as? String == digest ? old : ["status":"rejected","reasonCode":"IDEMPOTENCY_CONFLICT"] }
        let sid=input["sessionId"] as? String ?? "",row=m.db.get("session",sid),kind=input["action"] as? String ?? ""
        var result: MObject=["id":id,"digest":digest,"sessionId":sid,"action":kind,"at":Date().timeIntervalSince1970,"status":"rejected"]
        guard !row.isEmpty else { result["reasonCode"]="SESSION_NOT_FOUND";return result }
        if kind == "approve" {
            let pending=approvalSnapshot(),decision=input["decision"] as? String ?? ""
            if matches(pending,row),pending["id"] as? String == input["requestId"] as? String,["allow","deny"].contains(decision) {
                result["status"]="dispatching"
                guard m.db.execute("INSERT INTO kv(kind,id,body) VALUES('action',?,?)",[id,MonitorIO.json(result)]) else { return ["status":"rejected","reasonCode":"PERSISTENCE_UNAVAILABLE","reason":LHub("hubapi.err.persistence")] }
                let ok=resolveApproval(pending["id"] as! String,decision == "allow")
                result["status"]=ok ? "delivered" : "rejected";result["reasonCode"]=ok ? "" : "STALE_APPROVAL"
            } else { result["reasonCode"]="STALE_APPROVAL" }
        } else if kind == "reply" {
            // 运行代次只对「送进活着的那个进程」有意义。Codex 是排进 thread 队列，
            // 不要求它此刻在跑，也就没有代次可比 —— 对它强制校验只会永远 STALE_RUN。
            if row["provider"] as? String != "codex" {
                guard let expected=input["expectedRunId"] as? String,!expected.isEmpty,expected == row["runId"] as? String else { result["reasonCode"]="STALE_RUN";m.db.put("action",id,result);return result }
            }
            result["status"]="dispatching"
                guard m.db.execute("INSERT INTO kv(kind,id,body) VALUES('action',?,?)",[id,MonitorIO.json(result)]) else { return ["status":"rejected","reasonCode":"PERSISTENCE_UNAVAILABLE","reason":LHub("hubapi.err.persistence")] }
            let reply=MonitorControl.send(row,text:input["text"] as? String ?? "",messageID:id)
            result.merge(reply) { _,b in b }
        } else { let cap=MonitorControl.capabilities(row)[kind] as? MObject;result["reasonCode"]=cap?["reasonCode"] ?? "ACTION_UNSUPPORTED";result["reason"]=cap?["reasonText"] }
        m.db.put("action",id,result);m.db.event(["type":"action.updated","actionId":id,"sessionId":sid,"status":result["status"] ?? "unknown","at":Date().timeIntervalSince1970])
        return result
    }
    /// 只回图片，且类型限死在这张表里：transcript 里的 base64 块不能成为任意文件的出口。
    static let imageTypes = ["image/png","image/jpeg","image/gif","image/webp"]

    /// 从 transcript 里取出某条消息的第 index 个图片块。
    /// 按块读、按行切：整份记录可能几十 MB，一次性读进内存会把 app 顶爆。
    static func attachment(_ path: String, _ uuid: String, _ index: Int) -> (Data, String)? {
        guard !uuid.isEmpty, index >= 0, let f = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? f.close() }
        let needle = Data(uuid.utf8)
        var carry = Data()
        while let chunk = ((try? f.read(upToCount: 1 << 20)) ?? nil), !chunk.isEmpty {
            carry.append(chunk)
            while let nl = carry.firstIndex(of: 10) {
                let line = Data(carry[carry.startIndex..<nl])
                carry = Data(carry[carry.index(after: nl)...])
                if line.range(of: needle) != nil, let hit = image(line, uuid, index) { return hit }
            }
            // 坏文件里可能有一行永远不结束，别让 carry 无限长。
            if carry.count > 64 << 20 { return nil }
        }
        if carry.range(of: needle) != nil { return image(carry, uuid, index) }
        return nil
    }

    static func image(_ line: Data, _ uuid: String, _ index: Int) -> (Data, String)? {
        guard let o = (try? JSONSerialization.jsonObject(with: line)) as? MObject,
              o["uuid"] as? String == uuid,
              let content = (o["message"] as? MObject)?["content"] as? [MObject],
              index < content.count,
              content[index]["type"] as? String == "image",
              let src = content[index]["source"] as? MObject,
              let b64 = src["data"] as? String,
              let bytes = Data(base64Encoded: b64) else { return nil }
        let type = src["media_type"] as? String ?? "image/png"
        guard imageTypes.contains(type) else { return nil }
        return (bytes, type)
    }

    /// Claude Code 收到 peer socket 来的消息后，会包一层再落盘：第一行是
    /// 「Another Claude session sent a message:」，中间是原文，末尾接一段讲 peer
    /// 权限边界的固定模板。那段模板是写给会话里的模型看的，不是人打的字 ——
    /// Hub 要显示的是中间那句。模板文案将来变了就找不到尾巴，那时原样返回，
    /// 顶多是多显示一段，不会丢内容。
    static func unwrapPeer(_ text: String) -> String? {
        guard let stop = text.firstIndex(of: "\n"), text[text.startIndex..<stop].hasPrefix("Another Claude session sent a message") else { return nil }
        var body = String(text[text.index(after: stop)...])
        // 从**最后**一处开始截：用户自己的话里出现同样的开头也不会被误伤。
        if let tail = body.range(of: "\n\nThis came from", options: .backwards) { body = String(body[..<tail.lowerBound]) }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 终端回显、斜杠命令的内部展开、系统插进去的续跑指令 —— 这些都不是对话，
    /// 在手机上读会话时只会把真正说过的话冲掉。
    static func conversational(_ text: String, isMeta: Bool) -> String? {
        if let peer = unwrapPeer(text) { return peer.isEmpty ? nil : peer }
        // peer 之外的 meta 一律不是人说的话。
        if isMeta { return nil }
        if text.hasPrefix("<local-command-stdout>") || text.hasPrefix("<local-command-caveat>") { return nil }
        // 斜杠命令收成它本来的样子：`/model`，而不是三行 XML。
        if text.hasPrefix("<command-name>"), let end = text.range(of: "</command-name>") {
            let name = String(text[text.index(text.startIndex, offsetBy: 14)..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            var line = name.hasPrefix("/") ? name : "/" + name
            if let a = text.range(of: "<command-args>"), let b = text.range(of: "</command-args>"), a.upperBound <= b.lowerBound {
                let args = String(text[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespaces)
                if !args.isEmpty { line += " " + args }
            }
            return line
        }
        return text
    }

    static func messages(_ row: MObject) -> [MObject] {
        guard let path=row["transcriptPath"] as? String,let f=FileHandle(forReadingAtPath:path) else { return [] };defer { try? f.close() }
        let size=(try? f.seekToEnd()) ?? 0;try? f.seek(toOffset:size>2_000_000 ? size-2_000_000 : 0)
        let data=(try? f.readToEnd()) ?? Data()
        return data.split(separator:10).compactMap { line -> MObject? in
            guard let o=(try? JSONSerialization.jsonObject(with:Data(line))) as? MObject else { return nil }
            var message=o["message"] as? MObject ?? [:],role=o["type"] as? String ?? ""
            if o["type"] as? String == "response_item" { message=o["payload"] as? MObject ?? [:];role=message["role"] as? String ?? "" }
            guard ["user","assistant"].contains(role) else { return nil }
            let text: String
            var images: [MObject] = []
            if let content=message["content"] as? [MObject] {
                text=content.filter { ["text","input_text","output_text"].contains($0["type"] as? String ?? "") }.compactMap { $0["text"] as? String }.joined(separator:"\n")
                // 图片只报位置和大小：一张截图 base64 要 600KB，几条就能把这份 JSON 撑到手机拉不动。
                // 真正的字节走 /v2/attachment 按需取，浏览器还能缓存。
                for (i,part) in content.enumerated() where part["type"] as? String == "image" {
                    guard let src=part["source"] as? MObject, let data=src["data"] as? String, !data.isEmpty else { continue }
                    images.append(["index":i,"mediaType":src["media_type"] ?? "image/png","bytes":data.count/4*3])
                }
            }
            else { text=message["content"] as? String ?? "" }
            let shown = text.isEmpty ? "" : (conversational(text, isMeta: o["isMeta"] as? Bool == true) ?? "")
            // 只有图、没有字的消息也是消息 —— 以前这种整条被丢掉。
            guard !shown.isEmpty || !images.isEmpty else { return nil }
            var row: MObject = ["role":role,"text":String(shown.prefix(24000)),"id":o["uuid"] ?? message["id"] ?? "","at":o["timestamp"] ?? ""]
            if !images.isEmpty { row["images"]=images }
            return row
        }.suffix(80).map { $0 }
    }
}
