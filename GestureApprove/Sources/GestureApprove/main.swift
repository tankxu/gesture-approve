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
    private let flashWC = ScriptWindowController()
    private let mpInstallWC = ScriptWindowController()

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

    /// 屏幕锁定 / 系统睡眠期间用户无法比手势 → 审批直接回退终端，避免弹无人操作的卡片卡住后台。
    /// 用两个独立标志组合：唤醒(didWake)时屏幕往往仍锁定，必须等真正解锁(screenIsUnlocked)才恢复，
    /// 否则会在锁屏界面误弹卡片。systemSuspended = 锁屏中 或 睡眠中。
    private var screenLocked = false
    private var asleep = false
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
        observeSystemState()
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
        case "com.apple.screenIsLocked":            screenLocked = true
        case "com.apple.screenIsUnlocked":          screenLocked = false; server?.restart()
        case NSWorkspace.willSleepNotification.rawValue: asleep = true
        case NSWorkspace.didWakeNotification.rawValue:   asleep = false; server?.restart()
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
        let server = ApprovalServer(port: port) { [weak self] operation, reply in
            DispatchQueue.main.async {
                guard let self else { reply("ask", L("reply.notReady")); return }
                // 总开关关闭 -> 直接交回终端正常审批，不弹卡片
                guard self.approvalEnabled else { reply("ask", L("reply.gatingOff")); return }
                // 屏幕锁定/睡眠 -> 用户无法比手势，直接交回终端，不弹无人操作的卡片
                guard !self.systemSuspended else { reply("ask", L("reply.suspended")); return }
                // 白名单命中且整条安全 -> 直接放行，不打扰（危险/拼接命令仍要手势）
                if Allowlist.autoAllows(operation) { reply("allow", L("reply.allowlist")); return }
                self.controller.requestApproval(operation: operation, timeout: 90) { outcome in
                    switch outcome {
                    case .approved: reply("allow", L("reply.approved"))
                    case .denied:   reply("deny", L("reply.denied"))
                    case .timedOut: reply("ask", L("reply.timeout"))   // 不再自动拒绝
                    }
                }
            }
        }
        do { try server.start(); self.server = server }
        catch { NSLog("GestureApprove: 服务启动失败 \(error)（端口可能被占用）") }
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

        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quit)

        item.menu = menu
        self.statusItem = item
    }

    @objc private func openSettings() {
        settingsWC.show(
            openFlash: { [weak self] in
                guard let self else { return }
                self.flashWC.show(script: self.flashScript(), cfg: Self.firmwareConfig)
            },
            onPrimeESP32: { [weak self] in self?.controller.primeESP32() },
            onEngineChanged: { [weak self] in self?.controller.applyEngine() },
            openMediaPipeInstall: { [weak self] in self?.openMediaPipeInstall() })
    }

    private func openMediaPipeInstall() {
        var cfg = Self.mediapipeConfig
        cfg.onSuccess = { [weak self] in self?.controller.applyEngine() }
        mpInstallWC.show(script: MediaPipeInstaller.setupScript, cfg: cfg)
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
            idleHint: L("firmware.idleHint"))
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
            idleHint: L("mp.idleHint"))
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
            case .approved: body = L("test.approved")
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
        (repoRoot() as NSString).appendingPathComponent("firmware/flash.sh")
    }
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
    print("当前选择 id: \(VideoInputs.currentID())")
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

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
