import Foundation
import SQLite3
import CryptoKit
import Darwin

typealias MObject = [String: Any]

enum MonitorIO {
    static var home: String { ProcessInfo.processInfo.environment["GA_MONITOR_HOME"] ?? NSHomeDirectory() }
    static var root: String { ProcessInfo.processInfo.environment["GA_MONITOR_DIR"] ?? home + "/Library/Application Support/GestureApprove/monitor" }
    static var claude: String { ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? home + "/.claude" }
    static var codex: String { ProcessInfo.processInfo.environment["CODEX_HOME"] ?? home + "/.codex" }
    static func json(_ value: Any) -> String { String(data: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8), encoding: .utf8) ?? "{}" }
    static func object(_ text: String) -> MObject { (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? MObject ?? [:] }
    static func read(_ path: String) -> MObject { guard let d = FileManager.default.contents(atPath: path) else { return [:] }; return (try? JSONSerialization.jsonObject(with: d)) as? MObject ?? [:] }
    static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func atomic(_ value: Any, _ path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(json(value).utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
    static func number(_ x: Any?) -> Double { (x as? NSNumber)?.doubleValue ?? Double(x as? String ?? "") ?? 0 }
    private static let fractionalISO: ISO8601DateFormatter = { let f=ISO8601DateFormatter();f.formatOptions=[.withInternetDateTime,.withFractionalSeconds];return f }()
    private static let plainISO = ISO8601DateFormatter()
    static func stamp(_ x: Any?) -> Double {
        if let s = x as? String {
            if let d = fractionalISO.date(from: s) { return d.timeIntervalSince1970 }
            return plainISO.date(from:s)?.timeIntervalSince1970 ?? number(x)
        }
        let n = number(x); return n > 1e11 ? n / 1000 : n
    }
    static func alive(_ pid: Int) -> Bool { pid > 1 && (kill(Int32(pid), 0) == 0 || errno == EPERM) }
    static func executable(_ name: String) -> String? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        return paths.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    /// File-backed output avoids pipe deadlocks. A timeout never leaves a probing child behind.
    static func run(_ executable: String, _ args: [String], timeout: Double = 5, env: [String: String]? = nil, cwd: String? = nil) -> (Int32, Data) {
        let path = NSTemporaryDirectory() + "ga-probe-" + UUID().uuidString
        FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let out = FileHandle(forWritingAtPath: path) else { return (-1, Data()) }
        defer { try? out.close() }
        let p = Process(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = args
        p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        p.environment = env; if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let sem = DispatchSemaphore(value: 0); p.terminationHandler = { _ in sem.signal() }
        do { try p.run() } catch { return (-1, Data()) }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate(); if sem.wait(timeout: .now() + 0.3) == .timedOut { kill(p.processIdentifier, SIGKILL); _ = sem.wait(timeout: .now() + 1) }
            return (-2, Data())
        }
        return (p.terminationStatus, (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data())
    }
    static func birth(_ pid: Int) -> String {
        guard alive(pid) else { return "" }
        // Claude registry uses LC_ALL=C TZ=UTC, independent of the host locale.
        let (_, d) = run("/bin/ps", ["-p", String(pid), "-o", "lstart="], timeout: 1, env: ["LC_ALL":"C", "TZ":"UTC"])
        return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    static func providerParent() -> (Int, String) {
        var pid = Int(getppid())
        for _ in 0..<6 {
            let (_, d) = run("/bin/ps", ["-p", String(pid), "-o", "ppid=", "-o", "comm="], timeout: 1)
            let s = String(data: d, encoding: .utf8) ?? ""
            let parts = s.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2 else { break }
            let path = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            let base = (path as NSString).lastPathComponent.lowercased()
            if base == "claude" || base == "codex" || path.contains("/claude/versions/") { return (pid, path) }
            pid = Int(parts[0]) ?? 0; if pid <= 1 { break }
        }
        return (0, "")
    }
}

/// All access is serialized by LocalMonitor.queue; independent hook processes only write spool files.
final class MonitorDB {
    var handle: OpaquePointer?
    init(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw NSError(domain: "MonitorDB", code: 1) }
        sqlite3_busy_timeout(handle, 5000)
        execute("PRAGMA journal_mode=WAL"); execute("PRAGMA synchronous=NORMAL")
        execute("CREATE TABLE IF NOT EXISTS kv (kind TEXT, id TEXT, body TEXT NOT NULL, PRIMARY KEY(kind,id))")
        execute("CREATE TABLE IF NOT EXISTS events (seq INTEGER PRIMARY KEY AUTOINCREMENT, uid TEXT UNIQUE, at REAL, body TEXT)")
        execute("CREATE TABLE IF NOT EXISTS usage (id TEXT PRIMARY KEY, session TEXT, provider TEXT, model TEXT, at REAL, tokens INTEGER, body TEXT)")
        execute("CREATE INDEX IF NOT EXISTS usage_at ON usage(at)"); execute("CREATE INDEX IF NOT EXISTS usage_session ON usage(session)")
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
    deinit { sqlite3_close(handle) }
    @discardableResult func execute(_ sql: String, _ args: [Any] = []) -> Bool {
        guard let s = prepare(sql, args) else { return false }; defer { sqlite3_finalize(s) }; return sqlite3_step(s) == SQLITE_DONE
    }
    func rows(_ sql: String, _ args: [Any] = []) -> [MObject] {
        guard let s = prepare(sql, args) else { return [] }; defer { sqlite3_finalize(s) }
        var result: [MObject] = []
        while sqlite3_step(s) == SQLITE_ROW {
            var row: MObject = [:]
            for i in 0..<sqlite3_column_count(s) {
                let key = String(cString: sqlite3_column_name(s, i))
                switch sqlite3_column_type(s, i) {
                case SQLITE_INTEGER: row[key] = sqlite3_column_int64(s, i)
                case SQLITE_FLOAT: row[key] = sqlite3_column_double(s, i)
                case SQLITE_TEXT: row[key] = String(cString: sqlite3_column_text(s, i))
                default: break
                }
            }
            result.append(row)
        }
        return result
    }
    private func prepare(_ sql: String, _ args: [Any]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return nil }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, x) in args.enumerated() {
            let n = Int32(i + 1)
            if let v = x as? String { sqlite3_bind_text(s, n, v, -1, transient) }
            else if let v = x as? NSNumber { sqlite3_bind_double(s, n, v.doubleValue) }
            else { sqlite3_bind_null(s, n) }
        }
        return s
    }
    func get(_ kind: String, _ id: String) -> MObject { MonitorIO.object(rows("SELECT body FROM kv WHERE kind=? AND id=?", [kind,id]).first?["body"] as? String ?? "") }
    @discardableResult func put(_ kind: String, _ id: String, _ value: MObject) -> Bool { execute("INSERT INTO kv VALUES(?,?,?) ON CONFLICT(kind,id) DO UPDATE SET body=excluded.body", [kind,id,MonitorIO.json(value)]) }
    func all(_ kind: String) -> [MObject] { rows("SELECT body FROM kv WHERE kind=?", [kind]).map { MonitorIO.object($0["body"] as? String ?? "") } }
    func event(_ body: MObject, uid: String = UUID().uuidString) { execute("INSERT OR IGNORE INTO events(uid,at,body) VALUES(?,?,?)", [uid, Date().timeIntervalSince1970, MonitorIO.json(body)]) }
}
