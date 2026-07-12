import Foundation

/// 面向网络审批设备（ESP32 等）的**单值审批状态**，供 `/state` 长轮询读取。
///
/// 现有模型：同一时刻只有一个待审批（`ApprovalController.inFlight`），所以这里就是一个
/// 单值状态机 `idle → pending(某条命令) → idle`，不是消息队列。
///
/// 用**单调递增的 version**表达"审批动态"：pending 出现 / 被解决 / 超时清空，各让 version +1。
/// 设备带上"上次看到的 version"来长轮询：
///   · 服务端 version 已更新 → 立即返回当前快照；
///   · 否则挂起，直到状态变化（唤醒等待者）或调用方设定的 wait 秒超时。
/// version 游标同时覆盖"新 pending"和"被清空"，且**不怕丢事件**——设备断线重连带旧 version
/// 一问就能对齐到最新状态，不像边沿触发会漏掉一次。
///
/// 线程：`setPending`/`clear` 在主线程（审批控制器），`waitOrRegister`/快照读取在服务端 queue，
/// 全部用一把 `NSLock` 串起来，故标记 `@unchecked Sendable`。
final class DeviceApprovalState: @unchecked Sendable {
    private struct Pending {
        let id: String
        let operation: String
        let tool: String
        let cwd: String
        let expiresAt: Date
        let dangerous: Bool
    }

    private let lock = NSLock()
    // 从 1 起：初始 idle 也算"版本 1"，这样客户端首次用 since=0 轮询能立刻拿到当前状态，
    // 而不是把"从没见过任何版本(0)"误当成"已看到版本 0"而挂起等超时。
    private var version: UInt64 = 1
    private var pending: Pending?
    /// 挂起的长轮询等待者：状态一变全部唤醒，各自重新读快照回包。
    private var waiters: [([String: Any]) -> Void] = []

    // MARK: 写入（主线程，审批生命周期驱动）

    func setPending(id: String, operation: String, tool: String, cwd: String,
                    expiresAt: Date, dangerous: Bool) {
        lock.lock()
        pending = Pending(id: id, operation: operation, tool: tool, cwd: cwd,
                          expiresAt: expiresAt, dangerous: dangerous)
        version &+= 1
        let snap = Self.json(version: version, pending: pending)
        let woken = waiters; waiters = []
        lock.unlock()
        woken.forEach { $0(snap) }
    }

    /// 只清除 id 匹配的那条（避免旧审批的收尾误清掉刚出现的新审批）。
    func clear(id: String) {
        lock.lock()
        guard pending?.id == id else { lock.unlock(); return }
        pending = nil
        version &+= 1
        let snap = Self.json(version: version, pending: pending)
        let woken = waiters; waiters = []
        lock.unlock()
        woken.forEach { $0(snap) }
    }

    // MARK: 读取（服务端 queue）

    var currentVersion: UInt64 { lock.lock(); defer { lock.unlock() }; return version }
    func currentPendingID() -> String? { lock.lock(); defer { lock.unlock() }; return pending?.id }
    func snapshotJSON() -> [String: Any] { lock.lock(); defer { lock.unlock() }; return Self.json(version: version, pending: pending) }

    /// 长轮询核心：version 已比 `since` 新则立刻回快照；否则登记等待者，等状态变化再回。
    /// 超时由调用方（服务端）自己排一个定时兜底回当前快照。
    func waitOrRegister(since: UInt64, _ reply: @escaping ([String: Any]) -> Void) {
        lock.lock()
        if version > since {
            let snap = Self.json(version: version, pending: pending)
            lock.unlock()
            reply(snap)
            return
        }
        waiters.append(reply)
        lock.unlock()
    }

    // MARK: JSON

    private static func json(version: UInt64, pending: Pending?) -> [String: Any] {
        guard let p = pending else { return ["version": version, "state": "idle"] }
        let remainingMs = max(0, Int(p.expiresAt.timeIntervalSinceNow * 1000))
        return [
            "version": version,
            "state": "pending",
            "id": p.id,
            "operation": p.operation,
            "tool": p.tool,
            "cwd": p.cwd,
            "deadline_ms": remainingMs,
            "dangerous": p.dangerous,
        ]
    }
}
