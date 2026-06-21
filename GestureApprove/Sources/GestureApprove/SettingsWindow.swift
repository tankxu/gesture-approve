import SwiftUI
import AppKit
import ServiceManagement

@MainActor
final class SettingsState: ObservableObject {
    @Published var active = true   // 窗口可见时为 true；关闭时置 false 以停止摄像头预览
}

struct SettingsView: View {
    @ObservedObject var state: SettingsState
    @State private var inputs: [VideoInput] = VideoInputs.available()
    @State private var selectedID: String = VideoInputs.currentID()
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
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled
    @State private var appLang: String = UserDefaults.standard.string(forKey: I18n.langKey) ?? "system"
    @State private var confirmRestore = false
    @State private var checkingUpdate = false
    @State private var updateText = ""
    @State private var updateURL: URL? = nil
    let openFlash: () -> Void
    let onPrimeESP32: () -> Void
    let onEngineChanged: () -> Void
    let openMediaPipeInstall: () -> Void

    // 统一的视觉节奏：分区之间 / 分区内元素之间
    private let sectionSpacing: CGFloat = 14
    private let itemSpacing: CGFloat = 6
    private let columnWidth: CGFloat = 448

    private var selectedIsESP32: Bool { selectedID == VideoInputs.esp32ID }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            leftColumn.frame(width: columnWidth, alignment: .topLeading)
            Divider()
            rightColumn.frame(width: columnWidth, alignment: .topLeading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(18)
        .alert(L("settings.alert.title"), isPresented: Binding(get: { errorText != nil },
                                                set: { if !$0 { errorText = nil } })) {
            Button(L("settings.alert.ok"), role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .onAppear {
            mpInstalled = MediaPipeInstaller.isInstalled()
            engine = UserDefaults.standard.string(forKey: MediaPipeInstaller.engineKey) ?? "vision"
            trusted = Allowlist.trustedCommands()
            launchAtLogin = LaunchAtLogin.isEnabled
            // 旧的连续值（如 0.55）吸附到最近的档位，否则分段控件不高亮
            let snapped = [0.3, 0.6, 0.9].min(by: { abs($0 - minConf) < abs($1 - minConf) }) ?? 0.6
            if snapped != minConf { minConf = snapped; UserDefaults.standard.set(snapped, forKey: "gestureMinConf") }
        }
    }

    // MARK: 左栏 — 通用与权限

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            // 通用
            header("settings.section.general")
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
                    Spacer()
                }
                caption("settings.language.note")

                // 版本 + 检查更新（走 GitHub Releases）
                HStack(spacing: 8) {
                    Text("\(L("settings.version")) \(Updater.current)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let url = updateURL {
                        Button(L("settings.download")) { NSWorkspace.shared.open(url) }
                    }
                    Button(checkingUpdate ? L("settings.checking") : L("settings.checkUpdate")) {
                        checkUpdate()
                    }
                    .disabled(checkingUpdate)
                }
                .font(.caption)
                if !updateText.isEmpty {
                    Text(updateText).font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()

            // 接入 AI 工具
            header("settings.section.connect")
            VStack(alignment: .leading, spacing: itemSpacing) {
                Toggle(L("settings.connectClaude"), isOn: Binding(
                    get: { claudeInstalled },
                    set: { on in
                        do {
                            try on ? HookInstaller.installClaude() : HookInstaller.uninstallClaude()
                            claudeInstalled = on
                        } catch { errorText = "\(error)" }
                    }))
                Toggle(L("settings.connectCodex"), isOn: Binding(
                    get: { codexInstalled },
                    set: { on in
                        do {
                            try on ? HookInstaller.installCodex() : HookInstaller.uninstallCodex()
                            codexInstalled = on
                        } catch { errorText = "\(error)" }
                    }))
                Toggle(L("settings.connectGemini"), isOn: Binding(
                    get: { geminiInstalled },
                    set: { on in
                        do {
                            try on ? HookInstaller.installGemini() : HookInstaller.uninstallGemini()
                            geminiInstalled = on
                        } catch { errorText = "\(error)" }
                    }))
                Toggle(L("settings.connectKimi"), isOn: Binding(
                    get: { kimiInstalled },
                    set: { on in
                        do {
                            try on ? HookInstaller.installKimi() : HookInstaller.uninstallKimi()
                            kimiInstalled = on
                        } catch { errorText = "\(error)" }
                    }))
                caption("settings.connectCodexNote")
                caption("settings.connectDesc")
                caption("settings.hotkeyDesc")
            }

            Divider()

            // 自动放行规则（正则）
            HStack(alignment: .firstTextBaseline) {
                Text(L("settings.section.allowlist")).font(.headline)
                Spacer()
                Button(L("settings.allowlist.restore")) { confirmRestore = true }
                .buttonStyle(.link)
                .font(.caption)
                .confirmationDialog(L("settings.allowlist.restoreConfirm"),
                                    isPresented: $confirmRestore, titleVisibility: .visible) {
                    Button(L("settings.allowlist.restore"), role: .destructive) {
                        allowlistText = Allowlist.defaultPatterns.joined(separator: "\n")
                        Allowlist.setPatterns(Allowlist.defaultPatterns)
                    }
                    Button(L("settings.cancel"), role: .cancel) { }
                }
            }
            caption("settings.allowlist.desc")
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
            header("settings.section.trusted")
            caption("settings.trusted.desc")
            trustedList

            Spacer(minLength: 0)
        }
    }

    // MARK: 右栏 — 摄像头与识别

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            // 视频输入源
            header("settings.section.video")
            HStack(spacing: 6) {
                Picker("", selection: $selectedID) {
                    ForEach(inputs) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .onChange(of: selectedID) { _, newValue in
                    VideoInputs.setCurrentID(newValue)
                    if newValue == VideoInputs.esp32ID { onPrimeESP32() }   // 选中 ESP32 即复位预热
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
                            .font(.caption)
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
            header("settings.section.engine")
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
                    .font(.caption)
                }
                caption("settings.engine.desc")
            }

            Divider()

            // 识别精准度：三档，控制几何判定的松紧
            header("settings.section.precision")
            Picker("", selection: $minConf) {
                Text(L("settings.precision.loose")).tag(0.3)
                Text(L("settings.precision.standard")).tag(0.6)
                Text(L("settings.precision.strict")).tag(0.9)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: minConf) { _, v in UserDefaults.standard.set(v, forKey: "gestureMinConf") }

            Divider()

            // ESP32-CAM 入口：横条卡片，点击打开刷写弹窗
            Button(action: openFlash) {
                HStack(spacing: 14) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 24))
                        .foregroundStyle(.tint)
                        .frame(width: 44, height: 44)
                        .background(Color.primary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("settings.esp32card.title"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(L("settings.esp32card.desc"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .background(Color.primary.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
    }

    // MARK: 复用小部件

    @ViewBuilder private func header(_ key: String) -> some View {
        Text(L(key)).font(.headline)
    }

    @ViewBuilder private func caption(_ key: String) -> some View {
        Text(L(key))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var trustedList: some View {
        if trusted.isEmpty {
            Text(L("settings.trusted.empty"))
                .font(.caption)
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
        }
    }

    private func checkUpdate() {
        checkingUpdate = true
        updateText = ""
        updateURL = nil
        Updater.check { outcome in
            checkingUpdate = false
            switch outcome {
            case .upToDate:
                updateText = L("settings.upToDate")
            case .updateAvailable(let version, let url):
                updateText = "\(L("settings.updateAvailable")) \(version)"
                updateURL = url
            case .failed:
                updateText = L("settings.updateFailed")
            }
        }
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
        if !inputs.contains(where: { $0.id == selectedID }) {
            selectedID = inputs.first?.id ?? VideoInputs.esp32ID
            VideoInputs.setCurrentID(selectedID)
        }
        if selectedID == VideoInputs.esp32ID { onPrimeESP32() }   // 刷新时若用 ESP32，复位预热
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let state = SettingsState()

    func show(openFlash: @escaping () -> Void,
              onPrimeESP32: @escaping () -> Void,
              onEngineChanged: @escaping () -> Void,
              openMediaPipeInstall: @escaping () -> Void) {
        // 每次打开都重建视图：设置窗是复用的（关闭只隐藏），若沿用旧视图，其 @State 快照（信任命令、
        // 开机自启等）停留在上次打开时的值——比如刚在卡片上点的「总是允许」就不会显示。重建则重读最新。
        let hosting = NSHostingController(rootView: SettingsView(
            state: state, openFlash: openFlash, onPrimeESP32: onPrimeESP32,
            onEngineChanged: onEngineChanged, openMediaPipeInstall: openMediaPipeInstall))
        if window == nil {
            let w = NSWindow(contentViewController: hosting)
            w.title = L("settings.windowTitle")
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false   // ARC 管理，避免关闭崩溃/退出
            w.delegate = self
            window = w
        } else {
            window?.contentViewController = hosting   // 复用窗口但换新视图，刷新所有 @State
        }
        state.active = true              // 重新打开 -> 恢复预览
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        state.active = false             // 关闭 -> 停止预览、熄灭摄像头；app 继续在菜单栏运行
    }
}
