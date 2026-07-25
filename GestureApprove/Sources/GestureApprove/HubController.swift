import Foundation

/// 监管本机的 Remote Hub(独立 Python 服务 hub/hub.py:远程看会话/语音/回复)。
/// GA 当"常驻监工":spawn/kill 那个进程,并用 /health 探测运行状态给 tray 显示。
/// 与 hub 松耦合——只按路径拉起它、按 pkill 收掉,不 import 任何 hub 代码。
final class HubController {
    static let enabledKey = "hubEnabled"       // 持久开关:GA 启动时据此自动拉起
    static let cltPromptKey = "hubCLTPromptShown"  // 缺命令行工具的提示是否已弹过(自动启动只弹一次)
    static let port = 8787

    private var proc: Process?
    private let lock = NSLock()

    static var isEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// hub/hub.py 的绝对路径:release 用打包进 .app 的副本(Contents/Resources/hub/),
    /// 源码开发(swift run,bundle 里没打包)自动回退仓库根。demo.html/config.html 与它同目录。
    private func scriptPath() -> String {
        AppPaths.resource("hub/hub.py")
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
        guard HubController.isEnabled else { return }
        // 自动拉起也算"第一次启动服务":缺工具则弹提示+系统安装**一次**(之后每次登录不再打扰)。
        let firstTime = !UserDefaults.standard.bool(forKey: Self.cltPromptKey)
        start(promptIfMissing: firstTime)
    }

    /// 启动 hub。`promptIfMissing`=true(用户主动点开时)在缺命令行工具时弹提示并唤起系统安装。
    /// 返回是否已(或已在)运行——调用方据此决定要不要打开网页,避免打开一个连不上的空白页。
    @discardableResult
    func start(promptIfMissing: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let p = proc, p.isRunning { return true }
        // /usr/bin/python3 是 stub:没装命令行工具时它只会弹系统安装框、跑不了 hub。先探一下。
        guard Self.hasDevTools() else {
            if promptIfMissing {
                UserDefaults.standard.set(true, forKey: Self.cltPromptKey)  // 记下已弹,自动启动不再每次打扰
                Self.promptInstallDevTools()
            } else {
                GALog.log("Remote Hub: 缺命令行工具(python3),跳过自动启动")
            }
            return false
        }
        Self.killStray()
        let script = scriptPath()
        guard FileManager.default.fileExists(atPath: script) else {
            GALog.log("Remote Hub: 找不到 \(script)"); return false
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
            return true
        } catch {
            GALog.log("Remote Hub 启动失败: \(error)")
            return false
        }
    }

    /// 是否已装命令行工具(CLT/Xcode)。`xcode-select -p` 只查询、不弹框:退出 0 且路径存在即有。
    static func hasDevTools() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return false }
        let path = (String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }

    /// 缺命令行工具时:**同时**(1)唤起 macOS 自带的命令行工具安装框、(2)发一条 GA 通知说明缘由。
    /// 不再多一层"先点 GA 的安装按钮"——第一次启动服务即直接把系统安装弹出来。
    private static func promptInstallDevTools() {
        let x = Process()
        x.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        x.arguments = ["--install"]
        try? x.run()   // 弹出 macOS 自带的命令行工具安装对话框
        Notifier.post(title: L("hub.needCLT.title"), body: L("hub.needCLT.body"))
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
