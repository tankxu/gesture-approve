import AppKit
import AVFoundation
import Vision
import CoreGraphics
import ImageIO
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let controller = ApprovalController()
    private var server: ApprovalServer?
    private let settingsWC = SettingsWindowController()
    private let logWC = ApproveLogWindowController()
    private let flashWC = ScriptWindowController()
    private let mpInstallWC = ScriptWindowController()
    private let gkInstallWC = ScriptWindowController()

    private var port: UInt16 {
        if let s = ProcessInfo.processInfo.environment["GESTURE_APPROVE_PORT"],
           let v = UInt16(s) { return v }
        return 47600
    }

    private var approvalEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: "approvalEnabled") as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "approvalEnabled") }
    }
    private var enabledItem: NSMenuItem?
    private var updateItem: NSMenuItem?                                      // 「更新到 vX」菜单项（默认隐藏）
    private var updateTimer: Timer?
    private var pendingUpdate: (version: String, asset: URL, page: URL, notes: String)?

    /// 系统睡眠：靠 willSleep/didWake 维护（didWake 必达，可靠）。
    private var asleep = false
    /// 屏幕是否锁定——**每次实时查询，不缓存**。
    /// 锁屏/解锁走 DistributedNotificationCenter，从长时间睡眠/Power Nap 恢复时通知可能丢失或延迟；
    /// 一旦“解锁”通知丢了，缓存标志会永久卡在锁定态，手势再不接管、approve 一直回退 CLI（过夜唤醒的 bug）。
    /// 实时查 CGSession 则通知丢了也无所谓——每次审批都问一次真实状态。
    private var screenLocked: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let b = info["CGSSessionScreenIsLocked"] as? Bool { return b }
        if let i = info["CGSSessionScreenIsLocked"] as? Int { return i != 0 }
        return false
    }
    private var systemSuspended: Bool { screenLocked || asleep }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例：新实例接管、终止其它同 bundle 实例。配合 launchd KeepAlive，
        // 确保「受 launchd 管理的实例」胜出（崩溃自愈才有意义），也避免双菜单栏图标/端口冲突。
        let myPID = ProcessInfo.processInfo.processIdentifier
        if let bid = Bundle.main.bundleIdentifier {
            for other in NSRunningApplication.runningApplications(withBundleIdentifier: bid)
                where other.processIdentifier != myPID {
                other.terminate()
            }
        }
        UserDefaults.standard.register(defaults: [
            "gestureMinConf": 0.6,   // 默认识别精准度 60%
            // 默认引擎：已装 MediaPipe 则用它，否则用内置 Vision
            MediaPipeInstaller.engineKey: MediaPipeInstaller.isInstalled() ? "mediapipe" : "vision",
        ])
        Notifier.requestAuthorization()
        AVCaptureDevice.requestAccess(for: .video) { _ in }   // 首次弹相机授权
        setupStatusItem()
        registerHotkeys()
        startServer()
        Gatekeeper.shared.startIfNeeded()   // 智能放行守门员 daemon（仅开关开+已装才起；会先清残留）
        observeSystemState()
        // 后台检查更新：启动时 + 每 24h；有新版只在菜单栏菜单加一项，不弹窗不通知。
        checkForUpdate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForUpdate() }
        }
        GALog.log("启动：screenLocked=\(screenLocked) asleep=\(asleep)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        Gatekeeper.shared.stop()            // 退出时收掉 daemon，别留残留进程
    }

    /// 监听屏幕锁定/解锁、系统睡眠/唤醒：
    ///   · 锁屏/睡眠 → 暂停审批（approve 直接回退终端，不弹无人能操作的卡片）；
    ///   · 解锁/唤醒 → 各自清除对应标志；只有锁屏与睡眠都解除才真正恢复审批；
    ///   · 唤醒/解锁都顺带重启监听（NWListener 可能在睡眠期间静默失效）。
    private func observeSystemState() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(onSystemEvent(_:)),
                       name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(onSystemEvent(_:)),
                       name: NSWorkspace.didWakeNotification, object: nil)
        // 锁屏/解锁没有 NSWorkspace 通知，走 DistributedNotificationCenter 的私有事件名。
        let dc = DistributedNotificationCenter.default()
        dc.addObserver(self, selector: #selector(onSystemEvent(_:)),
                       name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        dc.addObserver(self, selector: #selector(onSystemEvent(_:)),
                       name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    @objc private func onSystemEvent(_ note: Notification) {
        switch note.name.rawValue {
        case "com.apple.screenIsLocked":            break   // 锁屏状态由 screenLocked 实时查询反映，无需缓存
        case "com.apple.screenIsUnlocked":          server?.restart(); controller.handleSystemWake()
        case NSWorkspace.willSleepNotification.rawValue: asleep = true
        case NSWorkspace.didWakeNotification.rawValue:   asleep = false; server?.restart(); controller.handleSystemWake()
        default: return
        }
        // restart() 只是复活监听（与手势开关无关，hook 始终需要能连上拿到 ask）；
        // 是否真正弹手势卡片仍由 approve 流程里的 approvalEnabled + systemSuspended 把关，这里不强开用户关掉的审批。
        GALog.log("系统事件 \(note.name.rawValue) → 锁屏=\(screenLocked) 睡眠=\(asleep) 审批\(systemSuspended ? "暂停" : "恢复")")
    }

    private func registerHotkeys() {
        HotKeyManager.shared.register(keyCode: HotKeyManager.keyY,
                                      modifiers: HotKeyManager.controlShift) { [weak self] in
            self?.controller.resolveByHotkey(approve: true)
        }
        HotKeyManager.shared.register(keyCode: HotKeyManager.keyN,
                                      modifiers: HotKeyManager.controlShift) { [weak self] in
            self?.controller.resolveByHotkey(approve: false)
        }
    }

    private func startServer() {
        let server = ApprovalServer(port: port) { [weak self] req, reply in
            DispatchQueue.main.async {
                guard let self else { reply("ask", L("reply.notReady")); return }
                // 总开关关闭 -> 直接交回终端正常审批，不弹卡片
                guard self.approvalEnabled else {
                    ApproveLog.record(req, decision: "ask", gate: .gatingOff, dangerous: Allowlist.isDangerous(req.operation))
                    reply("ask", L("reply.gatingOff")); return
                }
                // 屏幕锁定/睡眠 -> 用户无法比手势，直接交回终端，不弹无人操作的卡片
                guard !self.systemSuspended else {
                    ApproveLog.record(req, decision: "ask", gate: .suspended, dangerous: Allowlist.isDangerous(req.operation))
                    reply("ask", L("reply.suspended")); return
                }
                // 白名单命中且整条安全 -> 直接放行，不打扰（危险/拼接命令仍要手势）
                if Allowlist.autoAllows(req.operation) {
                    ApproveLog.record(req, decision: "allow", gate: .allowlist, dangerous: false)
                    reply("allow", L("reply.allowlist")); return
                }
                // 智能放行（可选，默认关）：规则没放行、且**不危险**时问本地 LLM 守门员——
                // 含组合命令（&& | ; 等）：LLM 看整条，能识别藏在拼接后的真实意图，比"前缀白名单"
                // 那种只看头部的判断更可靠，所以组合命令在这里交给 LLM 裁决而非直接落手势。
                // 仅「LLM 明确说 safe」免审；不可用/超时/不安全 → fail-safe 落手势。
                // 危险命令（deny-list 命中整条，组合命令里任一危险片段都会命中）永不进 LLM，
                // 直接走手势——LLM 只是额外放行器，绝不裁决危险命令；保底闸不变。
                if Gatekeeper.isEnabled,
                   !Allowlist.isDangerous(req.operation) {
                    Task { @MainActor in
                        if await Gatekeeper.shared.judge(operation: req.operation, cwd: req.cwd, tool: req.tool) {
                            ApproveLog.record(req, decision: "allow", gate: .smartgate, dangerous: false)
                            reply("allow", L("reply.smartgate"))
                        } else {
                            self.askGesture(req, reply)
                        }
                    }
                    return
                }
                self.askGesture(req, reply)
            }
        }
        do { try server.start(); self.server = server }
        catch { NSLog("GestureApprove: 服务启动失败 \(error)（端口可能被占用）") }
    }

    /// 弹手势卡片等用户裁决（白名单/智能放行都没放行时的最终路径）。
    private func askGesture(_ req: ApprovalRequest, _ reply: @escaping (String, String) -> Void) {
        let dangerous = Allowlist.isDangerous(req.operation)
        controller.requestApproval(operation: req.operation, cwd: req.cwd, tool: req.tool, timeout: 90) { outcome in
            switch outcome {
            case .approved:
                ApproveLog.record(req, decision: "allow", gate: .gesture, dangerous: dangerous)
                reply("allow", L("reply.approved"))
            case .alwaysAllowed:
                ApproveLog.record(req, decision: "allow", gate: .alwaysAllow, dangerous: dangerous)
                reply("allow", L("reply.approved"))
            case .denied:
                ApproveLog.record(req, decision: "deny", gate: .gesture, dangerous: dangerous)
                reply("deny", L("reply.denied"))
            case .timedOut:
                ApproveLog.record(req, decision: "ask", gate: .timeout, dangerous: dangerous)
                reply("ask", L("reply.timeout"))   // 不再自动拒绝
            }
        }
    }

    @objc private func toggleEnabled() {
        approvalEnabled.toggle()
        enabledItem?.state = approvalEnabled ? .on : .off
    }

    // MARK: 菜单

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let path = Bundle.main.path(forResource: "TrayIcon", ofType: "png"),
           let img = NSImage(contentsOfFile: path) {
            let h: CGFloat = 18
            img.size = NSSize(width: h * img.size.width / max(img.size.height, 1), height: h)
            img.isTemplate = true   // 模板图：自动适配深/浅色菜单栏
            item.button?.image = img
        } else {
            item.button?.image = NSImage(systemSymbolName: "hand.thumbsup",
                                         accessibilityDescription: L("app.name"))
        }
        let menu = NSMenu()
        menu.addItem(withTitle: L("menu.running"), action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        // 「更新到 vX.Y.Z」——默认隐藏，后台检查发现新版后才显示（最安静：不弹窗、不通知，不点即跳过）。
        let update = NSMenuItem(title: "", action: #selector(updateNow), keyEquivalent: "")
        update.target = self
        update.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
        update.isHidden = true
        menu.addItem(update)
        self.updateItem = update

        let enabled = NSMenuItem(title: L("menu.enable"), action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.target = self
        enabled.state = approvalEnabled ? .on : .off
        enabled.image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)
        menu.addItem(enabled)
        self.enabledItem = enabled

        menu.addItem(.separator())

        // 开机自启移到「设置」窗（避免两处状态不一致）。

        let settings = NSMenuItem(title: L("menu.settings"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settings)

        let test = NSMenuItem(title: L("menu.test"), action: #selector(testApproval), keyEquivalent: "t")
        test.target = self
        test.image = NSImage(systemSymbolName: "hand.thumbsup", accessibilityDescription: nil)
        menu.addItem(test)

        let log = NSMenuItem(title: L("menu.log"), action: #selector(openLog), keyEquivalent: "l")
        log.target = self
        log.image = NSImage(systemSymbolName: "list.bullet.rectangle", accessibilityDescription: nil)
        menu.addItem(log)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quit)

        item.menu = menu
        self.statusItem = item
    }

    // MARK: 后台检查更新（最安静：仅菜单项；用户不点即视为跳过该版本）

    private func checkForUpdate() {
        Updater.check { [weak self] outcome in
            guard let self else { return }
            guard case let .updateAvailable(version, asset, page, notes) = outcome, let asset else { return }
            self.pendingUpdate = (version, asset, page, notes)
            self.updateItem?.title = "🆕 \(L("menu.updateTo")) \(version)"
            self.updateItem?.isHidden = false
        }
    }

    /// 点菜单的「更新到 vX」：弹确认框显示该版本 changelog，确认后一键下载安装重启。
    @objc private func updateNow() {
        guard let u = pendingUpdate else { return }
        let alert = NSAlert()
        alert.messageText = "\(L("settings.updateAvailable")) \(u.version)"
        alert.informativeText = u.notes.isEmpty ? "" : Updater.plainNotes(u.notes)
        alert.addButton(withTitle: L("settings.installUpdate"))   // 第一个按钮：更新
        alert.addButton(withTitle: L("settings.cancel"))          // 第二个：取消
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Updater.installUpdate(from: u.asset, status: { _ in }, failure: { _ in
            NSWorkspace.shared.open(u.page)   // 自更新失败 → 回退打开下载页
        })
    }

    @objc private func openLog() { logWC.show() }

    @objc private func openSettings() {
        settingsWC.show(
            openFlash: { [weak self] in
                guard let self else { return }
                self.flashWC.show(script: self.flashScript(), cfg: Self.firmwareConfig)
            },
            onPrimeESP32: { [weak self] in self?.controller.primeESP32() },
            onEngineChanged: { [weak self] in self?.controller.applyEngine() },
            openMediaPipeInstall: { [weak self] in self?.openMediaPipeInstall() },
            openGatekeeperInstall: { [weak self] in self?.openGatekeeperInstall() })
    }

    private func openMediaPipeInstall() {
        var cfg = Self.mediapipeConfig
        cfg.onSuccess = { [weak self] in
            self?.controller.applyEngine()
            NotificationCenter.default.post(name: .gaMediaPipeInstalled, object: nil)   // 通知设置窗刷新状态
        }
        mpInstallWC.show(script: MediaPipeInstaller.setupScript, cfg: cfg)
    }

    private func openGatekeeperInstall() {
        var cfg = Self.gatekeeperConfig
        cfg.onSuccess = {
            // 装好即开启并起 daemon（首次判定时 helper 自行下模型），并通知设置窗刷新「就绪」。
            Gatekeeper.isEnabled = true
            Gatekeeper.shared.startIfNeeded()
            NotificationCenter.default.post(name: .gaGatekeeperInstalled, object: nil)
        }
        gkInstallWC.show(script: Gatekeeper.downloadScript, cfg: cfg)
    }

    static var firmwareConfig: ScriptUIConfig {
        ScriptUIConfig(
            windowTitle: L("firmware.windowTitle"),
            title: L("firmware.title"),
            intro: L("firmware.intro"),
            steps: [L("firmware.step1"), L("firmware.step2"), L("firmware.step3")],
            runLabel: L("firmware.runLabel"), rerunLabel: L("firmware.rerunLabel"), runIcon: "bolt.fill",
            footer: L("firmware.footer"),
            runningText: L("firmware.running"), successText: L("firmware.success"), failedText: L("firmware.failed"),
            idleHint: L("firmware.idleHint"),
            extraEnv: [
                "FLASH_VENV": AppPaths.supportPath("flashenv"),   // esptool venv 装到 Application Support
                // 脚本进度文案（按当前界面语言）——保持单一数据源在 Localization.swift。
                "FW_M_PREP_ESPTOOL": L("fw.sh.prepEsptool"),
                "FW_M_NO_PYTHON": L("fw.sh.noPython"),
                "FW_M_VENV_FAIL": L("fw.sh.venvFail"),
                "FW_M_ESPTOOL_FAIL": L("fw.sh.esptoolFail"),
                "FW_M_ESPTOOL_READY": L("fw.sh.esptoolReady"),
                "FW_M_NO_PORT": L("fw.sh.noPort"),
                "FW_M_PORT": L("fw.sh.port"),
                "FW_M_FLASHING": L("fw.sh.flashing"),
                "FW_M_SUCCESS": L("fw.sh.success"),
                "FW_M_FAILED": L("fw.sh.failed"),
                "FW_M_FAIL_HINT": L("fw.sh.failHint"),
            ])
    }

    static var mediapipeConfig: ScriptUIConfig {
        ScriptUIConfig(
            windowTitle: L("mp.windowTitle"),
            title: L("mp.title"),
            intro: L("mp.intro"),
            steps: [L("mp.step1"), L("mp.step2")],
            runLabel: L("mp.runLabel"), rerunLabel: L("mp.rerunLabel"), runIcon: "arrow.down.circle.fill",
            footer: L("mp.footer"),
            runningText: L("mp.running"), successText: L("mp.success"), failedText: L("mp.failed"),
            idleHint: L("mp.idleHint"),
            extraEnv: [
                "GA_BRIDGE": MediaPipeInstaller.bridgeDir,    // bundle 内 bridge（requirements/download_model 源）
                "GA_VENV": MediaPipeInstaller.venvDir,        // venv 装到 Application Support
                "GA_MODELDIR": MediaPipeInstaller.modelDir,   // 模型下载到 Application Support
                // 脚本进度文案（setup_mediapipe.sh 直接用，download_model.py 继承环境变量）。
                "MP_M_VENV": L("mp.sh.venv"),
                "MP_M_DEPS": L("mp.sh.deps"),
                "MP_M_MODEL": L("mp.sh.model"),
                "MP_M_DONE": L("mp.sh.done"),
                "MP_M_MODEL_EXISTS": L("mp.sh.modelExists"),
                "MP_M_MODEL_DOWNLOAD": L("mp.sh.modelDownload"),
                "MP_M_MODEL_DONE": L("mp.sh.modelDone"),
                "MP_M_BYTES": L("mp.sh.bytes"),
            ])
    }

    static var gatekeeperConfig: ScriptUIConfig {
        ScriptUIConfig(
            windowTitle: L("gk.windowTitle"),
            title: L("gk.title"),
            intro: L("gk.intro"),
            steps: [L("gk.step1"), L("gk.step2"), L("gk.step3")],
            runLabel: L("gk.runLabel"), rerunLabel: L("gk.rerunLabel"), runIcon: "arrow.down.circle.fill",
            footer: L("gk.footer"),
            runningText: L("gk.running"), successText: L("gk.success"), failedText: L("gk.failed"),
            idleHint: L("gk.idleHint"),
            extraEnv: [
                "GK_URL": Gatekeeper.helperURL.absoluteString,   // 固定 tag 的预编译 helper zip
                "GK_DIR": Gatekeeper.installDir,                 // 解压到 Application Support
                // 脚本进度文案（download_gatekeeper.sh 用）。
                "GK_M_DOWNLOAD": L("gk.sh.download"),
                "GK_M_EXTRACT": L("gk.sh.extract"),
                "GK_M_QUARANTINE": L("gk.sh.quarantine"),
                "GK_M_MISSING_BIN": L("gk.sh.missingBin"),
                "GK_M_MISSING_BUNDLE": L("gk.sh.missingBundle"),
                "GK_M_SIGN_OK": L("gk.sh.signOk"),
                "GK_M_SIGN_WARN": L("gk.sh.signWarn"),
                "GK_M_PREFETCH": L("gk.sh.prefetch"),
                "GK_M_PREFETCH_FAIL": L("gk.sh.prefetchFail"),
                "GK_M_READY": L("gk.sh.ready"),
                // 下面几条由 helper（--prefetch）自己读环境变量打印（脚本子进程继承环境）。
                "GK_M_MODEL_CACHE": L("gk.sh.modelCache"),
                "GK_M_DOWNLOADING": L("gk.sh.downloading"),
                "GK_M_DOWNLOADING_SUFFIX": L("gk.sh.downloadingSuffix"),
                "GK_M_PREFETCH_DONE": L("gk.sh.prefetchDone"),
                "GK_M_LOADING": L("gk.sh.loadingModel"),
                "GK_M_LOADING_SUFFIX": L("gk.sh.loadingModelSuffix"),
                "GK_M_DOWNLOAD_PCT": L("gk.sh.downloadPct"),
                "GK_M_MODEL_READY": L("gk.sh.modelReady"),
            ])
    }

    private var testInFlight = false
    @objc private func testApproval() {
        if testInFlight { return }   // 防重入：一次测试未结束时忽略再次点击
        testInFlight = true
        controller.requestApproval(operation: L("test.operation"), timeout: 15,
                                   offerAlwaysAllow: false) { [weak self] outcome in
            self?.testInFlight = false
            let body: String
            switch outcome {
            case .approved, .alwaysAllowed: body = L("test.approved")
            case .denied:   body = L("test.denied")
            case .timedOut: body = L("test.timeout")
            }
            Notifier.post(title: L("test.notifyTitle"), body: body)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: 一键刷固件

    /// 仓库根目录：优先 Info.plist 的 RepoRoot，回退按 bundle 位置推断。
    private func repoRoot() -> String {
        if let r = Bundle.main.object(forInfoDictionaryKey: "RepoRoot") as? String,
           FileManager.default.fileExists(atPath: r) {
            return r
        }
        // .../<repo>/GestureApprove/build/GestureApprove.app -> 上溯 4 层
        var p = Bundle.main.bundlePath
        for _ in 0..<4 { p = (p as NSString).deletingLastPathComponent }
        return p
    }

    private func flashScript() -> String {
        AppPaths.resource("firmware/flash.sh")   // bundle 内（回退仓库）
    }
}

// 命令行 hook：GestureApprove --hook <claude|codex|gemini|kimi>。尽早处理、不初始化 GUI。
// 取代 gesture_hook.py，让核心审批零 Python 依赖（同一二进制兼当 hook）。
if let i = CommandLine.arguments.firstIndex(of: "--hook"),
   CommandLine.arguments.count > i + 1 {
    HookCLI.run(target: CommandLine.arguments[i + 1])
}

// 训练数据提取：--extract-landmarks <imagesDir> <out.csv>
// imagesDir 下每个子文件夹是一个类别，里面是图片。对每张图跑 Vision 手部姿态，
// 输出 CSV：label,x0,y0,...,x20,y20（21 关节，Vision 归一化坐标）。
if let i = CommandLine.arguments.firstIndex(of: "--extract-landmarks"),
   CommandLine.arguments.count > i + 2 {
    let dir = CommandLine.arguments[i + 1]
    let outPath = CommandLine.arguments[i + 2]
    let fm = FileManager.default
    var rows: [String] = []
    let classes = (try? fm.contentsOfDirectory(atPath: dir))?.sorted() ?? []
    for cls in classes {
        let clsDir = (dir as NSString).appendingPathComponent(cls)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: clsDir, isDirectory: &isDir), isDir.boolValue else { continue }
        let files = (try? fm.contentsOfDirectory(atPath: clsDir)) ?? []
        var ok = 0, miss = 0
        for f in files {
            let ext = (f as NSString).pathExtension.lowercased()
            guard ["jpg", "jpeg", "png"].contains(ext) else { continue }
            let path = (clsDir as NSString).appendingPathComponent(f)
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { miss += 1; continue }
            let req = VNDetectHumanHandPoseRequest()
            req.maximumHandCount = 1
            try? VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:]).perform([req])
            guard let obs = req.results?.first, let lms = VisionClassifier.landmarks(obs) else { miss += 1; continue }
            let coords = lms.map { String(format: "%.5f,%.5f", $0.x, $0.y) }.joined(separator: ",")
            rows.append("\(cls),\(coords)")
            ok += 1
        }
        FileHandle.standardError.write("  \(cls): \(ok) 提取成功, \(miss) 跳过\n".data(using: .utf8)!)
    }
    try? rows.joined(separator: "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
    print("写出 \(rows.count) 条样本 -> \(outPath)")
    exit(0)
}

// 语言诊断模式：--lang，打印解析到的界面语言与几条样例文案后退出。
if CommandLine.arguments.contains("--lang") {
    print("preferredLanguages: \(Locale.preferredLanguages)")
    print("resolved: \(I18n.lang)")
    for k in ["menu.running", "card.needApproval", "settings.section.engine"] {
        print("  \(k) = \(L(k))")
    }
    exit(0)
}

// 实时识别诊断：--vision-cam，开默认摄像头跑 Vision ~10 秒，逐帧打印分类器内部值。
// 必须用 .app 内的二进制运行才有相机权限：
//   /Applications/GestureApprove.app/Contents/MacOS/GestureApprove --vision-cam
if CommandLine.arguments.contains("--vision-cam") {
    final class Probe: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
        let ctx = CIContext(options: nil)
        var n = 0
        func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            n += 1
            if n % 8 != 0 { return }   // 约每 8 帧打印一次
            let ci = CIImage(cvPixelBuffer: pb)
            guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return }
            let req = VNDetectHumanHandPoseRequest(); req.maximumHandCount = 1
            try? VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:]).perform([req])
            guard let obs = req.results?.first, let lms = VisionClassifier.landmarks(obs) else {
                print("帧\(n): 未检测到手"); return
            }
            let chir: String = obs.chirality == .right ? "右" : (obs.chirality == .left ? "左" : "未知")
            let (ext, tr) = VisionClassifier.geomFeatures(lms, extMargin: 1.0)
            let ang = VisionClassifier.uprightAngle(lms)
            let palmF = VisionClassifier.isPalmFacing(lms, chirality: obs.chirality)
            let (g, _) = VisionClassifier.classify(landmarks: lms, chirality: obs.chirality)
            print(String(format: "帧%d: 左右手=%@ 伸展指=%d 拇指比=%.2f 朝上角=%.0f° 手掌正面=%@ → 判定=%@",
                         n, chir, ext, tr, ang, palmF ? "是" : "否", g.rawValue))
        }
    }
    let probe = Probe()
    let session = AVCaptureSession()
    session.sessionPreset = .high
    let ds = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                              mediaType: .video, position: .unspecified)
    guard let dev = ds.devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? ds.devices.first,
          let input = try? AVCaptureDeviceInput(device: dev) else {
        print("无法打开摄像头"); exit(1)
    }
    session.addInput(input)
    let out = AVCaptureVideoDataOutput()
    out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    out.alwaysDiscardsLateVideoFrames = true
    out.setSampleBufferDelegate(probe, queue: DispatchQueue(label: "probe"))
    session.addOutput(out)
    print("用摄像头 \(dev.localizedName)，举手测试 10 秒…\n")
    session.startRunning()
    RunLoop.current.run(until: Date().addingTimeInterval(10))
    session.stopRunning()
    print("\n诊断结束")
    exit(0)
}

// 相机诊断模式：--cam-info，打印授权状态/设备列表/默认设备/当前选择后退出。
if CommandLine.arguments.contains("--cam-info") {
    let status = AVCaptureDevice.authorizationStatus(for: .video)
    print("授权状态: \(status.rawValue) (0=未决定 1=受限 2=拒绝 3=已授权)")
    let ds = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
        mediaType: .video, position: .unspecified)
    print("设备列表:")
    for d in ds.devices {
        print("  - \(d.localizedName) | pos=\(d.position.rawValue) | type=\(d.deviceType.rawValue) | id=\(d.uniqueID)")
    }
    print("系统默认: \(AVCaptureDevice.default(for: .video)?.localizedName ?? "无")")
    print("当前选择 id: \(VideoInputs.savedOrDefaultID())")
    exit(0)
}

// 串口直测模式：--serial-test [端口]，开串口抓一帧打印结果后退出（不启动 GUI）。
if CommandLine.arguments.contains("--serial-test") {
    let port = ESP32FrameSource.autodetectPort() ?? "/dev/cu.usbserial-FTB6SPL3"
    let baud = Int(ProcessInfo.processInfo.environment["GESTURE_ESP32_BAUD"] ?? "921600") ?? 921600
    print("打开 \(port) @ \(baud)")
    let sp = SerialPort(path: port, baud: baud)
    guard sp.open() else { print("打开失败"); exit(1) }
    sp.resetToRunMode()
    if let frame = sp.captureFrame(timeout: 4.0) {
        let path = "/tmp/ga_serialtest.jpg"
        try? frame.write(to: URL(fileURLWithPath: path))
        print("成功抓到 \(frame.count) 字节 -> \(path)")
        sp.close(); exit(0)
    } else {
        print("抓帧失败（魔数/波特率？）"); sp.close(); exit(2)
    }
}

// 忽略 SIGPIPE：MediaPipe daemon 崩溃后，若还有一帧往已关闭的 stdin 管道写
// （MediaPipeClassifier.submit），默认 SIGPIPE 会直接终止整个 app。改为忽略，
// write 转而返回 EPIPE（由 daemon 生命周期逻辑处理），app 不再被写管道拖垮。
signal(SIGPIPE, SIG_IGN)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
