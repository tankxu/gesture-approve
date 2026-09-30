import Foundation
import Darwin

enum MonitorControl {
    static func capability(_ available: Bool, _ reason: String, _ text: String, via: String = "") -> MObject { ["available":available,"reasonCode":available ? "" : reason,"reasonText":text,"transport":via] }
    static func capabilities(_ row: MObject) -> MObject {
        let provider=row["provider"] as? String ?? "", pid=Int(MonitorIO.number(row["pid"]))
        let live=MonitorIO.alive(pid), socket=row["socketPath"] as? String ?? ""
        // Registry advertises the peer wire protocol independently of the engine release.
        // Do not infer compatibility for absent or future protocol versions.
        let supported=MonitorIO.number(row["peerProtocol"]) == 1
        let claudeInbox=provider == "claude" && live && !socket.isEmpty && supported
        // Codex 的输入通道是 thread 队列（`codex queue`）：消息排进去，会话下一轮读到就处理，
        // **不要求它此刻在跑**。归档的会话 Codex 自己会拒（要先 unarchive），这里先说清楚。
        let archived=row["archived"] as? Bool == true, thread=row["nativeSessionId"] as? String ?? ""
        let codexQueue=provider == "codex" && !archived && !thread.isEmpty
        let reply=claudeInbox || codexQueue
        let reason: String
        if provider == "codex" { reason = archived ? "SESSION_ARCHIVED" : "SESSION_UNIDENTIFIED" }
        else if !live { reason = row["exited"] as? Bool == true ? "SESSION_EXITED" : "OWNER_NOT_CONNECTED" }
        else if socket.isEmpty { reason = "MESSAGING_DISABLED" }
        else { reason = "VERSION_UNSUPPORTED" }
        let descriptions=["SESSION_EXITED":LHub("hubapi.reason.sessionExited"), "OWNER_NOT_CONNECTED":LHub("hubapi.reason.ownerNotConnected"), "MESSAGING_DISABLED":LHub("hubapi.reason.messagingDisabled"), "VERSION_UNSUPPORTED":LHub("hubapi.reason.versionUnsupported"), "SESSION_ARCHIVED":LHub("hubapi.reason.sessionArchived"), "SESSION_UNIDENTIFIED":LHub("hubapi.reason.sessionUnidentified")]
        let replyText = codexQueue ? LHub("hubapi.reason.codexQueue")
                      : claudeInbox ? LHub("hubapi.reason.claudeInbox") : descriptions[reason]!
        return ["reply":capability(reply,reason,replyText,via:codexQueue ? "codex-queue" : claudeInbox ? "claude-inbox" : ""),
            "steer":capability(false,"OBSERVE_ONLY",LHub("hubapi.cap.steer")),
            "enqueue":capability(false,"OBSERVE_ONLY",LHub("hubapi.cap.enqueue")),
            "approve":capability(false,"NO_PENDING_REQUEST",LHub("hubapi.cap.approve")),
            "answer":capability(false,"APPROVAL_NOT_RELAYABLE",LHub("hubapi.cap.answer")),
            "interrupt":capability(false,"OWNER_NOT_CONNECTED",LHub("hubapi.cap.interrupt")),
            "resume":capability(false,"OBSERVE_ONLY",LHub("hubapi.cap.resume")),
            "replyViaUI":capability(false,"UI_UNAVAILABLE",LHub("hubapi.cap.replyViaUI"))]
    }
    /// Codex 没有 Claude 那种 peer socket，但 CLI 带 `codex queue`：把消息排进 thread 的队列。
    /// 队列存在 `~/.codex/queue_1.sqlite`，由 Codex 自己管 —— 我们只调它的 CLI，不碰那个库。
    static func queueCodex(_ row: MObject, text: String, messageID: String) -> MObject {
        guard let exe=MonitorIO.executable("codex") else { return ["status":"rejected","reasonCode":"CODEX_CLI_MISSING","reason":LHub("hubapi.err.codexMissing")] }
        var env=ProcessInfo.processInfo.environment
        // codex 是 `#!/usr/bin/env node` 脚本，而 app 从 launchd 继承的 PATH 里通常没有 node。
        env["PATH"]=((env["PATH"] ?? "")+":/opt/homebrew/bin:/usr/local/bin:"+MonitorIO.home+"/.local/bin").trimmingCharacters(in:CharacterSet(charactersIn:":"))
        let (code,data)=MonitorIO.run(exe,["queue","--thread",row["nativeSessionId"] as? String ?? "","--message",text],timeout:25,env:env)
        let out=(String(data:data,encoding:.utf8) ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        // 退出码不可靠（它报错时也可能是 0），按输出判断：成功会回 "Queued message <id> for thread <id>."
        guard out.contains("Queued message") else {
            return ["status":"rejected","reasonCode":"QUEUE_REFUSED",
                    "reason":out.isEmpty ? (code == -2 ? LHub("hubapi.err.queueTimeout") : LHub("hubapi.err.queueNoOutput")) : String(out.prefix(300))]
        }
        var result: MObject=["status":"delivered","messageId":messageID,"transport":"codex-queue",
                             "reason":LHub("hubapi.ok.queued")]
        // 队列条目自己的 id：撤回要用它。
        if let a=out.range(of:"Queued message "), let b=out.range(of:" for thread"), a.upperBound<b.lowerBound {
            result["queueItemId"]=String(out[a.upperBound..<b.lowerBound])
        }
        return result
    }

    static func send(_ row: MObject, text: String, messageID: String) -> MObject {
        let cap=capabilities(row)["reply"] as! MObject
        guard cap["available"] as? Bool == true else { return ["status":"rejected","reasonCode":cap["reasonCode"]!,"reason":cap["reasonText"]!] }
        let pid=Int(MonitorIO.number(row["pid"])), path=row["socketPath"] as? String ?? ""
        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, text.utf8.count<=32000 else { return ["status":"rejected","reasonCode":"INVALID_MESSAGE","reason":LHub("hubapi.err.invalidMessage")] }
        if row["provider"] as? String == "codex" { return queueCodex(row,text:text,messageID:messageID) }
        guard let birth=row["processStart"] as? String,!birth.isEmpty,MonitorIO.birth(pid)==birth else { return ["status":"rejected","reasonCode":"STALE_PROCESS_BINDING"] }
        var st=stat(); guard lstat(path,&st)==0,(st.st_mode & S_IFMT)==S_IFSOCK,st.st_uid==getuid() else { return ["status":"rejected","reasonCode":"TARGET_UNVERIFIED"] }
        let fd=socket(AF_UNIX,SOCK_STREAM,0); guard fd>=0 else { return ["status":"rejected","reasonCode":"INBOX_UNAVAILABLE"] }; defer { close(fd) }
        var timeout=timeval(tv_sec:2,tv_usec:0), one:Int32=1
        setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size)); setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size)); setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,socklen_t(MemoryLayout<Int32>.size))
        var addr=sockaddr_un(); addr.sun_family=sa_family_t(AF_UNIX)
        let bytes=Array(path.utf8)+[0];guard bytes.count<=MemoryLayout.size(ofValue:addr.sun_path) else { return ["status":"rejected","reasonCode":"INBOX_UNAVAILABLE"] }
        withUnsafeMutableBytes(of:&addr.sun_path) { $0.copyBytes(from:bytes) }
        let connected=withUnsafePointer(to:&addr) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard connected==0 else { return ["status":"rejected","reasonCode":"INBOX_UNAVAILABLE"] }
        var peerPID: Int32=0, peerLength=socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd,SOL_LOCAL,LOCAL_PEERPID,&peerPID,&peerLength)==0, Int(peerPID)==pid else { return ["status":"rejected","reasonCode":"TARGET_UNVERIFIED"] }
        let payload: MObject=["type":"user","session_id":row["nativeSessionId"] ?? "","uuid":messageID,"message":["content":text],"priority":"next"]
        let data=Data((MonitorIO.json(payload)+"\n").utf8)
        let count=data.withUnsafeBytes { Darwin.send(fd,$0.baseAddress,data.count,0) }
        guard count==data.count else { return ["status":"unconfirmed","reasonCode":"DELIVERY_UNCONFIRMED"] }
        // No forged auth line/permission class: Hub is a peer, not the user's approval authority.
        return ["status":"unconfirmed","reasonCode":"DELIVERY_UNCONFIRMED","reason":LHub("hubapi.ok.unconfirmed"),"messageId":messageID,"transport":"claude-inbox"]
    }
}
