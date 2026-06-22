import Foundation

/// 本地 LLM「智能放行」守门员(可选、默认关)。
///
/// 主 app 侧:管理 helper daemon 的生命周期,并向它发命令安全性判断请求。
/// helper(`GestureGatekeeper`,链接 MLX 跑本地 Qwen)单独按需下载、常驻,
/// 监听 `127.0.0.1:47601`,收到 `{operation,cwd,tool}` 回 `{safe:bool}`。
///
/// **fail-safe 铁律**:开关关 / helper 没装 / daemon 没起 / 超时 / 判定不安全
/// → 一律返回 `false`(=照常弹手势)。守门员**只会让明显安全的命令免审,从不自动拒绝**——
/// 危险命令的兜底永远是 deny-list + 手势。
final class Gatekeeper {
    static let shared = Gatekeeper()
    static let port: UInt16 = 47601
    static let enabledKey = "smartGateEnabled"

    /// 智能放行开关(默认关,用户在设置里主动开启)。
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }   // 缺省 false
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    // MARK: 按需下载(方案 B)
    /// helper 单独发布在固定 tag 的 release 里,与 app 发版解耦;只有 helper 本身更新才改这个 tag。
    static let helperTag = "gatekeeper-helper-v1"
    /// 预编译 helper 的下载地址(GitHub Release 固定资产名,跨 app 版本不变)。复用 Updater 的仓库。
    static var helperURL: URL {
        URL(string: "https://github.com/\(Updater.repo)/releases/download/\(helperTag)/GestureGatekeeper-helper.zip")!
    }
    /// 下载/解压脚本(bundle 内只读;开发期回退仓库)。
    static var downloadScript: String { AppPaths.resource("bridge/download_gatekeeper.sh") }
    /// 安装目录(按需下载落地处)。
    static var installDir: String { AppPaths.supportPath("gatekeeper") }

    // MARK: 安装位置(优先已下载的;开发期回退仓库 xcodebuild 产物)
    static var helperBinary: String {
        let installed = (installDir as NSString).appendingPathComponent("GestureGatekeeper")
        if FileManager.default.fileExists(atPath: installed) { return installed }
        // 源码开发回退:xcodebuild 产物(必须用 xcodebuild,swift build 编不出 Metal shaders)。
        // 该目录同时含 mlx-swift_Cmlx.bundle(metallib),与二进制同目录,运行时能找到。
        return (HookInstaller.repoRoot() as NSString)
            .appendingPathComponent("GestureApprove/.build/xcode/Build/Products/Release/GestureGatekeeper")
    }

    /// 就绪 = **安装目录(Application Support)里** 二进制 + metallib bundle + 模型权重 都在。
    /// 只认安装目录,不看开发期 .build 回退(否则开发机上没装也误判「就绪」)。
    /// 模型也要在(models/ 下有 .safetensors),否则视为未就绪→引导重新下载,
    /// 也避免 daemon 启动时静默下 ~1GB(改由下载窗显式预取)。
    static var isInstalled: Bool {
        let fm = FileManager.default
        let bin = (installDir as NSString).appendingPathComponent("GestureGatekeeper")
        let bundle = (installDir as NSString).appendingPathComponent("mlx-swift_Cmlx.bundle")
        guard fm.isExecutableFile(atPath: bin), fm.fileExists(atPath: bundle) else { return false }
        let modelsDir = URL(fileURLWithPath: (installDir as NSString).appendingPathComponent("models"))
        if let en = fm.enumerator(at: modelsDir, includingPropertiesForKeys: nil) {
            for case let f as URL in en where f.pathExtension == "safetensors" { return true }
        }
        return false
    }

    private var proc: Process?
    private let lock = NSLock()

    // MARK: daemon 生命周期
    /// 按需启动 helper daemon(仅当开关开 + 已安装 + 未在运行)。
    func startIfNeeded() {
        guard Gatekeeper.isEnabled, Gatekeeper.isInstalled else { return }
        lock.lock(); defer { lock.unlock() }
        if let p = proc, p.isRunning { return }
        // 先清掉任何残留 daemon(上次运行/其它 app 实例遗留),避免进程堆积 + 同端口多绑。
        Self.killStrayDaemons()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Gatekeeper.helperBinary)
        p.arguments = ["--serve", "--port", String(Gatekeeper.port)]
        // helper 自己把日志写文件;这里丢弃管道避免阻塞。
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            proc = p
            GALog.log("守门员 daemon 已启动 (pid \(p.processIdentifier))")
        } catch {
            GALog.log("守门员 daemon 启动失败: \(error)")
        }
    }

    /// 停止 daemon(关闭开关 / app 退出时调用)。连残留实例一并清掉。
    func stop() {
        lock.lock(); defer { lock.unlock() }
        proc?.terminate()
        proc = nil
        Self.killStrayDaemons()
        GALog.log("守门员 daemon 已停止")
    }

    /// 杀掉所有 `GestureGatekeeper --serve` 进程(本 app 没追踪到的历史残留也清)。
    /// daemon 不是 app 的子进程托管对象,跨重启会堆积;靠这个收口。
    private static func killStrayDaemons() {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", "GestureGatekeeper --serve"]
        try? kill.run()
        kill.waitUntilExit()
    }

    // MARK: 判断
    /// 问 helper:这条命令是否「明显安全、可免审放行」。
    /// 失败/超时/未就绪/不安全一律返回 false(fail-safe → 弹手势)。
    func judge(operation: String, cwd: String?, tool: String?) async -> Bool {
        guard Gatekeeper.isEnabled, Gatekeeper.isInstalled else { return false }
        guard let url = URL(string: "http://127.0.0.1:\(Gatekeeper.port)/judge") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 5.0          // 守门员要快;超时即回退手势(小模型首 token + 推理留足余量)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: String] = [
            "operation": operation,
            "cwd": cwd ?? "",
            "tool": tool ?? "",
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let safe = obj["safe"] as? Bool {
                return safe
            }
        } catch {
            // daemon 没起 / 模型还在加载 / 超时 → fail-safe
            GALog.log("守门员判断失败(回退手势): \(error.localizedDescription)")
        }
        return false
    }
}
