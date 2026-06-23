import Foundation
import AppKit

/// 通过 GitHub Releases API 检查新版本，并能 app 内自更新（下载→替换→重启）。
/// 无需自建服务：直接读公开仓库的 latest release。
enum Updater {
    static let repo = "tankxu/gesture-approve"
    static var latestAPI: URL { URL(string: "https://api.github.com/repos/\(repo)/releases/latest")! }
    static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases/latest")! }

    /// 当前版本（Info.plist 的 CFBundleShortVersionString，如 "0.3.3"）。
    static var current: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }

    enum Outcome {
        case upToDate
        /// asset = 新版 .zip 直链（app 自更新；可能为 nil）；page = release 页（回退）；notes = release 正文（changelog）。
        case updateAvailable(version: String, asset: URL?, page: URL, notes: String)
        case failed(String)
    }

    static func check(completion: @escaping (Outcome) -> Void) {
        var req = URLRequest(url: latestAPI)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 12
        URLSession.shared.dataTask(with: req) { data, _, err in
            let done: (Outcome) -> Void = { o in DispatchQueue.main.async { completion(o) } }
            if let err { done(.failed(err.localizedDescription)); return }
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else {
                done(.failed("no release data")); return
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let page = (obj["html_url"] as? String).flatMap(URL.init) ?? releasesPage
            // 取 .zip 资产直链（app 自更新用；找不到则回退到打开 release 页）
            let assets = obj["assets"] as? [[String: Any]] ?? []
            let asset = assets.compactMap { $0["browser_download_url"] as? String }
                .first { $0.hasSuffix(".zip") }
                .flatMap(URL.init)
            let notes = (obj["body"] as? String) ?? ""        // release 正文 = changelog
            done(isNewer(latest, than: current)
                 ? .updateAvailable(version: latest, asset: asset, page: page, notes: notes)
                 : .upToDate)
        }.resume()
    }

    /// 语义版本比较：a 是否比 b 新（按 . 分段逐位比数字）。
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - 自更新：下载 zip → 解压 → 清隔离 → 替换当前 .app → 重启

    /// 为什么能免 Gatekeeper 拦：app 自己用 URLSession 下载的 zip 不带 `com.apple.quarantine`
    /// （隔离属性是 LaunchServices 给浏览器等下载打的），解压出的 .app 也不带；再主动 `xattr -dr`
    /// 清一遍。未公证的新版本只要不带隔离属性，首次打开就不会被拦——首装那一份之后全程免 approve。
    /// status 回调报阶段文案，failure 回调报错（均在主线程）；成功则替换后重启、不返回。
    static func installUpdate(from asset: URL,
                             status: @escaping (String) -> Void,
                             failure: @escaping (String) -> Void) {
        let task = URLSession.shared.downloadTask(with: asset) { tmp, resp, err in
            if let err { DispatchQueue.main.async { failure(err.localizedDescription) }; return }
            guard let tmp, let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                DispatchQueue.main.async { failure("download failed") }; return
            }
            do {
                try performSwap(downloadedZip: tmp, status: status)
            } catch {
                DispatchQueue.main.async { failure(error.localizedDescription) }
            }
        }
        task.resume()
    }

    private static func performSwap(downloadedZip: URL, status: @escaping (String) -> Void) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("ga-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent("update.zip")
        try fm.moveItem(at: downloadedZip, to: zip)

        DispatchQueue.main.async { status(L("settings.update.installing")) }

        // 解压（zip 根目录直接是 GestureApprove.app —— 与 release 打包方式一致）
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, work.path]
        try ditto.run(); ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw err("unzip failed") }

        // 磁盘文件名仍是 GestureApprove.app（显示名 "Gesture Approve" 只是 CFBundleDisplayName）
        let newApp = work.appendingPathComponent("GestureApprove.app")
        guard fm.fileExists(atPath: newApp.path) else { throw err("app not found in archive") }

        let dest = Bundle.main.bundleURL                       // 当前运行的 .app（通常 /Applications/...）
        let pid = ProcessInfo.processInfo.processIdentifier
        // detached 脚本：等本进程退出 → 替换 → 清隔离 → 重启 → 清理临时目录
        let script = work.appendingPathComponent("swap.sh")
        let body = """
        #!/bin/bash
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.3; done
        /bin/rm -rf "\(dest.path)"
        /usr/bin/ditto "\(newApp.path)" "\(dest.path)"
        /usr/bin/xattr -dr com.apple.quarantine "\(dest.path)" 2>/dev/null || true
        /usr/bin/open "\(dest.path)"
        /bin/rm -rf "\(work.path)"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/bash")
        swap.arguments = [script.path]
        try swap.run()                                         // detached：不等它

        DispatchQueue.main.async { NSApp.terminate(nil) }      // 退出本进程，脚本随即替换+重启
    }

    private static func err(_ m: String) -> NSError {
        NSError(domain: "Updater", code: 1, userInfo: [NSLocalizedDescriptionKey: m])
    }
}
