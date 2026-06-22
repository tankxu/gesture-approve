import Foundation

/// 加载仓库里的审批规则配置 `config/gatekeeper-rules.json`（deny-list / 默认白名单 / 拼接符的单一来源）。
///
/// 路径解析复用 `AppPaths.resource`：发布版读 bundle 内 `Contents/Resources/config/`，
/// 开发期（从源码运行）回退仓库根 `config/`，所以改了文件开发期即时生效。
///
/// 任何一组缺失/为空/解析失败都返回 nil，调用方（`Allowlist`）回退到内置默认——
/// 确保 deny-list 永不因配置问题变空（安全兜底）。
struct RulesConfig {
    static let shared = RulesConfig()

    let dangerPatterns: [String]?
    let autoAllowPatterns: [String]?
    let compoundTokens: [String]?

    private struct File: Decodable {
        struct Rule: Decodable { let pattern: String }
        let dangerPatterns: [Rule]?
        let autoAllowPatterns: [Rule]?
        let compoundTokens: [String]?
    }

    init() {
        let path = AppPaths.resource("config/gatekeeper-rules.json")
        guard let data = FileManager.default.contents(atPath: path),
              let f = try? JSONDecoder().decode(File.self, from: data) else {
            GALog.log("规则配置未加载，使用内置默认: \(path)")
            dangerPatterns = nil; autoAllowPatterns = nil; compoundTokens = nil
            return
        }
        // 空数组按「未提供」处理 → 回退内置默认（绝不让 deny-list 变空）。
        func nonEmpty(_ a: [String]?) -> [String]? { (a?.isEmpty ?? true) ? nil : a }
        dangerPatterns = nonEmpty(f.dangerPatterns?.map(\.pattern))
        autoAllowPatterns = nonEmpty(f.autoAllowPatterns?.map(\.pattern))
        compoundTokens = nonEmpty(f.compoundTokens)
        GALog.log("规则配置已加载: danger=\(dangerPatterns?.count ?? 0) "
            + "allow=\(autoAllowPatterns?.count ?? 0) compound=\(compoundTokens?.count ?? 0) @ \(path)")
    }
}
