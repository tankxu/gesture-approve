import Foundation

enum UsageKind { case claude, codex }
// Legacy cases remain for saved preferences; collection is always local-only.
enum UsageSource: String { case local, ask, chrome, keychain }
enum ChromeIssue { case noTab, jsDisabled, accountMismatch, other }
enum UsageAskReason { case firstTime, chromeBroken(ChromeIssue) }
/// `pool` 只在一个工具同时有多个额度池时非空（比如 Codex 的订阅额度之外另给一份模型专属额度）。
/// 单池时它是 nil —— 给唯一一行标上池名，只是在每行前面糊一段谁都一样的字。
struct UsageWindow { let label: String; let pool: String?; let percent: Double?; let resetsAt: Date? }
struct ToolUsage { let kind: UsageKind; let name: String; let running: Int; let windows: [UsageWindow]; let note: String? }
final class UsageMonitor {
    static let shared=UsageMonitor()
    static let enabledKey="usageInMenu", sourceKey="usageSource"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey:enabledKey) as? Bool ?? true }
    static var source: UsageSource { get { .local } set {} }
    /// 采集开关和显示开关是两回事：会话是从 transcript 扫出来的，不装采集器也能显示"谁在跑"；
    /// 额度只有 Claude 的 statusLine hook 给得出来。默认 false —— 往 ~/.claude/settings.json
    /// 里写东西必须是用户自己点的，不能因为菜单默认显示额度就替他装上。
    static let collectKey="usageCollect"
    static var collecting: Bool {
        get { UserDefaults.standard.bool(forKey:collectKey) }
        set { UserDefaults.standard.set(newValue,forKey:collectKey) }
    }
    /// 开着、但配置不在位（app 换了路径、statusLine 被别的工具换走、用户手改过）→ 补装一次，
    /// 让"开着"永远等于"真的在采"。只在用户自己开过采集时才写文件。
    @discardableResult
    static func repairIfNeeded() -> [String] {
        guard collecting else { return [] }
        let ids=MonitorHooks.needingRepair()
        guard !ids.isEmpty else { return [] }
        _=MonitorHooks.apply(providers:ids,uninstall:false)
        return ids
    }
    /// 额度这段为什么没数 —— 三种完全不同的情况，以前长一个样（都是"还没有额度数据"）。
    enum CollectHint: String { case off="usage.collectOff", broken="usage.collectBroken", waiting="usage.collectWaiting" }
    static func hint(_ rows: [ToolUsage]) -> CollectHint? {
        guard isEnabled else { return nil }
        let blank=rows.allSatisfy { $0.windows.isEmpty }
        guard collecting else { return blank ? .off : nil }
        // 配置失效要一直说，哪怕还留着上一次的数字 —— 那些数字只会越来越旧。
        if !MonitorHooks.needingRepair().isEmpty { return .broken }
        return blank ? .waiting : nil
    }
    static var snoozedUntil: Date? = nil
    static var isSnoozed: Bool { false }
    static func snooze() {}
    static func endSnooze() {}
    private(set) var pendingAsk: UsageAskReason? = nil
    func clearPendingAsk() {}
    private(set) var snapshot: [ToolUsage]=[]
    func refresh(_ done: @escaping ([ToolUsage])->Void) {
        let m=LocalMonitor.shared
        m.queue.async {
            let accounts=m.quotas()["accounts"] as? [MObject] ?? []
            let sessions=m.sessions(limit:1000)["sessions"] as? [MObject] ?? []
            let rows=[("claude",UsageKind.claude,"Claude Code"),("codex",.codex,"Codex")].compactMap { provider,kind,name -> ToolUsage? in
                // `current` 只留最近一次上报里出现、且窗口还没滚过去的池：换过套餐、换过账号的旧池
                // 在库里留着是对的（它们是真发生过的观测），画进菜单就成了一屏读不懂的重影。
                let live=accounts.filter { $0["provider"] as? String == provider && $0["current"] as? Bool == true }
                                 .sorted { MonitorIO.number($0["receivedAt"]) > MonitorIO.number($1["receivedAt"]) }
                let named=live.count>1
                let windows=live.flatMap { q -> [UsageWindow] in
                    (q["windows"] as? [MObject] ?? [])
                        .filter { $0["expired"] as? Bool == false }
                        .sorted { MonitorIO.number($0["windowMinutes"]) < MonitorIO.number($1["windowMinutes"]) }
                        .map { w -> UsageWindow in
                            let reset=MonitorIO.number(w["resetsAt"])
                            return UsageWindow(label:Self.windowLabel(MonitorIO.number(w["windowMinutes"])),
                                               pool:named ? (Self.poolName(q) ?? L("usage.poolDefault")) : nil,
                                               percent:MonitorIO.number(w["usedPercent"]),
                                               resetsAt:reset>0 ? Date(timeIntervalSince1970:reset) : nil)
                        }
                }
                let running=sessions.filter { $0["provider"] as? String == provider && $0["activity"] as? String == "working" }.count
                // 既没在跑、也没有能看的额度 —— 这一段除了工具名什么都说不出来，不如不占位置。
                guard !windows.isEmpty || running>0 else { return nil }
                return ToolUsage(kind:kind,name:name,running:running,windows:windows,note:Self.note(live,windows))
            }
            DispatchQueue.main.async { self.snapshot=rows;done(rows) }
        }
    }
    /// 「5h」「7d」。服务端给的是分钟数，能整除就往上进一级，进不了才落回分钟。
    static func windowLabel(_ minutes: Double) -> String {
        let m=Int(minutes.rounded())
        if m>0 && m%1440==0 { return "\(m/1440)d" }
        if m>0 && m%60==0 { return "\(m/60)h" }
        return "\(m)m"
    }
    /// limit_id 是服务端内部键（`codex_bengalfox`），不该出现在菜单里；limit_name 才是给人看的
    /// （`GPT-5.3-Codex-Spark`）。拿不到可读名就返回 nil —— 宁可不标，也不把内部键甩给用户。
    static func poolName(_ q: MObject) -> String? {
        let name=(q["limitName"] as? String ?? "").trimmingCharacters(in:.whitespaces)
        guard !name.isEmpty, name != q["limitId"] as? String, name != "subscription" else { return nil }
        return String(name.prefix(28))
    }
    /// 额度行底下那句话。数值是「最近一次本地观测」，所以真正该说的是它有多旧 ——
    /// 原来那句「未强制刷新账户」对每个工具、每个时刻都一样，等于没说。
    static func note(_ accounts: [MObject], _ windows: [UsageWindow]) -> String? {
        guard !windows.isEmpty else { return L("usage.noSnapshot") }
        let age=accounts.map { max(0,Date().timeIntervalSince1970-MonitorIO.number($0["lastChangedAt"])) }.min() ?? 0
        // 不到一分钟就别报「1m 前」——compact 的最小刻度是分钟，刚拿到的数说成一分钟前是硬凑的。
        return age<60 ? L("usage.observedNow") : String(format:L("usage.observed"),UsageMenuSection.compact(age))
    }
    struct ClaudeSession { let pid: Int32; let version: String? }
    static func liveClaudeSessions() -> [ClaudeSession] {
        ((try? FileManager.default.contentsOfDirectory(atPath:MonitorIO.claude+"/sessions")) ?? []).compactMap { file in
            let row=MonitorIO.read(MonitorIO.claude+"/sessions/"+file),pid=Int(MonitorIO.number(MonitorIO.read(MonitorIO.claude+"/sessions/"+file)["pid"]))
            return MonitorIO.alive(pid) ? ClaudeSession(pid:Int32(pid),version:row["version"] as? String) : nil
        }
    }
    static func processCount(named name: String) -> Int { let (_,d)=MonitorIO.run("/usr/bin/pgrep",["-x",name]);return (String(data:d,encoding:.utf8) ?? "").split(separator:"\n").count }
}
