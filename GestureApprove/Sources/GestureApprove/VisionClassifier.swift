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
        let (gesture, box) = Self.classify(landmarks: lms, chirality: obs.chirality)
        onResult?(gesture, box)
    }

    /// 关键点 → 几何特征（朝向无关）判定手势；Core ML 模型仅在极端情况下软否决。
    ///
    /// 为什么以几何为主：👍 和握拳在 21 个关键点上仅差“拇指是否外伸”，纯模型极易混淆；
    /// 而张开手掌的“伸展手指数”几何上非常干净。下面两个特征都基于“到手腕的距离”，
    /// 与手的整体朝向无关，所以不像早期那版几何法那样怕相机角度。阈值经 HaGRID 样本实测：
    /// 👍 拇指比值 p5≈3.2、握拳 p95≈2.65（默认分界 2.8）；张开手 100% 命中“≥4 指伸展”。
    nonisolated static func classify(landmarks lms: [CGPoint], chirality: VNChirality = .unknown) -> (Gesture, CGRect?) {
        // 包围盒（转 y 向下）
        let xs = lms.map { $0.x }, ys = lms.map { $0.y }
        var box: CGRect? = nil
        if let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(), maxX > minX {
            box = CGRect(x: minX, y: 1 - maxY, width: maxX - minX, height: maxY - minY)
        }

        // 精准度滑杆同时控制两条路（0.3 宽松 … 0.6 默认 … 0.9 严格）：
        //   · 长手指“伸展”的判定 margin：0.85 → 1.0 → 1.15（越严越要求手指笔直，影响张手🖐）
        //   · 拇指外伸阈值：2.2 → 2.8 → 3.4（越严越要求拇指明显支棱，影响👍）
        let slider = (UserDefaults.standard.object(forKey: "gestureMinConf") as? Double) ?? 0.6
        let extMargin = CGFloat(0.85 + (slider - 0.3) * 0.5)
        let thumbTh = CGFloat(2.2 + (slider - 0.3) * 2.0)
        let maxTilt = CGFloat(55 - (slider - 0.6) * 50)            // 张手朝上容差：0.3→70° … 0.6→55° … 0.9→40°
        let thumbMaxTilt = CGFloat(60 - (slider - 0.6) * 40)       // 👍拇指朝上容差：0.3→72° … 0.6→60° … 0.9→48°
        let (extLong, thumbRatio) = geomFeatures(lms, extMargin: extMargin)

        var candidate: Gesture = .none
        if extLong >= 4 {
            // 张开手掌 = 拒绝；要求 (1)手掌正面朝相机 (2)手竖起来朝上（排除放平/朝下的手）。
            if isPalmFacing(lms, chirality: chirality) && isUpright(lms, maxTiltDeg: maxTilt) {
                candidate = .openPalm
            }
        } else if extLong <= 1 && thumbRatio >= thumbTh && thumbUpAngle(lms) <= thumbMaxTilt {
            candidate = .thumbUp                                    // 仅拇指外伸、其余蜷曲、且拇指朝上 = 通过
        }
        maybeDebug(lms, chirality, ext: extLong, tr: thumbRatio, cand: candidate)
        guard candidate != .none else { return (.none, box) }       // 握拳/手背/其它 → 不判定

        // 模型软校验：仅当模型极强烈认为是“other”时压制，避免极端误触。
        // 模型只能否决、不能促成，所以无法把握拳错判成 👍。
        if let probs = modelProbs(lms) {
            let idx = candidate == .thumbUp ? 0 : 1
            if probs[idx] < 0.10 && probs[2] > 0.80 { return (.none, box) }
        }
        return (candidate, box)
    }

    /// 诊断日志（开关：`defaults write com.tankxu.gestureapprove visionDebug -bool true`），限频 ~4/秒。
    nonisolated(unsafe) static var lastDebug = Date.distantPast
    nonisolated static func maybeDebug(_ lms: [CGPoint], _ chir: VNChirality, ext: Int, tr: CGFloat, cand: Gesture) {
        guard UserDefaults.standard.bool(forKey: "visionDebug") else { return }
        let now = Date()
        guard now.timeIntervalSince(lastDebug) > 0.25 else { return }
        lastDebug = now
        let chs = chir == .right ? "右" : (chir == .left ? "左" : "未知")
        let pf = isPalmFacing(lms, chirality: chir)
        GALog.log(String(format: "vision 左右手=%@ 伸展指=%d 拇指比=%.2f 指尖朝上角=%.0f° 拇指朝上角=%.0f° 手掌正面=%@ 判定=%@",
                         chs, ext, Double(tr), Double(uprightAngle(lms)), Double(thumbUpAngle(lms)), pf ? "是" : "否", cand.rawValue))
    }

    /// 是否“手掌正面朝向相机”（用于张开手只认手掌、不认手背）。
    /// 单看 2D 骨架无法分正反（右手手背 ≡ 左手手掌，互为镜像）；需结合 Vision 的左右手判定 +
    /// 关键点绕序（叉积符号）。手背是手掌的镜像，叉积符号相反。该判据只与镜像有关、与旋转无关。
    /// 推导：右手手掌正面 → 叉积>0；左手手掌正面 → 叉积<0。若实测装反，翻转下面这行的比较即可。
    nonisolated static func isPalmFacing(_ p: [CGPoint], chirality: VNChirality) -> Bool {
        guard chirality != .unknown else { return true }   // 拿不到左右手时不拦截
        let w = p[0], idx = p[5], lit = p[17]   // 手腕、食指掌指关节、小指掌指关节
        let cross = (idx.x - w.x) * (lit.y - w.y) - (idx.y - w.y) * (lit.x - w.x)
        return (chirality == .right) ? (cross > 0) : (cross < 0)
    }

    /// 手是否“竖起来朝上”（指尖整体在手腕上方、偏离正上方不超过 maxTiltDeg）。
    /// 用于把竖直正对相机的拒绝手势，与放平/朝下的手区分开（HaGRID 竖直手掌实测 p90≈12°）。
    nonisolated static func isUpright(_ p: [CGPoint], maxTiltDeg: CGFloat) -> Bool {
        uprightAngle(p) <= maxTiltDeg
    }

    /// 指尖整体相对手腕偏离“正上方”的夹角（0=正上、90=水平、>90=朝下）。
    nonisolated static func uprightAngle(_ p: [CGPoint]) -> CGFloat {
        let tips = [8, 12, 16, 20]
        let w = p[0]
        let tx = tips.reduce(0.0) { $0 + p[$1].x } / 4
        let ty = tips.reduce(0.0) { $0 + p[$1].y } / 4
        // Vision y 向上：dy>0 表示指尖在手腕上方。
        return atan2(abs(tx - w.x), ty - w.y) * 180 / .pi
    }

    /// 拇指尖相对手腕偏离“正上方”的夹角（0=拇指正上、90=横、>90=朝下）。用于 👍 须拇指朝上。
    nonisolated static func thumbUpAngle(_ p: [CGPoint]) -> CGFloat {
        atan2(abs(p[4].x - p[0].x), p[4].y - p[0].y) * 180 / .pi
    }

    /// 几何特征：伸展的长手指数(0–4) + 拇指外伸比值。基于到手腕/掌心的距离，朝向无关。
    /// extMargin 越大越严格（要求 tip 明显比 pip 远离手腕才算伸展）。
    nonisolated static func geomFeatures(_ p: [CGPoint], extMargin: CGFloat = 1.0) -> (extLong: Int, thumbRatio: CGFloat) {
        func dist(_ a: Int, _ b: Int) -> CGFloat { hypot(p[a].x - p[b].x, p[a].y - p[b].y) }
        func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        // 长手指 (PIP, Tip)：tip 比 pip 离手腕更远 = 伸展；蜷曲时 tip 收回更近。
        let longs = [(6, 8), (10, 12), (14, 16), (18, 20)]
        var ext = 0
        for (pip, tip) in longs where dist(tip, 0) > dist(pip, 0) * extMargin { ext += 1 }
        // 拇指外伸：拇指尖到掌心的距离 / 四掌指关节到掌心的平均半径。
        let mcps = [5, 9, 13, 17]
        let cx = ([0] + mcps).reduce(0.0) { $0 + p[$1].x } / 5
        let cy = ([0] + mcps).reduce(0.0) { $0 + p[$1].y } / 5
        let center = CGPoint(x: cx, y: cy)
        let palmR = max(mcps.reduce(0.0) { $0 + dist(p[$1], center) } / 4, 1e-6)
        return (ext, dist(p[4], center) / palmR)
    }

    /// 跑 Core ML 模型，返回 [thumbUp, openPalm, other] 概率（无模型/失败返回 nil）。
    nonisolated static func modelProbs(_ lms: [CGPoint]) -> [Float]? {
        guard let model else { return nil }
        let w = lms[0]
        var sum: CGFloat = 0
        for p in lms { sum += hypot(p.x - w.x, p.y - w.y) }
        let s = max(sum / CGFloat(lms.count), 1e-6)
        guard let arr = try? MLMultiArray(shape: [1, 42], dataType: .float32) else { return nil }
        for i in 0..<lms.count {
            arr[i * 2] = NSNumber(value: Float((lms[i].x - w.x) / s))
            arr[i * 2 + 1] = NSNumber(value: Float((lms[i].y - w.y) / s))
        }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: ["landmarks": MLFeatureValue(multiArray: arr)]),
              let out = try? model.prediction(from: provider),
              let name = out.featureNames.first,
              let probs = out.featureValue(for: name)?.multiArrayValue, probs.count >= 3 else {
            return nil
        }
        return (0..<3).map { probs[$0].floatValue }
    }
}
