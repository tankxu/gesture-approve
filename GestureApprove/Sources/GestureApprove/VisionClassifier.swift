import Vision
import CoreML
import CoreGraphics

/// 内置识别引擎：Apple Vision 提取手部关键点 → 自训的小 Core ML 模型分类。
/// 模型用 HaGRID 数据训练（旋转/翻转增强），对相机角度鲁棒；体积 ~几十 KB，零运行时依赖。
final class VisionClassifier {
    /// (gesture, 手部包围盒归一化矩形 y向下) 回调，在调用线程执行。
    var onResult: ((Gesture, CGRect?) -> Void)?

    private static let model: MLModel? = {
        guard let url = Bundle.main.url(forResource: "HandGesture", withExtension: "mlmodelc"),
              let m = try? MLModel(contentsOf: url) else {
            GALog.log("Vision: 找不到 HandGesture.mlmodelc")
            return nil
        }
        return m
    }()

    /// 固定的 21 关节顺序（训练与推理必须一致）。
    static let jointOrder: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip,
    ]

    /// 提取 21 个关节点（Vision 归一化坐标，y 向上）；缺失点用手腕填充。无手返回 nil。
    nonisolated static func landmarks(_ obs: VNHumanHandPoseObservation) -> [CGPoint]? {
        guard let pts = try? obs.recognizedPoints(.all) else { return nil }
        guard let wristPt = pts[.wrist], wristPt.confidence > 0.2 else { return nil }
        let w = CGPoint(x: wristPt.location.x, y: wristPt.location.y)
        return jointOrder.map { j in
            if let p = pts[j] { return CGPoint(x: p.location.x, y: p.location.y) }
            return w
        }
    }

    nonisolated func process(cgImage: CGImage) {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { onResult?(.none, nil); return }
        guard let obs = request.results?.first, let lms = Self.landmarks(obs) else {
            onResult?(.none, nil); return
        }
        let (gesture, box) = Self.classify(landmarks: lms)
        onResult?(gesture, box)
    }

    /// 关键点 → 归一化特征(以手腕为中心、按手掌尺度) → Core ML 模型 → 手势。
    nonisolated static func classify(landmarks lms: [CGPoint]) -> (Gesture, CGRect?) {
        // 包围盒（转 y 向下）
        let xs = lms.map { $0.x }, ys = lms.map { $0.y }
        var box: CGRect? = nil
        if let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(), maxX > minX {
            box = CGRect(x: minX, y: 1 - maxY, width: maxX - minX, height: maxY - minY)
        }
        guard let model else { return (.none, box) }

        // 归一化：减手腕、除以到手腕的平均距离（与训练一致）
        let w = lms[0]
        var sum: CGFloat = 0
        for p in lms { sum += hypot(p.x - w.x, p.y - w.y) }
        let s = max(sum / CGFloat(lms.count), 1e-6)
        guard let arr = try? MLMultiArray(shape: [1, 42], dataType: .float32) else { return (.none, box) }
        for i in 0..<lms.count {
            arr[i * 2] = NSNumber(value: Float((lms[i].x - w.x) / s))
            arr[i * 2 + 1] = NSNumber(value: Float((lms[i].y - w.y) / s))
        }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: ["landmarks": MLFeatureValue(multiArray: arr)]),
              let out = try? model.prediction(from: provider),
              let name = out.featureNames.first,
              let probs = out.featureValue(for: name)?.multiArrayValue, probs.count >= 3 else {
            return (.none, box)
        }
        var best = 0
        var bestVal = probs[0].floatValue
        for i in 1..<probs.count where probs[i].floatValue > bestVal {
            bestVal = probs[i].floatValue; best = i
        }
        let threshold = Float((UserDefaults.standard.object(forKey: "gestureMinConf") as? Double) ?? 0.6)
        guard bestVal >= threshold else { return (.none, box) }
        switch best {
        case 0: return (.thumbUp, box)
        case 1: return (.openPalm, box)
        default: return (.none, box)   // other
        }
    }
}
