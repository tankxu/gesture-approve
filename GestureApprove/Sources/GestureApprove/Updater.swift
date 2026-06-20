import Foundation

/// 通过 GitHub Releases API 检查新版本。无需自建服务：直接读公开仓库的 latest release。
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
        case updateAvailable(version: String, url: URL)
        case failed(String)
    }

    static func check(completion: @escaping (Outcome) -> Void) {
        var req = URLRequest(url: latestAPI)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 12
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let done: (Outcome) -> Void = { o in DispatchQueue.main.async { completion(o) } }
            if let err { done(.failed(err.localizedDescription)); return }
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else {
                done(.failed("no release data")); return
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let url = (obj["html_url"] as? String).flatMap(URL.init) ?? releasesPage
            done(isNewer(latest, than: current) ? .updateAvailable(version: latest, url: url) : .upToDate)
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
}
