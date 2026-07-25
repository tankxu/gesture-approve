import Foundation

/// 监管本机的 Remote Hub。**已从独立 Python 服务改为 Swift 原生**(HubServer + HubApp,同进程内),
/// 零外部依赖——不再 spawn python3、无 CLT 依赖。GA 负责起停;局域网开关走 server rebind。
final class HubController {
    static let enabledKey = "hubEnabled"       // 持久开关:GA 启动时据此自动拉起
    static let port = 8787

    private var server: HubServer?
    private var app: HubApp?
    private let lock = NSLock()

    static var isEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    func startIfEnabled() {
        if HubController.isEnabled { start() }
    }

    /// 起 Swift 原生 hub。幂等:已在跑则忽略。返回是否处于运行态(为兼容旧调用点仍给 Bool)。
    @discardableResult
    func start() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if server?.isRunning == true { return true }
        Self.killStrayPython()   // 清掉旧版独立 Python hub(升级过渡),避免占用 8787
        let app = HubApp(port: HubController.port)
        app.onSetLan = { [weak self] on in self?.server?.rebind(lan: on) }
        app.onStop = { [weak self] in self?.stop() }
        let server = HubServer(port: UInt16(HubController.port), lan: HubApp.lanEnabled(), router: app.route)
        server.start()
        self.app = app
        self.server = server
        GALog.log("Remote Hub(Swift 原生)已启动 :\(HubController.port)")
        return true
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        server?.stop()
        server = nil
        app = nil
        GALog.log("Remote Hub 已停止")
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return server?.isRunning == true }

    /// 兼容旧调用点(main.openHub 等):同进程内即时返回运行态。
    func checkRunning(_ done: @escaping (Bool) -> Void) { done(isRunning) }

    /// 清掉历史遗留的独立 Python hub 进程(旧版本用 `python3 hub.py`)。
    private static func killStrayPython() {
        let k = Process()
        k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        k.arguments = ["-f", "hub.py"]
        try? k.run()
        k.waitUntilExit()
    }
}
