import AppKit

/// 菜单栏菜单顶部的「用量」区渲染。
/// 只画正在跑的工具；一个都没跑就整段不出现（连分隔线都不留）。
///
/// 条目本身不可点（action = nil），靠 attributedTitle 显式配色保证禁用态也清晰可读。
enum UsageMenuSection {

    /// 把 rows 渲染成一组菜单项。空数组表示这次什么都不显示。
    /// 不带分隔线：这段紧跟在「运行中」标题行后面，后面本来就有一条分隔线，
    /// 自己再加一条就成了两条挨着的横线（NSMenu 不会合并相邻分隔线）。
    static func items(for rows: [ToolUsage]) -> [NSMenuItem] {
        var out: [NSMenuItem] = []
        for r in rows {
            out.append(headItem(r))
            // 多个额度池时，池名走一行小标题，而不是挤进每行开头 ——
            // 前缀会把「5h / 7d」这列顶得一行一个位置，进度条起点跟着乱，正是之前那张截图的样子。
            var shown: String? = nil
            for w in r.windows {
                if let p = w.pool, p != shown { out.append(poolItem(p)); shown = p }
                out.append(windowItem(w))
            }
            if let note = r.note { out.append(noteItem(note)) }
        }
        return out
    }

    // MARK: 单条

    /// 「Claude Code   ● 2」——工具名 + 在跑的会话数。
    /// 没在跑就只留工具名：绿点配个 0 看着像「有 0 个」的病态提示，不如不画。
    private static func headItem(_ r: ToolUsage) -> NSMenuItem {
        let item = NSMenuItem(title: r.name, action: nil, keyEquivalent: "")
        let s = NSMutableAttributedString(string: r.name, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        if r.running > 0 {
            s.append(NSAttributedString(string: "   ● \(r.running)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.systemGreen,
            ]))
        }
        item.attributedTitle = s
        item.toolTip = r.running > 0 ? String(format: L("usage.runningTip"), r.running)
                                     : L("usage.notRunningTip")
        return item
    }

    /// 「5h ▬▬▭▭ 19% · 3h23m 后重置」
    private static func windowItem(_ w: UsageWindow) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = windowLine(w)
        return item
    }

    /// 额度池小标题（「GPT-5.3-Codex-Spark」），比工具名轻一级。
    private static func poolItem(_ name: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return item
    }

    /// 额度为空时那一行解释。可点的用正文色（看得出能点），不可点的和 note 一样是灰字。
    static func hintItem(_ text: String, actionable: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: actionable ? NSColor.labelColor : NSColor.tertiaryLabelColor,
        ])
        return item
    }

    private static func noteItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        return item
    }

    /// 压成通知正文：「Claude Code · 5h 32% · 7d 10%」。一个百分比都没拿到就返回 nil。
    static func summary(_ rows: [ToolUsage]) -> String? {
        let lines = rows.compactMap { r -> String? in
            let parts = r.windows.compactMap { w -> String? in
                guard let p = w.percent else { return nil }
                return [w.pool, w.label, remainingText(p)].compactMap { $0 }.joined(separator: " ")
            }
            return parts.isEmpty ? nil : ([r.name] + parts).joined(separator: " · ")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: 一行用量

    /// 进度条走 NSTextAttachment 塞进 attributedTitle，而不是自定义 NSMenuItem.view：
    ///   · 自定义 view 从菜单项的最左边（连高亮区）起画，得自己猜一个左边距去凑「和别的菜单项对齐」，
    ///     而这个缩进是 AppKit 内部值（菜单里只要有一项带图标，整列还会再右移），没有公开 API 能问；
    ///   · 用 attributedTitle 就是普通菜单项，缩进由系统处理，天然对齐，且不用维护那个魔法数。
    /// 条子本身是画出来的图片，所以两端全圆角、高度随便调——以前的 `█░` 方块字符两样都做不到。
    static func windowLine(_ w: UsageWindow) -> NSAttributedString {
        let mono = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let dim = NSFont.systemFont(ofSize: 11)
        let s = NSMutableAttributedString()
        // 标签用等宽数字 + 补空格：5h / 7d 两列对齐，条子起点才不会一行一个样。
        s.append(NSAttributedString(string: w.label.padding(toLength: max(w.label.count, 2), withPad: " ", startingAt: 0) + "  ",
                                    attributes: [.font: mono, .foregroundColor: NSColor.secondaryLabelColor]))
        if let p = w.percent {
            let tint = color(for: p)
            let att = NSTextAttachment()
            att.image = barImage(percent: 100-p, tint: tint)
            // y 抬高一点点，让细条落在文字的视觉中线上，而不是压在基线上。
            att.bounds = NSRect(x: 0, y: 1.5, width: barSize.width, height: barSize.height)
            s.append(NSAttributedString(attachment: att))
            s.append(NSAttributedString(string: "  " + remainingText(p, pad: 3),
                                        attributes: [.font: mono, .foregroundColor: tint]))
        } else {
            s.append(NSAttributedString(string: L("usage.pending"),
                                        attributes: [.font: dim, .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        if let r = w.resetsAt {
            s.append(NSAttributedString(string: "  · \(resetText(r))",
                                        attributes: [.font: dim, .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        return s
    }

    /// 细胶囊条：高 4pt、两端全圆角（圆角半径 = 半高）。
    static let barSize = NSSize(width: 72, height: 4)

    static func barImage(percent: Double, tint: NSColor) -> NSImage {
        let size = barSize
        // flipped: false + drawingHandler：按当前屏幕缩放渲染，Retina 上不糊。
        let img = NSImage(size: size, flipped: false) { rect in
            capsule(rect).fill(with: .quaternaryLabelColor)
            let filled = size.width * max(0, min(100, percent)) / 100
            guard filled > 0.1 else { return true }
            var r = rect
            // 宽度小于条高时圆角会把胶囊挤变形，收敛成一个直径 = 条高的小圆点。
            r.size.width = max(filled, size.height)
            capsule(r).fill(with: tint)
            return true
        }
        img.isTemplate = false   // 有自己的语义色，别被菜单当模板图刷成单色
        return img
    }

    private static func capsule(_ r: NSRect) -> NSBezierPath {
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
    }

    // MARK: 格式化

    /// 用量条与百分比的配色：接近上限时才变色，平时保持安静。
    static func color(for pct: Double) -> NSColor {
        if pct >= 90 { return .systemRed }
        if pct >= 75 { return .systemOrange }
        return .secondaryLabelColor
    }

    /// 一律说「还剩多久」，不给绝对时间点：窗口最长 7 天，「6d20h 后重置」比「Fri, 07/08, 00:00」
    /// 既短又无歧义（后者还会被 07/08 到底是 7 月 8 号还是 8 月 7 号绊住）。
    static func resetText(_ date: Date) -> String {
        let left = date.timeIntervalSinceNow
        if left <= 0 { return L("usage.resetting") }
        return String(format: L("usage.resetIn"), compact(left))
    }

    /// 「剩余 72%」。之前这句是硬编码中文，混在一堆走 L() 的英文里，英文界面上就成了
    /// 「剩余 72% · resets in 41m」这种中英夹生的行。
    static func remainingText(_ usedPercent: Double, pad: Int = 0) -> String {
        String(format: L("usage.remaining"), String(format: "%\(pad)d", Int((100 - usedPercent).rounded())))
    }

    /// 6d20h / 3h30m / 45m —— 只保留两级，够看就行。
    static func compact(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        if m < 60 { return "\(max(m, 1))m" }
        let h = m / 60
        if h < 24 { return m % 60 == 0 ? "\(h)h" : "\(h)h\(m % 60)m" }
        return h % 24 == 0 ? "\(h / 24)d" : "\(h / 24)d\(h % 24)h"
    }
}

/// 「在浏览器中获取 Claude 用量信息」弹窗。抽出来是为了 `--usage-ask` 能拿真家伙做核对，
/// 而不是照着抄一份形状差不多的。按钮顺序即返回顺序：Claude Web / Keychain / 临时关闭。
enum UsageSourceAlert {
    /// 弹窗内容列宽。NSAlert 没有宽度 API，macOS 11 起默认那个 260pt 窄版式会把两句话挤成七八行。
    private static let width: CGFloat = 340

    static func make(_ reason: UsageAskReason) -> NSAlert {
        let a = NSAlert()
        a.messageText = L("usage.ask.title")
        a.informativeText = detail(reason)
        // 撑开宽度的唯一办法：给一条固定宽度的 accessoryView（高 0，不占垂直空间）。
        a.accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 0))

        let open = a.addButton(withTitle: L("usage.ask.useChrome"))
        open.keyEquivalent = "\r"        // 默认键 = 蓝色主按钮
        a.addButton(withTitle: L("usage.ask.useKeychain"))
        // 「暂不获取用量」**不绑 Esc**。随手一个 Esc 就静默停掉 24 小时的自动询问，
        // 事后完全看不出来发生过什么——这种代价必须是用户真的按了那个键才付。
        a.addButton(withTitle: L("usage.ask.snooze"))

        stretchButtons(a)
        return a
    }

    static func run(_ a: NSAlert) -> NSApplication.ModalResponse { a.runModal() }

    /// 竖排按钮有个约 228pt 的固定宽度，弹窗撑宽后它们就缩在中间、和正文对不齐。
    /// 那是 NSAlert 内部钉的 required 等宽约束（改 frame 没用，加低优先级约束也没用），
    /// 只能先把它关掉再换成自己的。找不到就原样保留——按钮窄一点，总比布局崩了强。
    private static func stretchButtons(_ a: NSAlert) {
        a.layout()   // 先让内部把那批约束建出来
        let ids = Set(a.buttons.map(ObjectIdentifier.init))
        var hosts: [NSView] = a.buttons
        if let stack = a.buttons.first?.superview { hosts.append(stack) }
        if let content = a.window.contentView { hosts.append(content) }
        for host in hosts {
            for c in host.constraints
            where c.firstAttribute == .width && c.secondItem == nil && c.priority == .required {
                guard let item = c.firstItem as? NSView, ids.contains(ObjectIdentifier(item)) else { continue }
                c.isActive = false
            }
        }
        for b in a.buttons { b.widthAnchor.constraint(equalToConstant: width).isActive = true }
    }

    static func detail(_ reason: UsageAskReason) -> String {
        switch reason {
        case .firstTime:                      return L("usage.ask.firstTime")
        case .chromeBroken(.noTab):           return L("usage.ask.noTab")
        case .chromeBroken(.jsDisabled):      return L("usage.ask.jsDisabled")
        case .chromeBroken(.accountMismatch): return L("usage.ask.otherAccount")
        case .chromeBroken(.other):           return L("usage.ask.otherFailure")
        }
    }
}

private extension NSBezierPath {
    func fill(with color: NSColor) {
        color.setFill()
        fill()
    }
}
