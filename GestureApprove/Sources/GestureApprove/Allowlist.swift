import Foundation

/// 自动放行白名单：决定一条操作是“跳过手势直接放行”还是“弹卡片比手势”。从不自动拒绝。
///
/// 五层逻辑（借鉴 Claude 官方 permissions / defrex 的策略思路）：
///   1. 危险 deny-list 命中 → **硬否决**，永远要手势（即使被显式“总是允许”过，如 rm -rf）。
///   2. **信任命令**整条精确命中（用户点“总是允许”亲手写入的完整命令，单独存储）→ 放行。
///   3. 某条正则规则**整条精确匹配** → 放行（用户在设置里写的锚定正则）。
///   4. 正则规则**前缀匹配**（内置只读命令快捷）→ 仅当命令“整条安全”（无 && ; | 反引号 $( 等拼接）才放行。
///   5. **复合命令拆段**：`ls | head`、`cd x && grep y` 这类链式命令，引号感知地按拼接符拆开，
///      每一段都命中只读白名单且无写向文件的重定向 → 整条放行。真实工作流里只读命令几乎总带
///      管道/&&（实测占弹卡的 14%），此前一刀切弹卡或交给 LLM（约 1s 延迟且会误判）。
///      这是决定论判定：危险模式在第 1 层已整条检查（跨段也命中），命令替换（` 与 $( ）一律不判。
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
        "^Bash: (ls|pwd|cd|cat|head|tail|less|grep|rg|find|echo|which|whoami|date|env|printenv|wc|file|stat|tree|du|df|ps|uname|hostname|open)\\b",
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
        if prefixHit && !isCompound(op) { return true }
        return allowsCompoundReadOnly(op)                       // 5. 复合命令逐段白名单判定
    }

    // MARK: 复合命令拆段判定（第 5 层）

    /// 复合 Bash 命令：拆段后**每一段**都命中白名单且无写向文件的重定向 → 整条放行。
    /// 危险 deny-list 已在 autoAllows 第 1 层整条检查过（`ls && rm -rf` 的 rm 跨段也命中）。
    /// 保守边界（宁可不放行，交给 LLM/手势）：
    ///   - 含命令替换 ` 或 $( ：内容无法静态判定，不放行。
    ///   - 段内含 > 重定向：写文件，不放行；仅豁免丢弃/合并输出的 >/dev/null 与 2>&1 类。
    ///   - heredoc / for-while 等结构：拆出的段不匹配白名单，自然不放行。
    static func allowsCompoundReadOnly(_ op: String) -> Bool {
        guard op.hasPrefix("Bash: ") else { return false }
        let cmd = String(op.dropFirst("Bash: ".count))
        guard !cmd.contains("`"), !cmd.contains("$(") else { return false }
        let segments = splitShellSegments(cmd)
        guard segments.count > 1 else { return false }   // 单段命令走第 3/4 层，不重复判
        for seg in segments {
            // 豁免安全重定向：丢弃输出（>/dev/null、2>/dev/null）与 fd 合并（2>&1）；
            // 清理后仍含 > 即写文件 → 不放行。/dev/null 后加边界，堵住 >/dev/nullhijack、
            // >/dev/null/../real.txt 这类"以 /dev/null 开头却写真实文件"的绕过。
            var s = seg.replacingOccurrences(of: #"\d?>>?\s*/dev/null(?=[\s;|&]|$)"#, with: " ", options: .regularExpression)
            s = s.replacingOccurrences(of: #"\d?>&\d"#, with: " ", options: .regularExpression)
            guard !s.contains(">") else { return false }
            s = s.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { continue }
            guard matchesAny("Bash: " + s, patterns()) else { return false }
        }
        return true
    }

    /// 引号感知地按拼接符（&& || | ; & 换行）切分 shell 命令；引号内与反斜杠转义的分隔符不切。
    /// 连续分隔符产生的空段被过滤（&& 与 & 因此无需区分）。
    static func splitShellSegments(_ cmd: String) -> [String] {
        var parts: [String] = []
        var cur = ""
        var quote: Character? = nil
        var i = cmd.startIndex
        while i < cmd.endIndex {
            let c = cmd[i]
            if let q = quote {
                cur.append(c)
                if c == q {
                    quote = nil
                } else if c == "\\", q == "\"" {   // 双引号内转义：连同下一字符一起收下
                    let n = cmd.index(after: i)
                    if n < cmd.endIndex { cur.append(cmd[n]); i = n }
                }
            } else if c == "'" || c == "\"" {
                quote = c
                cur.append(c)
            } else if c == "\\" {                   // 引号外转义（如 \; ）：不作为分隔符
                cur.append(c)
                let n = cmd.index(after: i)
                if n < cmd.endIndex { cur.append(cmd[n]); i = n }
            } else if c == "&", cur.hasSuffix(">") {
                cur.append(c)   // fd 复制重定向（2>&1）：& 不是分隔符。&> 写文件的 > 会留在段里被拒，方向保守
            } else if c == "&" || c == "|" || c == ";" || c == "\n" {
                parts.append(cur)
                cur = ""
            } else {
                cur.append(c)
            }
            i = cmd.index(after: i)
        }
        parts.append(cur)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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
            // 跳过空/纯空白 pattern：空正则匹配一切。设置窗的白名单 TextEditor 每敲一键就落库，
            // 用户在末尾留个空行就会写入空串——若不过滤，第 5 层复合拆段判定会把任意命令段
            // 都判成"命中白名单"，整条自动放行，闸门失效。
            let p = pat.trimmingCharacters(in: .whitespaces)
            if !p.isEmpty,
               let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]),
               re.firstMatch(in: op, range: range) != nil {
                return true
            }
        }
        return false
    }
}
