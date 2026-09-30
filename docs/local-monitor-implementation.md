# 本地额度、Token 与 Remote Hub 实现

2026-09-12。本机 macOS arm64；Claude Code 2.1.269；Codex CLI 0.151.0。

## 使用

应用菜单打开 Remote Hub。首页是一个装得上主屏的 app（`hub/app.html`）；`/monitor` 是额度与会话面板（`hub/monitor.html`）。两页文案都跟随软件语言，只有 zh/en 两套，其余语言落到英文。

## Hub 前端

三个去处，覆盖「远程用」真正需要的动作：**待办**（等你批准/等你输入的会话，外加此刻正在跑的）、**会话**（全部会话，搜索 + 按活跃/提供商筛选）、**额度**（额度窗口 + 日/月 Token）。点进会话读记录并回复。窄屏是底部 tab 单列，聊天覆盖整屏；≥1100px 是三栏工作台；860–1099px 之间列表与聊天占两栏、待办与额度收进右侧抽屉。`#s=<会话键>` 和 `#tab=<名字>` 是深链，浏览器/系统返回键先关聊天层而不是退出 app。

宽屏右栏只放额度：左栏列表本身就是「谁在等你」的答案（等待的排最前、带 pill），再列一遍是同一批会话的重影；审批的允许/拒绝因此挪进会话行。窄屏的待办 tab 保留待办与工作中两区 —— 那是它存在的理由。

`/v2/messages` 只回「人真正说过的话」。从 Hub 发出的回复走会话的 peer inbox，Claude Code 落盘时会包一层：一行抬头、正文、再加一段讲 peer 权限边界的固定模板，整条标 `isMeta`。那段模板是写给会话里的模型看的，不是人打的字，在手机上回看时会把真正发出去的那一句埋掉。现在读回来会剥掉它，同时丢掉其他非对话行（终端回显、`Continue from where you left off.`），斜杠命令收成 `/model claude-opus-5` 而不是三行 XML。模板文案将来变了就找不到尾巴，那时原样保留正文、顶多多显示一段，绝不砍内容；截尾从最后一处匹配开始找，用户自己引用同样的开头也不会被误伤。**投递不变**：Hub 仍以 peer 身份发送，不伪造用户本人的授权，接收方看到的与以前完全一致。

记录按完整 markdown 渲染（标题、列表、引用、表格、分隔线、粗体/斜体/删除线、行内码与代码块、链接、图片），**渲染只在前端做** —— `/v2/messages` 始终回原始文本，别的客户端拿到的还是原文。实现上先整段转义再逐块解析，生成的 HTML 一律走占位符还原，避免后续替换啃进已生成的标签（比如裸 URL 匹配进 href）；链接与图片限定 `http(s)`/`mailto`，`javascript:` 一类只留文字，本地路径的图片显示成标注而不是一张碎图。

消息里的图片不内联：transcript 里一张截图的 base64 就有 600KB，塞进消息列表手机根本拉不动。`/v2/messages` 只带 `images: [{index, mediaType, bytes}]`，字节走 `/v2/attachment` 按需取，浏览器长期缓存。该端点只回 png/jpeg/gif/webp，且必须命中指名消息的指名块；`<img>` 发不出 Authorization 头，所以它额外接受 `?token=`。纯图片、没有文字的消息以前整条被丢掉，现在会保留。

Codex 也能回复了。它没有 Claude 那种 peer socket，但 CLI 带 `codex queue --thread <id> --message <text>`：消息排进该 thread 的队列（落在 `~/.codex/queue_1.sqlite`，由 Codex 自己管，本实现只调 CLI、不碰那个库），会话下一轮读到就处理 —— **不要求它此刻在跑**。因此 Codex 的回复不校验运行代次（`expectedRunId`）：排队本来就不绑定某次运行，强校验只会永远 `STALE_RUN`。归档的 thread 会被 Codex 拒绝（要先 `unarchive`），这一条在 `capabilities.reply` 里提前说明，而不是等发送失败。`transport` 字段区分两条路：`claude-inbox` 与 `codex-queue`。Codex 要起子进程（秒级），所以这类请求不进监控队列，否则 Hub 的其他请求会一起被堵住。

发送有 4 秒撤回窗口。消息先停在 Hub 自己这边（页面内的待发位），气泡半透明、带「撤销」和一条走完即投递的进度线；撤销就是把它拿回输入框，什么都没发生过。**过了窗口就收不回来**：Claude 的 inbox 写进 socket 即生效，Codex 的队列条目也已落库 —— 所以「取消」只能发生在投递之前，界面不提供投递后的假撤回。投递失败时文本会放回输入框，不会凭空消失。

回复走两条路：`capabilities.reply.available` 为真时用 `/v2/actions`（直接送进还活着的进程），否则用 `/reply`（`claude --resume` 续上已退出的会话）；两条都不通时输入框上方直说原因，而不是等你按了发送才失败。消息按极简 markdown 渲染（粗体、行内码、代码块、列表、链接），先整段转义再插标签。

### PWA 的真实边界

manifest、service worker、图标三个外壳资源免 token（浏览器取它们时不会带 Authorization 头，403 就装不上主屏）；页面本身在局域网仍要 `?token=`，manifest 的 `start_url` 会带上当前 token。

局域网是 `http://`，不是安全上下文，于是：

- **iOS Safari**：分享 → 添加到主屏幕照常可用，全屏 standalone 运行，图标和启动色都生效。这是手机上的主路径。
- **Android Chrome**：安装提示（`beforeinstallprompt`）不会触发，只能加普通快捷方式。
- **Service worker**：不注册，所以离线外壳只在 Mac 本机（`127.0.0.1`，算安全上下文）访问时生效。注册失败是静默的，不影响其他功能。
- **麦克风**：`navigator.mediaDevices` 在非安全上下文里根本不存在，语音回复在局域网下不可用 —— 点麦克风会直接说明原因，而不是没反应。

要在手机上同时拿到语音和离线壳，需要给 Hub 一个 HTTPS 来源（自签证书或 Tailscale 之类），本实现不包含这一步。
**开关即安装**：设置里的「接入本机 AI 工具的额度采集」勾上就装、取消就还原，用户不需要碰命令行。
开关默认关闭 —— 往用户的 AI 工具配置里写东西必须是他自己点的；菜单栏里那段额度为空时会说明原因
（未开启 / 配置失效 / 已开启等下次刷新），前两种可直接点开启或修复。首次开启会先说明要动哪些文件。

**自愈**：开着但配置不在位（app 换过路径、statusLine 被别的工具换走、用户手改过）时，
App 启动和打开设置窗口各补装一次，让"开着"永远等于"真的在采"。关着时一个字节都不写。

首页“配置本机采集”只允许本机调用，并要求 Hub Bearer token。配置会备份原 Claude settings 与 Codex TOML，保留其他 hooks 与原 statusLine 输出。也可执行：

```sh
GestureApprove --monitor-status              # 每家采集器：有没有这个工具、装没装、是否指向旧路径
GestureApprove --monitor-install             # 这台机器上有哪家就装哪家
GestureApprove --monitor-install claude      # 只装点名的那家（逗号分隔）
GestureApprove --monitor-uninstall codex
```

**每家工具一个独立事务**：各自备份、各自校验、各自回滚，一家失败不牵连另一家（Codex 拒绝新 hooks 不会撤掉 Claude 的采集）。机器上没有的工具会被跳过并在结果里说明原因，不会为它创建任何配置文件。新增一家工具（grok 等）= 实现 `MonitorCollector` 并在 `MonitorHooks.collectors` 注册一行。

安装状态有三种：`absent`（没装）、`installed`（装了且指向当前 app）、`stale`（命令是我们写的，但指向别的 app 路径，或 statusLine 被其他工具换走 —— 会话照收、额度永远为空）。`stale` 与 `absent` 一样需要重装，重装会就地替换旧条目而不是叠加一条。

重复安装若内容无变化则不重写配置文件；每个配置旁只保留一份固定名备份 `<配置名>.ga-monitor-backup`（内容为本次写入前的状态）。

Claude 下一次客户端响应后能产生额度快照。Codex 修改后的 hooks 需要在原客户端 `/hooks` 审阅信任；安装成功不代表客户端已信任。关闭完成通知不会停止监控采集。

默认采集不读取凭证，不访问账户 Web API，不调用 Keychain。不存在本地快照时显示未知；刷新按钮只重新读取监控数据，不会强制请求账户额度。菜单栏原 Chrome/Keychain 用量实现已替换为本地数据源。

## 数据与准确性

- 数据目录：`~/Library/Application Support/GestureApprove/monitor/`。SQLite WAL 持久保存事件、会话、账本、文件进度和操作幂等键；hook 进程只原子写入 `inbox/*.json`。
- Claude：本地 `projects/**/*.jsonl` + `claude agents --json --all` + 活跃 registry + Desktop Code metadata + hooks + statusLine。
- Codex：`sessions` / `archived_sessions` JSONL + 只读 `state_5.sqlite` + hooks。`task_started`、`item_completed`、`task_complete`、`turn_aborted` 提供本地事件证据；PID 存活不能证明线程活跃，过时动态降为未知。
- 原生会话键包含 provider、profile 和完整 session ID；Desktop 元数据绑定 native CLI session ID。历史存在不等于运行中，已完成仅表示最近一轮结束。
- Claude 额度记录 5 小时和 7 天剩余百分比、重置时间、最后变化观测时间。重复 statusLine 重绘不伪造刷新时间。未下发的模型独立池不推算。账户归属未验证时明确标为本地 profile 观测。
- Codex 按 `limit_id` 分池，不能把某个模型的 100% 当成全部额度。
- 客户端每次上报都带上它当时全部的池，因此只出现在更早上报里的池是历史（换过套餐、下线的模型额度），不是第二个在用的池。`/v2/quotas` 的每条账户带 `current`：最近一次上报里出现、且至少一个窗口未过期时为 true。历史行保留不删，菜单和 Hub 首页只画 `current` 的池。
- 菜单里的额度：窗口按时长升序，已滚过去的窗口不画（过期数值既不是 0 也不是满，画出来只会误导）；多池并存时池名走一行小标题，用服务端的 `limit_name`，没有可读名就叫「订阅额度」——`limit_id` 是内部键，不进界面。底下一行给的是观测时间（「3h12m 前观测到」），因为数值是最近一次本地观测，不是刚查的账户。
- 首次索引期间展示扫描进度；大行支持至 64 MB，超限/坏 JSON/无法归属的累计基线显示覆盖缺口。文件截断/替换重建对应来源。
- Claude 子 agent 记录的消耗计入父会话，但子 agent 记录不会替换父会话的对话内容。
- Claude 按 requestId + message.id 去重；复制记录只计一次，归属冲突标 `ownershipAmbiguousRequests`。这类会话分摊仍有不确定性，账户总量不会重复计入。
- Codex 使用累计 counter 差值，忽略重复快照。输入中的 cached token 不重复相加；推理 token 已包含在输出中。无明确继承边界的 fork 不计作新增消耗，公开缺口原因。
- 日/月按请求发生时间与时区聚合。UI 使用本机时区，API 可指定 `timezone`。范围仅已配置本地记录，不含其他电脑或云端未落地数据。
- 价格表 `config/monitor-pricing.json` 打包并在初次启动复制到数据目录 `pricing.json`。按精确 model ID、缓存读写与 TTL 计算当前 API 等值 USD；未知模型、无法确定的计费项独立计为未定价。它不是历史账单，也不是订阅实际扣费。
- 价格来源：[OpenAI](https://developers.openai.com/api/docs/pricing)、[Anthropic](https://platform.claude.com/docs/en/about-claude/pricing)。表版本为 2026-09-12。长上下文超出已配置阈值时保守标未定价。

可在数据目录 `settings.json` 增加记录根：

```json
{"roots":[{"provider":"claude","path":"/absolute/history/projects","profile":"/absolute/profile"}]}
```

附加记录根用于历史统计，不自动给其他 profile 建立进程控制连接。Cowork 默认不纳入 Claude Code 会话。

## 操作通道与边界

| 操作/目标 | 本版实现 |
|---|---|
| Claude 活跃 CLI 或共享 Code 引擎，声明 peerProtocol 1 且有 inbox | Unix socket peer 消息；验证 registry procStart、当前 PID 出生时间、socket owner 与 peer PID；遵循原会话接收策略 |
| 回复送达 | 持久 idempotencyKey；先 `dispatching`，写 socket 后 `unconfirmed`，目标 transcript 出现相同 UUID 才 `delivered`。不会盲目重发 |
| GestureApprove 接管的真实挂起审批 | 精确匹配 profile/provider/session/request ID，只能允许或拒绝当前请求。过期返回 `STALE_APPROVAL` |
| 多个并发审批 | 现有卡片仍是单请求。第二条交回原客户端，不自动拒绝；Hub 不宣称它是已接管请求 |
| Codex 已有 Desktop/CLI 会话回复 | 本版未接入拥有该会话的原生 app-server，因此 `OWNER_NOT_CONNECTED`。不新建 server 冒充原会话控制，也不编辑记录注入消息 |
| 未声明 peerProtocol 1 / 无 inbox | `VERSION_UNSUPPORTED`（协议未验证，不代表引擎版本不兼容） / `MESSAGING_DISABLED` |
| 原生 steer、enqueue、interrupt、resume、结构化问答、UI 回复 | 本版未实现控制适配器；逐项返回明确原因，不显示为可用 |
| 云端会话 / 其他机器 | 未连接；本机覆盖报告明确排除 |

已实现的回复是 peer 消息，不伪装成人类审批。应用启动、CLI 在线与数据库可读，都不足以证明某个操作可执行。运行代次变化返回 `STALE_RUN`；socket 目标无法验证返回 `TARGET_UNVERIFIED`。

## API

全部 `/v2/*` 使用现有 `Authorization: Bearer <Hub token>`，沿用现有 Hub LAN 设置。

- `GET /v2/quotas`
- `GET /v2/usage?period=day|month|all&session=<完整会话键>&timezone=Asia/Bangkok`
- `GET /v2/sessions?limit=200`（上限 1000）
- `GET /v2/messages?session=<完整会话键>`（最近 2 MB 中的最多 80 条文本，省略工具载荷）
- `GET /v2/events?since=<持久游标>`（分页拉取；包含 latestCursor）
- `POST /v2/actions` / `GET /v2/actions?id=<幂等 UUID>`
- `GET /v2/collectors`（每家采集器的 present / state / collecting / needsRepair）
- `POST /v2/install`（仅 loopback）；可选 body `{"providers":["claude"],"uninstall":false}`，省略 providers = 对每一家表态。返回每家一行结果，整体 `ok=false` 时其余各家的成功结果照常返回

回复示例：
```json
{"action":"reply","sessionId":"claude:<profile-hash>:<uuid>","expectedRunId":"<sessions返回值>","idempotencyKey":"<新UUID>","text":"继续处理"}
```
审批示例：
```json
{"action":"approve","sessionId":"<完整会话键>","requestId":"<pendingApproval.id>","idempotencyKey":"<新UUID>","decision":"deny"}
```

## 验证

```sh
bash GestureApprove/Tests/MonitorTests/run.sh
swift build --package-path GestureApprove --product GestureApprove -c debug
bash GestureApprove/build_app.sh
```

回归覆盖：流式/复制去重、Codex 累计差值和继承缺口、缓存 TTL 计价、过期额度、历史额度池不计入当前、全部窗口过期的池不计入当前、重复重绘不刷新、过时 Codex 动态、跨 provider 审批拒绝、运行代次验证、幂等冲突、5 MB JSONL 大行、配置重复安装与原样恢复。

实机验证：原 Claude 测试会话下发 5h/7d 额度 88%/88%，与客户端底栏一致；Hub inbox 回复被同 UUID 写入原 transcript，返回 delivered，原会话答复 `GA_INBOX_CONFIRMED`。桌面页面、提供商过滤、会话 Token 详情及不可回复原因已检验。390px 手机页面修复长标题溢出，页面宽度为 390px。

操作持久化失败时返回 `PERSISTENCE_UNAVAILABLE`，不会先发送再补日志。`dispatching` 使用唯一插入保护跨进程竞态；结果写入失败也不会自动重发。回归测试通过只读 SQLite 故障注入验证该行为。

最终安装后，真实审批 HTTP 链路的模拟请求验证通过：错误会话不能裁决；准确匹配请求的拒绝操作返回 delivered；原 `/approve` 等待连接收到 deny；重复提交幂等、已完成请求的新提交返回 STALE_APPROVAL。该测试仅发送描述性模拟载荷，没有执行其中的命令。

2026-09-12 Claude 兼容修复：采集 registry 的 peerProtocol/peerFeatures；按明确声明的 peerProtocol 1 接入，替换仅接受引擎 2.1.269 的白名单。缺失或未知协议仍拒绝；清空缺失的 socket/协议元数据，避免沿用旧注册信息。
进程出生时间统一使用 `LC_ALL=C TZ=UTC`，与 Claude registry 一致；不再复用旧的本地时区字符串。协议与时区均增加回归检查。
实机回归：独立 Claude 2.1.261 会话通过已安装 GA 的 POST /v2/actions 接收消息，原 transcript UUID 与 action ID 一致；GET /v2/actions 返回 delivered，原模型回复 GA_PEER_V1_CONFIRMED。原有五个版本 2.1.259/261/263/265/267 的活跃会话均已公开 reply.available=true；未向用户原有业务会话发送测试消息。31 项回归通过。
