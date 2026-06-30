# GestureApprove 运行机制总览

> 改任何一块(进程、端口、后台 daemon、保活、睡眠唤醒、审批通路)之前先读这份。
> 这里讲"**整体怎么跑起来、为什么这么设计**";细分专题见 [camera-resilience.md](./camera-resilience.md)(摄像头看门狗/唤醒)。
> 代码里只有"怎么做",设计意图在这两份文档。

---

## 0. 一句话

它是一个**菜单栏常驻 app**,给 AI 编码工具(Claude Code / Codex / Gemini / Kimi)做"执行命令前的手势审批":AI 要跑命令 → hook 拦下来问 app → app 按层判定(白名单/本地 LLM/手势)→ 把 allow/deny/ask 还给 AI。一切本地、离线、fail-safe(任何故障都交回终端,绝不乱放行也绝不硬卡)。

---

## 1. 进程与端口全景

同时最多有 4 类进程,**主 app 是唯一长驻核心,其余都可选且各自解耦**:

| 进程 | 角色 | 起停 | 通信 |
|---|---|---|---|
| **GestureApprove**(主 app) | 菜单栏 app(`.accessory`,无 Dock 图标),持有审批服务、识别引擎、摄像头、UI | launchd 登录自启 + KeepAlive 保活 | 监听 **127.0.0.1:47600** |
| **GestureApprove --hook <target>** | 同一个二进制兼做 hook,每次 AI 调工具时被 AI 拉起、跑完即退 | AI 工具按需 spawn(短命) | POST 到 47600,阻塞等结果 |
| **GestureGatekeeper --serve**(守门员 helper) | 可选的本地 LLM(Qwen3-1.7B-4bit / MLX),判命令"是否明显安全免审" | `Gatekeeper.startIfNeeded()` 按需起,常驻 | 监听 **127.0.0.1:47601** |
| **python gesture_daemon.py**(MediaPipe) | 可选的识别引擎 daemon,比内置 Vision 更准 | `MediaPipeClassifier.start()` 按需起,常驻 | stdin/stdout 二进制管道(非 socket) |

**端口约定**:`47600`=审批服务(hook↔app),`47601`=守门员(app↔LLM)。都是 `127.0.0.1`(纯本地,不监听外网)。审批端口可用环境变量 `GESTURE_APPROVE_PORT` 覆盖。

**关键解耦点**:
- hook 是**主 app 二进制自己**(`--hook` 模式),不是单独脚本 → 零 Python 依赖、版本永远和 app 一致。
- 主 app **零 MLX 依赖**;LLM 推理全在单独的 `GestureGatekeeper` 里 → app 包很小(~1.8MB),不装 LLM 也能用。
- MediaPipe 跑在独立 Python 进程 → 崩了不拖垮主 app,且能用系统 Python 生态。

---

## 2. 落盘位置

只读资源打进 `.app` bundle;可写产物落到 `~/Library/Application Support/GestureApprove/`(`AppPaths.supportPath`):

- `gatekeeper/` — 守门员 helper:`GestureGatekeeper` 二进制 + `mlx-swift_Cmlx.bundle`(含 Metal `.metallib`)+ `models/`(模型权重,`HF_HUB_CACHE` 指到这)。卸载删此目录即净。
- `mediapipe/` — `.venv/`(Python 虚拟环境)+ `models/gesture_recognizer.task`(~300MB)。
- `~/Library/LaunchAgents/com.tankxu.gestureapprove.login.plist` — 登录自启的 LaunchAgent。
- `/tmp/gestureapprove.log` — 运行日志(`GALog`,排障第一站)。
- 配置:Claude `~/.claude/settings.json`、Codex `~/.codex/config.toml`、Gemini `~/.gemini/settings.json`、Kimi `~/.kimi/config.toml`(hook 注入,改前备份)。

`AppPaths.resource()` 读资源时 **bundle 优先、回退仓库根** → 源码开发时改 `config/` 即时生效,发版时用 bundle 内的。

---

## 3. 保活与自愈策略总表 ⭐

这是全局最重要的一张表——**每个会"静默失效"的东西都配了一个自愈手段**。设计原则:宁可多做一次无害的重启/重建,也不能让某个组件悄悄死掉、用户却以为它在工作。

| 组件 | 怎么会失效 | 自愈手段 | 代码 |
|---|---|---|---|
| **主 app 进程** | 崩溃 / 被杀 | launchd `KeepAlive={SuccessfulExit:false}` 仅异常退出时拉起;正常"退出"不重启 | `LaunchAtLogin.swift` |
| **多实例冲突** | 升级/手动重复启动 → 双图标、抢端口 | 启动时杀掉所有同 bundleID 的旧实例,新实例(launchd 管的那个)胜出 | `main.swift` `applicationDidFinishLaunching` |
| **审批服务 NWListener** | 睡眠后 socket 静默 `.failed`,端口悄悄死 → hook 连不上、approve 不再走 app | ①`stateUpdateHandler` 检测到 `.failed` 自动 `scheduleRestart`(退避重试);②唤醒/解锁时主动 `server.restart()` | `ApprovalServer.swift` `restart()` |
| **摄像头 capture session** | USB 采集卡打嗝 / 睡眠挂起 → `isRunning` 仍 true 却不吐帧;唤醒后设备没枚举完被误判 → 开错摄像头 | ①始终用 `savedOrDefaultID()` 选定设备、严格不 fallback;②审批期看门狗:设备未枚举则重试、已配置无帧按首帧宽限(3s)/`staleThreshold`(1.5s)重建;③唤醒懒重建;④runtime error/中断结束触发(唤醒后首次 ~2s 是 USB 物理启动,有意不消除) | `FrameSource.swift`,详见 [camera-resilience.md](./camera-resilience.md) |
| **守门员 daemon** | 崩溃 / 上次没收干净留残留 | 无主动心跳;靠①每次 `startIfNeeded` 前 `pkill` 清残留;②不可用时 `judge()` 返回 false → 落手势(fail-safe 兜底) | `Gatekeeper.swift` `killStrayDaemons` |
| **ESP32 串口源** | 设备欠压 / USB 抖动 → 连续抓帧失败 | 读取线程常驻,连续失败 3 次触发**限频复位**(两次复位至少隔 8s,避免频繁重启把 ESP32 搞掉电) | `FrameSource.swift` `ESP32FrameSource.maybeReset` |
| **锁屏状态判断** | 长睡眠/Power Nap 后"解锁"通知可能丢失 → 缓存标志永卡锁定态(过夜唤醒 bug) | `screenLocked` **不缓存**,每次审批实时查 `CGSessionCopyCurrentDictionary` | `main.swift` `screenLocked` |

> 记一条经验:**这套软件里凡是"复用的长生命周期资源"(socket / capture session / daemon / 串口)都假设它会静默失效**,所以都配了"检测→重建"或"主动复位"。新增这类资源时照这个模式做。

---

## 4. 睡眠 / 锁屏 / 唤醒 统一策略 ⭐

监听 4 个事件(`observeSystemState`),`NSWorkspace` 出睡眠、`DistributedNotificationCenter` 私有名出锁屏:

| 事件 | 动作 |
|---|---|
| `willSleep` | `asleep = true` |
| `didWake` | `asleep = false`;`server.restart()`(复活监听);`handleSystemWake()`(摄像头懒重建、对齐选定设备,不亮灯) |
| `screenIsLocked` | 无动作(锁屏状态靠 `screenLocked` 实时查,不缓存) |
| `screenIsUnlocked` | `server.restart()`;`handleSystemWake()` |

**两个状态**:`asleep`(靠 willSleep/didWake 维护,didWake 必达可靠)、`screenLocked`(实时查 CGSession)。合成 `systemSuspended = screenLocked || asleep`。

**审批闸**:`systemSuspended` 为真时,审批服务直接 `reply("ask")` 回退终端——锁屏/睡眠时用户没法比手势,不弹无人操作的卡片。所以**那段时间摄像头根本不会开**;唤醒时的 `handleSystemWake()` 是为"刚醒、还没下一条命令"那一瞬间预热的(对称于网络的 `server.restart()`)。

设计要点:唤醒时**网络和摄像头一起复活**,因为它们是同一类"睡眠期间静默失效"的资源。改睡眠逻辑时,这两个要成对考虑。

---

## 5. 审批数据通路(端到端)

```
AI 工具(CC/Codex/…) 要执行工具调用
   │  触发各家的 PreToolUse/PermissionRequest/BeforeTool hook
   ▼
GestureApprove --hook <target>          (HookCLI.run)
   │  读 stdin JSON → 拼 "Bash: <cmd>" → POST 127.0.0.1:47600/approve(阻塞,默认超时100s)
   ▼
ApprovalServer(主 app, NWListener)      (onApprove 回调,主线程)
   │  按层判定 ↓↓↓
   │   1) 总开关关       → reply ask("已关闭")
   │   2) systemSuspended → reply ask("锁屏/睡眠")
   │   3) 白名单 autoAllows → reply allow("白名单")
   │   4) 智能放行(可选): 不危险 && 守门员说 safe → reply allow("smartgate")
   │   5) 落手势 askGesture → 弹刘海卡片 + 开摄像头 + 等手势/热键/超时(90s)
   │        👍thumbUp→allow  🖐openPalm→deny  超时→ask
   ▼
hook 拿到 {decision, reason}            (HookCLI.emit)
   │  按目标工具格式写 stdout(各家字段不同)
   ▼
AI 工具: allow→执行 / deny→拦截 / ask→走它自己的终端确认
```

**判定分层的铁律**(改判定逻辑务必守住):
- **deny-list 是硬闸**:危险命令(`rm`/`sudo`/`curl|sh`/`git push -f`/敏感文件读 …)**永远要手势,永不进 LLM**。LLM 只是"额外放行器",绝不裁决危险命令、绝不自动拒绝。
- **白名单只放行不否决**;危险判定只否决不放行;两者独立。
- **拼接符防绕过**:命令含 `&& | ; \` $( > <` 等时,前缀白名单失效(防 `ls && rm -rf` 把危险藏在后面),交给 LLM 看整条或落手势。
- **fail-safe = ask**:任何环节出错/超时/离线 → `ask` 交回终端,从不硬 allow/deny。hook HTTP 超时(100s)> 卡片超时(90s),保证 app 有时间回 ask。

规则来源:`config/gatekeeper-rules.json`(`dangerPatterns`/`autoAllowPatterns`/`compoundTokens`),由 `RulesConfig` 加载,损坏则回退 `Allowlist` 里的 `builtin*`(保证 deny-list 永不为空)。

---

## 6. 子系统速查

### 主进程(`main.swift`)
`.accessory` 菜单栏 app。启动顺序:杀旧实例 → 注册默认值 → 请求通知/相机权限 → 菜单栏图标 → 注册热键 → 启服务 → 启守门员 → 监听系统事件 → 检查更新。退出时 `Gatekeeper.stop()` 收 daemon。

### 全局热键(`HotKeyManager.swift`)
Carbon `RegisterEventHotKey` 注册 `^⇧Y`(approve)/`^⇧N`(deny)。用 Carbon 而非 AX → 免辅助功能权限,任意 app 聚焦都能触发。

### 自动更新(`Updater.swift`)
启动时 + 每 24h 查 `releases/latest`。有新版只在菜单栏加一项"🆕 更新到 vX"(不弹窗不通知,不点=跳过)。点了→下载 zip→`ditto` 解压→detached `swap.sh`(等本进程退出→替换→清 quarantine→重启)。URLSession 下载不带隔离属性,免 Gatekeeper 拦。
> 发版细节(版本号/tag/产物名/helper 解耦)见 memory `release-process`,不在本文件重复。

### hook 安装(`HookInstaller.swift`)
四家工具开关:开→写配置(原文件备份 `.bak.<时间戳>`)、关→移除。Claude/Gemini 是 JSON(`hooks.PreToolUse`/`BeforeTool`),Codex/Kimi 是 TOML(用 `>>> gesture-approve (managed) >>>` 标记块管理,便于整块删)。command 一律是 `<app 二进制> --hook <target>`。Gemini 的 timeout 单位是毫秒。

### 识别引擎(`GestureEngine.swift` + 三个源)
帧从 `CameraFrameSource`/`ESP32FrameSource` 经 `submit(jpeg:preview:)` 喂入 → 走 Vision(内置 CoreML,`HandGesture.mlmodelc`,无需下载)或 MediaPipe(独立 daemon,更准)→ 结果进**0.5s 时间窗多数投票**(≥60% 同手势才锁定,容忍抖动)→ `onStable` 回调触发判定。识别精度档(loose/standard/strict)经 `gestureMinConf`(0.3/0.6/0.9)映射到两套引擎各自的阈值——映射不同因为两者 score 分布不同,详见 memory `mediapipe-precision`。

### 守门员 helper(`Gatekeeper.swift` + `GestureGatekeeper/main.swift`)
独立进程跑 MLX + Qwen3-1.7B-4bit。`startIfNeeded`(开关开+已装才起)→ 监听 47601 → `judge()` POST 一条命令、5s 超时、返回 safe/unsafe(失败 false=落手势)。helper 单独编译(`build_gatekeeper_helper.sh`,必须 xcodebuild + Metal 工具链,不能 swift build,见 memory `gatekeeper-build`)、单独下载(固定 tag `gatekeeper-helper-v1`,与 app 发版解耦)。模型权重不在 zip 里,`--prefetch` 时从 HF 拉到 `gatekeeper/models/`。

### 摄像头与帧可靠性(`FrameSource.swift`)
见 [camera-resilience.md](./camera-resilience.md)。要点:capture session 跨审批复用,配看门狗 + 唤醒主动复位双层自愈。

---

## 7. 排障入口

- **审批不弹卡 / AI 命令直接过或直接卡**:`tail -f /tmp/gestureapprove.log`,看 `requestApproval`(进了审批流程)还是被白名单/智能放行直接放过(没这行)。只读/明显安全命令被放行不弹卡是**正常设计**;要复现弹卡用危险命令(如 `rm` 一个临时文件)。
- **刘海黑屏**:`grep 看门狗 /tmp/gestureapprove.log` —— 出现"重建会话"= 兜底救了一次(好事)。
- **唤醒后失灵**:看日志 `系统事件 … → 锁屏=? 睡眠=? 审批暂停/恢复`,确认 `systemSuspended` 是否卡在暂停。
- **守门员不工作**:确认开关开、`Model ready`;`pgrep -fl "GestureGatekeeper --serve"` 看 daemon 在不在;`judge` 失败会 fail-safe 落手势,不影响安全。
- **端口被占**:`lsof -i :47600 -i :47601`。
