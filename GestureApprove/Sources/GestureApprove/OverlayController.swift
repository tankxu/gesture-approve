import AppKit
import SwiftUI
import Combine

/// 卡片要展示的可观察状态。
@MainActor
final class ApprovalViewModel: ObservableObject {
    @Published var operation: String = ""
    @Published var locked: Gesture? = nil
    @Published var visible: Bool = false
    @Published var timeout: TimeInterval = 90   // 倒计时环时长
    @Published var sessionID: Int = 0           // 每次审批 +1，用于重启环动画
}

/// SwiftUI 根视图：组合操作信息(vm)与即时手势(engine)，并处理展开/收起动画。
struct RootCardView: View {
    @ObservedObject var vm: ApprovalViewModel
    @ObservedObject var engine: GestureEngine
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack {
            if vm.visible {
                NotchCardView(operation: vm.operation,
                              live: engine.live,
                              locked: vm.locked,
                              previewImage: engine.previewImage,
                              handBox: engine.handBox,
                              timeout: vm.timeout,
                              sessionID: vm.sessionID,
                              onApprove: onApprove,
                              onDeny: onDeny)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.7, anchor: .top).combined(with: .opacity),
                        removal: .scale(scale: 0.85, anchor: .top).combined(with: .opacity)))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: vm.visible)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: vm.locked)
    }
}

/// 编排一次审批：在刘海处展开卡片、开摄像头、等手势或超时、回判定。
@MainActor
final class ApprovalController {
    private let vm = ApprovalViewModel()
    private let engine = GestureEngine()
    private var currentSource: FrameSource?
    // 复用同一个源实例，避免每次审批重建导致设备抢占（第二次拿不到画面）
    private var cameraSource: CameraFrameSource?
    private var esp32Source: ESP32FrameSource?
    private var panel: NSPanel?

    private var inFlight = false
    private var completion: ((ApprovalOutcome) -> Void)?
    private var timeoutWork: DispatchWorkItem?

    init() {
        buildPanel()
    }

    private func buildPanel() {
        let size = NSSize(width: 360, height: 240)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false   // 允许点击图标
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let root = RootCardView(vm: vm, engine: engine,
                                onApprove: { [weak self] in self?.resolveByHotkey(approve: true) },
                                onDeny: { [weak self] in self?.resolveByHotkey(approve: false) })
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.alphaValue = 0
        self.panel = panel
    }

    /// 选有刘海的那块屏；没有则用主屏。
    private func notchScreen() -> NSScreen {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func positionPanel() {
        guard let panel else { return }
        let screen = notchScreen()
        let size = panel.frame.size
        let x = screen.frame.midX - size.width / 2
        let y = screen.frame.maxY - size.height   // 顶部对齐（刘海下方展开）
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    /// 发起一次审批。`completion(true)` 表示通过。线程：主线程。
    func requestApproval(operation: String, timeout: TimeInterval = 15, completion: @escaping (ApprovalOutcome) -> Void) {
        if inFlight {
            completion(.denied)  // 同一时刻只处理一个请求；并发请求直接拒绝
            return
        }
        inFlight = true
        self.completion = completion

        vm.operation = operation.isEmpty ? L("card.noOperation") : operation
        vm.locked = nil
        vm.timeout = timeout
        vm.sessionID += 1
        vm.visible = true

        NSSound(named: "Submarine")?.play()   // 音效提醒：需要审批

        positionPanel()
        panel?.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            panel?.animator().alphaValue = 1
        }

        engine.reset()
        engine.onStable = { [weak self] gesture in
            self?.finish(with: gesture)
        }
        let inputID = VideoInputs.currentID()
        GALog.log("requestApproval inputID=\(inputID) op=\(operation)")
        let source = makeSource(for: inputID)
        currentSource = source
        source.start()

        let work = DispatchWorkItem { [weak self] in self?.finish(with: .none) }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    /// 设置里切换识别引擎后调用。
    func applyEngine() { engine.applyEngineSetting() }

    /// 选中 ESP32 / 点刷新时调用：确保 ESP32 源存在并复位一次（提前唤醒，避免首次没画面）。
    func primeESP32() {
        if esp32Source == nil { esp32Source = ESP32FrameSource(engine: engine) }
        esp32Source?.prime()
    }

    /// 复用源实例：相同输入返回同一个对象，切换输入才重建。
    private func makeSource(for inputID: String) -> FrameSource {
        if inputID == VideoInputs.esp32ID {
            if esp32Source == nil { esp32Source = ESP32FrameSource(engine: engine) }
            return esp32Source!
        }
        if cameraSource == nil || cameraSource!.deviceUniqueID != inputID {
            cameraSource?.stop()
            cameraSource = CameraFrameSource(engine: engine, deviceUniqueID: inputID)
        }
        return cameraSource!
    }

    /// 由全局热键/点击调用：仅在有审批进行中时生效，立即用通过/拒绝结束。
    func resolveByHotkey(approve: Bool) {
        guard inFlight else { return }
        finish(with: approve ? .thumbUp : .openPalm)
    }

    private func finish(with gesture: Gesture) {
        guard inFlight else { return }
        timeoutWork?.cancel()
        timeoutWork = nil
        engine.onStable = nil
        currentSource?.stop()
        currentSource = nil

        let outcome: ApprovalOutcome
        switch gesture {
        case .thumbUp: outcome = .approved
        case .openPalm: outcome = .denied
        case .none: outcome = .timedOut
        }
        vm.locked = gesture.isDecisive ? gesture : nil

        // 结果音效反馈
        switch gesture {
        case .thumbUp:  NSSound(named: "Glass")?.play()
        case .openPalm: NSSound(named: "Basso")?.play()
        case .none:     break
        }

        // 锁定后停留片刻展示结果勾选，再收起。
        let dwell: TimeInterval = gesture.isDecisive ? 0.7 : 0.15
        DispatchQueue.main.asyncAfter(deadline: .now() + dwell) { [weak self] in
            guard let self else { return }
            self.vm.visible = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                self.panel?.animator().alphaValue = 0
            } completionHandler: {
                self.panel?.orderOut(nil)
            }
            let done = self.completion
            self.completion = nil
            self.inFlight = false
            done?(outcome)
        }
    }
}
