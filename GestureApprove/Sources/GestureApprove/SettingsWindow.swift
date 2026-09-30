import SwiftUI
import AppKit
import Combine
import ServiceManagement

extension Notification.Name {
    /// MediaPipe 安装窗安装成功后发出，设置窗据此刷新「已安装」状态。
    static let gaMediaPipeInstalled = Notification.Name("gaMediaPipeInstalled")
    /// 守门员组件下载成功后发出，设置窗据此刷新「就绪」状态。
    static let gaGatekeeperInstalled = Notification.Name("gaGatekeeperInstalled")
}

@MainActor
final class SettingsState: ObservableObject {
    @Published var active = true   // 窗口可见时为 true；关闭时置 false 以停止摄像头预览
    /// 两栏中较高那一栏的内容高度：窗口首次打开时据此收到刚好包住内容，不留一大片空白。
    @Published var contentHeight: CGFloat = 0
}

/// 分区图标一律黑白（跟随外观的次要色）：图标只是分区的标记，不该染上任何"可以点"的颜色——
/// 这个窗口里的彩色留给真正能操作的控件（勾选框、分段控件、链接按钮）。
private let sectionIconColor = Color.secondary

/// 量出一栏内容的自然高度（两栏取较大者）。
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 说明文字收进一个「?」：设置窗打开时是一列干净的选项，想看解释再点开，
/// 而不是每个开关下面都压着两行小字（那样整页看上去就是一堵文字墙）。
///
/// **点击**触发而不是 hover：hover 弹出的 popover，鼠标一移进去就判定"离开"把自己关掉，
/// 长一点的文案根本读不完（旧的 Codex 提示就是这个毛病）。
private struct HelpHint: View {
    let keys: [String]
    @State private var show = false

    init(_ keys: String...) { self.keys = keys }
    init(keys: [String]) { self.keys = keys }

    var body: some View {
        Button { show.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(L(keys.first ?? ""))       // 悬停给系统 tooltip，点开才是完整文案
        .popover(isPresented: $show, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(keys, id: \.self) { Text(L($0)) }
            }
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 260, alignment: .leading)   // 窄一点：靠左的「?」弹出时不至于探出窗口太多
            .padding(12)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var state: SettingsState
    // 显示**真实持久化的选择**（savedOrDefaultID，不回退）：所选设备被拔掉时插入"已断开"占位，
    // 让 UI 与审批行为一致。以前用带回退的读取，UI 显示内置摄像头且预览有画面、
    // 但持久值仍是已拔掉的设备 → 审批黑屏，用户完全无从排查（真实事故）。
    @State private var inputs: [VideoInput] = SettingsView.initialInputs()
    @State private var selectedID: String = VideoInputs.savedOrDefaultID()
    @State private var missingID: String? = SettingsView.disconnectedID()

    /// 保存的选择指向已不存在的相机时返回它（ESP32 无所谓在不在，排除）。
    private static func disconnectedID() -> String? {
        let saved = VideoInputs.savedOrDefaultID()
        guard saved != VideoInputs.esp32ID,
              !VideoInputs.available().contains(where: { $0.id == saved }) else { return nil }
        return saved
    }

    private static func initialInputs() -> [VideoInput] {
        var list = VideoInputs.available()
        if let missing = disconnectedID() {
            list.insert(VideoInput(id: missing, name: L("video.disconnected")), at: 0)
        }
        return list
    }
    @State private var claudeInstalled = HookInstaller.isClaudeInstalled()
    @State private var codexInstalled = HookInstaller.isCodexInstalled()
    @State private var geminiInstalled = HookInstaller.isGeminiInstalled()
    @State private var kimiInstalled = HookInstaller.isKimiInstalled()
    @State private var minConf: Double = (UserDefaults.standard.object(forKey: "gestureMinConf") as? Double) ?? 0.6
    @State private var errorText: String?
    @State private var engine: String = UserDefaults.standard.string(forKey: MediaPipeInstaller.engineKey) ?? "vision"
    @State private var mpInstalled = MediaPipeInstaller.isInstalled()
    @State private var rotation: Int = (UserDefaults.standard.object(forKey: "frameRotation") as? Int) ?? 0
    @State private var allowlistText: String = Allowlist.patterns().joined(separator: "\n")
    @State private var trusted: [String] = Allowlist.trustedCommands()
    @State private var smartGate: Bool = Gatekeeper.isEnabled
    @State private var gateInstalled: Bool = Gatekeeper.isInstalled
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled
    @State private var appLang: String = UserDefaults.standard.string(forKey: I18n.langKey) ?? "system"
    @State private var confirmRestore = false
    @State private var checkingUpdate = false
    @State private var updateText = ""
    @State private var updateAsset: URL? = nil    // 新版 zip 直链（app 自更新）
    @State private var updatePage: URL? = nil     // release 页（找不到 zip 时回退）
    @State private var updateVersion = ""         // 新版本号（弹窗标题用）
    @State private var updateNotes = ""           // 新版 changelog（弹窗正文用）
    @State private var installing = false
    @State private var deviceApiOn: Bool = DeviceApi.isEnabled
    @State private var agentNotify: Bool = AgentNotify.claudeEnabled
    @State private var agentNotifyCodex: Bool = AgentNotify.codexEnabled
    @State private var focusAuth: Notifier.FocusAuth = Notifier.focusAuth
    @State private var agentNotifyDesktop: Bool = AgentNotify.desktopEnabled
    @State private var agentNotifyHub: Bool = AgentNotify.hubEnabled
    @State private var usageInMenu: Bool = UsageMonitor.isEnabled
    @State private var usageSource: UsageSource = UsageMonitor.source
    @State private var usageSnoozed: Bool = UsageMonitor.isSnoozed
    @State private var usageCollect: Bool = UsageMonitor.collecting
    @State private var usageCollectors: [MObject] = MonitorHooks.status()
    let openFlash: () -> Void
    let onPrimeESP32: () -> Void
    let onEngineChanged: () -> Void
    let openMediaPipeInstall: () -> Void
    let openGatekeeperInstall: () -> Void
    let onDeviceApiChanged: (Bool) -> Void
    let openHubConfig: () -> Void

    // 统一的视觉节奏：分区之间 / 分区内元素之间
    private let sectionSpacing: CGFloat = 14
    private let itemSpacing: CGFloat = 6
    private let columnWidth: CGFloat = 448

    private var selectedIsESP32: Bool { selectedID == VideoInputs.esp32ID }

    var body: some View {
        // 左右两栏各自独立滚动:每栏一个 ScrollView,窗口高度在 show() 里钳住,于是两栏分别在窗内滚。
        HStack(alignment: .top, spacing: 20) {
            ScrollView {
                leftColumn.frame(width: columnWidth, alignment: .topLeading)
                    .padding(.vertical, 18)
                    .background(heightReporter)
            }
            .frame(width: columnWidth)
            Divider()
            ScrollView {
                rightColumn.frame(width: columnWidth, alignment: .topLeading)
                    .padding(.vertical, 18)
                    .background(heightReporter)
            }
            .frame(width: columnWidth)
        }
        .padding(.horizontal, 18)
        .onPreferenceChange(ContentHeightKey.self) { h in
            MainActor.assumeIsolated { state.contentHeight = h }
        }
        .alert(L("settings.alert.title"), isPresented: Binding(get: { errorText != nil },
                                                set: { if !$0 { errorText = nil } })) {
            Button(L("settings.alert.ok"), role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .gaMediaPipeInstalled)) { _ in
            mpInstalled = MediaPipeInstaller.isInstalled()   // 安装窗装完后刷新「已安装」状态
        }
        .onReceive(NotificationCenter.default.publisher(for: .gaGatekeeperInstalled)) { _ in
            gateInstalled = Gatekeeper.isInstalled           // 守门员下载完后刷新「就绪」+ 已被装好流程开启
            smartGate = Gatekeeper.isEnabled
        }
        .onAppear {
            mpInstalled = MediaPipeInstaller.isInstalled()
            engine = UserDefaults.standard.string(forKey: MediaPipeInstaller.engineKey) ?? "vision"
            trusted = Allowlist.trustedCommands()
            launchAtLogin = LaunchAtLogin.isEnabled
            smartGate = Gatekeeper.isEnabled
            gateInstalled = Gatekeeper.isInstalled
            // 开关开着但 hook 不在（换过 app 路径、手改过 settings.json）→ 补装一次，
            // 让"开着"永远等于"真的会通知"。只在不一致时写文件，不会每次打开设置都改用户配置。
            agentNotify = AgentNotify.claudeEnabled
            agentNotifyCodex = AgentNotify.codexEnabled
            if agentNotify, !HookInstaller.isClaudeStopInstalled() {
                do { try HookInstaller.installClaudeStop() } catch { errorText = "\(error)" }
            }
            if agentNotifyCodex, !HookInstaller.isCodexStopInstalled() {
                do { try HookInstaller.installCodexStop() } catch { errorText = "\(error)" }
            }
            // 采集同理：开着但配置不在位就补装一次，然后按补装后的真实状态刷新这几行。
            usageCollect = UsageMonitor.collecting
            UsageMonitor.repairIfNeeded()
            usageCollectors = MonitorHooks.status()
            agentNotifyDesktop = AgentNotify.desktopEnabled
            agentNotifyHub = AgentNotify.hubEnabled
            focusAuth = Notifier.focusAuth
            // 功能开着却没这个权限 = 勿扰时会吵人，打开设置窗时再追一次（被拒过就只提示不弹系统框）
            if agentNotify || agentNotifyCodex { demandFocusPermission(explainIfDenied: false) }
            // 旧的连续值（如 0.55）吸附到最近的档位，否则分段控件不高亮
            let snapped = [0.3, 0.6, 0.9].min(by: { abs($0 - minConf) < abs($1 - minConf) }) ?? 0.6
            if snapped != minConf { minConf = snapped; UserDefaults.standard.set(snapped, forKey: "gestureMinConf") }
        }
    }

    // MARK: 左栏 — 通用与权限

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            // 通用
            header("settings.section.general", icon: "gearshape")
            VStack(alignment: .leading, spacing: itemSpacing) {
                Toggle(L("menu.launchAtLogin"), isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }))
                HStack(spacing: 8) {
                    Text(L("settings.language"))
                    Picker("", selection: Binding(
                        get: { appLang },
                        set: { v in
                            UserDefaults.standard.set(v, forKey: I18n.langKey)   // 先写偏好，重渲染即读到新语言
                            appLang = v
                        })) {
                        Text(L("settings.language.system")).tag("system")
                        Text("English").tag("en")
                        Text("简体中文").tag("zh")
                        Text("日本語").tag("ja")
                        Text("한국어").tag("ko")
                        Text("Español").tag("es")
                        Text("Français").tag("fr")
                    }
                    .labelsHidden()
                    .fixedSize()
                    HelpHint("settings.language.note")
                    Spacer()
                }

                // 版本 + 检查更新（走 GitHub Releases）
                HStack(spacing: 8) {
                    Text("\(L("settings.version")) \(Updater.current)")
                        .foregroundStyle(.secondary)
                    Button(checkingUpdate ? L("settings.checking") : L("settings.checkUpdate")) {
                        checkUpdate()
                    }
                    .disabled(checkingUpdate || installing)
                    if let asset = updateAsset {
                        Button(installing ? L("settings.update.downloading") : L("settings.installUpdate")) {
                            startInstall(asset)
                        }
                        .disabled(installing)
                    } else if let page = updatePage {
                        Button(L("settings.download")) { NSWorkspace.shared.open(page) }
                    }
                    Spacer()
                }
                .font(.system(size: 11))
                if !updateText.isEmpty {
                    Text(updateText).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            Divider()

            // 接入 AI 工具
            header("settings.section.connect", icon: "terminal", "settings.connectDesc", "settings.hotkeyDesc")
            VStack(alignment: .leading, spacing: itemSpacing) {
                // 四个接入开关横排一行，节约高度。
                HStack(spacing: 14) {
                    Toggle("Claude Code", isOn: Binding(
                        get: { claudeInstalled },
                        set: { on in
                            do {
                                try on ? HookInstaller.installClaude() : HookInstaller.uninstallClaude()
                                claudeInstalled = on
                            } catch { errorText = "\(error)" }
                        }))
                        .fixedSize()
                    HStack(spacing: 3) {
                        Toggle("Codex", isOn: Binding(
                            get: { codexInstalled },
                            set: { on in
                                do {
                                    try on ? HookInstaller.installCodex() : HookInstaller.uninstallCodex()
                                    codexInstalled = on
                                } catch { errorText = "\(error)" }
                            }))
                            .fixedSize()
                        HelpHint("settings.connectCodexNote")   // Codex 要 /hooks 信任一次
                    }
                    Toggle("Gemini CLI", isOn: Binding(
                        get: { geminiInstalled },
                        set: { on in
                            do {
                                try on ? HookInstaller.installGemini() : HookInstaller.uninstallGemini()
                                geminiInstalled = on
                            } catch { errorText = "\(error)" }
                        }))
                        .fixedSize()
                    Toggle("Kimi CLI", isOn: Binding(
                        get: { kimiInstalled },
                        set: { on in
                            do {
                                try on ? HookInstaller.installKimi() : HookInstaller.uninstallKimi()
                                kimiInstalled = on
                            } catch { errorText = "\(error)" }
                        }))
                        .fixedSize()
                    Spacer(minLength: 0)
                }

                Divider().padding(.vertical, 2)
                // 用量显示也属于「接入的 AI 工具」这件事：哪个在跑就显示哪个的额度。
                HStack(spacing: 5) {
                    Toggle(L("settings.usage.enable"), isOn: Binding(
                        get: { usageInMenu },
                        set: { v in
                            usageInMenu = v
                            UserDefaults.standard.set(v, forKey: UsageMonitor.enabledKey)
                        }))
                        .fixedSize()
                    HelpHint("settings.usage.note")
                    Spacer(minLength: 0)
                }
                if usageInMenu {
                    // 弹窗里点过「临时关闭（24 小时）」——给条明路回来，不然只能干等。
                    if usageSnoozed {
                        HStack {
                            caption("settings.usage.snoozed")
                            Button(L("settings.usage.resume")) {
                                UsageMonitor.endSnooze()
                                usageSnoozed = false
                            }
                            .controlSize(.small)
                        }
                    }
                    // 开关即安装：勾上就往本机各家 AI 工具的配置里注册采集器，关掉就还原。
                    // 让「开着」等于「真的在采」——以前这个开关只管显示，数据得去 Hub 网页里另装。
                    HStack(spacing: 5) {
                        Toggle(L("settings.usage.collect"), isOn: Binding(
                            get: { usageCollect },
                            set: { on in
                                let result = MonitorHooks.apply(uninstall: !on)
                                usageCollectors = MonitorHooks.status()
                                guard result["ok"] as? Bool == true else {
                                    errorText = (result["results"] as? [MObject] ?? [])
                                        .compactMap { $0["error"] as? String }.joined(separator: "\n")
                                    return   // 失败就别把开关留在「开」上
                                }
                                UsageMonitor.collecting = on
                                usageCollect = on
                            }))
                            .fixedSize()
                        // 原理和边界进问号，不占正文：这一屏真正要给的是「现在采到没有」。
                        HelpHint("settings.usage.collectNote", "settings.usage.collectPrivacy")
                        Spacer(minLength: 0)
                    }
                    ForEach(usageCollectors.indices, id: \.self) { i in
                        caption(verbatim: Self.collectorLine(usageCollectors[i]))
                    }
                }
            }

            Divider()

            // Agent 完成通知（Claude Code 的 Stop hook —— 只旁观，不干预 agent）
            header("settings.section.agentnotify", icon: "bell.badge", "settings.agentnotify.desc", "settings.agentnotify.codexTrust")
            VStack(alignment: .leading, spacing: itemSpacing) {
                // 两家各装各的 Stop hook（Claude: ~/.claude/settings.json；Codex: ~/.codex/config.toml）
                HStack(spacing: 14) {
                    Toggle("Claude Code", isOn: Binding(
                        get: { agentNotify },
                        set: { on in
                            do {
                                try on ? HookInstaller.installClaudeStop() : HookInstaller.uninstallClaudeStop()
                                AgentNotify.claudeEnabled = on
                                agentNotify = on
                                if on { demandFocusPermission() }
                            } catch {
                                errorText = "\(error)"   // hook 没装成就别把开关点亮，否则显示与实际不符
                                agentNotify = AgentNotify.claudeEnabled
                            }
                        }))
                        .fixedSize()
                    Toggle("Codex", isOn: Binding(
                        get: { agentNotifyCodex },
                        set: { on in
                            do {
                                try on ? HookInstaller.installCodexStop() : HookInstaller.uninstallCodexStop()
                                AgentNotify.codexEnabled = on
                                agentNotifyCodex = on
                                if on { demandFocusPermission() }
                            } catch {
                                errorText = "\(error)"
                                agentNotifyCodex = AgentNotify.codexEnabled
                            }
                        }))
                        .fixedSize()
                    Spacer(minLength: 0)
                }
                // 没这个权限，勿扰/专注时提示音照样响 —— 属于"开了但不好使"，得让人一眼看见。
                if (agentNotify || agentNotifyCodex), focusAuth != .granted {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(L("settings.agentnotify.focusMissing"))
                        Button(L("settings.agentnotify.focusGrant")) { demandFocusPermission() }
                            .controlSize(.small)
                    }
                    .font(.system(size: 11))
                }
                if agentNotify || agentNotifyCodex {
                    Toggle(L("settings.agentnotify.desktop"), isOn: Binding(
                        get: { agentNotifyDesktop },
                        set: { v in agentNotifyDesktop = v; AgentNotify.desktopEnabled = v }))
                        .padding(.leading, 16)
                    HStack(spacing: 5) {
                        Toggle(L("settings.agentnotify.hub"), isOn: Binding(
                            get: { agentNotifyHub },
                            set: { v in agentNotifyHub = v; AgentNotify.hubEnabled = v }))
                            .fixedSize()
                        HelpHint("settings.agentnotify.hubNote")
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 16)
                }
            }

            Divider()

            // 智能放行（本地 LLM 守门员）
            header("settings.section.smartgate", icon: "sparkles", "settings.smartgate.desc", "settings.smartgate.hookNote")
            VStack(alignment: .leading, spacing: itemSpacing) {
                Toggle(L("settings.smartgate.enable"), isOn: Binding(
                    get: { smartGate },
                    set: { on in
                        Gatekeeper.isEnabled = on
                        smartGate = on
                        gateInstalled = Gatekeeper.isInstalled
                        if on { Gatekeeper.shared.startIfNeeded() } else { Gatekeeper.shared.stop() }
                    }))
                if smartGate {
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Image(systemName: gateInstalled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            Text(L(gateInstalled ? "settings.smartgate.installed" : "settings.smartgate.notInstalled"))
                        }
                        .foregroundStyle(gateInstalled ? Color.green : Color.orange)
                        Button(L(gateInstalled ? "settings.smartgate.redownload" : "settings.smartgate.download")) {
                            openGatekeeperInstall()
                        }
                    }
                    .font(.system(size: 11))
                }
            }

            Divider()

            // 自动放行规则（正则）
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(sectionIconColor)
                    .frame(width: 16)
                Text(L("settings.section.allowlist")).font(.headline)
                HelpHint("settings.allowlist.desc")
                Spacer()
                Button(L("settings.allowlist.restore")) { confirmRestore = true }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .confirmationDialog(L("settings.allowlist.restoreConfirm"),
                                    isPresented: $confirmRestore, titleVisibility: .visible) {
                    Button(L("settings.allowlist.restore"), role: .destructive) {
                        allowlistText = Allowlist.defaultPatterns.joined(separator: "\n")
                        Allowlist.setPatterns(Allowlist.defaultPatterns)
                    }
                    Button(L("settings.cancel"), role: .cancel) { }
                }
            }
            TextEditor(text: $allowlistText)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 56)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
                .onChange(of: allowlistText) { _, v in
                    Allowlist.setPatterns(v.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
                }

            // 信任的命令（点“总是允许”写入，可逐条删除）
            header("settings.section.trusted", icon: "checkmark.seal", "settings.trusted.desc")
            trustedList
        }
    }

    // MARK: 右栏 — 摄像头与识别

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            // 视频输入源
            header("settings.section.video", icon: "video")
            HStack(spacing: 6) {
                Picker("", selection: $selectedID) {
                    ForEach(inputs) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .onChange(of: selectedID) { _, newValue in
                    VideoInputs.setCurrentID(newValue)
                    if newValue == VideoInputs.esp32ID { onPrimeESP32() }   // 选中 ESP32 即复位预热
                    if let missing = missingID, newValue != missing {       // 改选了真实设备：撤掉"已断开"占位
                        missingID = nil
                        inputs.removeAll { $0.id == missing }
                    }
                }
                Button(action: reload) { Image(systemName: "arrow.clockwise") }
                    .help(L("settings.refresh.help"))
                Picker("", selection: $rotation) {
                    Text(L("settings.rotation.none")).tag(0)
                    Text("90°").tag(90)
                    Text("180°").tag(180)
                    Text("270°").tag(270)
                }
                .labelsHidden()
                .fixedSize()
                .help(L("settings.rotation.help"))
                .onChange(of: rotation) { _, v in
                    UserDefaults.standard.set(v, forKey: "frameRotation")
                }
            }

            // 预览
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.black)
                if selectedIsESP32 {
                    VStack(spacing: 10) {
                        Image(systemName: "cable.connector.horizontal").font(.system(size: 28))
                        Text(L("settings.esp32.noPreview"))
                        Text(L("settings.esp32.noPreviewHint"))
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                } else if missingID != nil && selectedID == missingID {
                    // 所选相机已被拔掉：说清运行时行为（临时回退），别黑屏装死
                    VStack(spacing: 10) {
                        Image(systemName: "video.slash").font(.system(size: 28))
                        Text(L("video.disconnected"))
                        Text(L("video.disconnected.hint"))
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                } else if state.active {
                    CameraPreview(deviceUniqueID: selectedID, rotation: rotation)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .frame(height: 200)

            Divider()

            // 识别引擎
            header("settings.section.engine", icon: "cpu", "settings.engine.desc")
            VStack(alignment: .leading, spacing: itemSpacing) {
                Picker("", selection: $engine) {
                    Text(L("settings.engine.vision")).tag("vision")
                    Text(L("settings.engine.mediapipe")).tag("mediapipe")
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .onChange(of: engine) { _, v in
                    UserDefaults.standard.set(v, forKey: MediaPipeInstaller.engineKey)
                    if v == "mediapipe" && !mpInstalled { openMediaPipeInstall() }
                    onEngineChanged()
                }
                if engine == "mediapipe" {
                    HStack(spacing: 8) {
                        if mpInstalled {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                Text(L("settings.engine.installed"))
                            }.foregroundStyle(.green)
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                Text(L("settings.engine.notInstalled"))
                            }.foregroundStyle(.orange)
                        }
                        Button(mpInstalled ? L("settings.engine.redownload") : L("settings.engine.download")) { openMediaPipeInstall() }
                    }
                    .font(.system(size: 11))
                }
            }

            Divider()

            // 识别精准度：三档，控制几何判定的松紧
            header("settings.section.precision", icon: "target")
            Picker("", selection: $minConf) {
                Text(L("settings.precision.loose")).tag(0.3)
                Text(L("settings.precision.standard")).tag(0.6)
                Text(L("settings.precision.strict")).tag(0.9)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: minConf) { _, v in UserDefaults.standard.set(v, forKey: "gestureMinConf") }

            Divider()

            // ESP32-CAM 入口：单行窄条（这是给少数人用的可选硬件，不该占掉一整块版面）。
            // 说明挪进条子右侧的「?」——它在按钮**外面**，避免按钮套按钮点哪儿都触发刷写。
            HStack(spacing: 5) {
                Button(action: openFlash) {
                    HStack(spacing: 8) {
                        Image(systemName: "camera.aperture")
                            .font(.system(size: 13))
                            .foregroundStyle(.tint)
                        Text(L("settings.esp32card.title"))
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                HelpHint("settings.esp32card.desc")
            }

            Divider()

            // 远程审批设备（ESP32 等经 HTTP API 审批）
            header("settings.section.deviceapi", icon: "antenna.radiowaves.left.and.right", "settings.deviceapi.desc")
            VStack(alignment: .leading, spacing: itemSpacing) {
                Toggle(L("settings.deviceapi.enable"), isOn: Binding(
                    get: { deviceApiOn },
                    set: { on in
                        DeviceApi.isEnabled = on
                        deviceApiOn = on
                        onDeviceApiChanged(on)   // 运行时起停设备监听，无需重启
                    }))
                // 连接信息(地址/token/其它网卡)集中到 hub 的 /config 页展示,这里只放一个跳转按钮。
                if deviceApiOn {
                    Button(L("settings.deviceapi.openConfig")) { openHubConfig() }
                        .controlSize(.small)
                        .padding(.top, 2)
                }
            }
        }
    }


    // MARK: 复用小部件

    /// 内容高度上报（放在 background 里，不参与布局）。
    private var heightReporter: some View {
        GeometryReader { g in
            Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
        }
    }

    /// 分区标题：SF Symbol + 标题 +（可选）说明的「?」。
    /// 图标只是分区的视觉锚点，让一长列开关有节奏、扫一眼能定位到自己要找的那节。
    @ViewBuilder private func header(_ key: String, icon: String, _ help: String...) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(sectionIconColor)
                .frame(width: 16)
            Text(L(key)).font(.headline)
            if !help.isEmpty { HelpHint(keys: help) }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func caption(_ key: String) -> some View {
        Text(L(key))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func caption(verbatim text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 「Claude Code — 采集中」。本机没装这家工具时说「本机未安装」，别让用户以为是接入失败。
    static func collectorLine(_ row: MObject) -> String {
        let name = row["name"] as? String ?? row["id"] as? String ?? ""
        let state: String
        if row["present"] as? Bool != true { state = L("settings.usage.state.missing") }
        else {
            switch row["state"] as? String {
            case "installed": state = L("settings.usage.state.collecting")
            case "stale": state = L("settings.usage.state.stale")
            default: state = L("settings.usage.state.absent")
            }
        }
        return name + " — " + state
    }

    @ViewBuilder private var trustedList: some View {
        if trusted.isEmpty {
            Text(L("settings.trusted.empty"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        } else {
            // 信任命令是唯一会无限增长的列表 -> 封顶高度，超出内部滚动，避免把窗口撑过屏幕。
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(trusted, id: \.self) { cmd in
                        HStack(spacing: 6) {
                            Text(cmd)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Button {
                                Allowlist.removeTrustedCommand(cmd)
                                trusted = Allowlist.trustedCommands()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help(L("settings.trusted.remove"))
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 8)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(.trailing, 4)   // 给滚动条留位
            }
            .frame(maxHeight: 156)       // 约 6 条；再多则内部滚动，窗口高度不变
            // ScrollView 默认会把给它的空间吃满：只有一条命令时也照样撑满 156，
            // 窗口按内容贴合高度就会白白多出一截。fixedSize 让它取内容高度，
            // 上面的 maxHeight 仍然封顶（超过就恢复滚动）。
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func checkUpdate() {
        checkingUpdate = true
        updateText = ""
        updateAsset = nil
        updatePage = nil
        Updater.check { outcome in
            checkingUpdate = false
            switch outcome {
            case .upToDate:
                updateText = L("settings.upToDate")
            case .updateAvailable(let version, let asset, let page, let notes):
                updateText = "\(L("settings.updateAvailable")) \(version)"
                updateVersion = version
                updateNotes = notes
                updateAsset = asset
                updatePage = page
            case .failed:
                updateText = L("settings.updateFailed")
            }
        }
    }

    /// 点「立即更新」：先弹确认框显示该版本 changelog，确认后 app 自己下载 → 替换 → 重启（成功不返回）。
    private func startInstall(_ asset: URL) {
        let alert = NSAlert()
        alert.messageText = "\(L("settings.updateAvailable")) \(updateVersion)"
        alert.informativeText = updateNotes.isEmpty ? "" : Updater.plainNotes(updateNotes)
        alert.addButton(withTitle: L("settings.installUpdate"))   // 第一个按钮：更新
        alert.addButton(withTitle: L("settings.cancel"))          // 第二个按钮：取消
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        installing = true
        updateText = L("settings.update.downloading")
        Updater.installUpdate(from: asset, status: { s in
            updateText = s
        }, failure: { _ in
            installing = false
            updateText = L("settings.update.installFailed")
            if let p = updatePage { NSWorkspace.shared.open(p) }   // 自更新失败 → 回退打开下载页
        })
    }

    /// 索要「专注状态」权限：没问过就弹系统框，被拒过就弹我们自己的说明框（并给关掉功能的出路）。
    private func demandFocusPermission(explainIfDenied: Bool = true) {
        Notifier.ensureFocusAuthorization(explainIfDenied: explainIfDenied) {
            focusAuth = Notifier.focusAuth
            agentNotify = AgentNotify.claudeEnabled       // 用户可能在弹窗里选了"关掉完成通知"
            agentNotifyCodex = AgentNotify.codexEnabled
        }
        focusAuth = Notifier.focusAuth
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            try LaunchAtLogin.set(on)
        } catch {
            errorText = "\(error)"
        }
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    private func reload() {
        inputs = VideoInputs.available()
        let saved = VideoInputs.savedOrDefaultID()
        if saved != VideoInputs.esp32ID, !inputs.contains(where: { $0.id == saved }) {
            // 所选设备仍缺席：保留"已断开"占位而不是悄悄改写用户的选择——
            // 审批时 CameraFrameSource 会临时回退，插回设备后一切自动恢复。
            missingID = saved
            inputs.insert(VideoInput(id: saved, name: L("video.disconnected")), at: 0)
        } else {
            missingID = nil
        }
        selectedID = saved
        if selectedID == VideoInputs.esp32ID { onPrimeESP32() }   // 刷新时若用 ESP32，复位预热
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let state = SettingsState()
    /// 还等着按内容高度收一次窗口（收完置 false）。
    private var fitToContent = false
    /// 用户亲手拖过窗口高度 —— 从此不再自作主张改它。
    private var userResized = false
    private var heightObserver: AnyCancellable?

    func show(openFlash: @escaping () -> Void,
              onPrimeESP32: @escaping () -> Void,
              onEngineChanged: @escaping () -> Void,
              openMediaPipeInstall: @escaping () -> Void,
              openGatekeeperInstall: @escaping () -> Void,
              onDeviceApiChanged: @escaping (Bool) -> Void,
              openHubConfig: @escaping () -> Void) {
        // 每次打开都重建视图：设置窗是复用的（关闭只隐藏），若沿用旧视图，其 @State 快照（信任命令、
        // 开机自启等）停留在上次打开时的值——比如刚在卡片上点的「总是允许」就不会显示。重建则重读最新。
        let hosting = NSHostingController(rootView: SettingsView(
            state: state, openFlash: openFlash, onPrimeESP32: onPrimeESP32,
            onEngineChanged: onEngineChanged, openMediaPipeInstall: openMediaPipeInstall,
            openGatekeeperInstall: openGatekeeperInstall, onDeviceApiChanged: onDeviceApiChanged,
            openHubConfig: openHubConfig))
        let creating = (window == nil)
        if creating {
            let w = NSWindow(contentViewController: hosting)
            w.title = L("settings.windowTitle")
            // .resizable:允许拖右下角调高度。宽度另用 contentMin/MaxSize 锁死(两栏固定宽,横向拉伸无意义)。
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false   // ARC 管理，避免关闭崩溃/退出
            w.delegate = self
            window = w
        } else {
            window?.contentViewController = hosting   // 复用窗口但换新视图，刷新所有 @State
        }
        // 锁宽 + 放开高度:拖右下角只调高度;高度上限不超过屏幕可视区(菜单栏/Dock 之外),避免盖住 Dock。
        // 首次打开给个保守初值,等 SwiftUI 量出真实内容高度后再收紧(见 fitToContent)。
        if let w = window {
            let vf = (w.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 820)
            let cw = max(hosting.view.fittingSize.width, 952)
            let maxH = vf.height - 28          // 留标题栏
            w.contentMinSize = NSSize(width: cw, height: 360)
            w.contentMaxSize = NSSize(width: cw, height: maxH)
            let curH = w.contentLayoutRect.height
            let newH = (creating || curH < 360 || curH > maxH) ? min(maxH, 900) : curH
            w.setContentSize(NSSize(width: cw, height: newH))
        }
        // 内容高度是 SwiftUI 布局后才知道的，所以窗口"贴合内容"要等第一次上报回来再做。
        // 每次打开都重新贴合（信任命令增删、语言切换都会改变内容高度）——
        // 唯独用户自己拖过高度之后不再插手，那是他的选择。
        fitToContent = !userResized
        state.active = true              // 重新打开 -> 恢复预览
        heightObserver = state.$contentHeight.sink { [weak self] h in
            MainActor.assumeIsolated { self?.applyContentHeight(h) }
        }
        NSApp.activate(ignoringOtherApps: true)
        if creating { window?.center() }   // 只首次居中;之后保留用户挪动/调整过的位置与高度
        window?.makeKeyAndOrderFront(nil)
    }

    /// 把窗口收到刚好包住内容（上限仍是屏幕可视区）。内容比屏幕高时维持上限，两栏各自滚动。
    private func applyContentHeight(_ h: CGFloat) {
        guard fitToContent, h > 0, let w = window else { return }
        fitToContent = false
        let vf = (w.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 820)
        let target = min(vf.height - 28, max(360, h))
        guard abs(target - w.contentLayoutRect.height) > 1 else { return }
        w.setContentSize(NSSize(width: w.contentLayoutRect.width, height: target))
        w.center()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        userResized = true       // 只有用户拖动会走到这里；程序 setContentSize 不触发
    }

    func windowWillClose(_ notification: Notification) {
        state.active = false             // 关闭 -> 停止预览、熄灭摄像头；app 继续在菜单栏运行
    }
}
