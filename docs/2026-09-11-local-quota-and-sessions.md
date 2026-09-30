# Claude 额度与 Claude/Codex 本地会话研究

研究日期：2026-09-11。目标：GestureApprove 获取 Claude 订阅额度时，不依赖应用自行调用 Web/OAuth usage API，也不由应用读取系统钥匙串；同时复核两家活跃会话与动态接口。

本次是研究，未改应用实现、用户 Claude 配置或现有会话。检查了现有源码、官方文档与本机 Claude 2.1.267 / Codex 0.151.0；会话部分由一个并行 agent 独立研究并做只读验证。

## 结论

| 目标 | 建议来源 | 可用边界 |
| --- | --- | --- |
| Claude 5h/7d 额度 | 官方 statusLine JSON → 本地快照 | 本机代码确认支持；需要运行中的交互会话提供观测值 |
| Claude 无运行会话时的额度 | 最近快照；原生 cachedUsageUtilization 可辅助 | 只能提供旧观测，必须标时间与过期状态 |
| Claude 活跃会话 | `claude agents --json --all` | 本机已实测；分别解释 status、state 与 waitingFor |
| Claude 会话动态 | CLI 快照校准 + lifecycle/tool hooks | hooks 收即时事件，快照修正漏报与重启状态 |
| Codex 同一服务内的状态/动态 | app-server thread 状态与通知 | 必须连接真正承载会话的 app-server |
| 当前 Codex 桌面已有会话 | hooks + SQLite 历史目录 + JSONL 增量 | 尚未验证可供第三方连接的桌面运行态订阅端点 |

## Claude 额度：现在已有官方本地出口

`statusLine` 脚本通过 stdin 接收 JSON，其中包括：

```json
{
  "session_id": "...",
  "version": "2.1.267",
  "rate_limits": {
    "five_hour": { "used_percentage": 23.5, "resets_at": 1738425600 },
    "seven_day": { "used_percentage": 41.2, "resets_at": 1738857600 }
  }
}
```

以上数值仅为结构示例，不是当前账户额度。百分比是已用比例，0–100；重置时间是 Unix 秒，不是毫秒或 ISO 字符串。

官方 changelog 在 2.1.80 已记录加入 5h/7d 字段，2.1.243 修复闲置时窗口重置仍显示旧比例的问题。2.1.251 新增 gateway spend limit；当前文档的示例统一要求 2.1.251，不应将它误写成最初引入 5h/7d 的版本。当前安装 2.1.267 满足要求。[状态栏文档](https://code.claude.com/docs/en/statusline)、[官方更新记录](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md)。

本机二进制中的状态栏构造函数 `V1o` 调用 `tF()`，将内存里的 five_hour/seven_day utilization 乘 100 写进 used_percentage；`tF()` 对 rawUtilization 做窗口有效期过滤。采集脚本因此不需要网络请求、OAuth token 或 Keychain。这里的“无 Keychain”指 GestureApprove 的采集路径；Claude 自己正常登录仍使用它原有的认证机制。

刷新与缺失值：

- 官方面向 Pro/Max 的订阅窗口，在会话首次 API 响应后才可能出现，每个窗口可独立缺失。
- 新消息等事件会触发状态栏更新；refreshInterval 只重跑本地脚本，不能当成强制刷新远端额度。
- 没有新请求时，其他机器或网页端的消耗不会自动反映进本机快照。
- 重置后缺失的窗口应显示“等待刷新”，不能凭空写成 0%。
- 本机用户和当前项目没有已配置的 statusLine。本次未安装采集器，未获得当前账户真实 statusLine payload，因此验证层级是“官方接口 + 本机实现确认”，不是端到端采集完成。

建议实现：增加 `local` 数据源；状态栏 bridge 原子写入按 session 分文件的精简快照；应用读取快照并保留 source、receivedAt、会话和账户关联。不要把定时重绘的时间冒充服务器观测时间；来源本身没有响应时间时应标为“最近接收的会话快照”。同一账户多会话不可累加百分比，也不可简单取最大值；使用最近可信观测，并将账号切换作为失效边界。已有 statusLine 时必须把同一份 stdin 交给原命令并保留其输出。

## 两条辅助路径的核对结果

### 原生磁盘缓存：能读，但本机已过期

本机 `~/.claude.json.cachedUsageUtilization` 实际存在，结构包含 `accountUuid`、`fetchedAtMs`、`utilization`，窗口内部用 `utilization`（0–100）和 ISO `resets_at`。

只读取这些额度字段并比较账户 ID，未输出凭证。缓存账户与本机登录账户相符，但采集时间为 **2026-08-24 19:15:14 UTC**，两个窗口均已过期，不能用于当前额度展示。

2.1.267 的内部读取函数 `M_n` 限制缓存年龄为 1 小时；写入函数 `bXn` 同账户至少间隔 5 分钟。这是二进制实现细节，尚不是稳定公开接口。可作可选冷启动补充，但要检查账户、年龄和各窗口的 resets_at，绝不能只见字段就显示。

### 新 control request `get_usage`：仍会联网

本机 schema 存在实验性的 `get_usage`，可返回 session usage、订阅窗口、model_scoped 和 behaviors；`skip_behaviors` 用于省去 transcript 扫描。

本机调用链为 `B4e → Spt → jD`，`jD` 明确调用 `/api/oauth/usage` 并设 `refreshOAuth: true`；失败时才尝试内存/磁盘种子。因此它并不是纯本地额度方案，不应为了规避 Web API 改成调用这个控制请求。CLI 帮助也没有独立的 `claude usage --json` 子命令。

SDK 的 `rate_limit_event` 可作为由应用自己托管会话的补充，但不等同于可附着任意现有会话、持续提供完整双窗口的公开接口。token 数、美元成本和 OpenTelemetry token/cost 指标也不能可靠换算订阅剩余额度。

## Claude 会话：优先官方 JSON 列表

```sh
claude agents --json --all
```

官方将其明确作为外部程序读取会话状态的支持路径，并建议轮询；不再优先直接解析 `~/.claude/jobs/`。本机只读实测约 0.1 秒得到 6 条，包括 4 条 interactive 和 2 条 background；这只是采样时的数量。[官方会话 JSON 文档](https://code.claude.com/docs/en/agent-view#list-sessions-as-json)。

- 标识/展示：`sessionId`、`name`、`cwd`、`pid`、`kind`。
- 运行态：`status` 的 busy/waiting/idle；字段可缺失，需按 kind 解析。
- 后台任务状态：`state` 的 working/blocked/done/failed/stopped；`waitingFor` 可进一步解释审批或问答。
- “有进程”“正在生成”“需要用户输入”“任务已完成”应分别表示。后台会话即使进程退出仍可 blocked，不能只凭 PID 排除。

建议 UI 打开时每 3–5 秒校准一次（应用策略，不是官方固定频率），关掉 UI 后降低频率；合并现有 hooks 的 UserPromptSubmit、PreToolUse、PostToolUse、Stop、SessionEnd 等事件。Stop 表示一轮结束，不等于会话退出；区分主会话和 subagent，事件按 ID 去重并处理崩溃漏报。

## Codex 会话：接口完整，但服务实例边界仍在

官方 app-server 提供 `thread/list` 历史列表、`thread/loaded/list` 内存会话 ID、thread/read 的 status，以及 `thread/status/changed`、turn/*、item/* 等实时通知。loaded 包含空闲会话，并不等于正在生成；活跃状态还可带 waitingOnApproval 等标记。[官方 App Server 文档](https://learn.chatgpt.com/docs/app-server)。

本机安装的 0.151.0 已有 app-server proxy/daemon 相关命令，但会话 agent 检查到当前桌面内置 app-server 使用 stdio，默认 daemon control socket 不存在。新建 app-server 可以读取历史，却不能因此观察另一个进程的内存状态。不能为监听而恢复/抢占用户已有线程。

本机 state_5.sqlite 的 threads 表没有 runtime status/pid；updated_at 不是活跃标志。当前部署建议保留 SQLite 作为历史索引、JSONL 作为内容恢复来源，扩充官方 hooks 获取启动、输入、工具活动、结束和中断动态。新版 hooks 可异步运行，但需要按现有安装路径处理信任与去重。[官方 Hooks 文档](https://learn.chatgpt.com/docs/hooks)。

若将来由 GestureApprove 托管或明确共享同一个 app-server，再使用原生协议作为主要运行态来源，并保持传输连接消费事件。当前没有把“协议具备此能力”报告为“桌面版所有会话已可订阅”。

## 对现有源码的接入顺序

1. `UsageMonitor.swift`：增加 Claude 本地 statusLine 快照源，缺失/过期显示未知；按本次要求不自动回退 Chrome 或 Keychain。
2. `HookInstaller.swift` / `HookCLI.swift`：增加可组合的状态栏采集器，保留已有配置；提供卸载恢复。
3. `UsageMonitor.liveClaudeSessions()` / `HubApp.listSessions()`：使用官方 agents JSON 作为 Claude 当前状态来源，旧文件扫描只作历史/旧版兼容。
4. `AgentEvents.swift`：从 Stop 通知扩展为会话状态事件，接入现有本地服务与 Hub 事件流；两家共享统一展示模型，但保留来源与可信度。
5. Codex 原生 app-server 订阅作为独立后续接入项；当前先完成 hooks 与本地恢复链路。

上线前验证应包括真实会话首次响应、双会话并发、额度窗口过期、账户切换、应用重启、CLI 崩溃、等待审批与普通完成的区分。当前应用相关文件有大量既有未提交变更，本次仅新增这份研究记录。
