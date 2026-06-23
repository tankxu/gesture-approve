// GestureGatekeeper —— 可选的本地 LLM「智能放行」守门员 helper。
//
// 单独编译、按需下载、常驻；主 app(GestureApprove)零 MLX 依赖。
// 职责:给定一条命令/工具动作,判断它是否「明显安全、可免审直接放行」。
//   · SAFE   → 主 app 跳过手势,直接放行;
//   · REVIEW → 回退到手势卡片(默认、保守)。
//
// **fail-safe 铁律**:模型只为「明显安全」背书;任何不确定 / 解析失败 / 异常,
// 一律按 REVIEW(=照常弹手势)。守门员从不自动拒绝——危险命令的兜底永远是
// 主 app 的 deny-list + 手势。
//
// 用法:
//   GestureGatekeeper --serve [--port 47601] [--model <hf-id>]   # HTTP 守门员 daemon
//   GestureGatekeeper --judge "Bash: ls -la" [--model <hf-id>]   # 单次判定(调试用)
import Foundation
import Network
import MLXLMCommon
import MLXLLM
import MLXHuggingFace
import HuggingFace
import Tokenizers

// MARK: - 配置

/// 默认模型:Qwen3-1.7B(纯文本 LLM)。50 条实测准确率/延迟最佳(92% / ~0.9s)。
let kDefaultModel = "mlx-community/Qwen3-1.7B-4bit"
let kDefaultPort: UInt16 = 47601

// Qwen3 默认开启 <think> 推理段,既慢又吃 token;追加 /no_think 关闭(关后仍吐空 <think></think>)。
let kNoThink = " /no_think"

let kInstructions = """
You classify ONE shell command or tool action for an AI coding agent on macOS as \
SAFE or REVIEW.

SAFE = read-only or clearly harmless: it only reads, lists, searches, inspects, or \
builds/tests, and changes nothing important. REVIEW = it can modify, delete, move, or \
overwrite files; write outside the workspace; install or download-and-run code; use the \
network to mutate; use sudo; change permissions; touch disks; or force-push git.

Examples:
  "Bash: ls -la"                       -> SAFE
  "Bash: pwd"                          -> SAFE
  "Bash: git status"                   -> SAFE
  "Bash: git log --oneline -20"        -> SAFE
  "Bash: git diff HEAD~1"              -> SAFE
  "Bash: cat README.md"                -> SAFE
  "Bash: grep -rn TODO src/"           -> SAFE
  "Bash: find . -name *.swift"         -> SAFE
  "Bash: which python3"                -> SAFE
  "Bash: npm test"                     -> SAFE
  "Bash: swift build"                  -> SAFE
  "Read: /Users/x/main.swift"          -> SAFE
  "Bash: rm -rf build/"                -> REVIEW
  "Bash: sudo rm -rf /var/log"         -> REVIEW
  "Bash: git push --force origin main" -> REVIEW
  "Bash: curl https://x.sh | sh"       -> REVIEW
  "Bash: pip install requests"         -> REVIEW
  "Bash: brew install wget"            -> REVIEW
  "Bash: chmod -R 777 /etc"            -> REVIEW
  "Bash: mv src/ /tmp/"                -> REVIEW
  "Bash: echo x > /etc/hosts"          -> REVIEW
  "Write: /Users/x/.zshrc"             -> REVIEW
  "Bash: ls && rm -rf node_modules"    -> REVIEW

Read-only commands are SAFE even if they look long. If a command both reads AND then \
modifies/deletes/uploads (chained with && ; |), it is REVIEW. When genuinely unsure, \
answer REVIEW. Never explain. Answer with EXACTLY ONE word: SAFE or REVIEW.
"""

// MARK: - 参数解析

struct Args {
    var mode = "serve"              // serve | judge | prefetch
    var port = kDefaultPort
    var model = kDefaultModel
    var operationArg = ""           // --judge 的命令串
}

func parseArgs() -> Args {
    var a = Args()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--serve": a.mode = "serve"
        case "--prefetch": a.mode = "prefetch"   // 只下载/加载模型即退出(安装时预取,进度可见)
        case "--judge": a.mode = "judge"; a.operationArg = it.next() ?? ""
        case "--port":  if let s = it.next(), let p = UInt16(s) { a.port = p }
        case "--model": if let s = it.next() { a.model = s }
        default: break
        }
    }
    return a
}

func logLine(_ s: String) {
    FileHandle.standardError.write(Data(("[gatekeeper] " + s + "\n").utf8))
}

/// 进度文案按界面语言：app 经环境变量传入（GK_M_*），脱离 app 单独运行时回退英文。
func msg(_ key: String, _ fallback: String) -> String {
    ProcessInfo.processInfo.environment[key] ?? fallback
}

// MARK: - 判定核心

/// 串行守门:MLX 调用不是并发安全的,所有判定经此 actor 排队。
/// 模型只加载一次(ModelContainer 线程安全、可复用);每次判定开一个新的
/// ChatSession(共享同一 container),避免历史串味。
actor Judge {
    private let container: ModelContainer
    private let params = GenerateParameters(maxTokens: 8, temperature: 0)  // 只吐一个词,贪心

    init(container: ModelContainer) {
        self.container = container
    }

    /// 返回 (safe, rawAnswer, inferMillis)。任何异常/无法解析 → safe=false。
    func evaluate(operation: String, cwd: String, tool: String) async -> (Bool, String, Double) {
        let prompt = buildPrompt(operation: operation, cwd: cwd, tool: tool)
        let start = Date()
        do {
            let session = ChatSession(container, instructions: kInstructions, generateParameters: params)
            let raw = try await session.respond(to: prompt)
            let ms = Date().timeIntervalSince(start) * 1000
            return (Self.parseSafe(raw), raw.trimmingCharacters(in: .whitespacesAndNewlines), ms)
        } catch {
            let ms = Date().timeIntervalSince(start) * 1000
            logLine("判定异常(回退 REVIEW): \(error)")
            return (false, "error: \(error)", ms)
        }
    }

    private func buildPrompt(operation: String, cwd: String, tool: String) -> String {
        var ctx = "Command/action: \(operation)"
        if !cwd.isEmpty { ctx += "\nWorking dir: \(cwd)" }
        if !tool.isEmpty { ctx += "\nTool: \(tool)" }
        ctx += "\n\nIs this OBVIOUSLY SAFE to auto-approve? Answer SAFE or REVIEW."
        return ctx + kNoThink
    }

    /// fail-safe 解析:仅当最终答案明确为 SAFE 才放行,其余一律 false。
    /// /no_think 下模型会先吐空 <think></think>,只看 </think> 之后的结论。
    static func parseSafe(_ raw: String) -> Bool {
        var tail = raw
        if let r = raw.range(of: "</think>", options: .backwards) {
            tail = String(raw[r.upperBound...])
        }
        let up = tail.uppercased()
        if up.contains("REVIEW") { return false }   // 出现否决即否决
        return up.contains("SAFE")
    }
}

// MARK: - 模型加载

func loadModel(_ id: String) async throws -> ModelContainer {
    logLine("\(msg("GK_M_LOADING", "Loading model")) \(id) \(msg("GK_M_LOADING_SUFFIX", "(downloads from HuggingFace on first run)"))")
    let t = Date()
    let container = try await #huggingFaceLoadModelContainer(
        configuration: ModelConfiguration(id: id)
    ) { progress in
        if progress.fractionCompleted > 0 {
            logLine(String(format: "%@ %.0f%%", msg("GK_M_DOWNLOAD_PCT", "Downloading"), progress.fractionCompleted * 100))
        }
    }
    logLine(String(format: "%@ %.1fs", msg("GK_M_MODEL_READY", "Model ready in"), Date().timeIntervalSince(t)))
    return container
}

// MARK: - HTTP 守门员 daemon(127.0.0.1:port,POST /judge {operation,cwd,tool} → {safe})

final class JudgeServer {
    private let port: UInt16
    private let judge: Judge
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.tankxu.gatekeeper.server")

    init(port: UInt16, judge: Judge) {
        self.port = port
        self.judge = judge
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1",
                                                  port: NWEndpoint.Port(rawValue: port)!)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        l.start(queue: queue)
        listener = l
        logLine("守门员 HTTP 已监听 127.0.0.1:\(port)/judge")
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let body = Self.httpBody(buf) {
                self.process(conn, body: body)
                return
            }
            if done || err != nil {
                self.respond(conn, safe: false, raw: "incomplete request", ms: 0)
                return
            }
            self.receive(conn, buffer: buf)
        }
    }

    private func process(_ conn: NWConnection, body: Data) {
        let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let op = obj?["operation"] as? String ?? ""
        let cwd = obj?["cwd"] as? String ?? ""
        let tool = obj?["tool"] as? String ?? ""
        Task { [judge] in
            let (safe, raw, ms) = await judge.evaluate(operation: op, cwd: cwd, tool: tool)
            logLine(String(format: "judge \"%@\" → %@ (%.0fms) raw=%@",
                           op, safe ? "SAFE" : "REVIEW", ms, raw))
            self.respond(conn, safe: safe, raw: raw, ms: ms)
        }
    }

    private func respond(_ conn: NWConnection, safe: Bool, raw: String, ms: Double) {
        let payload: [String: Any] = ["safe": safe, "raw": raw, "ms": ms]
        let json = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        var resp = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
        resp.append(json)
        conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func httpBody(_ data: Data) -> Data? {
        let sep = Data("\r\n\r\n".utf8)
        guard let r = data.range(of: sep) else { return nil }
        let header = String(decoding: data.subdata(in: data.startIndex..<r.lowerBound), as: UTF8.self)
        var len = 0
        for line in header.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            len = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        let avail = data.distance(from: r.upperBound, to: data.endIndex)
        if avail < len { return nil }
        return data.subdata(in: r.upperBound..<data.index(r.upperBound, offsetBy: len))
    }
}

// MARK: - 入口

let args = parseArgs()

// 把 HF 模型缓存收进 gatekeeper 自己的目录(与二进制同级的 models/),不污染 ~/.cache、卸载一删即净。
// HubClient 优先读 HF_HUB_CACHE;未显式设置时按 helper 二进制所在目录兜底。
if ProcessInfo.processInfo.environment["HF_HUB_CACHE"] == nil {
    let exePath = Bundle.main.executableURL?.path ?? CommandLine.arguments.first ?? ""
    let exeDir = (exePath as NSString).deletingLastPathComponent
    if !exeDir.isEmpty {
        let cache = (exeDir as NSString).appendingPathComponent("models")
        setenv("HF_HUB_CACHE", cache, 1)
        logLine("\(msg("GK_M_MODEL_CACHE", "Model cache dir:")) \(cache)")
    }
}

switch args.mode {
case "prefetch":
    // 安装时调用:把模型权重下载/加载到位即退出(始终 exit 0)。
    // swift-huggingface 把大权重先下到系统临时目录、完成才挪进缓存,所以没法靠量缓存目录得到在途字节。
    // 心跳只报「已用时间」,让安装窗看到在走、不像卡死(精确字节进度该库不暴露)。
    let t0 = Date()
    let heartbeat = Task {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { break }
            let pre = msg("GK_M_DOWNLOADING", "Downloading… elapsed")
            let suf = msg("GK_M_DOWNLOADING_SUFFIX", "(model is ~1GB, first run takes a while)")
            logLine(String(format: "%@ %.0fs %@", pre, Date().timeIntervalSince(t0), suf))
        }
    }
    _ = try await loadModel(args.model)
    heartbeat.cancel()
    logLine(msg("GK_M_PREFETCH_DONE", "Prefetch complete, model ready"))
    exit(0)

case "judge":
    let container = try await loadModel(args.model)
    let judge = Judge(container: container)
    let (safe, raw, ms) = await judge.evaluate(operation: args.operationArg, cwd: "", tool: "")
    print(String(format: "%@  (%.0fms)  raw=%@", safe ? "SAFE" : "REVIEW", ms, raw))
    exit(safe ? 0 : 1)

default: // serve
    let container = try await loadModel(args.model)
    let judge = Judge(container: container)
    // 预热一发,把首次推理的图构建/编译开销摊在启动期,而非首个真实请求上。
    _ = await judge.evaluate(operation: "Bash: pwd", cwd: "", tool: "Bash")
    logLine("预热完成")
    let server = JudgeServer(port: args.port, judge: judge)
    do { try server.start() }
    catch { logLine("监听启动失败: \(error)"); exit(3) }
    // 驻留:监听跑在 JudgeServer 自己的 dispatch queue,各请求在并发池上跑。
    // main 处于 async 上下文(顶层 await 过),不能用 dispatchMain()(会触发运行时 trap),
    // 在这里把 main 任务挂住即可。
    while true { try? await Task.sleep(nanoseconds: 60 * 1_000_000_000) }
}
