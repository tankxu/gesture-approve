import Foundation
import Darwin

enum AppPaths { static func resource(_ rel:String)->String { FileManager.default.currentDirectoryPath + "/" + rel } }
enum GALog { static func log(_ s:String) {} }
@main struct Regression {
 static func main() throws {
  let root=NSTemporaryDirectory()+"ga-monitor-tests-"+UUID().uuidString
  setenv("GA_MONITOR_HOME",root,1);setenv("GA_MONITOR_DIR",root+"/monitor",1);setenv("CLAUDE_CONFIG_DIR",root+"/.claude",1);setenv("CODEX_HOME",root+"/.codex",1)
  defer { try? FileManager.default.removeItem(atPath:root) }
  let m=LocalMonitor.shared,db=m.db,l=m.ledger
  let now=Date().timeIntervalSince1970,profile=MonitorIO.claude
  func check(_ b:@autoclosure()->Bool,_ message:String) { if !b() { fatalError(message) };print("PASS \(message)") }
  func total()->Double { MonitorIO.number((l.report(period:"all")["totals"] as? MObject)?["total"]) }
  let savedTZ=ProcessInfo.processInfo.environment["TZ"]
  setenv("TZ","Asia/Bangkok",1)
  let birthBangkok=MonitorIO.birth(Int(getpid()))
  setenv("TZ","America/Los_Angeles",1)
  check(!birthBangkok.isEmpty && MonitorIO.birth(Int(getpid())) == birthBangkok,"process binding independent of local timezone")
  if let savedTZ { setenv("TZ",savedTZ,1) } else { unsetenv("TZ") }
  var peer:MObject=["provider":"claude","pid":Int(getpid()),"socketPath":"/test/peer.sock","peerProtocol":1]
  for version in ["2.1.259","2.1.261","2.1.263","2.1.265","2.1.267","2.1.269"] {
   peer["engineVersion"]=version
   check((MonitorControl.capabilities(peer)["reply"] as! MObject)["available"] as? Bool == true,"Claude peer v1 supported on \(version)")
  }
  for proto in [0,2] {
   peer["peerProtocol"]=proto
   check((MonitorControl.capabilities(peer)["reply"] as! MObject)["reasonCode"] as? String == "VERSION_UNSUPPORTED","missing or future peer protocol rejected \(proto)")
  }
  peer["peerProtocol"]=1;peer["socketPath"]=""
  check((MonitorControl.capabilities(peer)["reply"] as! MObject)["reasonCode"] as? String == "MESSAGING_DISABLED","protocol alone cannot enable absent inbox")
  peer["socketPath"]="/test/peer.sock";peer["provider"]="codex"
  check((MonitorControl.capabilities(peer)["reply"] as! MObject)["available"] as? Bool == false,"Claude peer protocol cannot enable Codex control")
  let registryPath=profile+"/sessions/"+String(getpid())+".json"
  try MonitorIO.atomic(["sessionId":"peer-regression","pid":Int(getpid()),"procStart":MonitorIO.birth(Int(getpid())),"peerProtocol":1,"version":"2.1.261","messagingSocketPath":"/test/peer.sock"],registryPath)
  m.discoverLive()
  let registryKey=LocalMonitor.sessionKey("claude",profile,"peer-regression")
  check(MonitorIO.number(db.get("session",registryKey)["peerProtocol"]) == 1,"registry discovery persists peer protocol")
  try MonitorIO.atomic(["sessionId":"peer-regression","pid":Int(getpid()),"procStart":MonitorIO.birth(Int(getpid()))],registryPath)
  m.discoverLive()
  let cleared=db.get("session",registryKey)
  check(MonitorIO.number(cleared["peerProtocol"]) == 0 && cleared["socketPath"] as? String == "","registry cannot retain removed socket or protocol")
  var state:MObject=[:]
  let u:MObject=["type":"assistant","sessionId":"c1","timestamp":now,"requestId":"req1","message":["id":"msg1","model":"claude-sonnet-5","usage":["input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":40,"cache_creation":["ephemeral_1h_input_tokens":40]]]]
  l.ingest("claude","c1.jsonl",profile,u,ordinal:0,state:&state);l.ingest("claude","c1.jsonl",profile,u,ordinal:1,state:&state)
  check(total()==100,"Claude repeated streaming snapshot counts once")
  let parentPath=db.get("session",LocalMonitor.sessionKey("claude",profile,"c1"))["transcriptPath"] as? String
  var subState:MObject=[:];l.ingest("claude","/projects/c1/subagents/agent-test.jsonl",profile,u,ordinal:0,state:&subState)
  check(db.get("session",LocalMonitor.sessionKey("claude",profile,"c1"))["transcriptPath"] as? String == parentPath,"subagent transcript cannot replace parent conversation")
  let cost=l.report(period:"all")["totals"] as! MObject
  check(abs(MonitorIO.number(cost["pricedUSD"])-0.000386)<0.00000001,"Claude cache TTL pricing and output not double counted")
  var copy=u;copy["sessionId"]="c2";var s2:MObject=[:];l.ingest("claude","copy.jsonl",profile,copy,ordinal:0,state:&s2)
  check(total()==100,"copied request globally deduplicated")
  check(MonitorIO.object(db.rows("SELECT body FROM usage").first!["body"] as! String)["ownershipAmbiguous"] as? Bool == true,"ambiguous copied ownership retained")
  var cs:MObject=["sid":"x","model":"gpt-6-astra","turn":"t"]
  func codex(_ input:Int,_ output:Int,_ read:Int)->MObject { ["type":"event_msg","timestamp":now,"payload":["type":"token_count","info":["total_token_usage":["input_tokens":input,"cached_input_tokens":read,"output_tokens":output,"total_tokens":input+output],"last_token_usage":["input_tokens":input,"cached_input_tokens":read,"output_tokens":output,"total_tokens":input+output]]]] }
  l.ingest("codex","x.jsonl",MonitorIO.codex,codex(100,10,50),ordinal:0,state:&cs)
  l.ingest("codex","x.jsonl",MonitorIO.codex,codex(100,10,50),ordinal:1,state:&cs)
  l.ingest("codex","x.jsonl",MonitorIO.codex,codex(220,30,110),ordinal:2,state:&cs)
  check(total()==350,"Codex cumulative counters use deltas and ignore repeats")
  var fork:MObject=["sid":"f","ambiguousFork":true];l.ingest("codex","f.jsonl",MonitorIO.codex,codex(220,30,110),ordinal:0,state:&fork)
  check(total()==350 && fork["unaccountedReason"] as? String == "FORK_BOUNDARY_UNKNOWN","unknown fork excluded with reason")
  let rate:MObject=["five_hour":["used_percentage":25,"resets_at":now+3600]]
  m.quota("claude",profile,rate,now);m.quota("claude",profile,rate,now+10)
  var q=(m.quotas()["accounts"] as! [MObject])[0]
  check(MonitorIO.number(q["lastChangedAt"])==now,"statusLine redraw cannot fake fresh observation")
  check(MonitorIO.number((q["windows"] as! [MObject])[0]["remainingPercent"])==75,"remaining percent uses server observation")
  m.quota("claude",profile,["five_hour":["used_percentage":25,"resets_at":now-1]],now+11);q=(m.quotas()["accounts"] as! [MObject])[0]
  check((q["windows"] as! [MObject])[0]["remainingPercent"] is NSNull,"expired quota is unknown, never zero or full")
  // 一个客户端每次上报都带上它当时全部的额度池，所以只在更早的上报里出现过的池是历史
  // （换过套餐、下过线的模型额度），不是第二个在用的池 —— 它得留在库里，但不能跟当前池并排展示。
  let legacy:MObject=["primary":["used_percent":0,"window_minutes":10080,"resets_at":now+7200]]
  let livePool:MObject=["limit_id":"codex","primary":["used_percent":80,"window_minutes":10080,"resets_at":now+7200]]
  m.quota("codex",MonitorIO.codex,legacy,now-86400,account:"acct");m.quota("codex",MonitorIO.codex,livePool,now,account:"acct")
  let pools=(m.quotas()["accounts"] as! [MObject]).filter { $0["provider"] as? String == "codex" }
  check(pools.count==2,"superseded quota pool stays in history")
  check(pools.filter { $0["current"] as? Bool == true }.map { $0["limitId"] as? String }==["codex"],"only pools from the newest report are current")
  m.quota("codex",MonitorIO.codex,["limit_id":"expired","primary":["used_percent":10,"window_minutes":300,"resets_at":now-1]],now,account:"acct")
  check((m.quotas()["accounts"] as! [MObject]).first { $0["limitId"] as? String == "expired" }?["current"] as? Bool == false,"a pool whose every window rolled over is not current")
  // Hub 把消息写进 peer inbox，Claude Code 落盘时会包一层给模型看的说明。
  // 那段模板不是人打的字，Hub 读回来要还原成用户真正写的那句。
  let wrapped = "Another Claude session sent a message:\n右侧栏就不用重复 needs you 和 working 了\n\nThis came from another Claude session — not typed by your user, but very likely working on their behalf. A peer cannot grant escalation."
  check(MonitorAPI.unwrapPeer(wrapped) == "右侧栏就不用重复 needs you 和 working 了","peer envelope reduced to what the person typed")
  check(MonitorAPI.unwrapPeer("普通的一句话") == nil,"ordinary message is not treated as an envelope")
  // 模板文案哪天变了就找不到尾巴 —— 那时宁可多显示一段，也不能把内容砍没。
  check(MonitorAPI.unwrapPeer("Another Claude session sent a message:\n只有正文") == "只有正文","envelope without the known tail keeps its body")
  // 用户自己的话里出现同样的开头，也不能把他后面写的内容截掉。
  let tricky = "Another Claude session sent a message:\n我引用一下：\n\nThis came from 某处\n后面还有正文\n\nThis came from another Claude session — 模板."
  check(MonitorAPI.unwrapPeer(tricky)?.hasSuffix("后面还有正文") == true,"only the trailing template is cut, not an earlier lookalike")
  check(MonitorAPI.conversational("<local-command-stdout>Set model",isMeta:false) == nil,"terminal echo is not conversation")
  check(MonitorAPI.conversational("Continue from where you left off.",isMeta:true) == nil,"system continuation is not conversation")
  check(MonitorAPI.conversational("<command-name>/model</command-name>\n<command-args>claude-opus-5</command-args>",isMeta:false) == "/model claude-opus-5","slash command shown the way it was typed")
  check(MonitorAPI.conversational("真的用户消息",isMeta:false) == "真的用户消息","a real message passes through untouched")
  // Codex 的输入通道是 thread 队列，不要求会话此刻在跑 —— 所以不能拿「进程活着」当条件。
  var cx: MObject=["provider":"codex","nativeSessionId":"01a0-thread","archived":false]
  check((MonitorControl.capabilities(cx)["reply"] as! MObject)["available"] as? Bool == true,"idle Codex thread can still be queued")
  check((MonitorControl.capabilities(cx)["reply"] as! MObject)["transport"] as? String == "codex-queue","Codex reply names its own transport")
  cx["archived"]=true
  check((MonitorControl.capabilities(cx)["reply"] as! MObject)["reasonCode"] as? String == "SESSION_ARCHIVED","an archived Codex thread says so instead of failing later")
  cx["archived"]=false; cx["nativeSessionId"]=""
  check((MonitorControl.capabilities(cx)["reply"] as! MObject)["available"] as? Bool == false,"a Codex row without a thread id cannot be queued")
  // Claude 那条路不受影响：仍然要求活着的进程 + 已注册 inbox + 受支持的协议版本。
  let claudeIdle: MObject=["provider":"claude","nativeSessionId":"x","socketPath":"/test/p.sock","peerProtocol":1]
  check((MonitorControl.capabilities(claudeIdle)["reply"] as! MObject)["available"] as? Bool == false,"Claude still needs a live owner")

  // 图片按引用取：base64 塞不进消息列表，但取出来的必须正好是指名那条消息的那个块，
  // 而且只能是图片 —— transcript 里的 base64 不能变成任意文件的出口。
  let attachPath = root + "/attach.jsonl"
  let pngBytes = Data([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a])
  let withImage: MObject = ["uuid":"att-1","type":"user","message":["content":[
      ["type":"text","text":"看这个"],
      ["type":"image","source":["type":"base64","media_type":"image/png","data":pngBytes.base64EncodedString()]]]]]
  let disguised: MObject = ["uuid":"att-2","type":"user","message":["content":[
      ["type":"image","source":["type":"base64","media_type":"text/html","data":Data("<script>".utf8).base64EncodedString()]]]]]
  try (MonitorIO.json(withImage)+"\n"+MonitorIO.json(disguised)+"\n").write(toFile:attachPath,atomically:true,encoding:.utf8)
  check(MonitorAPI.attachment(attachPath,"att-1",1)?.0 == pngBytes,"attachment returns the named image block verbatim")
  check(MonitorAPI.attachment(attachPath,"att-1",0) == nil,"a text block is not an attachment")
  check(MonitorAPI.attachment(attachPath,"att-2",0) == nil,"a non-image media type is refused")
  check(MonitorAPI.attachment(attachPath,"att-1",9) == nil,"index beyond the content array yields nothing")
  check(MonitorAPI.attachment(attachPath,"no-such-message",1) == nil,"unknown message id yields nothing")
  m.ingest(["provider":"codex","session_id":"busy","hook_event_name":"UserPromptSubmit","at":now-200,"pid":getpid(),"processStart":MonitorIO.birth(Int(getpid()))])
  let sessions=m.sessions()["sessions"] as! [MObject]
  check(sessions.first { $0["nativeSessionId"] as? String == "busy" }?["activity"] as? String == "unknown","live Codex owner cannot keep stale thread working")
  let row=db.get("session",LocalMonitor.sessionKey("claude",profile,"c1"))
  let pending:MObject=["state":"pending","deadline_ms":1000,"sessionId":"c1","provider":"codex","id":"r"]
  check(!MonitorAPI.matches(pending,row),"same session string in different provider cannot approve")
  let request:MObject=["idempotencyKey":UUID().uuidString,"sessionId":row["id"]!,"action":"reply","expectedRunId":"wrong","text":"hello"]
  let a=MonitorAPI.action(request,m);let b=MonitorAPI.action(request,m)
  check(a["reasonCode"] as? String == "STALE_RUN" && MonitorIO.json(a)==MonitorIO.json(b),"stale run rejected and retry idempotent")
  var changed=request;changed["text"]="other"
  check(MonitorAPI.action(changed,m)["reasonCode"] as? String == "IDEMPOTENCY_CONFLICT","idempotency key cannot target different content")
  var bound=row;bound["runId"]="test-bound";db.put("session",row["id"] as! String,bound)
  db.execute("PRAGMA query_only=ON")
  let failed=MonitorAPI.action(["idempotencyKey":UUID().uuidString,"sessionId":row["id"]!,"action":"reply","expectedRunId":"test-bound","text":"never sent"],m)
  check(failed["reasonCode"] as? String == "PERSISTENCE_UNAVAILABLE","failed durable reservation cannot send a message")
  db.execute("PRAGMA query_only=OFF")
  let path=root+"/large.jsonl";let large=MObject(dictionaryLiteral:("type","user"),("sessionId","large"),("timestamp",now),("message",["content":String(repeating:"x",count:5_000_000)]))
  try Data((MonitorIO.json(large)+"\n"+MonitorIO.json(u)+"\n").utf8).write(to:URL(fileURLWithPath:path))
  check(l.scan("claude",path,profile),"JSONL line over 4MB progresses")
  // ── 采集器安装：一家一个事务，用户有什么就装什么 ──
  let fm=FileManager.default
  let execA="/Applications/GestureApprove.app/Contents/MacOS/GestureApprove"
  let execB=root+"/moved/GestureApprove.app/Contents/MacOS/GestureApprove"   // 同一个 app 换了位置
  let settingsPath=profile+"/settings.json",codexPath=MonitorIO.codex+"/config.toml"
  func mtime(_ path:String)->Double { MonitorIO.number((try? fm.attributesOfItem(atPath:path))?[.modificationDate].flatMap { ($0 as? Date)?.timeIntervalSince1970 }) }
  func stops(_ o:MObject)->[MObject] { ((o["hooks"] as? MObject ?? [:])["Stop"] as? [MObject]) ?? [] }
  let cfg:MObject=["custom":true,"statusLine":["type":"command","command":"printf original"],"hooks":["Stop":[["hooks":[["type":"command","command":"printf keep"]]]]]]
  try MonitorIO.atomic(cfg,settingsPath);try fm.createDirectory(atPath:MonitorIO.codex,withIntermediateDirectories:true)
  try "model = \"gpt-6-astra\"\n".write(toFile:codexPath,atomically:true,encoding:.utf8)

  check(ClaudeCollector.state(execA) == .absent,"untouched settings report no collector")
  var r=MonitorHooks.apply(providers:["claude"],uninstall:false,executable:execA)
  check(r["ok"] as? Bool==true,"claude-only install succeeds")
  check(ClaudeCollector.state(execA) == .installed,"claude collector reports installed")
  // 点名一家就只碰一家 —— 以前 Claude 和 Codex 共用一次事务，Codex 出问题会把 Claude 一起撤掉。
  check(try! String(contentsOfFile:codexPath,encoding:.utf8)=="model = \"gpt-6-astra\"\n","installing claude never touches the Codex config")
  let settings=MonitorIO.read(settingsPath)
  check(stops(settings).count==2,"install preserves the user's own hooks")

  let stamp=mtime(settingsPath)
  r=MonitorHooks.apply(providers:["claude"],uninstall:false,executable:execA)
  check(MonitorIO.json(MonitorIO.read(settingsPath))==MonitorIO.json(settings),"reinstall is idempotent")
  check(mtime(settingsPath)==stamp,"an unchanged reinstall does not rewrite the file")
  let backups=((try? fm.contentsOfDirectory(atPath:profile)) ?? []).filter { $0.contains("ga-monitor-backup") }
  check(backups==["settings.json.ga-monitor-backup"],"backups use one fixed name, not one per call")
  check(MonitorIO.json(MonitorIO.read(settingsPath+".ga-monitor-backup"))==MonitorIO.json(cfg),"backup holds the pre-install config")

  // 路径漂移：命令还是我们的，但指着一个不存在的 app —— 文件里"看着装了"，其实每次执行都失败。
  check(ClaudeCollector.state(execB) == .stale,"a moved app is not 'installed'")
  check(MonitorHooks.needingRepair(["claude"],executable:execB)==["claude"],"drift is surfaced as needing repair")
  r=MonitorHooks.apply(providers:["claude"],uninstall:false,executable:execB)
  check(ClaudeCollector.state(execB) == .installed && ClaudeCollector.state(execA) == .stale,"reinstall repairs the drifted path")
  check(stops(MonitorIO.read(settingsPath)).count==2,"repair replaces the stale entry instead of stacking another")
  let repaired=MonitorIO.read(settingsPath)

  // 别的工具把 statusLine 换走：hook 还在，但额度从此永远是空的 —— 不能算装好。
  var hijacked=repaired;hijacked["statusLine"]=["type":"command","command":"printf someone-else"]
  try MonitorIO.atomic(hijacked,settingsPath)
  check(ClaudeCollector.state(execB) == .stale,"hooks without our statusLine is not a working collector")
  try MonitorIO.atomic(repaired,settingsPath)

  // Codex：点名才装；装完原有配置还在。
  r=MonitorHooks.apply(providers:["codex"],uninstall:false,executable:execB)
  check(r["ok"] as? Bool==true,"codex install succeeds: \(MonitorIO.json(r))")
  check(CodexCollector.state(execB) == .installed,"codex collector reports installed")
  check(CodexCollector.state(execA) == .stale,"codex drift is detected the same way")
  check(try! String(contentsOfFile:codexPath,encoding:.utf8).contains("gpt-6-astra"),"codex install keeps the user's settings")

  // 没装这家工具就一个字节都不写。清空 PATH 让 codex 真的"不存在"；
  // MonitorIO.executable 还会兜底翻 /opt/homebrew/bin 之类，那里真有 codex 的机器上这条跳过。
  try fm.removeItem(atPath:MonitorIO.codex)
  let savedPATH=ProcessInfo.processInfo.environment["PATH"] ?? ""
  setenv("PATH",root,1)
  defer { setenv("PATH",savedPATH,1) }
  if MonitorIO.executable("codex")==nil {
   check(!CodexCollector.isPresent(),"absent codex is reported absent")
   let skipped=MonitorHooks.apply(uninstall:false,executable:execB)
   let codexRow=(skipped["results"] as! [MObject]).first { $0["id"] as? String=="codex" }
   check(codexRow?["skipped"] as? Bool==true,"an absent tool is skipped, not failed")
   check(!fm.fileExists(atPath:codexPath),"an absent tool never gets a config file created for it")
  } else { print("SKIP absent-codex case (codex is installed on this machine)") }

  // ── 开关语义：开着必须等于真的在采 ──
  // 用 app 自己的路径装，才能模拟真实的"装好了"状态（自愈判断读的是 Bundle.main.executablePath）。
  let selfExec=MonitorHooks.executablePath
  _=MonitorHooks.apply(providers:["claude"],uninstall:true,executable:selfExec)
  UsageMonitor.collecting=false
  check(UsageMonitor.hint([]) == .off,"no collector installed reads as 'collection off', not 'no data'")
  // 关着的时候，自愈一个字节都不写 —— 默认开着的显示开关不能替用户改配置文件。
  check(UsageMonitor.repairIfNeeded().isEmpty && ClaudeCollector.state(selfExec) == .absent,"repair never installs while collection is off")
  _=MonitorHooks.apply(providers:["claude"],uninstall:false,executable:selfExec)
  UsageMonitor.collecting=true
  check(UsageMonitor.hint([]) == .waiting,"installed but no snapshot yet reads as 'waiting', not 'off'")
  // 配置被别的工具换走 → 开关还开着，但已经不在采了：必须报"失效"，而不是继续说"等下次刷新"。
  var broken=MonitorIO.read(settingsPath);broken["statusLine"]=["type":"command","command":"printf someone-else"]
  try MonitorIO.atomic(broken,settingsPath)
  check(UsageMonitor.hint([]) == .broken,"a hijacked statusLine is reported as stale, not as waiting")
  check(UsageMonitor.repairIfNeeded()==["claude"],"repair fixes it because the user did opt in")
  check(UsageMonitor.hint([]) == .waiting,"after repair the switch means what it says")
  UsageMonitor.collecting=false
  _=MonitorHooks.apply(providers:["claude"],uninstall:true,executable:selfExec)
  try MonitorIO.atomic(cfg,settingsPath)
  _=MonitorHooks.apply(providers:["claude"],uninstall:false,executable:execB)

  // ── 文案分层：app 界面 6 语言，Hub（页面 + HTTP API）只有 zh/en ──
  check(I18n.hubLang == (I18n.lang.hasPrefix("zh") ? "zh" : "en"),"hub language mirrors the page's own zh/en rule")
  // 安装结果两边都要出现，所以它是 6 语言的；调用方用 lang: 选。
  let ja=MonitorHooks.apply(providers:["codex"],uninstall:false,executable:execB,lang:"ja")
  let en=MonitorHooks.apply(providers:["codex"],uninstall:false,executable:execB,lang:"en")
  check(ja["hint"] as? String != en["hint"] as? String,"install results keep all six app languages")
  // API 自己的词汇表只有 zh/en：问日文拿到的就是英文，不是键名，也不是半截中文。
  for key in ["hubapi.err.queueTimeout","hubapi.cap.approve","hubapi.note.quotas"] {
   let ja=I18n.string(key,lang:"ja"), en=I18n.string(key,lang:"en"), zh=I18n.string(key,lang:"zh")
   check(ja == en && en != key && zh != key && zh != en,"\(key) is zh/en only and falls back to en")
  }

  r=MonitorHooks.apply(providers:["claude"],uninstall:true,executable:execB)
  check(MonitorIO.json(MonitorIO.read(settingsPath))==MonitorIO.json(cfg),"uninstall restores original Claude settings")
  check(ClaudeCollector.state(execB) == .absent,"uninstall leaves no collector behind")

  // 价格表：新模型靠 LiteLLM 远端表自动定价，不靠发版。
  let lite:MObject=[
   "claude-new-9":["litellm_provider":"anthropic","mode":"chat","input_cost_per_token":4e-6,"output_cost_per_token":2e-5,"cache_read_input_token_cost":2e-7,"cache_creation_input_token_cost":5e-6,"cache_creation_input_token_cost_above_1hr":8e-6,"provider_specific_entry":["fast":2.0]],
   "gpt-new":["litellm_provider":"openai","mode":"responses","input_cost_per_token":2e-6,"output_cost_per_token":1.2e-5,"cache_read_input_token_cost":2e-7,"input_cost_per_token_priority":4e-6,
    "input_cost_per_token_above_272k_tokens":4e-6,"output_cost_per_token_above_272k_tokens":1.8e-5,"cache_read_input_token_cost_above_272k_tokens":4e-7],
   "bedrock/claude-new-9":["litellm_provider":"anthropic","mode":"chat","input_cost_per_token":1,"output_cost_per_token":1],
   "gpt-image-x":["litellm_provider":"openai","mode":"image_generation","input_cost_per_token":1e-6,"output_cost_per_token":1e-6],
   "absurd":["litellm_provider":"openai","mode":"chat","input_cost_per_token":5.0,"output_cost_per_token":1e-6]]
  let conv=MonitorPricing.convert(lite)
  check(Set(conv.keys)==["claude-new-9","gpt-new"],"LiteLLM import keeps first-party text models and drops absurd prices")
  let cn=conv["claude-new-9"] as! MObject, gn=conv["gpt-new"] as! MObject
  check(abs(MonitorIO.number(cn["cacheWrite1h"])-8)<1e-9 && MonitorIO.number(cn["fastMultiplier"])==2,"LiteLLM per-token prices become per-million with 1h write and fast mode")
  check(MonitorIO.number(gn["longAbove"])==272000 && abs(MonitorIO.number(gn["longOutput"])-18)<1e-9 && abs(MonitorIO.number(gn["fastMultiplier"])-2)<1e-9,"LiteLLM long-context and priority tiers imported")
  let pm:MObject=["claude-haiku-4-5":["input":1,"output":5],"claude-opus-5-5":["input":4,"output":20]]
  check(MonitorPricing.lookup("claude-opus-5-5[1m]",pm) != nil && MonitorPricing.lookup("us.anthropic.claude-haiku-4-5-20251001-v1:0",pm) != nil && MonitorPricing.lookup("anthropic/claude-opus-5-5",pm) != nil,"deployment wrappers and snapshot dates map to the base model")
  check(MonitorPricing.lookup("claude-opus-5-6",pm) == nil && MonitorPricing.lookup("claude-haiku-4",pm) == nil,"unknown model is never priced as a similar one")
  check(MonitorLedger.cost(["model":"<synthetic>","input":0,"output":0],prices:pm)==0,"zero-token row is free, not unpriced")
  check(abs((MonitorLedger.cost(["model":"gpt-new","input":300000,"output":1000],prices:conv) ?? -1)-(300000*4+1000*18)/1e6)<1e-12,"long-context request priced at the long tier")
  check(MonitorLedger.cost(["model":"gpt-6-astra","input":300000,"output":1],prices:["gpt-6-astra":["input":10,"output":50,"maxInput":272000]]) == nil,"long context without long prices stays unpriced")
  check(MonitorLedger.cost(["model":"gpt-6-astra","input":1000,"output":1],prices:["gpt-6-astra":["input":10,"output":50,"maxInput":272000]]) != nil,"short request under maxInput is priced")
  try MonitorIO.atomic(["version":"t","models":["claude-mine-1":["input":1,"output":2]]],MonitorPricing.overridePath)
  try MonitorIO.atomic(["version":"t","fetchedAt":now,"models":conv],MonitorPricing.remotePath)
  let merged=MonitorPricing.table()["models"] as! MObject
  check(merged["claude-mine-1"] != nil && merged["claude-new-9"] != nil && merged["claude-sonnet-5"] != nil,"bundled, remote and local price layers merge")
  check(MonitorPricing.valid(["input":10,"output":50,"maxInput":272000]) && !MonitorPricing.valid(["input":5000,"output":1]),"token thresholds are not mistaken for absurd prices")
  var ar:MObject=["sid":"ar","model":"codex-auto-review","turn":"t"]
  l.ingest("codex","ar.jsonl",MonitorIO.codex,codex(500,5,0),ordinal:0,state:&ar)
  let arTotals=l.report(period:"all",session:LocalMonitor.sessionKey("codex",MonitorIO.codex,"ar"))["totals"] as! MObject
  check(MonitorIO.number(arTotals["internalRequests"])==1 && MonitorIO.number(arTotals["unpricedRequests"])==0,"provider-internal model reported apart from missing prices")
  print("ALL MONITOR REGRESSIONS PASSED")
 }
}
