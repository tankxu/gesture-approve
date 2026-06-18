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
            Text(L("settings.section.connect")).font(.headline)
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
            Text(L("settings.connectDesc"))
                .font(.caption).foregroundStyle(.secondary)
            Text(L("settings.hotkeyDesc"))
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            Text(L("settings.section.video")).font(.headline)

            HStack(spacing: 6) {
                Picker("", selection: $selectedID) {
                    ForEach(inputs) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()

                Button(action: reload) { Image(systemName: "arrow.clockwise") }
                    .help(L("settings.refresh.help"))

                Spacer()

                // 画面旋转（相机被装歪/倒置时用）
                Image(systemName: "rotate.right")
                    .foregroundStyle(.secondary)
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
                        Text(L("settings.esp32.noPreview"))
                        Text(L("settings.esp32.noPreviewHint"))
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
            Text(L("settings.section.engine")).font(.headline)
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
            Text(L("settings.engine.desc"))
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            // 识别精准度（仅 MediaPipe 生效）
            HStack {
                Text(L("settings.section.precision")).font(.headline)
                Spacer()
                Text(String(format: "%.0f%%", minConf * 100))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: $minConf, in: 0.3...0.9, step: 0.05)
                .onChange(of: minConf) { _, v in UserDefaults.standard.set(v, forKey: "gestureMinConf") }
            HStack {
                Text(L("settings.precision.loose")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(L("settings.precision.strict")).font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            // 自动放行白名单
            Text(L("settings.section.allowlist")).font(.headline)
            Text(L("settings.allowlist.desc"))
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
        }
        .padding(20)
        .frame(width: 480)
        .alert(L("settings.alert.title"), isPresented: Binding(get: { errorText != nil },
                                                set: { if !$0 { errorText = nil } })) {
            Button(L("settings.alert.ok"), role: .cancel) { errorText = nil }
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
            w.title = L("settings.windowTitle")
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
