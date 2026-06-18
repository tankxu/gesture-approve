import Foundation

/// 简单文件日志，便于在 GUI app 里可靠取诊断（统一日志对 ad-hoc 包不稳定）。
/// 输出到 /tmp/gestureapprove.log。
enum GALog {
    static let path = "/tmp/gestureapprove.log"

    static func log(_ s: String) {
        let line = "\(Date()) \(s)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
