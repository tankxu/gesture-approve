import AppKit
import AVFoundation
import Vision
import CoreGraphics
import ImageIO
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
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

    // MARK: 网络审批设备（ESP32 等）API —— 独立 LAN 端口 + Bearer token，与可信的本地 hook 口隔离。
    // 端口/token/开关等配置见 DeviceApi；开关默认关，可在设置窗「远程审批设备」里打开。
    private let deviceState = DeviceApprovalState()

    // Remote Hub(Swift 原生 HubServer/HubApp:远程会话/语音/回复)监管
    private let hub = HubController()

    private var approvalEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: "approvalEnabled") as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "approvalEnabled") }
    }
    private var enabledItem: NSMenuItem?
    private var bigModeItem: NSMenuItem?                                     // Big Mode 开关（放大审批卡片）
    private var updateItem: NSMenuItem?                                      // 「更新到 vX」菜单项（默认隐藏）

    private var bigMode: Bool {
        get { UserDefaults.standard.bool(forKey: "bigMode") }
        set { UserDefaults.standard.set(newValue, forKey: "bigMode") }
    }
    private var updateTimer: Timer?
    private var pendingUpdate: (version: String, asset: URL, page: URL, notes: String)?

    /// 用量区当前占用的菜单项（重建时先摘掉这些）。见 rebuildUsage。
    private var usageItems: [NSMenuItem] = []
    /// 菜单是否正展开——决定「选数据来源」的弹窗现在弹还是等收起来再弹。
    private var menuIsOpen = false
    /// 本轮问题里是否已经自动弹过一次（防止每点一次菜单弹一次）。
    private var autoAskedSource = false
    /// 这次开合菜单期间用户点了某个菜单项（设置/退出/测试…）——那就别拿弹窗打断他。
    private var menuActionFired = false

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
        // 完成通知开着就必须有「专注状态」权限，否则勿扰时那一声照样吵人。每次启动都查，
        // 被拒过也照样提醒（系统不会再弹第二次，只能我们出面）。延后一拍等 app 起完再弹。
        if AgentNotify.isEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                Notifier.ensureFocusAuthorization(explainIfDenied: true)
            }
        }
        AVCaptureDevice.requestAccess(for: .video) { _ in }   // 首次弹相机授权
        setupStatusItem()
        registerHotkeys()
        controller.deviceState = deviceState   // 让审批控制器发布/清空设备可见的审批动态
        MonitorAPI.approvalSnapshot = { [deviceState] in deviceState.snapshotJSON() }
        MonitorAPI.resolveApproval = { [weak self] id, allow in
            let sem = DispatchSemaphore(value: 0); var accepted = false
            DispatchQueue.main.async { accepted = self?.controller.resolveByExternal(id: id, approve: allow) ?? false; sem.signal() }
            sem.wait(); return accepted
        }
        LocalMonitor.shared.start()
        // 开着但配置不在位 → 启动时补装一次（app 换过路径、被别的工具覆盖、用户手改过）。
        // 关着就一个字节都不写，见 UsageMonitor.repairIfNeeded。
        UsageMonitor.repairIfNeeded()
        startServer()
        Gatekeeper.shared.startIfNeeded()   // 智能放行守门员 daemon（仅开关开+已装才起；会先清残留）
        hub.startIfEnabled()                // Remote Hub：后台自动起 Swift 原生服务(菜单入口点开即用)
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
        // 设备参数始终传入；是否真正开放由 deviceEnabled 开关控制（设置窗可运行时起停）。
        if DeviceApi.isEnabled {
            let ips = DeviceApi.localIPv4Addresses().joined(separator: ", ")
            GALog.log("设备 API 已开放：http://\(ips.isEmpty ? "<本机IP>" : ips):\(DeviceApi.port) token=\(DeviceApi.token)")
        }
        let server = ApprovalServer(
            port: port,
            devicePort: DeviceApi.port,
            deviceToken: DeviceApi.token,
            deviceState: deviceState,
            deviceEnabled: DeviceApi.isEnabled,
            onResolve: { [weak self] id, decision, reply in
                Task { @MainActor in
                    guard let self else { reply(false); return }
                    reply(self.controller.resolveByExternal(id: id, approve: decision == "allow"))
                }
            },
            // agent 完成通知：Stop hook → 桌面横幅 + Remote Hub 的 /events（开关见设置窗）。
            onAgentEvent: { payload in AgentNotify.handle(payload) }
        ) { [weak self] req, reply in
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
        controller.requestApproval(operation: req.operation, cwd: req.cwd, tool: req.tool, session: req.session, provider: req.provider, requestKind: req.requestKind, profileId: req.profileId, timeout: 90) { outcome in
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

    @objc private func toggleBigMode() {
        bigMode.toggle()
        bigModeItem?.state = bigMode ? .on : .off
    }

    /// 远程 Hub:唯一入口。确保 hub 在跑(没跑先拉起),然后打开网页仪表盘。启停/配置都在网页里。
    @objc private func openHub() {
        hub.start()   // Swift 原生、幂等:已在跑则忽略,binding 瞬时
        let open = { _ = NSWorkspace.shared.open(URL(string: "http://127.0.0.1:\(HubController.port)/")!) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: open)
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
        menu.delegate = self          // menuWillOpen 时刷新用量区
        // 「用户点了菜单项」没有 delegate 回调，用这条通知代替；它在 menuDidClose 之后发出，
        // 所以 askUsageSourceAfterMenu 才要延后一拍去读这个标记。
        NotificationCenter.default.addObserver(
            forName: NSMenu.willSendActionNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuActionFired = true }
        }
        menu.addItem(withTitle: L("menu.running"), action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        // 用量区插在这条分隔线之前（索引 1 起），由 rebuildUsage 动态增删。

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

        let big = NSMenuItem(title: L("menu.bigMode"), action: #selector(toggleBigMode), keyEquivalent: "")
        big.target = self
        big.state = bigMode ? .on : .off
        big.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)
        menu.addItem(big)
        self.bigModeItem = big

        menu.addItem(.separator())

        // 远程 Hub:唯一入口,点开打开网页仪表盘(启停/配置都在网页里)
        let hubItem = NSMenuItem(title: L("menu.hub"), action: #selector(openHub), keyEquivalent: "")
        hubItem.target = self
        hubItem.image = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: nil)
        menu.addItem(hubItem)

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

    // MARK: 用量区（谁在跑就显示谁的额度与窗口）

    /// 打开菜单时才采集，不常驻轮询。
    /// 先用上次结果秒出，异步拿到新数据再原地覆盖（NSMenu 支持菜单打开期间改内容）。
    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        menuActionFired = false
        rebuildUsage(UsageMonitor.shared.snapshot)
        UsageMonitor.shared.refresh { [weak self] rows in
            guard let self else { return }
            self.rebuildUsage(rows)
            // 采集比用户关菜单还慢时，菜单已经关了 —— 那就现在问。
            if !self.menuIsOpen { self.askUsageSourceAfterMenu() }
        }
    }

    /// 弹窗要等菜单收起来再弹：NSMenu 跟踪期是嵌套 runloop，这时候上模态框会打架，
    /// 而且用户本来可能只是想点「设置」，把菜单从他手里抢走很粗暴。
    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        askUsageSourceAfterMenu()
    }

    /// 菜单收起后再决定要不要弹。**必须延后一拍**：点菜单项时 AppKit 是先收菜单
    /// （menuDidClose）、后执行 action，当场就问的话，点「退出」「设置」都会先被这个弹窗截胡。
    /// 这一拍里只要有菜单 action 发出，就说明用户是去干别的了，这轮不问。
    private func askUsageSourceAfterMenu() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.menuActionFired else { return }
            self.askUsageSourceIfNeeded()
        }
    }

    private func rebuildUsage(_ rows: [ToolUsage]) {
        guard let menu = statusItem?.menu else { return }
        for item in usageItems where item.menu === menu { menu.removeItem(item) }
        usageItems = UsageMenuSection.items(for: rows)
        // 额度是空的时候说清楚是哪一种空：没开采集（可点开启）、配置失效（可点修复）、
        // 还是已经在采只是还没等到客户端刷新（不可点）。以前三种都只有一句"还没有额度数据"。
        if let hint = UsageMonitor.hint(rows) {
            let item = UsageMenuSection.hintItem(L(hint.rawValue), actionable: hint != .waiting)
            if hint != .waiting { item.action = #selector(fixUsageCollection); item.target = self }
            usageItems.append(item)
        }
        // 用户在弹窗里点了「以后再说」之后，菜单里留一行可点的入口，方便随时改主意。
        if UsageMonitor.shared.pendingAsk != nil {
            let pick = NSMenuItem(title: L("usage.chooseSource"),
                                  action: #selector(chooseUsageSource), keyEquivalent: "")
            pick.target = self
            usageItems.append(pick)
        }
        for (offset, item) in usageItems.enumerated() {
            menu.insertItem(item, at: 1 + offset)   // 紧跟「运行中」标题行
        }
    }

    /// 自动弹窗每个「问题周期」只弹一次：Chrome 一直不通时，不能每点一次菜单就弹一次。
    /// 通道恢复正常（pendingAsk 被清掉）后重新武装。
    /// 冷却期内一概不自动弹——但菜单里那行入口照常在，用户想起来随时能点。
    private func askUsageSourceIfNeeded() {
        guard let reason = UsageMonitor.shared.pendingAsk else { autoAskedSource = false; return }
        guard !autoAskedSource, !UsageMonitor.isSnoozed else { return }
        autoAskedSource = true
        showUsageSourceAlert(reason)
    }

    /// 菜单里点「开启采集 / 修复配置」。开启要先说清楚会动哪些文件 —— 写用户的 AI 工具配置
    /// 不能静默进行；修复不再问：他早就同意过接入，这次只是路径或被别人覆盖了。
    @objc private func fixUsageCollection() {
        if UsageMonitor.collecting {
            let fixed = UsageMonitor.repairIfNeeded()
            if fixed.isEmpty { return }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = L("usage.collectConfirm.title")
            alert.informativeText = L("usage.collectConfirm.body")
            alert.addButton(withTitle: L("usage.collectConfirm.ok"))
            alert.addButton(withTitle: L("settings.cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let result = MonitorHooks.apply(uninstall: false)
            // 装失败就别把开关留在「开」上——那正是这次要消灭的那种谎。
            guard result["ok"] as? Bool == true else {
                let failed = NSAlert()
                failed.messageText = L("usage.collectConfirm.title")
                failed.informativeText = (result["results"] as? [MObject] ?? [])
                    .compactMap { $0["error"] as? String }.joined(separator: "\n")
                failed.runModal()
                return
            }
            UsageMonitor.collecting = true
        }
        UsageMonitor.shared.refresh { [weak self] rows in self?.rebuildUsage(rows) }
    }

    @objc private func chooseUsageSource() {
        showUsageSourceAlert(UsageMonitor.shared.pendingAsk ?? .firstTime)
    }

    /// 「用量从哪儿取？」——Chrome（不弹授权）还是钥匙串（弹系统授权框）。
    /// 静默降级到钥匙串是不行的：那个系统授权框必须是用户自己选来的。
    private func showUsageSourceAlert(_ reason: UsageAskReason) {
        NSApp.activate(ignoringOtherApps: true)
        switch UsageSourceAlert.run(UsageSourceAlert.make(reason)) {
        case .alertFirstButtonReturn:
            UsageMonitor.source = .chrome
            UsageMonitor.shared.clearPendingAsk()
            UsageMonitor.endSnooze()      // 主动选了来源，就不该再压着提示
            HubApp.openClaudeTab()
            // 标签页要几秒才加载完，立刻采集必然扑空——先等 3 秒，不成再给两次机会。
            fetchAfterManualChoice(delay: 3, retries: 2)
        case .alertSecondButtonReturn:
            UsageMonitor.source = .keychain
            UsageMonitor.shared.clearPendingAsk()
            UsageMonitor.endSnooze()
            // 钥匙串不重试：每试一次都可能再弹一次系统授权框。
            fetchAfterManualChoice(delay: 0, retries: 0)
        case .alertThirdButtonReturn:
            // 暂不获取用量：24 小时内不再自动弹。**pendingAsk 故意不清**——
            // 菜单里那行入口得留着，用户改主意时点一下就能回来。
            UsageMonitor.snooze()
            UsageMonitor.shared.refresh { [weak self] rows in self?.rebuildUsage(rows) }
        default:
            break   // Esc 等非按钮关闭：什么都不做，别替用户做 24 小时的决定
        }
    }

    /// 用户刚在弹窗里选完来源之后的那次采集。**只有这条路会发通知**——他刚点过，
    /// 得给个回音；平时点开菜单的自动采集一律静默。失败也不通知（菜单里那行灰字已经写着原因了），
    /// 只是再试几次：Chrome 标签页加载慢是最常见的「失败」，几秒后自己就好了。
    private func fetchAfterManualChoice(delay: TimeInterval, retries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            UsageMonitor.shared.refresh { rows in
                self.rebuildUsage(rows)
                // 成功与否看 pendingAsk：拿不到时 rows 里可能还留着上一轮的缓存数字，
                // 光看「有没有数」会把失败当成成功报出去。
                guard UsageMonitor.shared.pendingAsk == nil else {
                    if retries > 0 { self.fetchAfterManualChoice(delay: 4, retries: retries - 1) }
                    return
                }
                guard let body = UsageMenuSection.summary(rows) else { return }
                Notifier.post(title: L("usage.notify.title"), body: body)
            }
        }
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
            openGatekeeperInstall: { [weak self] in self?.openGatekeeperInstall() },
            onDeviceApiChanged: { [weak self] on in self?.server?.setDeviceEnabled(on) },
            openHubConfig: { [weak self] in self?.openHubConfig() })
    }

    /// 确保 hub 在跑,然后打开配置页(/config,设备配对信息集中在那)。
    @objc private func openHubConfig() {
        hub.start()
        let open = { _ = NSWorkspace.shared.open(URL(string: "http://127.0.0.1:\(HubController.port)/config")!) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: open)
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

if let i = CommandLine.arguments.firstIndex(of: "--monitor-hook"), CommandLine.arguments.count > i+1 { MonitorHooks.capture(provider: CommandLine.arguments[i+1], statusLine: false) }
if CommandLine.arguments.contains("--monitor-statusline") { MonitorHooks.capture(provider: "claude", statusLine: true) }
if CommandLine.arguments.contains("--monitor-status") {
    print(MonitorIO.json(["collectors": MonitorHooks.status()])); exit(0)
}
// --monitor-install [claude,codex]：省略目标 = 这台机器上有哪家就装哪家。
if let i = CommandLine.arguments.firstIndex(where: { $0 == "--monitor-install" || $0 == "--monitor-uninstall" }) {
    let next = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : ""
    let ids = next.isEmpty || next.hasPrefix("-") ? nil
        : next.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let result = MonitorHooks.apply(providers: ids, uninstall: CommandLine.arguments[i] == "--monitor-uninstall",
                                    executable: Bundle.main.executablePath ?? CommandLine.arguments[0])
    print(MonitorIO.json(result))
    exit(result["ok"] as? Bool == true ? 0 : 1)
}
if let i = CommandLine.arguments.firstIndex(of: "--monitor-serve"), CommandLine.arguments.count > i+1, let port=UInt16(CommandLine.arguments[i+1]) {
    let app=HubApp(port:Int(port)); let server=HubServer(port:port,lan:false,router:app.route)
    LocalMonitor.shared.start(); server.start(); print("Monitor listening on loopback port \(port)")
    withExtendedLifetime((app,server)) { RunLoop.main.run() }; exit(0)
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

// Agent 完成通知：--agent-notify [on|off|status] [claude|codex]（默认 status + 两家都作用）。
// 等价于设置窗里的开关：装/卸各家 Stop hook 并同步偏好，外加打印开关与 hook 是否在位——
// 排查"没收到通知"时先看这里。
if let i = CommandLine.arguments.firstIndex(of: "--agent-notify") {
    let args = CommandLine.arguments
    let action = args.count > i + 1 ? args[i + 1] : "status"
    let who = args.count > i + 2 ? args[i + 2] : "all"
    let doClaude = (who == "all" || who == "claude"), doCodex = (who == "all" || who == "codex")
    do {
        switch action {
        case "on":
            if doClaude { try HookInstaller.installClaudeStop(); AgentNotify.claudeEnabled = true }
            if doCodex  { try HookInstaller.installCodexStop();  AgentNotify.codexEnabled = true }
        case "off":
            if doClaude { try HookInstaller.uninstallClaudeStop(); AgentNotify.claudeEnabled = false }
            if doCodex  { try HookInstaller.uninstallCodexStop();  AgentNotify.codexEnabled = false }
        default:
            break
        }
    } catch {
        print("失败: \(error)")
        exit(1)
    }
    // --agent-notify test：走一遍真实的通知路径并回头核对，排查"事件有记录但没看到横幅"。
    if action == "test" {
        let sem = DispatchSemaphore(value: 0)
        Notifier.diagnose(title: "\(L("agent.notify.title")) · test",
                          body: "GestureApprove 通知自检") { sem.signal() }
        while sem.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        exit(0)
    }
    print("Claude Code: \(AgentNotify.claudeEnabled ? "开" : "关")（hook 在位: \(HookInstaller.isClaudeStopInstalled())）")
    print("Codex:       \(AgentNotify.codexEnabled ? "开" : "关")（hook 在位: \(HookInstaller.isCodexStopInstalled())，首次需在 Codex 里按 t 信任）")
    print("桌面通知: \(AgentNotify.desktopEnabled ? "开" : "关")  Hub 推送: \(AgentNotify.hubEnabled ? "开" : "关")")
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

/// 把用量行画到一张 PNG 上（--usage out.png）。只为调样式：菜单里的真实缩进由 AppKit 处理，
/// 这里固定留一段近似的左边距，看的是条子本身的粗细/圆角/和文字的对齐。
func renderUsagePreview(_ rows: [ToolUsage], to path: String) {
    let lines: [NSAttributedString] = rows.flatMap { r -> [NSAttributedString] in
        // 没在跑就不画绿点，跟菜单里的 headItem 保持一致（预览图是用来核对菜单长什么样的）。
        [NSAttributedString(string: r.running > 0 ? "\(r.name)   ● \(r.running)" : r.name, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])] + r.windows.reduce(into: (shown: nil as String?, lines: [NSAttributedString]())) { acc, w in
            // 池名只在切换到新池时出一行，跟菜单里的排法一致。
            if let p = w.pool, p != acc.shown {
                acc.lines.append(NSAttributedString(string: p, attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
                acc.shown = p
            }
            acc.lines.append(UsageMenuSection.windowLine(w))
        }.lines
    }
    guard !lines.isEmpty else { print("没有可渲染的行"); return }
    let rowH: CGFloat = 20, inset = NSPoint(x: 24, y: 10)
    let size = NSSize(width: 360, height: CGFloat(lines.count) * rowH + inset.y * 2)
    let img = NSImage(size: size, flipped: false) { rect in
        NSColor.windowBackgroundColor.setFill()
        rect.fill()
        for (i, line) in lines.enumerated() {
            let y = size.height - inset.y - CGFloat(i + 1) * rowH + (rowH - line.size().height) / 2
            line.draw(at: NSPoint(x: inset.x, y: y))
        }
        return true
    }
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { print("渲染失败"); return }
    try? png.write(to: URL(fileURLWithPath: path))
    print("\n预览图 -> \(path)")
}

// 用量诊断模式：--usage [out.png]，打印菜单里那段用量区的原始数据后退出（不启动 GUI）。
// 给了 .png 路径就顺便把用量行渲染成图片——调进度条样式时不用真去点开菜单栏菜单。
// 注意用 .app 内的二进制跑，钥匙串授权是按二进制授予的：
//   /Applications/GestureApprove.app/Contents/MacOS/GestureApprove --usage
if let usageArg = CommandLine.arguments.firstIndex(of: "--usage") {
    let pngPath: String? = CommandLine.arguments.count > usageArg + 1
        && CommandLine.arguments[usageArg + 1].hasSuffix(".png")
        ? CommandLine.arguments[usageArg + 1] : nil
    let sessions = UsageMonitor.liveClaudeSessions()
    print("Claude Code 活跃会话: \(sessions.count)  版本: \(sessions.first?.version ?? "-")")
    print("codex 进程: \(UsageMonitor.processCount(named: "codex"))")
    print("用量数据来源: \(UsageMonitor.source.rawValue)")
    if let until = UsageMonitor.snoozedUntil, UsageMonitor.isSnoozed {
        print("暂不主动询问（入口仍在），恢复时间: \(until)")
    }
    let sem = DispatchSemaphore(value: 0)
    UsageMonitor.shared.refresh { rows in
        if rows.isEmpty { print("（没有正在运行的工具，菜单里不显示用量区）") }
        for r in rows {
            print("\n\(r.name)  ● \(r.running)")
            for w in r.windows {
                // 跟菜单说同一件事：菜单画的是「还剩多少」，诊断里印 used% 只会让两边对不上。
                let left = w.percent.map { UsageMenuSection.remainingText($0) } ?? "—"
                let reset = w.resetsAt.map { UsageMenuSection.resetText($0) } ?? "-"
                let pool = w.pool.map { $0 + " " } ?? ""
                print("  \(pool)\(w.label)  \(left)  · \(reset)")
            }
            if let n = r.note { print("  note: \(n)") }
        }
        // 手动选完来源那次采集会把这段发成系统通知（自动采集不发）。
        // 带 --notify 就真发一条，用来验证「前台时横幅会不会被系统吞掉」。
        if let body = UsageMenuSection.summary(rows) {
            print("\n通知正文:\n\(body)")
            if CommandLine.arguments.contains("--notify") {
                Notifier.requestAuthorization()
                Notifier.printAuthorizationStatus()
                Notifier.post(title: L("usage.notify.title"), body: body)
                print("已发出通知")
            }
        }
        if let ask = UsageMonitor.shared.pendingAsk {
            switch ask {
            case .firstTime:                 print("\n待问用户: 首次采集，还没选来源")
            case .chromeBroken(.noTab):      print("\n待问用户: Chrome 没有已登录的 claude.ai 标签页")
            case .chromeBroken(.jsDisabled): print("\n待问用户: Chrome 未允许通过 Apple 事件执行 JavaScript")
            case .chromeBroken(.accountMismatch): print("\n待问用户: 浏览器登录的是另一个账号")
            case .chromeBroken(.other):      print("\n待问用户: Chrome 通道返回异常")
            }
        }
        if let path = pngPath { renderUsagePreview(rows, to: path) }
        sem.signal()
    }
    // refresh 的回调走主线程，这里必须转 runloop 而不是干等信号量。
    while sem.wait(timeout: .now() + 0.05) == .timedOut {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    // 通知是异步投递的，立刻 exit 会把它掐掉。
    if CommandLine.arguments.contains("--notify") {
        RunLoop.current.run(until: Date().addingTimeInterval(2))
    }
    exit(0)
}

// 用量来源弹窗预览：--usage-ask [first|notab|jsoff|other]，弹出真正的那个弹窗并打印点了哪个键。
// 核对四种情形的文案（换行、长度、按钮顺序）时不用真去把 Chrome 弄断。
if let i = CommandLine.arguments.firstIndex(of: "--usage-ask") {
    let which = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "first"
    let reason: UsageAskReason
    switch which {
    case "notab":   reason = .chromeBroken(.noTab)
    case "jsoff":   reason = .chromeBroken(.jsDisabled)
    case "account": reason = .chromeBroken(.accountMismatch)
    case "other":   reason = .chromeBroken(.other)
    default:      reason = .firstTime
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.activate(ignoringOtherApps: true)
    let alert = UsageSourceAlert.make(reason)
    print("标题: \(alert.messageText)")
    print("正文: \(alert.informativeText)")
    print("按钮: \(alert.buttons.map(\.title).joined(separator: " | "))")
    // 这些都得等模态把窗口摆上屏才有意义，所以派到模态自己的 runloop 里。
    // 「按钮宽」是给 UsageSourceAlert.stretchButtons 做回归用的：那段要关掉 NSAlert 内部的
    // required 等宽约束，哪天系统换了实现，这里就会从 340 变回 228。
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        let w = alert.window
        NSApp.activate(ignoringOtherApps: true)   // 截图时窗口得是 key，否则默认键不显示蓝色
        w.makeKeyAndOrderFront(nil)
        print("窗口: \(NSStringFromRect(w.frame))")
        print("按钮宽: \(alert.buttons.map { Int($0.frame.width) })")
        print("WINDOW:\(w.windowNumber)")        // 给 screencapture -l 用
        fflush(stdout)
    }
    fflush(stdout)
    switch UsageSourceAlert.run(alert) {
    case .alertFirstButtonReturn:  print("选择: Claude Web")
    case .alertSecondButtonReturn: print("选择: Keychain")
    case .alertThirdButtonReturn:  print("选择: 暂不获取用量（冷却 24 小时）")
    default:                       print("关闭但未选择（不冷却）")
    }
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
