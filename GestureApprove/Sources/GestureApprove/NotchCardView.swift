import SwiftUI

/// 从刘海下方展开的黑色审批卡片。
struct NotchCardView: View {
    /// 操作名（如 "Bash: rm -rf build"）。
    let operation: String
    /// 发起项目的工作目录（显示其末段作为项目名）。
    var cwd: String = ""
    /// 工具名（Bash/Edit/…）。
    var tool: String = ""
    /// 当前即时识别到的手势，用于高亮对应图标。
    let live: Gesture
    /// 已锁定的判定（nil 表示尚未锁定）。
    let locked: Gesture?
    /// 摄像头当前画面（黑玻璃背景）。
    var previewImage: CGImage? = nil
    /// 手部包围盒（归一化，y 向下），用于按手大小/位置推近。
    var handBox: CGRect? = nil
    /// 倒计时环：超时时长 + 会话标识（每次审批变化以重启动画）。
    var timeout: TimeInterval = 90
    var sessionID: Int = 0
    /// 点击图标的回调（通过/拒绝）。
    var onApprove: (() -> Void)? = nil
    var onDeny: (() -> Void)? = nil
    /// 是否可“总是允许”（危险/空操作时不提供），及其回调。
    var canAlwaysAllow: Bool = false
    var onAlwaysAllow: (() -> Void)? = nil
    /// 整体放大系数（Big Mode）：所有字号/尺寸/间距乘以它，1 为常规。
    var scale: CGFloat = 1
    /// Big Mode：给定则卡片铺满该尺寸（全屏黑卡）、内容垂直居中、无圆角；nil 为常规自适应卡片。
    var fillFrame: CGSize? = nil

    /// 点击命令文字展开/收起完整命令——浮层 panel 上 .help tooltip 不触发，改用点击。
    @State private var commandExpanded = false

    /// "📁 项目名 · 工具"：cwd 取末段目录名，与 tool 组合；都为空则不显示。
    private var contextLabel: String {
        let project = cwd.isEmpty ? "" : (cwd as NSString).lastPathComponent
        let parts = [project, tool].filter { !$0.isEmpty }
        return parts.isEmpty ? "" : "📁 " + parts.joined(separator: " · ")
    }

    /// 卡片里要显示的命令：若 operation 形如 "Bash: cmd" 且 tool 已单独显示，去掉前缀只留命令体。
    private var displayCommand: String {
        if !tool.isEmpty, operation.hasPrefix(tool + ": ") {
            return String(operation.dropFirst(tool.count + 2))
        }
        return operation
    }

    /// 命令文本，危险片段标红加粗。
    private var styledOperation: AttributedString {
        let cmd = displayCommand
        var s = AttributedString(cmd)
        s.foregroundColor = .white.opacity(0.9)
        for r in Allowlist.dangerRanges(in: cmd) {
            if let lo = AttributedString.Index(r.lowerBound, within: s),
               let hi = AttributedString.Index(r.upperBound, within: s) {
                s[lo..<hi].foregroundColor = Color(red: 1.0, green: 0.42, blue: 0.42)  // 柔和红，黑底可读
                s[lo..<hi].inlinePresentationIntent = .stronglyEmphasized
            }
        }
        return s
    }

    private var approveActive: Bool { locked == .thumbUp || (locked == nil && live == .thumbUp) }
    private var denyActive: Bool { locked == .openPalm || (locked == nil && live == .openPalm) }
    /// 检测到手势时推近画面。
    private var zoomedIn: Bool { locked != nil || live.isDecisive }

    var body: some View {
        if let fill = fillFrame {
            fullScreenBody(fill)
        } else {
            regularBody
        }
    }

    // MARK: 全屏 Big Mode 布局
    // 标题贴顶、提示贴底（都用小 padding 紧贴屏幕边缘），命令+图标成一组由两个弹性 Spacer
    // 顶到垂直中心——审核内容是最大项、居中占据屏幕主区。UI 文本（标题/标签/提示）克制。
    private func fullScreenBody(_ fill: CGSize) -> some View {
        // 字号随屏尺寸微调，保证不同分辨率都协调；命令是最大项。
        let unit = min(fill.width, fill.height * 1.6) / 1000
        let cmdSize = max(34, 52 * unit)      // 审核内容：最大
        let titleSize = max(15, 20 * unit)    // "APPROVAL NEEDED"：小
        let ctxSize = max(15, 19 * unit)      // 📁 项目·工具
        let hintSize = max(14, 18 * unit)     // 底部提示
        let iconD = max(96, 132 * unit)       // 手势大圆
        let iconLabel = max(16, 22 * unit)
        let margin: CGFloat = 24              // 贴边距离（固定小值，让标题真正贴顶、提示真正贴底）

        return VStack(spacing: 0) {
            // 贴顶：标题 + 上下文
            VStack(spacing: 10) {
                Text(L("card.needApproval"))
                    .font(.system(size: titleSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .tracking(titleSize * 0.25)
                if !contextLabel.isEmpty {
                    Text(contextLabel)
                        .font(.system(size: ctxSize, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, margin)
                }
            }
            .padding(.top, margin + 10)   // 多让 10pt，避免标题贴到刘海摄像头

            Spacer(minLength: 24)   // 弹性：把标题顶到最上

            // 垂直居中的主区：命令（最大）+ 手势图标
            VStack(spacing: iconD * 0.5) {
                Text(styledOperation)
                    .font(.system(size: cmdSize, weight: .semibold, design: .monospaced))
                    .lineLimit(commandExpanded ? nil : 12)
                    .minimumScaleFactor(0.3)   // 超长命令/路径自动缩小字号，塞进下面的高度上限，不撑爆布局
                    .multilineTextAlignment(.center)
                    .frame(maxHeight: fill.height * 0.5)   // 命令区最多占半屏高，标题/图标/提示始终有位置
                    .padding(.horizontal, margin)
                    .contentShape(Rectangle())
                    .onTapGesture { commandExpanded.toggle() }

                HStack(spacing: iconD * 0.7) {
                    gestureIcon(symbol: "hand.thumbsup.fill", label: L("card.approve"),
                                tint: .green, active: approveActive, done: locked == .thumbUp,
                                action: onApprove, diameter: iconD, symbolSize: iconD * 0.42, labelSize: iconLabel)
                    gestureIcon(symbol: "hand.raised.fill", label: L("card.deny"),
                                tint: .red, active: denyActive, done: locked == .openPalm,
                                action: onDeny, diameter: iconD, symbolSize: iconD * 0.42, labelSize: iconLabel)
                }
            }

            Spacer(minLength: 24)   // 弹性：把提示沉到最下

            // 贴底：提示 + 总是允许
            VStack(spacing: 12) {
                Text(locked == nil ? L("card.hint") : (locked == .thumbUp ? L("card.approved") : L("card.denied")))
                    .font(.system(size: hintSize))
                    .foregroundStyle(.white.opacity(0.4))
                if locked == nil, canAlwaysAllow, let onAlwaysAllow {
                    Button(action: onAlwaysAllow) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.seal")
                            Text(L("card.alwaysAllow"))
                        }
                        .font(.system(size: hintSize * 0.9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Capsule().fill(.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, margin)
        }
        .frame(width: fill.width, height: fill.height)
        .background(cardBackground)
        .overlay(alignment: .topTrailing) {
            if locked == nil {
                CountdownRing(duration: timeout, sessionID: sessionID, scale: 1.4)
                    .frame(width: 24, height: 24)
                    .padding(margin * 0.6)
            }
        }
    }

    // MARK: 常规刘海卡片布局
    private var regularBody: some View {
        VStack(spacing: 14 * scale) {
            // 顶部留白，让卡片从刘海下沿“长出来”
            Text(L("card.needApproval"))
                .font(.system(size: 12 * scale, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .tracking(2 * scale)
                .padding(.top, 10 * scale)

            // 上下文：📁 项目名 · 工具（有信息才显示，让你知道是哪个会话/项目在请求）
            if !contextLabel.isEmpty {
                Text(contextLabel)
                    .font(.system(size: 11 * scale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 18 * scale)
            }

            // 命令本身：危险片段(rm -rf / |sh / sudo …)标红加粗。小字号 + 多行 + 左对齐，长命令更易读；
            // hover 显示完整命令（长命令仍可能尾部省略，但危险片段尽量可见，悬停可看全）。
            Text(styledOperation)
                .font(.system(size: 11 * scale, weight: .medium, design: .monospaced))
                .lineLimit(commandExpanded ? nil : 3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18 * scale)
                .contentShape(Rectangle())
                .onTapGesture { commandExpanded.toggle() }

            HStack(spacing: 28 * scale) {
                gestureIcon(symbol: "hand.thumbsup.fill",
                            label: L("card.approve"),
                            tint: Color.green,
                            active: approveActive,
                            done: locked == .thumbUp,
                            action: onApprove)
                gestureIcon(symbol: "hand.raised.fill",
                            label: L("card.deny"),
                            tint: Color.red,
                            active: denyActive,
                            done: locked == .openPalm,
                            action: onDeny)
            }

            VStack(spacing: 7 * scale) {
                Text(locked == nil ? L("card.hint") : (locked == .thumbUp ? L("card.approved") : L("card.denied")))
                    .font(.system(size: 11 * scale))
                    .foregroundStyle(.white.opacity(0.4))
                if locked == nil, canAlwaysAllow, let onAlwaysAllow {
                    Button(action: onAlwaysAllow) {
                        HStack(spacing: 4 * scale) {
                            Image(systemName: "checkmark.seal")
                            Text(L("card.alwaysAllow"))
                        }
                        .font(.system(size: 10 * scale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 10 * scale).padding(.vertical, 4 * scale)
                        .background(Capsule().fill(.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 14 * scale)
        }
        .frame(width: 360 * scale)
        .background(cardBackground)
        .overlay(alignment: .topTrailing) {
            if locked == nil {
                CountdownRing(duration: timeout, sessionID: sessionID, scale: scale)
                    .frame(width: 16 * scale, height: 16 * scale)
                    .padding(14 * scale)
            }
        }
    }

    /// 黑玻璃卡片背景：黑底 → 实时画面(压暗/模糊/低透明) → 暗角渐变 → 描边。
    private var cardBackground: some View {
        // 全屏 Big Mode 不用圆角（铺满屏幕边缘），常规卡片保留圆角
        let shape = RoundedRectangle(cornerRadius: fillFrame != nil ? 0 : 26 * scale, style: .continuous)
        return ZStack {
            shape.fill(Color.black)
            if let previewImage {
                GeometryReader { geo in
                    // 按手部包围盒自适应：缩放使手占画面约 targetFrac，并居中到手；偏移夹紧防止露黑边
                    let box = handBox
                    let bw = box?.width ?? 1, bh = box?.height ?? 1
                    let targetFrac: CGFloat = 0.75
                    let fitZoom = box != nil ? targetFrac / max(max(bw, bh), 0.05) : 1.0
                    let zoom: CGFloat = zoomedIn ? min(max(fitZoom, 1.0), 3.0) : 1.0
                    let bcx = box.map { $0.midX } ?? 0.5
                    let bcy = box.map { $0.midY } ?? 0.5
                    let maxOffX = (zoom - 1) / 2 * geo.size.width
                    let maxOffY = (zoom - 1) / 2 * geo.size.height
                    let offX = zoomedIn ? min(max((0.5 - bcx) * geo.size.width * zoom, -maxOffX), maxOffX) : 0
                    let offY = zoomedIn ? min(max((0.5 - bcy) * geo.size.height * zoom, -maxOffY), maxOffY) : 0
                    Image(decorative: previewImage, scale: 1, orientation: .up)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(zoom, anchor: .center)
                        .offset(x: offX, y: offY)
                        .scaleEffect(x: -1, y: 1)   // 水平镜像：像照镜子，手移动方向符合直觉
                        .blur(radius: 1.5)
                        .saturation(0.35)   // 降饱和，画面更低调不抢眼
                        .opacity(0.7)
                        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: zoom)
                        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: offX)
                        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: offY)
                }
                // 轻压暗，兼顾画面可见与文字清晰
                LinearGradient(colors: [.black.opacity(0.3), .black.opacity(0.15)],
                               startPoint: .top, endPoint: .bottom)
            }
            shape.strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
        .clipShape(shape)
    }

    @ViewBuilder
    private func gestureIcon(symbol: String, label: String, tint: Color,
                            active: Bool, done: Bool, action: (() -> Void)? = nil,
                            diameter: CGFloat = 70, symbolSize: CGFloat = 30, labelSize: CGFloat = 12) -> some View {
        Button(action: { action?() }) {
            iconBody(symbol: symbol, label: label, tint: tint, active: active, done: done,
                     diameter: diameter, symbolSize: symbolSize, labelSize: labelSize)
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }

    @ViewBuilder
    private func iconBody(symbol: String, label: String, tint: Color, active: Bool, done: Bool,
                          diameter: CGFloat, symbolSize: CGFloat, labelSize: CGFloat) -> some View {
        VStack(spacing: labelSize * 0.7) {
            ZStack {
                Circle()
                    .fill(active ? tint.opacity(0.22) : Color.white.opacity(0.05))
                    .frame(width: diameter, height: diameter)
                    .overlay(
                        Circle().strokeBorder(active ? tint : .white.opacity(0.12),
                                              lineWidth: active ? 2.5 : 1)
                    )
                Image(systemName: symbol)
                    .font(.system(size: symbolSize, weight: .medium))
                    .foregroundStyle(active ? tint : .white.opacity(0.35))
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: symbolSize * 0.66))
                        .foregroundStyle(tint)
                        .background(Circle().fill(.black))
                        .offset(x: diameter * 0.37, y: -diameter * 0.37)
                }
            }
            .scaleEffect(active ? 1.08 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: active)

            Text(label)
                .font(.system(size: labelSize, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? tint : .white.opacity(0.5))
        }
    }
}

/// 倒计时圆环：随审批时长从满到空匀速走完。每次审批(sessionID 变化)重启。
struct CountdownRing: View {
    let duration: TimeInterval
    let sessionID: Int
    var scale: CGFloat = 1
    @State private var progress: CGFloat = 1

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.15), lineWidth: 2 * scale)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.white.opacity(0.7),
                        style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round))
                .rotationEffect(.degrees(-90))   // 从 12 点方向开始
        }
        .onAppear { restart() }
        .onChange(of: sessionID) { _, _ in restart() }
    }

    private func restart() {
        progress = 1
        withAnimation(.linear(duration: duration)) { progress = 0 }
    }
}
