import Foundation
import AppKit
import ServiceManagement

/// 开机自启 + 崩溃自愈。
///
/// 自管一个 `~/Library/LaunchAgents/` 下的 LaunchAgent（不用 `SMAppService.agent`——后者
/// 的 register() 在本项目实测会静默失败、不进 BTM、极难调试）：
///   · `RunAtLoad` → 登录时自动起；
///   · `KeepAlive = { SuccessfulExit = false }` → **异常退出（崩溃/被杀）**后由 launchd 自动拉起
///     （有 ~10s 节流），而正常退出(exit 0)不拉起，用户仍能主动退出。
/// 用 `launchctl bootstrap/bootout` 加载/卸载，行为可用 `launchctl print` 直接核验。
enum LaunchAtLogin {
    static let label = "xyz.anome.gestureapprove.login"

    private static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    private static var uid: String { String(getuid()) }
    private static var serviceTarget: String { "gui/\(uid)/\(label)" }

    /// 以「plist 是否存在」为准：enable 必写、disable 必删，二者同步。
    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func set(_ on: Bool) throws {
        try? SMAppService.mainApp.unregister()   // 清掉历史登录项式注册，避免双重启动
        if on { try enable() } else { disable() }
    }

    // MARK: - 启用

    /// 只写 plist，**不**立刻 bootstrap/重启当前 app。
    /// `~/Library/LaunchAgents/` 下的 agent 会在下次登录由 launchd 自动加载，届时 RunAtLoad 自启、
    /// KeepAlive 崩溃自愈一并生效——和系统里任何「登录时打开」的 app 一样，改设置不当场重启。
    private static func enable() throws {
        guard let exec = Bundle.main.executablePath else { return }
        let plist: [String: Any] = [
            "Label": label,
            "Program": exec,                                   // 绝对路径，指向当前 .app 的可执行
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],            // 仅异常退出（崩溃/被杀）才重启
            "ProcessType": "Interactive",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: plistURL)
    }

    // MARK: - 停用

    private static func disable() {
        // 仅当 launchd 此刻确实在托管本 job（重新登录后才会）时，bootout 会终止当前实例——
        // 那种情况下先 detach 一个延迟 open 接班保活；未加载时直接删 plist，不打扰当前实例。
        let loaded = isLoaded()
        launchctl("bootout", serviceTarget)
        try? FileManager.default.removeItem(at: plistURL)
        if loaded { reopenDetached() }
    }

    private static func isLoaded() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["print", serviceTarget]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private static func reopenDetached() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 3; open \"\(Bundle.main.bundlePath)\""]
        try? p.run()
    }

    // MARK: - launchctl

    private static func launchctl(_ args: String...) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }
}
