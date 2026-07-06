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

    // 首帧宽限：USB 采集卡 startRunning 到吐出第一帧可达 ~2s，远超 staleThreshold。
    // 还没出过首帧时用更长的 firstFrameGrace，避免看门狗在首帧到达前就误判卡死、陷入重建循环。
    private var deliveredFrame = false
    private let firstFrameGrace: TimeInterval = 3.0

    // 选定设备缺席：区分"唤醒后还没枚举完"（短暂，要严格等它，别误切内置）和"被永久拔掉"
    // （无限等 = 审批永远黑屏）。缺席不到 fallbackGrace 只等；超过则判为已移除，**临时**回退
    // 到默认设备（内置优先）保证审批有画面。不改写用户保存的选择；看门狗持续探测选定设备，
    // 插回即自动切回。missingSince 跨审批保留——设备一直缺席时第二次审批不必重新等满宽限。
    private var missingSince: Date?
    private var usingFallback = false
    private var loggedFallback = false   // 回退只记一条日志，避免看门狗每拍刷屏
    private let fallbackGrace: TimeInterval = 4.0   // 必须 > USB 唤醒重枚举 ~2s

    init(engine: GestureEngine, deviceUniqueID: String? = nil) {
        self.engine = engine
        self.deviceUniqueID = deviceUniqueID
    }

    // MARK: 垂直视野最大化

    /// 挑"尽量方"的格式：内置 FaceTime 的默认 16:9 (1920x1080) 是从近方形传感器**裁切**的横条，
    /// 上下——尤其手所在的下方——被切掉。选 min(宽,高) 最大的横向/方形格式（FaceTime HD 实测有
    /// 1552x1552，垂直视野 +44%），手放在键盘附近也能入框。竖版格式(高>宽)牺牲太多水平视野，排除。
    /// 分辨率本身无所谓：识别前会缩到 ~240 高。只有 16:9 的设备（OBS/Camo/采集卡）返回 nil，不折腾。
    static func tallFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        var best: AVCaptureDevice.Format?
        var bestMin: Int32 = 0
        for f in device.formats {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard d.width >= d.height,
                  Double(d.height) / Double(d.width) > 0.6,   // 比 16:9(0.5625) 更方才有收益
                  f.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 15 })
            else { continue }
            if min(d.width, d.height) > bestMin {
                bestMin = min(d.width, d.height)
                best = f
            }
        }
        return best
    }

    /// 应用高格式（审批采集与设置预览共用，保证两边看到同样的取景范围）。
    /// **必须在 session.startRunning() 之后调用**：macOS 没有 iOS 的 inputPriority preset，
    /// 实测无论 .high 还是 .photo，commit/startRunning 都会把事务内设置的 activeFormat
    /// 打回 16:9（首帧 1920x1080）；只有运行后再设才真正生效。
    /// 若日志中"camera 首帧"仍是 16:9 尺寸说明又被打回（回归标志）。
    static func applyTallFormat(to device: AVCaptureDevice, session: AVCaptureSession) {
        guard let fmt = tallFormat(for: device), device.activeFormat != fmt else { return }
        do {
            try device.lockForConfiguration()
        } catch {
            return
        }
        device.activeFormat = fmt
        device.unlockForConfiguration()
        let d = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
        GALog.log("camera 格式 \(d.width)x\(d.height)（扩大垂直视野）")
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.active = true
            self.deliveredFrame = false
            self.lastFrameAt = Date()   // 给首帧留出宽限，避免刚启动就误判为卡死
            // 上次审批落在临时回退设备上、期间选定设备已插回：拆掉回退会话，直接用选定设备重配
            if self.usingFallback, let id = self.deviceUniqueID, AVCaptureDevice(uniqueID: id) != nil {
                self.teardownIO()
            }
            self.configureIfNeeded()
            if self.configured { self.startSessionEnforcingTallFormat() }
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
            // 唤醒时选定设备不在系统里：现在就开始计缺席时长。真是"睡眠期间被拔走"的话，
            // 首次审批就不必再从头黑等满宽限期；只是枚举慢的话，configure 找到它会清零。
            if let id = self.deviceUniqueID, self.missingSince == nil, AVCaptureDevice(uniqueID: id) == nil {
                self.missingSince = Date()
                GALog.log("camera 唤醒时选定设备缺席 \(id)，开始计时")
            }
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
    /// - 正开着临时回退设备：探测选定设备是否已插回，回来就重建切回。
    /// - 已配置但无新帧：还没出过首帧给 firstFrameGrace(避免误判)，出过帧后断流用 staleThreshold 快速恢复。
    private func scheduleWatchdog() {
        queue.asyncAfter(deadline: .now() + watchdogInterval) { [weak self] in
            guard let self, self.active else { return }
            if !self.configured {
                self.rebuild()   // 设备未就绪：重试配置等它枚举回来（configureIfNeeded 严格用选定设备）
            } else if self.usingFallback, let id = self.deviceUniqueID, AVCaptureDevice(uniqueID: id) != nil {
                self.rebuild()   // 选定设备已插回：重建切回（configureIfNeeded 会优先用它并记日志）
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
        if configured { startSessionEnforcingTallFormat() }
    }

    /// 启动会话并在**运行后**应用高格式——时机见 applyTallFormat 注释（事务内设置会被 preset 打回）。
    private func startSessionEnforcingTallFormat() {
        if !session.isRunning { session.startRunning() }
        if let dev = (session.inputs.first as? AVCaptureDeviceInput)?.device {
            Self.applyTallFormat(to: dev, session: session)
        }
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
                    self.startSessionEnforcingTallFormat()
                }
            }
        }
        session.beginConfiguration()
        session.sessionPreset = .high
        // 指定了设备就**严格用它**：找不到通常是 USB 采集卡刚唤醒还没枚举完——宽限期内视为
        // "未就绪"，保持 configured=false 让看门狗继续等它回来，别急着 fallback（否则唤醒瞬间
        // 就会"选了 AVerMedia 却开了 FaceTime"、还识别不准）。缺席超过 fallbackGrace 判为
        // 已被拔掉：临时回退到默认设备保证审批不黑屏，选定设备插回后由看门狗切回。
        let device: AVCaptureDevice?
        if let id = deviceUniqueID {
            if let chosen = AVCaptureDevice(uniqueID: id) {
                if missingSince != nil { GALog.log("camera 选定设备已回归 \(chosen.localizedName)") }
                missingSince = nil
                usingFallback = false
                loggedFallback = false
                device = chosen
            } else {
                let since: Date
                if let s = missingSince {
                    since = s
                } else {
                    since = Date()
                    missingSince = since
                    GALog.log("camera 选定设备未就绪(等待枚举) \(id)")
                }
                if Date().timeIntervalSince(since) > fallbackGrace {
                    device = VideoInputs.preferredDefaultDevice()
                    usingFallback = (device != nil)
                    if !loggedFallback {
                        loggedFallback = true
                        GALog.log("camera 选定设备缺席超 \(Int(fallbackGrace))s，判为已拔出，临时回退 \(device?.localizedName ?? "(无可用设备)")")
                    }
                } else {
                    device = nil   // 宽限期内：继续等枚举
                }
            }
        } else {
            device = VideoInputs.preferredDefaultDevice()
        }
        guard let device,
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration(); return   // 未就绪：看门狗下一拍重试（缺席日志已在首次记过）
        }
        GALog.log("camera 使用 \(device.localizedName)\(usingFallback ? "（临时回退）" : "")")
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
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if !deliveredFrame {   // 首帧记尺寸：核对高格式是否真生效（16:9 尺寸=被 preset 覆盖，回归标志）
            GALog.log("camera 首帧 \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb))")
        }
        deliveredFrame = true  // 已出过首帧：之后断流才按 staleThreshold 快速判卡死（在 queue 上，无需加锁）
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
