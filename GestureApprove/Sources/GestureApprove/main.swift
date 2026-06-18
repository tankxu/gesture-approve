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
    private var loginItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
                guard let self else { reply("ask", "服务未就绪"); return }
                // 总开关关闭 -> 直接交回终端正常审批，不弹卡片
                guard self.approvalEnabled else { reply("ask", "审批拦截已关闭"); return }
                // 白名单命中 -> 直接放行，不打扰
                if Allowlist.matches(operation) { reply("allow", "白名单自动放行"); return }
                self.controller.requestApproval(operation: operation, timeout: 90) { outcome in
                    switch outcome {
                    case .approved: reply("allow", "👍 通过")
                    case .denied:   reply("deny", "🖐 拒绝")
                    case .timedOut: reply("ask", "超时，交回终端审批")   // 不再自动拒绝
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
                                         accessibilityDescription: "手势审批")
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "手势审批 · 运行中", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        let enabled = NSMenuItem(title: "启用审批拦截", action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.target = self
        enabled.state = approvalEnabled ? .on : .off
        enabled.image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)
        menu.addItem(enabled)
        self.enabledItem = enabled

        let login = NSMenuItem(title: "开机自启", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        login.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(login)
        self.loginItem = login

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settings)

        let test = NSMenuItem(title: "测试审批卡片", action: #selector(testApproval), keyEquivalent: "t")
        test.target = self
        test.image = NSImage(systemSymbolName: "hand.thumbsup", accessibilityDescription: nil)
        menu.addItem(test)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quit)

        item.menu = menu
        self.statusItem = item
    }

    @objc private func toggleLaunchAtLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            NSLog("GestureApprove: 开机自启切换失败 \(error)")
        }
        loginItem?.state = (svc.status == .enabled) ? .on : .off
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

    static let firmwareConfig = ScriptUIConfig(
        windowTitle: "刷写 ESP32-CAM 固件",
        title: "把 ESP32-CAM 刷成审批摄像头",
        intro: "ESP32-CAM 是一块很便宜的带摄像头的小模块。刷入配套固件后，它就能通过 USB 把画面传给电脑，代替自带摄像头识别手势。",
        steps: ["用 USB-串口适配器把 ESP32-CAM 接到电脑",
                "点「开始刷写」，等待出现「刷写成功」",
                "回到设置，把视频输入源选成「ESP32-CAM（串口）」"],
        runLabel: "开始刷写", rerunLabel: "重新刷写", runIcon: "bolt.fill",
        footer: "无需安装 PlatformIO。首次会自动下载约 20MB 小工具。裸 FTDI 没自动复位：GPIO0 接 GND → 复位 → 重试。",
        runningText: "正在刷写…", successText: "刷写成功", failedText: "刷写失败",
        idleHint: "把设备接好后点「开始刷写」，这里实时显示进度。")

    static let mediapipeConfig = ScriptUIConfig(
        windowTitle: "下载 MediaPipe 识别引擎",
        title: "下载 MediaPipe（更准的手势识别）",
        intro: "MediaPipe 是 Google 的预训练手势模型，识别更准、更耐受光线与角度。它需要一个约 300MB 的 Python 运行时（仅下载一次）。",
        steps: ["点「开始下载」，自动建好 Python 环境并下载模型",
                "完成后回到设置即自动启用 MediaPipe"],
        runLabel: "开始下载", rerunLabel: "重新下载", runIcon: "arrow.down.circle.fill",
        footer: "下载约 300MB，耗时取决于网速。完成后无需重启 app。",
        runningText: "正在下载安装…", successText: "安装完成", failedText: "安装失败",
        idleHint: "点「开始下载」开始安装，这里实时显示进度。")

    private var testInFlight = false
    @objc private func testApproval() {
        if testInFlight { return }   // 防重入：一次测试未结束时忽略再次点击
        testInFlight = true
        controller.requestApproval(operation: "测试手势识别", timeout: 15) { [weak self] outcome in
            self?.testInFlight = false
            let body: String
            switch outcome {
            case .approved: body = "✅ 已通过（👍）"
            case .denied:   body = "🛑 已拒绝（🖐）"
            case .timedOut: body = "⌛️ 超时未操作（真实审批时会交回终端）"
            }
            Notifier.post(title: "手势审批 · 测试结果", body: body)
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
