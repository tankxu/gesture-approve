import AppKit
import Foundation
import Intents
import UserNotifications

/// 系统通知封装。首次使用会请求授权。
enum Notifier {
    /// 没有 delegate 的话，**app 处于前台时系统会直接把横幅吞掉**。
    /// GA 平时是菜单栏 accessory 不占前台，但弹过卡片/对话框之后它就是活跃 app 了，
    /// 紧接着发的通知正好撞上这条规则。willPresent 里明确要求照常显示。
    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        static let shared = Delegate()
        func userNotificationCenter(_ center: UNUserNotificationCenter,
                                    willPresent notification: UNNotification,
                                    withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
            done([.banner, .sound])
        }
    }

    static func requestAuthorization() {
        UNUserNotificationCenter.current().delegate = Delegate.shared
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// 诊断用（`--usage --notify`）：通知不显示时，先看这两个值。
    static func printAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            print("通知授权: \(s.authorizationStatus.rawValue)（2=已授权）  横幅: \(s.alertSetting.rawValue)（2=开）")
            fflush(stdout)
        }
    }

    /// 「Agent 完成」的提示音（木琴「登·登·登·灯」，由 `Assets/sounds/render_agent_done.swift`
    /// 用系统 GM 音源离线渲染，改几个音符就能换旋律）**由 app 自己播**，通知本身设成静音。
    ///
    /// 为什么不用 `UNNotificationSound(named:)`：实测（macOS 26）无论把 aiff 放进 app bundle 的
    /// `Contents/Resources`，还是装到 `~/Library/Sounds`（系统给自定义提示音的正规位置，
    /// 系统设置里都能看到它），通知播出来的**始终是系统默认音**，且没有任何报错——
    /// 试了两轮才确认这条路在这个系统版本上是死的。自己播则 100% 可控，还能顺带避免
    /// "通知有声、声音却不是它"的错觉。
    ///
    /// 代价：勿扰/专注模式下系统会静音通知，而我们这一声照常响。想彻底安静就关掉「桌面通知」开关。
    private static var playing: NSSound?      // NSSound 一被释放就掐断播放，得留个引用
    static func playAgentDone() {
        // 自己播就得自己守规矩：系统在勿扰/专注时会静音通知，我们这一声也得跟着闭嘴。
        if isFocused {
            GALog.log("勿扰/专注模式开启，跳过完成提示音（通知照常进通知中心）")
            return
        }
        guard installCustomSound(), let s = NSSound(contentsOf: userSoundURL, byReference: true) else {
            NSSound.beep()      // 提示音都没了也别让它彻底无声
            return
        }
        // NSSound 走系统主音量，但默认 volume=1.0 顶格；系统提示音那条通道另有一个更低的
        // 「提示音量」，两相对比就显得这一声特别冲。压到六成，听感才和其它提示音在一个量级。
        s.volume = 0.6
        playing = s
        s.play()
    }

    // MARK: 勿扰 / 专注模式

    enum FocusAuth { case granted, denied, notDetermined }

    /// 「专注状态」权限。`INFocusStatusCenter` 是 macOS 上唯一公开的查询途径
    /// （`~/Library/DoNotDisturb` 那套数据库受 TCC 保护，普通 app 读不到）。
    static var focusAuth: FocusAuth {
        switch INFocusStatusCenter.default.authorizationStatus {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }

    /// 当前是否处于勿扰或任一专注模式。**没授权就当作"没开专注"**——
    /// 宁可多响一声，也好过因为读不到状态而永久静音、让人以为通知坏了。
    static var isFocused: Bool {
        guard focusAuth == .granted else { return false }
        return INFocusStatusCenter.default.focusStatus.isFocused ?? false
    }

    /// 确保拿到「专注状态」权限——这是完成通知能守规矩的前提，**没有它，勿扰时那一声照样会响**。
    /// 所以每次启动、每次打开完成通知开关都查一遍，而不是首次问过就算了：
    ///   · 从没问过 → 弹系统授权框（就是那个 "share that you have notifications silenced" 的框）；
    ///   · 点过「不允许」→ **系统不会再问第二次**，只能我们出面解释，并把人送去系统设置；
    ///     顺手给一个「干脆关掉完成通知」的出路，免得他被反复追问又不想授权。
    @MainActor
    static func ensureFocusAuthorization(explainIfDenied: Bool, onChange: (() -> Void)? = nil) {
        switch focusAuth {
        case .granted:
            return
        case .notDetermined:
            INFocusStatusCenter.default.requestAuthorization { status in
                GALog.log("专注状态授权结果: \(status.rawValue)（2=已授权）")
                DispatchQueue.main.async { onChange?() }
            }
        case .denied:
            guard explainIfDenied else { return }
            let alert = NSAlert()
            alert.messageText = L("focus.alert.title")
            alert.informativeText = L("focus.alert.body")
            alert.addButton(withTitle: L("focus.alert.open"))      // 打开系统设置
            alert.addButton(withTitle: L("focus.alert.disable"))   // 关掉完成通知
            alert.addButton(withTitle: L("focus.alert.later"))     // 以后再说
            NSApp.activate(ignoringOtherApps: true)
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                openFocusPrivacySettings()
            case .alertSecondButtonReturn:
                AgentNotify.claudeEnabled = false
                AgentNotify.codexEnabled = false
                try? HookInstaller.uninstallClaudeStop()
                try? HookInstaller.uninstallCodexStop()
                GALog.log("用户选择关闭 Agent 完成通知（未授予专注状态权限）")
                onChange?()
            default:
                break
            }
        }
    }

    /// 打开「隐私与安全性 → 专注模式」。锚点名各系统版本不一，依次退到隐私总页。
    static func openFocusPrivacySettings() {
        for s in ["x-apple.systempreferences:com.apple.preference.security?Privacy_Focus",
                  "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Focus",
                  "x-apple.systempreferences:com.apple.preference.security"] {
            if let u = URL(string: s), NSWorkspace.shared.open(u) { return }
        }
    }

    /// 授权状态的可读描述（诊断用）。
    static var focusStatusText: String {
        switch focusAuth {
        case .granted: return isFocused ? "已授权 · 当前处于勿扰/专注（提示音会静音）" : "已授权 · 当前不在专注模式"
        case .denied:  return "已拒绝 —— 读不到专注状态，勿扰时提示音仍会响（系统设置 → 隐私与安全性 → 专注模式）"
        case .notDetermined: return "尚未询问（开启完成通知或下次启动时会问）"
        }
    }

    static let soundFileName = "AgentDone.aiff"
    /// `~/Library/Sounds/AgentDone.aiff` —— macOS 放自定义提示音的正规位置。
    static var userSoundURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Sounds").appendingPathComponent(soundFileName)
    }

    /// 把 bundle 里的提示音装进 `~/Library/Sounds`（已是同一份就跳过）。
    /// 我们自己播不强求这个位置，但装过去有两点好处：系统设置的提示音列表里能看到它，
    /// 用户想换成别的音也有个明确的落点。
    @discardableResult
    static func installCustomSound() -> Bool {
        guard let src = Bundle.main.url(forResource: "AgentDone", withExtension: "aiff") else {
            GALog.log("提示音 AgentDone.aiff 不在 bundle 的 Resources 根目录，退回系统默认音")
            return false
        }
        let dst = userSoundURL
        let fm = FileManager.default
        // 比修改时间而不是文件大小：重新渲染的提示音时长/格式不变时字节数完全一样，
        // 比大小会认成"已经装过"，于是永远用着旧那一版（换了旋律却没生效）。
        let srcT = (try? fm.attributesOfItem(atPath: src.path)[.modificationDate] as? Date) ?? nil
        let dstT = (try? fm.attributesOfItem(atPath: dst.path)[.modificationDate] as? Date) ?? nil
        if let dstT, let srcT, dstT >= srcT { return true }   // 已经是最新那一份
        do {
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
            GALog.log("提示音已装到 \(dst.path)")
            return true
        } catch {
            GALog.log("提示音安装失败: \(error.localizedDescription)，退回系统默认音")
            return false
        }
    }

    @discardableResult
    /// `sound: nil` = 通知静音（声音由调用方自己播，见 playAgentDone）。
    static func post(title: String, subtitle: String = "", body: String,
                     sound: UNNotificationSound? = .default,
                     thread: String? = nil,
                     identifier: String = UUID().uuidString) -> String {
        let content = UNMutableNotificationContent()
        content.title = title
        if !subtitle.isEmpty { content.subtitle = subtitle }
        content.body = body
        content.sound = sound
        // 同一个项目的完成通知归一组：通知中心里叠成一摞而不是铺开几十条
        // （实测跑几个会话一天就能堆上百条，全平铺根本没法看）。
        if let thread { content.threadIdentifier = thread }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        // 失败要留痕：投递被系统拒掉（授权被撤、内容超限…）时，以前是彻底无声无息的，
        // "这条怎么没弹"就没法查了。成功不记，免得刷屏。
        UNUserNotificationCenter.current().add(request) { err in
            if let err { GALog.log("通知投递失败: \(err.localizedDescription) 标题=\(title)") }
        }
        return identifier
    }

    /// 「我没看到通知」自检：打印授权与呈现方式，再发一条测试通知并回头查它有没有真的进通知中心。
    /// 能把三种情况分开：没授权 / 投递成功但被专注模式或"横幅样式=无"吞掉 / 压根没投递。
    static func diagnose(title: String, body: String, done: @escaping () -> Void) {
        UNUserNotificationCenter.current().delegate = Delegate.shared
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            let center = UNUserNotificationCenter.current()
            center.getNotificationSettings { s in
                let style: String
                switch s.alertStyle {
                case .none:   style = "无（不弹横幅，只进通知中心）"
                case .banner: style = "横幅（几秒后自动消失）"
                case .alert:  style = "提醒（停留到你处理）"
                @unknown default: style = "未知"
                }
                func flag(_ v: UNNotificationSetting) -> String {
                    switch v {
                    case .enabled: return "开"
                    case .disabled: return "关"
                    case .notSupported: return "不支持"
                    @unknown default: return "?"
                    }
                }
                print("授权: \(s.authorizationStatus.rawValue)（2=已授权）  提示: \(flag(s.alertSetting))  声音: \(flag(s.soundSetting))")
                print("通知中心: \(flag(s.notificationCenterSetting))  样式: \(style)  预览: \(s.showPreviewsSetting.rawValue)")
                // 「堆积了一大堆却从没见它弹过」的两个经典元凶，光看上面几项查不出来：
                print("定时摘要(通知摘要): \(flag(s.scheduledDeliverySetting))  时效性通知: \(flag(s.timeSensitiveSetting))")
                if s.scheduledDeliverySetting == .enabled {
                    print("⚠️ 这个 app 被放进了「通知摘要」——通知不会实时弹，只在摘要时段一起出现。")
                    print("   系统设置 → 通知 → 定时摘要，把 GestureApprove 移出去。")
                }
                if s.timeSensitiveSetting == .disabled {
                    print("提示: 专注模式开启时这类通知会被静音（只进通知中心）。")
                }
                print("提示音文件: \(installCustomSound() ? userSoundURL.path : "缺失（会退回系统提示音）")")
                print("勿扰/专注: \(focusStatusText)")
                print("发通知（静音）+ 自己播提示音…")
                playAgentDone()
                let id = post(title: title, subtitle: "~/LocalDev/gesture-approve", body: body, sound: nil)
                // 投递是异步的，给系统一点时间再回头查。
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    center.getDeliveredNotifications { list in
                        let hit = list.contains { $0.request.identifier == id }
                        print(hit
                            ? "✅ 这条已进通知中心（没看到横幅 = 被专注模式/勿扰静音，或样式设成了「无」）"
                            : "⚠️ 通知中心里找不到这条 —— 系统没收下它，看上面的授权与提示设置")
                        print("通知中心里 GestureApprove 现有 \(list.count) 条")
                        done()
                    }
                }
            }
        }
    }
}
