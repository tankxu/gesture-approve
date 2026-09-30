# GestureApprove：额度、Token 账本与 Remote Hub 技术方案

日期：2026-09-12。方案版本：v2。适用于 Claude Code Desktop 的 Code 会话、Claude Code CLI、Codex Desktop 与 Codex CLI；云端/SSH/容器按执行主机另行接入。Claude Chat、Cowork 不默认混入 Code 的统计。

这是设计交付，未安装采集器或修改用户设置，未向现有会话发送测试消息。当前本机 Claude CLI 为 2.1.269，Codex CLI 为 0.151.0；已有 Claude 会话仍观察到 2.1.259–2.1.267。应以目标会话的运行引擎版本决定协议能力，不能以 PATH 中的版本代替，也不能假定桌面内置版本相同。

## 1. 最终架构

每台执行主机运行一个 Local Agent，包含四类独立适配器：额度、用量账本、会话观察、会话控制。观察和控制分开，不因能列出会话就宣称能回复。

数据链路：

```text
客户端/CLI 的 hooks、原生事件、会话文件
  → 执行主机 Local Agent
  → 本地 SQLite：事件日志、会话状态、额度快照、用量账本
  → Remote Hub：汇总、持久化游标、手机/设备订阅

手机/设备操作
  → Hub 动作记录
  → 会话所属 Local Agent
  → 已注册的控制通道
  → 接收/执行证据回传
```

本地端点使用 Unix socket/loopback；跨主机通过鉴权加密通道。额度认证由原生工具管理，不向 Hub 上传 OAuth、浏览器 cookie、Keychain 内容或本地 peer token。断线时本地写账和保存事件，恢复后按序补传。

会话主键为 `hostId + provider + profileId + nativeSessionId`，同时保存 `surface`、`executionLocation`、`runId`、`parentSessionId`。CLI/桌面/Remote Control 可能只是同一会话的不同呈现，用原生 ID 映射合并，不按名称、项目目录或 PID 合并。

## 2. 当前剩余额度

### 默认：沿用不自行调用 Web API、不读取 Keychain 的限制

| 来源 | 首选采集 | 展示 |
| --- | --- | --- |
| Claude CLI | statusLine 的 rate_limits | 5h/7d 剩余百分比、各自重置时间 |
| Claude Desktop Code | 已接入引擎事件若含额度则直接收；否则同账户 CLI 的可信快照/原生缓存辅助 | 明确额度是账户级，不是假称该桌面会话已独立采集 |
| Codex | 同一 app-server 的 account/rateLimits/updated；未连接时读取 rollout rate_limits | 按 limitId、模型范围、windowDuration 展示全部实际窗口 |

Claude statusLine 是官方 JSON 出口，不需要采集器进行网络请求。窗口字段可缺失，不能将缺失视为 0 已用；不要假定 Desktop 会执行 CLI 的 statusLine 脚本。Codex 的 primary 不一定是 5h，本机样本即出现 primary=10080 分钟，不能根据字段位置硬编码。[Claude 状态栏](https://code.claude.com/docs/en/statusline)、[Codex App Server](https://learn.chatgpt.com/docs/app-server)。

每个额度快照保存 account/profile、limitId、usedPercent、resetsAt、source、observedAt（若来源有）、receivedAt、freshness。剩余比例为有效已用比例对应的 100-usedPercent；不同窗口、模型池和账户不能相加。没有明确账户证据时标为归属未确认，不能拿当前登录身份给旧会话倒填账户。

Claude statusLine 的 5h/7d 并不覆盖所有可能的模型独立池或额外消费余额；这些没有被来源提供时标为“未获取”。仅两个窗口尚有剩余，不能保证某个具体模型一定能继续运行；也没有可靠的“剩余绝对 token 数”换算公式。

“最近收到脚本输出”不等于“服务器刚刷新”：状态栏重复绘制不能刷新观测时间；没有观测时间的来源只标接收时间。窗口过期清除当前百分比但保留历史；短期旧快照可以显示为“上次观测”，不伪装实时。账户切换必须隔离缓存。

### 可选增强：交给官方程序按需联网刷新

如果限制是“不让 GA 调私有 Web API/拿 OAuth”，但允许官方程序正常联网，可以增加：Claude 专用隔离 PTY 执行 `/usage`；Codex 官方 app-server 执行 `account/rateLimits/read`。它们不需要 GA 读取 Keychain，但原生程序自身仍可能访问其认证存储并联网；遇到登录/系统授权就停止后台探测，不自动确认。

这不是默认纯本地模式，也不是把联网包装成离线。若所有额度查询网络请求都被禁止，任何监控工具都只能拿到最近已观测的数据，无法知道其他设备此后的消耗。不开推理请求“刷额度”，不轮询用户正在工作的 TUI。

`get_usage` 控制请求仍会请求 OAuth usage endpoint，不作为纯本地方案。第三方 CodexBar 也明确区分 OAuth、Web、CLI PTY 和本地成本扫描，并没有一种万能离线额度接口。[CodexBar Claude 实现说明](https://github.com/steipete/CodexBar/blob/main/docs/claude.md)。

## 3. 今日、本月、每会话 Token 与价值

### 建立逐请求账本

本机真实 Claude 日志已确认有 input、output、cache_read、cache_creation，并细分 5m/1h 写缓存；Codex 日志已确认有 total/last_token_usage、cached_input、cache_write、reasoning_output。统计无需调用模型或额度 API。

| 提供方 | 主要来源 | 正确处理 |
| --- | --- | --- |
| Claude | transcript 中 assistant.message.usage | 以 requestId + message.id 等稳定标识折叠流式重复记录，保留该请求最终完整 usage |
| Codex | rollout token_count + turn_context；同服务 tokenUsage 事件加速更新 | 按请求/累计计数变化生成账目，去掉仅重复广播限额的事件，不能把累计总数逐行相加 |

按版本验证 token 字段包含关系。当前 Codex 样本 input_tokens 已包含 cached_input_tokens，output_tokens 包含 reasoning_output_tokens；缓存和推理是明细，不能再次加进 total。Claude 的基础 input、cache_read、cache_creation 分开计量。用量中的 iterations、aggregate、子明细不能重复累计。

账本处理以下情况：文件追加与替换、部分写入、日志迁移/归档、resume、fork 复制的历史前缀、子 agent 继承的上下文、模型切换、压缩造成的累计计数变化。同一请求在不同源只记一次；父会话可显示含子 agent 的汇总，但全局总量不能再加一次子 agent。缺稳定 requestId 时记录去重方法与可信度，不能按相同 token 数随意删除独立请求。

通过 FSEvents/文件监听读新增字节，定期重新发现已配置的数据根，SQLite 保存文件身份和解析游标。启动先展示已完成的缓存，再后台补历史。支持 CLAUDE_CONFIG_DIR、CODEX_HOME 与桌面独立数据根。

本机已确认 Claude Desktop 元数据含 `sessionId ↔ cliSessionId` 映射；部分旧/隔离运行环境还有嵌套 `.claude/projects`。先按映射找真实 transcript，不能因为它同时出现在桌面和 CLI 索引里就计两次。Codex 同时纳入 sessions 和 archived_sessions。第三方 ccusage、CodexBar 的本地扫描与去重可以作为校验参考，生产适配器固定版本并保留回归样本。[ccusage](https://github.com/ccusage/ccusage)、[CodexBar Codex 账本](https://github.com/steipete/CodexBar/blob/main/docs/codex.md)。

### 统计与价值口径

默认按 Asia/Bangkok 的自然日、自然月分桶；跨日会话按请求发生时间拆分，而非全部记在会话创建日。保留 UTC 原始时间，允许切换报告时区。

输出今日、本月、每会话/项目/模型的 token、缓存比例、API 等价价值；会话同时显示本轮和累计，子 agent 可展开。

```text
API 等价价值
  = Σ（互不重复的 token 计费分类 × 对应模型/模式单价 ÷ 1,000,000）
```

价格表按精确模型、有效日期、standard/fast/priority、长上下文条件、缓存读/写及 TTL 版本化；未知模型不默认套相近型号，不把缺价算成免费。保存 pricingVersion 和 costBasis；缺少影响价格的条件时展示估算/区间或未知。工具收费若另计则单列。

**API 等价价值不是订阅实际扣款，也不是“剩余额度值多少钱”。** 实际付款单独来自账单/明确支出记录。历史标准价估算和“按今天价格重估”应分开；没有历史价证据时不声称历史实际成本。[Anthropic 定价](https://platform.claude.com/docs/en/about-claude/pricing)、[OpenAI 定价](https://developers.openai.com/api/docs/pricing)。

每份报表附 coverage：已接入主机、可读历史范围、已扫描至何时、未定价请求数、未覆盖会话。其他电脑、云端、被删除日志不可伪装已统计。Codex 新增 `account/usage/read` 可提供账户 token 活动汇总及可空的日桶，但需要联网、不是每会话成本明细；只能作为独立账户汇总/对账源，不能再加到本地账本，也不能假定服务端日桶时区等于用户时区。[账户用量接口](https://learn.chatgpt.com/docs/app-server#7-token-usage-chatgpt)。

## 4. 会话列表与准确状态

| 会话来源 | 发现与历史 | 当前状态证据 | 控制策略 |
| --- | --- | --- | --- |
| Claude CLI | agents --json --all + transcript | 原生 state/status/waitingFor + hooks | Channels 或已注册 inbox；审批单独处理 |
| Claude Desktop 本地 Code | Desktop 元数据映射 + hook 注册 + transcript | 共享引擎 hooks；原生列表覆盖经该版本验证后补充 | 该 session 暴露 inbox 时使用；否则桌面 UI 兼容 |
| Codex CLI | 每个 CODEX_HOME 的索引/rollout + hook 注册 | hooks；可连接同服务时原生状态事件 | 同 app-server 控制；否则只有已注册输入通道才能发消息 |
| Codex Desktop 本地任务 | 对应主机索引 + hook 注册 + 桌面映射 | hooks；可连接承载服务时原生事件 | 同服务协议优先；否则桌面 UI 兼容 |
| SSH/容器/远程主机 | 执行环境安装 Local Agent 后汇总 | 执行端事件 | 执行端控制通道 |
| 未接入的云端任务 | 有官方连接时获取；本地镜像仅作历史 | 无实时证据就标未知/未接入 | 打开官方入口，不宣称可由 Hub 本地控制 |

Claude Desktop 和 CLI 共享 hooks/settings，但会话历史的呈现分别维护。不能只扫 `~/.claude/projects` 就声称覆盖全部桌面会话；CLI `agents --json` 对本机 CLI 已验证，对每个桌面引擎版本仍要验证。[Desktop 配置与会话](https://code.claude.com/docs/en/desktop)、[原生会话 JSON](https://code.claude.com/docs/en/agent-view#list-sessions-as-json)。

状态分别存储：

- `connection`：online / offline / unknown。
- `lifecycle`：loaded / exited / archived。
- `activity`：working / waiting_approval / waiting_input / waiting_external / idle / unknown。
- `lastTurnOutcome`：completed / interrupted / failed / none。

界面映射为“工作中、等待审批、等待回答、等待外部任务、本轮已完成、空闲、失败、中断、离线、状态未知”。“已完成”只代表本轮结果，不擅自推断整个项目完成。还存在运行中的子 agent 时，父项显示“主会话本轮完成，子任务仍在运行”。登录、配额或策略阻塞给独立原因，不混成普通审批。

证据优先级：当前原生运行态/匹配的待处理请求 → hooks 事件 → transcript 历史推断。时间戳、runId、turnId 和事件序号避免异步 Stop 晚到盖掉新一轮 Working。没有写文件不代表停止；进程活着不代表工作中；主机失联不标完成。

建议活动界面 3–5 秒做快照校准，实时事件目标正常联网下 1 秒内到 Hub；空闲降低扫描频率。这是验收目标而非已测性能。Codex 新起 app-server 能读账户/历史，不等于它能看到另一个桌面进程的运行态。[Codex 状态协议](https://learn.chatgpt.com/docs/app-server)、[Codex Hooks](https://learn.chatgpt.com/docs/hooks)。

## 5. 回复与审批：采用多通道，但能力必须真实

### Claude

1. **受控 CLI 会话优先 Channels。** 将 GA bridge 作为双向 MCP channel，支持普通消息、回复工具和 tool permission relay。Channels 当前仍为 research preview，自定义 channel 受 allowlist/开发启动参数限制，需要每个会话主动启用，不能宣称能热接管所有现存 CLI 或 Desktop。权限 relay 不覆盖项目 trust、MCP consent、系统登录等所有对话框。[Channels](https://code.claude.com/docs/en/channels-reference)。
2. **现有会话优先尝试已注册 inbox socket。** 官方已提供供脚本/hooks 投递的本地 socket，SessionStart 可记录精确 session ID 与 socket；无需读 OAuth/Keychain。macOS 同用户连接遵循 inbound accept/hold/refuse。运行中在工具边界接收，不打断正在执行的工具；空闲时可启动新一轮。[会话 inbox](https://code.claude.com/docs/en/cross-session-messaging#the-sessions-inbox-socket)。
3. **inbox 消息不是用户审批。** 本机 2.1.269 实现将它标为 peer/meta，跳过 slash command 与附件解释。普通消息“同意”不能冒充某个系统审批答复；完整 wire 格式按版本兼容并用收件证据验收。不得借 own-child token 绕过 inbound 限制。
4. **审批单独走现有 GA 的挂起 PermissionRequest、Channels permission relay 或 SDK 权限回调。** 只解决能关联到当前 requestId 的请求，超时/终端已处理必须失效。监控 hook 可异步，承担授权决定的 hook 必须保持有效的同步返回/协议响应通道。

### Codex

1. **同一 app-server 是完整控制通道。** idle 用 turn/start；working 用 turn/steer 并携带 expectedTurnId；中断用 turn/interrupt；审批和结构化问答回复原始 server request。[Codex 控制协议](https://learn.chatgpt.com/docs/app-server)。
2. **当前桌面 stdio 实例不能被另起 server 接管。** 现有 CLI/桌面如果只接了观察 hooks，则普通回复能力仍为空；挂起的 PermissionRequest 可独立响应。不能把监控 hooks 输出的 additionalContext 当成通用用户输入控制口。
3. **新增 Hub 托管会话可完整控制。** 由 Local Agent 持有 app-server 连接；现有原生会话则按实际可接入程度分级，不强迫全部换前端。

### 桌面 UI 兼容通道

两家桌面版没有可用原生控制口时，可提供用户启用的 macOS Accessibility 自动化：打开准确会话、校验 ID/可验证映射、填入消息、发送、回读消息进入正确 transcript 的证据。不能只凭标题匹配，也不能把按钮点击成功当成送达。

这条通道依赖未锁屏桌面、权限、当前 UI 版本与无阻挡弹窗，不能用来承诺无人值守的全场景控制。对终端仅在已绑定 tmux/PTY/具体终端会话时考虑输入，不往未知前台窗口盲打。UI 兼容通道本轮未做实机回复验证，首版不作为默认成功通道。

### 已退出会话

提供独立“恢复并发送”动作，而非隐藏在普通回复后。先核实没有存活 owner、没有并发恢复，再以原配置/项目/权限恢复；显示实际执行主机、引擎、是否新 run，以及原界面是否会同步。不同时启动第二个进程写同一会话。

## 6. 回复不了时的明确分类

| 原因码 | 用户看到的原因 | 可用动作 |
| --- | --- | --- |
| OBSERVE_ONLY | 已接入监控，未接入消息通道 | 开启控制桥或打开原客户端 |
| OWNER_NOT_CONNECTED | 承载会话的 app-server/PTY 未连接 Hub | 接入原 owner，不能另起进程冒充 |
| MESSAGING_DISABLED | 会话未启用消息、bare 模式或无 inbox | 下次启动时启用支持的通道 |
| INBOUND_HELD / INBOUND_REFUSED | 消息等待接收授权 / 被接收策略拒绝 | 显示等待或拒绝；不谎报送达 |
| CHANNEL_NOT_ENABLED | 会话未加载 channel 或组织不允许 | 使用已允许通道或原客户端 |
| APPROVAL_NOT_RELAYABLE | 当前是本地 trust、登录、系统权限等不可转发对话框 | 在原客户端处理 |
| REQUEST_EXPIRED | 审批已超时、撤回或在原客户端处理 | 刷新状态，不重放旧批准 |
| TURN_CHANGED | 用户回复时目标轮次已改变 | 重新确认目标轮次，禁止误 steer |
| SESSION_EXITED | 原会话已退出 | 显式恢复并发送 |
| HOST_OFFLINE | 执行主机离线 | 可保存草稿；审批不离线排队自动执行 |
| CLOUD_NOT_CONNECTED | 云端/远程执行环境未接入 | 打开官方入口或接入执行环境 |
| AUTH_REQUIRED / QUOTA_EXHAUSTED | 登录失效 / 当前额度不足 | 恢复认证或等待重置；分清可收消息与可运行 |
| SCREEN_LOCKED | 执行主机桌面已锁屏 | 解锁后使用 UI 通道；原生通道另判 |
| AX_NOT_AUTHORIZED | 未授予桌面自动化所需的辅助功能权限 | 配置 UI 通道或使用原生通道 |
| UI_BLOCKED_BY_MODAL | 原客户端被其他弹窗阻挡 | 在原客户端处理弹窗 |
| TARGET_UNVERIFIED | 无法确认当前 UI 对应目标会话 | 拒绝发送，避免串会话 |
| DELIVERY_UNCONFIRMED | 已写入通道但未取得接收证据 | 标为待确认，不盲目重试 |
| VERSION_UNSUPPORTED / HISTORY_MISSING | 该版本协议不支持 / 恢复所需历史缺失 | 升级适配器或打开原客户端 |

每个会话返回独立 capabilities：reply、enqueue、steer、approve、answer、interrupt、resume、openNative；每项携带 available、transport、reasonCode、reasonText，而不是一个 canReply。

## 7. Hub 合约与交付验收

保留旧接口兼容，新增 `/v2/accounts/*/quota`、`/v2/usage`、`/v2/sessions`、`/v2/events`、`/v2/sessions/{id}/actions`。用量查询支持 day/month/session/model，必须同时返回 coverage 与 valuation basis。

动作携带 actionId/idempotencyKey、sessionKey、expectedRunId/expectedTurnId、必要的 requestId 与 expiresAt。普通消息的结果区分：Hub 已保存、已排队、通道已接受、已投递、会话开始处理、已回答、失败、无法确认。不能把 HTTP 200/socket write/UI click 直接映射成“会话收到”。

观察事件进入本地持久日志；Hub 使用可续传 cursor，重连先读快照再补增量。限制每个会话的控制并发，终端与 Hub 谁先有效解决审批谁生效，另一端立即失效。重试不重复发送、不重复批准。

交付顺序：先完成账本和两家观察通道；再接 Claude inbox/Channels 与审批、Codex 同服务控制；最后补桌面 UI、跨主机和云端。发布目标应覆盖以下验收，不能以编译通过替代：

1. 四个入口各开真实会话，验证发现、工作、审批、问答、本轮完成、中断、退出；Desktop 本地与云端分开统计覆盖。
2. 每个支持回复的通道将带唯一标识的消息送入指定会话，原会话与 Hub 都可见；不支持时返回具体原因。
3. Hub 和原客户端竞答同一审批，第二次不得执行；失联、过期、轮次变化不误批准。
4. token 账本覆盖跨日/月、缓存读写、流式重复、fork、resume、子 agent、压缩、归档，按真实记录核对；只观察无推理时总量不增加。
5. quota 对照原生使用界面，验证账号切换、模型独立窗口、缺失、过期和断网；快照时间不被重复重绘刷“新”。
6. 重启与断线补传不丢状态、不重复记账；锁屏/UI失败不误称已发送。

现有代码改动重点：UsageMonitor 拆分 QuotaProvider/UsageLedger；HubApp 拆分 SessionProvider/ControlProvider；AgentEvents 扩为持久事件与状态归约器；HookInstaller/HookCLI 分别安装观察 hook、审批 relay 和消息注册。废除 `canReply = 有网页桥 || 进程已退出` 这种静态推断，废除仅靠 transcript stop_reason/PID 判定实时状态。
