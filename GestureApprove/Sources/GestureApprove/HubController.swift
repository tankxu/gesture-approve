import Foundation

/// 监管本机的 Remote Hub(独立 Python 服务 hub/hub.py:远程看会话/语音/回复)。
/// GA 当"常驻监工":spawn/kill 那个进程,并用 /health 探测运行状态给 tray 显示。
/// 与 hub 松耦合——只按路径拉起它、按 pkill 收掉,不 import 任何 hub 代码。
final class HubController {
    static let enabledKey = "hubEnabled"       // 持久开关:GA 启动时据此自动拉起
    static let port = 8787

    private var proc: Process?
    private let lock = NSLock()

    static var isEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// hub/hub.py 的绝对路径(仓库内)。
    private func scriptPath() -> String {
        var root = ""
        if let r = Bundle.main.object(forInfoDictionaryKey: "RepoRoot") as? String,
           FileManager.default.fileExists(atPath: r) {
            root = r
        } else {
            var p = Bundle.main.bundlePath
            for _ in 0..<4 { p = (p as NSString).deletingLastPathComponent }
            root = p
        }
        return (root as NSString).appendingPathComponent("hub/hub.py")
    }

    /// 探 /health 判断 hub 是否在跑(本 app 起的、或手动起的都算)。异步回主线程外的调用方自理。
    func checkRunning(_ done: @escaping (Bool) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:\(HubController.port)/health") else { done(false); return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.0
        URLSession.shared.dataTask(with: req) { data, _, err in
            done(err == nil && data != nil)
        }.resume()
    }

    func startIfEnabled() {
        if HubController.isEnabled { start() }
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        if let p = proc, p.isRunning { return }
        Self.killStray()
        let script = scriptPath()
        guard FileManager.default.fileExists(atPath: script) else {
            GALog.log("Remote Hub: 找不到 \(script)"); return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [script]
        p.currentDirectoryURL = URL(fileURLWithPath: (script as NSString).deletingLastPathComponent)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            proc = p
            GALog.log("Remote Hub 已启动 (pid \(p.processIdentifier))")
        } catch {
            GALog.log("Remote Hub 启动失败: \(error)")
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        proc?.terminate()
        proc = nil
        Self.killStray()
        GALog.log("Remote Hub 已停止")
    }

    /// 收掉所有 hub.py 进程(本 app 没追踪到的手动/残留实例也清)。
    private static func killStray() {
        let k = Process()
        k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        k.arguments = ["-f", "hub.py"]
        try? k.run()
        k.waitUntilExit()
    }
}
