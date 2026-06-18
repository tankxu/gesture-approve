import SwiftUI
import AppKit

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
    @State private var minConf: Double = (UserDefaults.standard.object(forKey: "gestureMinConf") as? Double) ?? 0.6
    @State private var errorText: String?
    @State private var engine: String = UserDefaults.standard.string(forKey: MediaPipeInstaller.engineKey) ?? "vision"
    @State private var mpInstalled = MediaPipeInstaller.isInstalled()
    @State private var rotation: Int = (UserDefaults.standard.object(forKey: "frameRotation") as? Int) ?? 0
    @State private var allowlistText: String = Allowlist.patterns().joined(separator: "\n")
    let openFlash: () -> Void
    let onPrimeESP32: () -> Void
    let onEngineChanged: () -> Void
    let openMediaPipeInstall: () -> Void

    private var selectedIsESP32: Bool { selectedID == VideoInputs.esp32ID }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 接入：一键写入/移除 hook
            Text("接入 AI 工具").font(.headline)
            Toggle("接入 Claude Code", isOn: Binding(
                get: { claudeInstalled },
                set: { on in
                    do {
                        try on ? HookInstaller.installClaude() : HookInstaller.uninstallClaude()
                        claudeInstalled = on
                    } catch { errorText = "\(error)" }
                }))
            Toggle("接入 Codex", isOn: Binding(
                get: { codexInstalled },
                set: { on in
                    do {
                        try on ? HookInstaller.installCodex() : HookInstaller.uninstallCodex()
                        codexInstalled = on
                    } catch { errorText = "\(error)" }
                }))
            Text("开启即自动写入对应配置（已自动备份原文件），新开 CC/Codex 会话生效；关闭即移除。")
                .font(.caption).foregroundStyle(.secondary)
            Text("审批时：⌃⇧Y 通过 · ⌃⇧N 拒绝（或比手势）；超时/未接入会回退到终端正常审批。")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            Text("视频输入源").font(.headline)

            HStack(spacing: 6) {
                Picker("", selection: $selectedID) {
                    ForEach(inputs) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()

                Button(action: reload) { Image(systemName: "arrow.clockwise") }
                    .help("刷新设备列表")

                Spacer()

                // 画面旋转（相机被装歪/倒置时用）
                Image(systemName: "rotate.right")
                    .foregroundStyle(.secondary)
                Picker("", selection: $rotation) {
                    Text("不旋转").tag(0)
                    Text("90°").tag(90)
                    Text("180°").tag(180)
                    Text("270°").tag(270)
                }
                .labelsHidden()
                .fixedSize()
                .help("画面整体旋转角度")
                .onChange(of: rotation) { _, v in
                    UserDefaults.standard.set(v, forKey: "frameRotation")
                }
            }
            .onChange(of: selectedID) { _, newValue in
                VideoInputs.setCurrentID(newValue)
                if newValue == VideoInputs.esp32ID { onPrimeESP32() }   // 选中 ESP32 即复位预热
            }

            // 预览
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.black)
                if selectedIsESP32 {
                    VStack(spacing: 10) {
                        Image(systemName: "cable.connector.horizontal").font(.system(size: 28))
                        Text("ESP32-CAM 串口源 · 无实时预览")
                        Text("刷好固件并接上后，用「测试审批卡片」验证")
                            .font(.caption)
                    }
                    .foregroundStyle(.white.opacity(0.6))
                } else if state.active {
                    CameraPreview(deviceUniqueID: selectedID)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .frame(height: 230)

            Divider()

            // 识别引擎
            Text("识别引擎").font(.headline)
            Picker("", selection: $engine) {
                Text("Apple Vision（内置 · 体积小）").tag("vision")
                Text("MediaPipe（更准 · 需下载 ~300MB）").tag("mediapipe")
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
                            Text("已安装")
                        }.foregroundStyle(.green)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text("未安装（先下载才会生效）")
                        }.foregroundStyle(.orange)
                    }
                    Button(mpInstalled ? "重新下载…" : "下载安装…") { openMediaPipeInstall() }
                }
                .font(.caption)
            }
            Text("Vision 内置零依赖、准度一般；MediaPipe 需下载约 300MB 运行时，识别更准更稳。")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            // 识别精准度（仅 MediaPipe 生效）
            HStack {
                Text("识别精准度").font(.headline)
                Spacer()
                Text(String(format: "%.0f%%", minConf * 100))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: $minConf, in: 0.3...0.9, step: 0.05)
                .onChange(of: minConf) { _, v in UserDefaults.standard.set(v, forKey: "gestureMinConf") }
            HStack {
                Text("宽松（易触发）").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("严格（少误判）").font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            // 自动放行白名单
            Text("自动放行规则").font(.headline)
            Text("命中任一行(正则)的命令直接通过、不弹手势卡片。匹配「工具: 内容」，如 Bash: ls。")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $allowlistText)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 64)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
                .onChange(of: allowlistText) { _, v in
                    Allowlist.setPatterns(v.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
                }

            Divider()

            // 新手入口：横条卡片，点击打开刷写弹窗
            Button(action: openFlash) {
                HStack(spacing: 14) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 24))
                        .foregroundStyle(.tint)
                        .frame(width: 44, height: 44)
                        .background(Color.primary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("使用 ESP32-CAM 作为摄像头")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("没有合适的摄像头？用一块 ESP32-CAM 模块，刷入配套固件就能当审批摄像头。")
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
        }
        .padding(20)
        .frame(width: 480)
        .alert("接入失败", isPresented: Binding(get: { errorText != nil },
                                                set: { if !$0 { errorText = nil } })) {
            Button("好", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .onAppear {
            mpInstalled = MediaPipeInstaller.isInstalled()
            engine = UserDefaults.standard.string(forKey: MediaPipeInstaller.engineKey) ?? "vision"
        }
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
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(
                state: state, openFlash: openFlash, onPrimeESP32: onPrimeESP32,
                onEngineChanged: onEngineChanged, openMediaPipeInstall: openMediaPipeInstall))
            let w = NSWindow(contentViewController: hosting)
            w.title = "手势审批 · 设置"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false   // ARC 管理，避免关闭崩溃/退出
            w.delegate = self
            window = w
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
