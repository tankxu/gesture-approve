import Foundation

/// 简单文件日志，便于在 GUI app 里可靠取诊断（统一日志对 ad-hoc 包不稳定）。
/// 输出到 /tmp/gestureapprove.log，超过 10 MB 轮转到 .1（曾经出过 13 GB 的事故，上限必须有）。
enum GALog {
    static let path = "/tmp/gestureapprove.log"
    private static let maxBytes: UInt64 = 10 * 1024 * 1024

    private static let queue = DispatchQueue(label: "com.tankxu.gestureapprove.log")
    private static var handle: FileHandle?
    private static var written: UInt64 = 0   // 当前文件大小（打开时初始化，之后累加）

    static func log(_ s: String) {
        let line = "\(Date()) \(s)\n"
        // sync：保证短命 CLI 路径（--usage 等）退出前落盘；日志频率低，同步无感。
        queue.sync {
            guard let data = line.data(using: .utf8) else { return }
            if handle == nil { open() }
            if written + UInt64(data.count) > maxBytes { rotate() }
            guard let h = handle else { return }
            h.write(data)
            written += UInt64(data.count)
        }
    }

    private static func open() {
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let h = FileHandle(forWritingAtPath: path) else { return }
        written = h.seekToEndOfFile()
        handle = h
    }

    private static func rotate() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(atPath: path + ".1")
        try? FileManager.default.moveItem(atPath: path, toPath: path + ".1")
        open()
    }
}
