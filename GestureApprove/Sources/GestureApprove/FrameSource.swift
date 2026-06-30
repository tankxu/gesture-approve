import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import ImageIO
import Darwin

/// 帧来源：开/关，持续把帧喂给 GestureEngine。
protocol FrameSource: AnyObject {
    func start()
    func stop()
}

// MARK: - FaceTime 摄像头

final class CameraFrameSource: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    private weak var engine: GestureEngine?
    let deviceUniqueID: String?
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.tankxu.gestureapprove.camera")
    private var configured = false   // 输入/输出是否已挂好（重建时清掉再挂）
    private var observersAdded = false
    private static let ciContext = CIContext(options: nil)

    // 帧看门狗：USB 采集卡可能在 session.isRunning 仍为 true 时静默停吐帧（无运行时错误）。
    // 审批期间(active)定期检查，若超过阈值没有新帧就整体重建会话自愈，避免“刘海黑屏”。
    private var active = false
    private var lastFrameAt = Date.distantPast
    private let staleThreshold: TimeInterval = 1.5
    private let watchdogInterval: TimeInterval = 0.8

    // 唤醒预热：解锁/唤醒后主动把摄像头拉起来吐一帧再关掉，把 USB 重新枚举的耗时提前消化，
    // 让“唤醒后第一次审批”立刻有画面，而不是等到 start() 才发现设备没好。
    // 首帧宽限：USB 采集卡 startRunning 到吐出第一帧可达 ~2s，远超 staleThreshold。
    // 还没出过首帧时用更长的 firstFrameGrace，避免看门狗在首帧到达前就误判卡死、陷入重建循环。
    private var deliveredFrame = false
    private let firstFrameGrace: TimeInterval = 3.0

    init(engine: GestureEngine, deviceUniqueID: String? = nil) {
        self.engine = engine
        self.deviceUniqueID = deviceUniqueID
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.active = true
            self.deliveredFrame = false
            self.lastFrameAt = Date()   // 给首帧留出宽限，避免刚启动就误判为卡死
            self.configureIfNeeded()
            if self.configured && !self.session.isRunning { self.session.startRunning() }
            self.scheduleWatchdog()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.active = false
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    /// 睡眠唤醒/解锁后调用：系统挂起会让复用的会话静默失效（isRunning 仍为 true 却不吐帧）。
    /// 空闲时主动拆掉输入/输出，下次审批 start() 自然重新配置——省掉看门狗那 ~1.5s 首帧黑屏。
    /// 与 ApprovalServer.restart()（唤醒后复活网络监听）对称。审批进行中则交给看门狗，不打断当前会话。
    func invalidate() {
        queue.async { [weak self] in
            guard let self, !self.active else { return }
            self.teardownIO()
        }
    }

    /// 拆掉输入/输出并置 configured=false（仍在 queue 上调用）。
    private func teardownIO() {
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for out in session.outputs { session.removeOutput(out) }
        session.commitConfiguration()
        configured = false
    }

    /// 看门狗：仅在审批期间循环自检，把会话推到"能吐帧"的状态。
    /// - 设备还没枚举回来(!configured，USB 唤醒慢)：重试配置，直到选定设备出现。
    /// - 已配置但无新帧：还没出过首帧给 firstFrameGrace(避免误判)，出过帧后断流用 staleThreshold 快速恢复。
    private func scheduleWatchdog() {
        queue.asyncAfter(deadline: .now() + watchdogInterval) { [weak self] in
            guard let self, self.active else { return }
            if !self.configured {
                self.rebuild()   // 设备未就绪：重试配置等它枚举回来（configureIfNeeded 严格用选定设备）
            } else {
                let grace = self.deliveredFrame ? self.staleThreshold : self.firstFrameGrace
                if Date().timeIntervalSince(self.lastFrameAt) > grace {
                    GALog.log("camera 看门狗：\(grace)s 无新帧，重建会话")
                    self.rebuild()
                }
            }
            self.scheduleWatchdog()
        }
    }

    /// 拆掉输入/输出并重新配置、重启——把静默卡死的会话恢复到能吐帧的状态。
    private func rebuild() {
        teardownIO()
        deliveredFrame = false
        lastFrameAt = Date()   // 重置宽限窗口
        configureIfNeeded()
        if configured && !session.isRunning { session.startRunning() }
    }

    private func configureIfNeeded() {
        if configured { return }
        if !observersAdded {
            observersAdded = true
            NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError,
                                                   object: session, queue: nil) { [weak self] note in
                GALog.log("camera 运行时错误: \(String(describing: note.userInfo?[AVCaptureSessionErrorKey]))")
                self?.queue.async { if self?.active == true { self?.rebuild() } }
            }
            NotificationCenter.default.addObserver(forName: .AVCaptureSessionWasInterrupted,
                                                   object: session, queue: nil) { note in
                GALog.log("camera 被中断(可能被其它 app 占用): \(String(describing: note.userInfo))")
            }
            NotificationCenter.default.addObserver(forName: .AVCaptureSessionInterruptionEnded,
                                                   object: session, queue: nil) { [weak self] _ in
                GALog.log("camera 中断结束，尝试恢复")
                self?.queue.async {
                    guard let self, self.active else { return }
                    if !self.session.isRunning { self.session.startRunning() }
                }
            }
        }
        session.beginConfiguration()
        session.sessionPreset = .high
        // 指定了设备就**严格用它**：找不到通常是 USB 采集卡刚唤醒还没枚举完——视为"未就绪"，
        // 保持 configured=false 让预热/看门狗继续等它回来，**绝不 fallback 到内置摄像头**
        // （否则会出现"选了 AVerMedia 却开了 FaceTime"、还识别不准）。没指定才用内置默认。
        let device: AVCaptureDevice?
        if let id = deviceUniqueID {
            device = AVCaptureDevice(uniqueID: id)
        } else {
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                mediaType: .video, position: .unspecified)
            device = discovery.devices.first(where: { $0.deviceType == .builtInWideAngleCamera })
                ?? discovery.devices.first
                ?? AVCaptureDevice.default(for: .video)
        }
        guard let device,
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            GALog.log("camera 选定设备未就绪(等待枚举) \(deviceUniqueID ?? "默认")")
            session.commitConfiguration(); return
        }
        GALog.log("camera 使用 \(device.localizedName)")
        session.addInput(input)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        configured = true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        lastFrameAt = Date()   // 喂帧时间戳，供看门狗判断会话是否还活着
        deliveredFrame = true  // 已出过首帧：之后断流才按 staleThreshold 快速判卡死（在 queue 上，无需加锁）
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var ci = CIImage(cvPixelBuffer: pb)
        // 下采样到高 ~240，减小传给 MediaPipe 的体积并加速
        let h = ci.extent.height
        if h > 260 {
            let s = 240.0 / h
            ci = ci.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        let space = CGColorSpaceCreateDeviceRGB()
        guard let jpeg = Self.ciContext.jpegRepresentation(of: ci, colorSpace: space, options: [:]),
              let cg = Self.ciContext.createCGImage(ci, from: ci.extent) else {
            return
        }
        engine?.submit(jpeg: jpeg, preview: cg)
    }
}

// MARK: - ESP32-CAM（串口）

final class ESP32FrameSource: FrameSource {
    private weak var engine: GestureEngine?
    private let portPath: String
    private let baud: Int
    private var thread: Thread?
    private var alive = false      // 读取线程在源的整个生命周期内存活，避免反复开关串口抢占
    private var feeding = false    // 是否把帧喂给引擎（审批期间为 true）
    nonisolated(unsafe) private var resetRequested = false  // 选中/刷新时置位，loop 复位 ESP32

    init(engine: GestureEngine, port: String? = nil, baud: Int? = nil) {
        self.engine = engine
        self.portPath = port ?? Self.autodetectPort() ?? "/dev/cu.usbserial-FTB6SPL3"
        self.baud = baud ?? Int(ProcessInfo.processInfo.environment["GESTURE_ESP32_BAUD"] ?? "") ?? 921600
    }

    static func autodetectPort() -> String? {
        if let env = ProcessInfo.processInfo.environment["GESTURE_ESP32_PORT"] { return env }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        let match = names.first { n in
            n.hasPrefix("cu.usbserial") || n.hasPrefix("cu.SLAB_USBtoUART")
                || n.hasPrefix("cu.wchusbserial") || n.hasPrefix("cu.usbmodem")
        }
        return match.map { "/dev/\($0)" }
    }

    private func ensureThread() {
        if !alive {
            alive = true
            let t = Thread { [weak self] in self?.loop() }
            t.stackSize = 1 << 20
            thread = t
            t.start()
        }
    }

    func start() { ensureThread(); feeding = true }

    func stop() { feeding = false }   // 仅暂停喂帧，串口与线程保留以便下次秒开

    /// 选中 ESP32 / 点刷新时调用：确保线程在跑并复位一次 ESP32（提前进入干净状态）。
    func prime() { ensureThread(); resetRequested = true }

    private func loop() {
        let port = SerialPort(path: portPath, baud: baud)
        guard port.open() else {
            GALog.log("ESP32 打开串口失败 \(portPath)")
            alive = false
            return
        }
        port.resetToRunMode()
        var fails = 0
        var lastReset = Date()
        // 复位限频：两次复位至少间隔 8s，避免频繁重启 ESP32 导致掉电/USB 掉线
        func maybeReset() {
            guard Date().timeIntervalSince(lastReset) > 8 else { return }
            port.resetToRunMode()
            lastReset = Date()
            fails = 0
        }
        while alive {
            if resetRequested {              // 选中/刷新触发的复位
                resetRequested = false
                maybeReset()
            }
            // 省电：仅审批期间(feeding)抓帧，平时不发 CAP，ESP32 不编码不传输 -> 不发烫
            if !feeding {
                fails = 0
                usleep(100_000)
                continue
            }
            if let jpeg = port.captureFrame(timeout: 1.0) {
                fails = 0
                engine?.submit(jpeg: jpeg, preview: Self.cgImage(from: jpeg))
            } else {
                fails += 1
                if fails >= 3 { maybeReset() }   // 连续失败 -> 限频复位自愈
            }
        }
        port.close()
    }

    private static func cgImage(from data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
