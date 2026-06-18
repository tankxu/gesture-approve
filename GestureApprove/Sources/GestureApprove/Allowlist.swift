import Foundation

/// 自动放行白名单：操作匹配任一正则则直接通过，不弹手势卡片。
enum Allowlist {
    static let key = "allowlistPatterns"

    /// 默认放行常见只读/安全命令（匹配 hook 传来的 "<tool>: <detail>" 串）。
    static let defaultPatterns = [
        "^Bash: git (status|log|diff|branch|show|remote|stash list)",
        "^Bash: (ls|pwd|cat|head|tail|less|grep|rg|find|echo|which|whoami|date|env|printenv|wc|file|stat|tree|du|df|ps|uname|hostname|open)\\b",
    ]

    static func patterns() -> [String] {
        (UserDefaults.standard.array(forKey: key) as? [String]) ?? defaultPatterns
    }

    static func setPatterns(_ p: [String]) {
        UserDefaults.standard.set(p, forKey: key)
    }

    static func matches(_ op: String) -> Bool {
        let range = NSRange(op.startIndex..., in: op)
        for pat in patterns() {
            let p = pat.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { continue }
            if let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]),
               re.firstMatch(in: op, range: range) != nil {
                return true
            }
        }
        return false
    }
}
