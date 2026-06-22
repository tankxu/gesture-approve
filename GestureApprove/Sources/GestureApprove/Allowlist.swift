import Foundation

/// 自动放行白名单：决定一条操作是“跳过手势直接放行”还是“弹卡片比手势”。从不自动拒绝。
///
/// 四层逻辑（借鉴 Claude 官方 permissions / defrex 的策略思路）：
///   1. 危险 deny-list 命中 → **硬否决**，永远要手势（即使被显式“总是允许”过，如 rm -rf）。
///   2. **信任命令**整条精确命中（用户点“总是允许”亲手写入的完整命令，单独存储）→ 放行。
///   3. 某条正则规则**整条精确匹配** → 放行（用户在设置里写的锚定正则）。
///   4. 正则规则**前缀匹配**（内置只读命令快捷）→ 仅当命令“整条安全”（无 && ; | 反引号 $( 等拼接）才放行。
///
/// deny-list / 默认白名单 / 拼接符这三组规则的**单一来源**是仓库里的 `config/gatekeeper-rules.json`
/// （方便大家看和改）。运行时优先读它；缺失/损坏则回退到下面 `builtin*` 内置默认，确保 deny-list 永不为空。
enum Allowlist {
    static let key = "allowlistPatterns"
    static let trustedKey = "trustedCommands"

    /// 默认放行常见只读/安全命令（匹配 hook 传来的 "<tool>: <detail>" 串，多为前缀匹配）。
    static let defaultPatterns = RulesConfig.shared.autoAllowPatterns ?? builtinDefaultPatterns
    /// 危险命令 deny-list：命中则**始终要手势**，也是「智能放行」的保底闸（命中者永不进 LLM）。
    static let dangerPatterns = RulesConfig.shared.dangerPatterns ?? builtinDangerPatterns
    /// 命令拼接/重定向标记：出现任一则前缀白名单不放行（避免 "ls && rm -rf" 这类链式绕过）。
    static let compoundTokens = RulesConfig.shared.compoundTokens ?? builtinCompoundTokens

    // MARK: 内置默认（config 缺失/损坏时的安全兜底）
    // 这里只放**核心子集**——覆盖最致命的操作即可，不必跟 config 的完整清单逐条同步。
    // 正常情况下规则全部来自 config/gatekeeper-rules.json；这套仅在配置读不到时顶上，保证 deny-list 不空。
    static let builtinDefaultPatterns = [
        "^Bash: git (status|log|diff|branch|show|remote|stash list)",
        "^Bash: (ls|pwd|cat|head|tail|less|grep|rg|find|echo|which|whoami|date|env|printenv|wc|file|stat|tree|du|df|ps|uname|hostname|open)\\b",
    ]
    static let builtinDangerPatterns = [
        "\\brm\\b",
        ":\\s*\\(\\s*\\)\\s*\\{",
        "\\b(mkfs|fdisk)\\b", "\\bdd\\s+if=", "\\bdiskutil\\s+(erase|partition|reformat)",
        "\\b(curl|wget)\\b[^|]*\\|\\s*(sudo\\s+)?(sh|bash|zsh|python3?)",
        ">\\s*/dev/(disk|rdisk|sd)", "\\bchmod\\s+-R\\s+0?777", "\\bsudo\\b",
        "\\bgit\\s+push\\b.*--force|\\bgit\\s+push\\b.*-f\\b",
        "\\bgit\\s+reset\\s+--hard\\b", "\\bgit\\s+clean\\b",
        "\\b(kill|killall|pkill)\\b",
        "\\bshutdown\\b|\\breboot\\b|\\bhalt\\b",
        "\\bssh-keygen\\b", "\\btruncate\\b",
        "\\blaunchctl\\s+(unload|remove|bootout)\\b",
        "\\bdocker\\s+(system\\s+)?prune\\b|\\bdocker\\s+rmi\\b",
        "\\b(pip3?|npm|yarn|pnpm|brew|gem|cargo)\\s+(install|add|i)\\b",
    ]
    static let builtinCompoundTokens = ["&&", "||", ";", "|", "`", "$(", ">", "<", "\n"]

    static func patterns() -> [String] {
        (UserDefaults.standard.array(forKey: key) as? [String]) ?? defaultPatterns
    }

    static func setPatterns(_ p: [String]) {
        UserDefaults.standard.set(p, forKey: key)
    }

    /// 用户亲手信任的整条命令（点“总是允许”写入），与正则白名单分开存。
    static func trustedCommands() -> [String] {
        (UserDefaults.standard.array(forKey: trustedKey) as? [String]) ?? []
    }

    static func setTrustedCommands(_ c: [String]) {
        UserDefaults.standard.set(c, forKey: trustedKey)
    }

    static func removeTrustedCommand(_ op: String) {
        setTrustedCommands(trustedCommands().filter { $0 != op })
    }

    static func isDangerous(_ op: String) -> Bool { matchesAny(op, dangerPatterns) }

    /// 命令里命中危险模式的片段位置（供卡片高亮标红）。返回合并后的字符范围。
    static func dangerRanges(in op: String) -> [Range<String.Index>] {
        let ns = NSRange(op.startIndex..., in: op)
        var ranges: [Range<String.Index>] = []
        for pat in dangerPatterns {
            guard let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) else { continue }
            re.enumerateMatches(in: op, range: ns) { m, _, _ in
                if let m, let r = Range(m.range, in: op) { ranges.append(r) }
            }
        }
        return ranges
    }

    static func isCompound(_ op: String) -> Bool { compoundTokens.contains { op.contains($0) } }

    /// 是否自动放行（不弹手势）。
    static func autoAllows(_ op: String) -> Bool {
        if isDangerous(op) { return false }                     // 1. 危险 → 硬否决
        if trustedCommands().contains(op) { return true }       // 2. 信任命令整条命中 → 放行
        let full = NSRange(op.startIndex..., in: op)
        var prefixHit = false
        for pat in patterns() {
            let p = pat.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty,
                  let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: op, range: full) else { continue }
            if m.range == full { return true }                  // 3. 锚定正则整条匹配 → 放行
            prefixHit = true                                    // 4. 前缀匹配 → 需过拼接闸
        }
        return prefixHit && !isCompound(op)
    }

    /// 把这条命令加入“信任命令”（卡片上点“总是允许”时调用），以后同样命令免审。
    static func addAlwaysAllow(_ op: String) {
        var cur = trustedCommands()
        guard !cur.contains(op) else { return }
        cur.append(op)
        setTrustedCommands(cur)
    }

    private static func matchesAny(_ op: String, _ pats: [String]) -> Bool {
        let range = NSRange(op.startIndex..., in: op)
        for pat in pats {
            if let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]),
               re.firstMatch(in: op, range: range) != nil {
                return true
            }
        }
        return false
    }
}
