import SwiftUI
import AppKit

/// 「审批日志」窗口：回看每一次接管的判定——命令、时间、会话、结果，
/// 以及命中的是白名单 / 黑名单 / 智能放行 / 手势，还是「总是允许」写入信任命令。
struct ApproveLogView: View {
    @State private var entries: [ApproveLogEntry] = ApproveLog.recent()
    @State private var confirmClear = false
    /// 当前信任命令集合：决定每行显示「加入白名单」按钮还是「已在白名单」。
    @State private var trusted: Set<String> = Set(Allowlist.trustedCommands())
    /// 鼠标悬停的行 id：仅该行显示「加入白名单」按钮，避免每行都挂一排按钮显得杂乱。
    @State private var hoveredID: String? = nil

    private let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if entries.isEmpty {
                Spacer()
                Text(L("log.empty"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { row($0) }
                    }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .onReceive(NotificationCenter.default.publisher(for: .gaApproveLogged)) { _ in
            entries = ApproveLog.recent()
            trusted = Set(Allowlist.trustedCommands())
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(L("log.windowTitle")).font(.headline)
            Text("\(entries.count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: Capsule())
            Spacer()
            Button { entries = ApproveLog.recent() } label: {
                Label(L("log.refresh"), systemImage: "arrow.clockwise")
            }
            Button {
                NSWorkspace.shared.selectFile(ApproveLog.path,
                                              inFileViewerRootedAtPath: AppPaths.support)
            } label: {
                Label(L("log.reveal"), systemImage: "folder")
            }
            Button(role: .destructive) { confirmClear = true } label: {
                Label(L("log.clear"), systemImage: "trash")
            }
            .disabled(entries.isEmpty)
            .confirmationDialog(L("log.clearConfirm"), isPresented: $confirmClear, titleVisibility: .visible) {
                Button(L("log.clear"), role: .destructive) {
                    ApproveLog.clear()
                    entries = []
                }
                Button(L("settings.cancel"), role: .cancel) {}
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder private func row(_ e: ApproveLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                decisionTag(e.decision)
                gateTag(e)
                if e.dangerous { plainTag(L("log.danger"), color: .red) }
                Spacer(minLength: 6)
                allowlistControl(e)
                Text(timeFmt.string(from: e.date))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(e.operation.isEmpty ? L("card.noOperation") : e.operation)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                if !e.tool.isEmpty { metaItem("hammer", e.tool) }
                if !projectName(e.cwd).isEmpty { metaItem("folder", projectName(e.cwd)) }
                if !e.session.isEmpty { metaItem("number", String(e.session.prefix(8))) }
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())   // 整行（含留白）都参与 hover 命中
        .background(hoveredID == e.id ? Color.primary.opacity(0.04) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
        }
        .onHover { hoveredID = $0 ? e.id : (hoveredID == e.id ? nil : hoveredID) }
    }

    /// 每行右侧的白名单控件：把这条命令一键加入信任命令（以后免审）。
    /// 「加入白名单」按钮只在**鼠标悬停该行**时出现；已在白名单的行常显「已在白名单」状态。
    /// 危险命令不提供——它即使加了也会被 deny-list 硬否决、永远要手势，给按钮会误导。
    @ViewBuilder private func allowlistControl(_ e: ApproveLogEntry) -> some View {
        if !e.operation.isEmpty && !Allowlist.isDangerous(e.operation) {
            if trusted.contains(e.operation) {
                HStack(spacing: 2) {
                    Image(systemName: "checkmark.circle.fill")
                    Text(L("log.inAllowlist"))
                }
                .font(.system(size: 11))
                .foregroundStyle(.green)
            } else if hoveredID == e.id {
                Button {
                    Allowlist.addAlwaysAllow(e.operation)
                    trusted.insert(e.operation)
                    Notifier.post(title: L("alwaysAllow.notifyTitle"), body: e.operation)
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "plus.circle")
                        Text(L("log.addAllowlist"))
                    }
                    .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help(L("log.addAllowlist.help"))
            }
        }
    }

    @ViewBuilder private func metaItem(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(text).lineLimit(1).truncationMode(.middle)
        }
    }

    // MARK: 标签

    @ViewBuilder private func decisionTag(_ decision: String) -> some View {
        switch decision {
        case "allow": plainTag(L("log.allow"), color: .green)
        case "deny":  plainTag(L("log.deny"), color: .red)
        default:      plainTag(L("log.ask"), color: .secondary)
        }
    }

    @ViewBuilder private func gateTag(_ e: ApproveLogEntry) -> some View {
        let (label, color): (String, Color) = {
            switch e.gateKind {
            case .allowlist:   return (L("gate.allowlist"), .green)
            case .smartgate:   return (L("gate.smartgate"), .blue)
            case .gesture:     return (L("gate.gesture"), .purple)
            case .alwaysAllow: return (L("gate.alwaysAllow"), .teal)
            case .timeout:     return (L("gate.timeout"), .orange)
            case .suspended:   return (L("gate.suspended"), .gray)
            case .gatingOff:   return (L("gate.gatingOff"), .gray)
            case .none:        return (e.gate, .gray)
            }
        }()
        plainTag(label, color: color)
    }

    @ViewBuilder private func plainTag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }

    private func projectName(_ cwd: String) -> String {
        cwd.isEmpty ? "" : (cwd as NSString).lastPathComponent
    }
}

extension Notification.Name {
    /// 写入一条审批记录后发出，日志窗口据此实时刷新。
    static let gaApproveLogged = Notification.Name("gaApproveLogged")
}

@MainActor
final class ApproveLogWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: ApproveLogView())
            let w = NSWindow(contentViewController: hosting)
            w.title = L("log.windowTitle")
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 720, height: 480))
            w.isReleasedWhenClosed = false
            w.delegate = self
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
