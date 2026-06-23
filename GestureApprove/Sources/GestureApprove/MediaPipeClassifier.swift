import Foundation
import CoreGraphics

/// 调用常驻的 Python MediaPipe 进程（gesture_daemon.py）做手势识别。
/// 用请求/响应配速：上一帧出结果前不发下一帧，避免管道堆积。
final class MediaPipeClassifier {
    /// (gesture, 手部包围盒归一化矩形) 回调，在后台线程调用。
    var onResult: ((Gesture, CGRect?) -> Void)?

    private let process = Process()
    private let inPipe = Pipe()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
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
        do {
            try process.run()
            GALog.log("MediaPipe daemon 已启动")
        } catch {
            GALog.log("MediaPipe daemon 启动失败：\(error)")
            started = false
        }
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
            self.inPipe.fileHandleForWriting.write(frame)
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
