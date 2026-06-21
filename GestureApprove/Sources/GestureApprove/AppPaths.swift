import Foundation

/// 资源/数据路径：让 release 下载的 .app **零仓库依赖**。
///   · 只读脚本/固件 → 打包进 .app 的 `Contents/Resources/`（签名、只读）；
///   · 可写产物（venv / 下载的模型 / esptool 环境）→ `~/Library/Application Support/GestureApprove/`。
/// 开发场景（从源码 `swift run`，bundle 里没打包资源）自动回退到仓库根目录。
enum AppPaths {
    /// bundle 内只读资源（build_app.sh 打包）；找不到则回退仓库根，便于源码开发。
    static func resource(_ rel: String) -> String {
        if let r = Bundle.main.resourcePath {
            let p = (r as NSString).appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return (HookInstaller.repoRoot() as NSString).appendingPathComponent(rel)
    }

    /// 可写数据根：~/Library/Application Support/GestureApprove。
    static var support: String {
        let base = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support")
        return (base as NSString).appendingPathComponent("GestureApprove")
    }

    static func supportPath(_ rel: String) -> String {
        (support as NSString).appendingPathComponent(rel)
    }
}
