import Combine
import CoreGraphics
import CoreImage
import Foundation

/// 手势识别引擎：可在内置 Vision 与可选 MediaPipe 之间切换；做稳定性投票后给出判定。
/// 与图像来源解耦——来源调用 `submit(jpeg:preview:)` 喂帧。
@MainActor
final class GestureEngine: ObservableObject {
    @Published private(set) var live: Gesture = .none
    /// 供刘海卡片显示的当前画面（已节流）。
    @Published private(set) var previewImage: CGImage?
    /// 手部包围盒（归一化，y 向下），用于按手大小/位置推近。
    @Published private(set) var handBox: CGRect?

    /// 同一决定性手势在时间窗内占多数后回调一次（主线程）。
    var onStable: ((Gesture) -> Void)?

    private let vision = VisionClassifier()                 // 内置引擎，始终可用
    nonisolated(unsafe) private var mp: MediaPipeClassifier? // 可选引擎，安装后才有
    nonisolated(unsafe) private var useMP = false
    nonisolated(unsafe) private var frameCounter = 0

    // 时间窗多数投票（容忍抖动），与帧率无关
    private let windowDuration: TimeInterval = 0.5
    private let minSpan: TimeInterval = 0.3
    private let lockFraction = 0.6
    private let lingerDuration: TimeInterval = 0.35
    private var samples: [(t: Date, g: Gesture)] = []
    private var locked = false
    private var lastDecisive: Gesture = .none
    private var lastDecisiveTime = Date.distantPast

    init() {
        vision.onResult = { [weak self] g, box in
            Task { @MainActor in self?.ingest(gesture: g, box: box) }
        }
        applyEngineSetting()
    }

    /// 按设置选择识别引擎：MediaPipe（已安装）或内置 Vision。设置变更后调用。
    func applyEngineSetting() {
        if MediaPipeInstaller.usingMediaPipe() {
            if mp == nil {
                let c = MediaPipeClassifier()
                c.onResult = { [weak self] g, box in
                    Task { @MainActor in self?.ingest(gesture: g, box: box) }
                }
                c.start()
                mp = c
            }
            useMP = true
        } else {
            useMP = false
            mp?.stop()
            mp = nil
        }
    }

    func reset() {
        locked = false
        samples.removeAll()
        lastDecisive = .none
        lastDecisiveTime = .distantPast
        live = .none
        previewImage = nil
        handBox = nil
    }

    // MARK: 喂帧（可从任意线程调用）

    /// preview 用于卡片背景；识别按当前引擎走 MediaPipe(jpeg) 或 Vision(preview)。
    nonisolated func submit(jpeg: Data, preview: CGImage?) {
        frameCounter &+= 1
        let everyOther = frameCounter % 2 == 0

        // 画面旋转（默认 0 时零开销；相机被装歪/倒置时用）
        var pv = preview
        var jp = jpeg
        let rot = (UserDefaults.standard.object(forKey: "frameRotation") as? Int) ?? 0
        if rot != 0, let p = preview, let r = Self.rotate(p, degrees: rot) {
            pv = r
            if useMP { jp = Self.jpegData(r) ?? jpeg }
        }

        if let pv, everyOther {
            Task { @MainActor in self.previewImage = pv }
        }
        if useMP {
            mp?.submit(jpeg: jp)             // MediaPipe 有自己的请求/响应配速
        } else if let pv, everyOther {
            vision.process(cgImage: pv)      // Vision 约 15fps，避免过载
        }
    }

    nonisolated(unsafe) private static let ciCtx = CIContext(options: nil)
    private nonisolated static func rotate(_ cg: CGImage, degrees: Int) -> CGImage? {
        let o: CGImagePropertyOrientation = degrees == 90 ? .right : (degrees == 180 ? .down : .left)
        let ci = CIImage(cgImage: cg).oriented(o)
        return ciCtx.createCGImage(ci, from: ci.extent)
    }
    private nonisolated static func jpegData(_ cg: CGImage) -> Data? {
        ciCtx.jpegRepresentation(of: CIImage(cgImage: cg),
                                 colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:])
    }

    // MARK: 识别结果 -> 稳定性投票

    private func ingest(gesture raw: Gesture, box: CGRect?) {
        if let box { handBox = box }

        let now = Date()
        // 平滑高亮：决定性手势短暂丢失（linger 内）时维持
        if raw.isDecisive {
            lastDecisive = raw; lastDecisiveTime = now; live = raw
        } else if lastDecisive.isDecisive, now.timeIntervalSince(lastDecisiveTime) < lingerDuration {
            live = lastDecisive
        } else {
            live = .none; lastDecisive = .none
        }

        guard !locked else { return }
        samples.append((now, live))
        let cutoff = now.addingTimeInterval(-windowDuration)
        samples.removeAll { $0.t < cutoff }

        guard samples.count >= 3, let first = samples.first,
              now.timeIntervalSince(first.t) >= minSpan else { return }

        let total = samples.count
        let thumb = samples.filter { $0.g == .thumbUp }.count
        let palm = samples.filter { $0.g == .openPalm }.count
        let need = max(2, Int((Double(total) * lockFraction).rounded()))

        if thumb >= need && thumb >= palm {
            locked = true
            onStable?(.thumbUp)
        } else if palm >= need && palm > thumb {
            locked = true
            onStable?(.openPalm)
        }
    }
}
