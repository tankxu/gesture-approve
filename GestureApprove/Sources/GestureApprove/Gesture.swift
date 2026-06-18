import Foundation

/// 审批手势。
enum Gesture: String {
    case thumbUp   // 👍 通过
    case openPalm  // 🖐 拒绝
    case none      // 未识别到明确手势

    var isDecisive: Bool { self == .thumbUp || self == .openPalm }
}

/// 一次审批的最终结果。
enum ApprovalOutcome {
    case approved   // 👍
    case denied     // 🖐
    case timedOut   // 超时未识别

    var isApproved: Bool { self == .approved }
}
