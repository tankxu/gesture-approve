import SwiftUI
import AppKit

/// 跑一个 shell 脚本并把输出实时推给界面（固件刷写、MediaPipe 下载安装共用）。
@MainActor
final class ScriptRunner: ObservableObject {
    enum Status { case idle, running, success, failed }

    @Published var output: String = ""
    @Published var status: Status = .idle
    private var process: Process?

    func run(script: String) {
        guard status != .running else { return }
        output = ""
        status = .running
        guard FileManager.default.fileExists(atPath: script) else {
            output = "找不到脚本：\(script)\n"
            status = .failed
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if d.isEmpty { return }
            let s = String(decoding: d, as: UTF8.self)
            DispatchQueue.main.async { self.output += s }
        }
        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self.status = (proc.terminationStatus == 0) ? .success : .failed
            }
        }
        do { try p.run(); process = p }
        catch { output += "无法启动：\(error)\n"; status = .failed }
    }
}

/// 进度窗的文案配置。
struct ScriptUIConfig {
    var windowTitle: String
    var title: String
    var intro: String
    var steps: [String]
    var runLabel: String
    var rerunLabel: String
    var runIcon: String
    var footer: String
    var runningText: String
    var successText: String
    var failedText: String
    var idleHint: String
    var onSuccess: (() -> Void)? = nil
}

struct ScriptView: View {
    @ObservedObject var runner: ScriptRunner
    let script: String
    let cfg: ScriptUIConfig

    private var hasStarted: Bool { runner.status != .idle }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(cfg.title).font(.system(size: 16, weight: .bold))
                Text(cfg.intro).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !cfg.steps.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(cfg.steps.enumerated()), id: \.offset) { i, s in
                        stepRow(i + 1, s)
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 12) {
                Button(action: { runner.run(script: script) }) {
                    Label(hasStarted ? cfg.rerunLabel : cfg.runLabel, systemImage: cfg.runIcon)
                        .frame(minWidth: 90)
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(runner.status == .running)
                statusBadge
                Spacer()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(logText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .id("logEnd")
                }
                .onChange(of: runner.output) { _, _ in
                    withAnimation(.linear(duration: 0.1)) { proxy.scrollTo("logEnd", anchor: .bottom) }
                }
            }
            .frame(maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(cfg.footer).font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 580, height: 460)
        .onChange(of: runner.status) { _, s in
            if s == .success { cfg.onSuccess?() }
        }
    }

    private var logText: String {
        if !runner.output.isEmpty { return runner.output }
        return hasStarted ? "准备中…" : cfg.idleHint
    }

    @ViewBuilder private func stepRow(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .frame(width: 20, height: 20).background(Circle().fill(.tint))
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch runner.status {
        case .idle:    Label("空闲", systemImage: "circle").foregroundStyle(.secondary)
        case .running: HStack(spacing: 8) { ProgressView().controlSize(.small); Text(cfg.runningText).foregroundStyle(.orange) }
        case .success: Label(cfg.successText, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:  Label(cfg.failedText, systemImage: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

@MainActor
final class ScriptWindowController {
    private var window: NSWindow?
    private let runner = ScriptRunner()

    func show(script: String, cfg: ScriptUIConfig) {
        if window == nil {
            let hosting = NSHostingController(rootView: ScriptView(runner: runner, script: script, cfg: cfg))
            let w = NSWindow(contentViewController: hosting)
            w.title = cfg.windowTitle
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
