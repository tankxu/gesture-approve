import Foundation
import CoreGraphics

/// 调用常驻的 Python MediaPipe 进程（gesture_daemon.py）做手势识别。
/// 用请求/响应配速：上一帧出结果前不发下一帧，避免管道堆积。
final class MediaPipeClassifier {
    /// (gesture, 手部包围盒归一化矩形) 回调，在后台线程调用。
    var onResult: ((Gesture, CGRect?) -> Void)?

    // process 与三个 pipe 是 var：daemon 崩溃后不能二次 run() 同一 Process，需重建（见 rebuildProcess）。
    private var process = Process()
    private var inPipe = Pipe()
    private var outPipe = Pipe()
    private var errPipe = Pipe()
    private let ioQueue = DispatchQueue(label: "com.tankxu.gestureapprove.mp")
    private var started = false
    private var pending = false
    private var lineBuffer = Data()

    private let pythonPath: String
    private let scriptPath: String

    init() {
        pythonPath = MediaPipeInstaller.venvPython     // Application Support 的 venv
        scriptPath = MediaPipeInstaller.daemonScript   // bundle 内 daemon（回退仓库）
    }

    func start() {
        ioQueue.async { [weak self] in self?.startLocked() }
    }

    private func startLocked() {
        guard !started else { return }
        guard FileManager.default.fileExists(atPath: pythonPath),
              FileManager.default.fileExists(atPath: scriptPath) else {
            GALog.log("MediaPipe: 找不到 venv 或 daemon（先跑 setup.sh）")
            return
        }
        started = true
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptPath]
        var env = ProcessInfo.processInfo.environment
        env["GESTURE_MODEL"] = MediaPipeInstaller.modelFile   // 模型在 Application Support
        process.environment = env
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            self?.handleOutput(h.availableData)
        }
        // 排空 stderr：daemon 的 READY 与 MediaPipe/TFLite 的告警都往这里写，没人读的话
        // 管道缓冲（~64KB）写满后 daemon 会阻塞在 write、不再吐结果 → 识别静默冻结。
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty, let s = String(data: d, encoding: .utf8) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty && t != "READY" { GALog.log("MediaPipe daemon stderr: \(t.prefix(300))") }
            }
        }
        // daemon 崩溃/退出（OOM、venv 被系统 Python 升级破坏、收到超大帧主动退出等）：
        // 复位状态并清背压，避免 pending 永久卡 true 让识别静默死亡；active 时自动重启一次。
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.ioQueue.async {
                guard self.started else { return }   // 主动 stop() 已置 false，不算崩溃
                GALog.log("MediaPipe daemon 意外退出(code \(proc.terminationStatus))，重启")
                self.started = false
                self.pending = false
                self.lineBuffer.removeAll()
                self.rebuildProcess()
                self.startLocked()
            }
        }
        do {
            try process.run()
            GALog.log("MediaPipe daemon 已启动")
        } catch {
            GALog.log("MediaPipe daemon 启动失败：\(error)")
            started = false
        }
    }

    /// 崩溃重启前重建 Process 与管道：Process 不能二次 run()，Pipe 也已随旧进程失效。
    private func rebuildProcess() {
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        process = Process()
        inPipe = Pipe()
        outPipe = Pipe()
        errPipe = Pipe()
    }

    func stop() {
        ioQueue.async { [weak self] in
            guard let self, self.started else { return }
            self.started = false
            self.process.terminate()
        }
    }

    /// 提交一帧 JPEG（若上一帧还没出结果则丢弃，形成天然背压）。
    func submit(jpeg: Data) {
        ioQueue.async { [weak self] in
            guard let self, self.started, !self.pending else { return }
            guard jpeg.count > 0 && jpeg.count < 8_000_000 else { return }
            self.pending = true
            var len = UInt32(jpeg.count).littleEndian
            var frame = Data(bytes: &len, count: 4)
            frame.append(jpeg)
            // 可抛版写：daemon 刚崩、管道已断时返回 EPIPE 而非 raise（SIGPIPE 已忽略）。
            // 失败就清 pending，交给 terminationHandler 重启，不让背压永久卡死。
            do {
                try self.inPipe.fileHandleForWriting.write(contentsOf: frame)
            } catch {
                self.pending = false
            }
        }
    }

    // readabilityHandler 线程：拆行解析
    private func handleOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        lineBuffer.append(data)
        while let nl = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<nl)
            lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
            ioQueue.async { [weak self] in self?.pending = false }
            if let line = String(data: lineData, encoding: .utf8) { parse(line) }
        }
    }

    private func parse(_ line: String) {
        // 格式: gesture x0 y0 x1 y1 conf
        let parts = line.split(separator: " ")
        guard parts.count >= 6 else { return }
        var gesture: Gesture
        switch parts[0] {
        case "thumbUp":  gesture = .thumbUp
        case "openPalm": gesture = .openPalm
        default:         gesture = .none
        }
        // 按设置里的「识别精准度」三档过滤：置信度不足则视为未识别。
        // 注意：滑杆值（0.3/0.6/0.9）在 Vision 里是「几何松紧」、在这里是 MediaPipe 的 gesture
        // score 阈值——两者量纲不同，不能直接套用滑杆裸值（旧逻辑高档 0.9 连理想样图都过不了）。
        // 实测 MediaPipe 官方清晰 Thumb_Up 样图 score 仅 0.73、Open_Palm/Victory 0.8~0.9，真实摄像头
        // 更低。故三档分别取可用值（非线性，thumbUp 可用区间本就窄）：
        //   低 0.40 · 中 0.55 · 高 0.70（高档略低于 thumbUp 上限 0.73、余量很小，仍可能偏紧）。
        let conf = Double(parts[5]) ?? 1
        let slider = (UserDefaults.standard.object(forKey: "gestureMinConf") as? Double) ?? 0.6
        let threshold: Double
        switch slider {
        case ..<0.45: threshold = 0.40   // 低
        case ..<0.75: threshold = 0.55   // 中
        default:      threshold = 0.70   // 高
        }
        if gesture.isDecisive && conf < threshold { gesture = .none }

        var box: CGRect? = nil
        if let x0 = Double(parts[1]), let y0 = Double(parts[2]),
           let x1 = Double(parts[3]), let y1 = Double(parts[4]), x0 >= 0, x1 > x0 {
            box = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }
        onResult?(gesture, box)
    }
}
