# Claude Session Hub — API 对接文档(给 ESP32 / 客户端)

一个跑在 Mac 上的本地服务(**GestureApprove 内置,Swift 原生**,零外部依赖),把本机的 Claude Code 会话
暴露成 HTTP API:**看会话列表、看聊天记录、语音转写(ASR)、回复注入**。设备(ESP32)
通过局域网 HTTP 调用即可,**不需要 HTTPS/TLS**(secure-context 那套只限浏览器;设备直接 HTTP+token)。

参考实现:`hub/app.html`(Hub 首页,演示各端点用法 + WAV 编码)。
它的取数方式也是推荐做法:**`/sessions` 当主源**(离线可用、全量),`/cloud/sessions` 拿到就合并
(补桌面 app 的会话与未读状态),拿不到只在状态栏提一句、不影响列表。

---

## 0. 连接信息(本机当前值)

| 项 | 值 |
|---|---|
| Base URL | `http://192.168.2.106:8787`(Mac 局域网 IP,DHCP 可能变,见下) |
| 绑定 | `0.0.0.0:8787`(局域网可达) |
| 认证 | `Authorization: Bearer <token>`(除 `/health` 外所有端点必带) |
| token | `<YOUR_HUB_TOKEN>` |
| token 来源 | `~/.claude-session-hub/config.json` 的 `token` 字段(hub 启动日志也会打印) |

- **IP 会变**:探活用 `GET /health`(免认证);IP 做成可配置,或给 Mac 设静态 IP。
- 前提:设备与 Mac 同一 Wi-Fi;hub 随 GestureApprove 运行(菜单栏 →「远程 Hub」;局域网开关在配置页)。

---

## 1. 认证

除 `GET /health` 外,每个请求都要带:

```
Authorization: Bearer <YOUR_HUB_TOKEN>
```

缺失/错误 → `401 {"error":"unauthorized"}`。

---

## 2. 端点

### GET /health  (免认证)
探活。
```json
{ "ok": true, "service": "claude-session-hub" }
```

### GET /sessions
会话列表。**来源是 `~/.claude/projects` 下的 transcript,不是运行时注册表** ——
注册表只登记还活着的进程(本机 6 条),而磁盘上躺着 75 个会话;关掉终端的会话以前就此消失。
现在全都列,注册表退居为"这条还活着吗 / 有没有网页桥"的补充。按最后写入时间倒序。

| 参数 | 默认 | 说明 |
|---|---|---|
| `limit` | 60 | 最多返回几条(按最近写入排序) |
| `alive` | 0 | 1=只要进程还活着的 |

```json
{ "sessions": [
  {
    "sessionId": "db26a1cd-a693-4518-8881-e81eee93ec50",
    "bridgeSessionId": "session_019fHjasvYEAFxWCfVfpdJog",
    "title": "修复Claude审批逻辑切换失效问题",
    "titleSource": "aiTitle",              // aiTitle / firstMsg / name
    "name": "gesture-approve-15",
    "entrypoint": "cli",                    // cli / claude-desktop
    "status": "busy",                       // busy / idle(注册表侧)
    "state": "tool",                        // active / tool / wait / done / ""(见下)
    "waitingForUser": false,                // true = 在等你回答(AskUserQuestion 未答)
    "cwd": "/Users/tank/.../gesture-approve",
    "pid": 12345,
    "alive": true,
    "updatedAt": 1783880154558,          // transcript 最后写入时间(毫秒)
    "webUrl": "https://claude.ai/code/session_019fHjasvYEAFxWCfVfpdJog",  // 无 bridge 时为 null
    "canReply": true                     // 能否 POST /reply(见下)
  }
]}
```
字段要点:
- **`webUrl` / `bridgeSessionId`**:非 null ⇒ 该会话**可回复**(有 claude.ai share link);null ⇒ **只读**(桌面原生会话等)。设备端应据此区分"可回复/只读"。
- **`state`**:`active`=模型在跑;`tool`=在用工具;`wait`=在等你回答;`done`=已结束一轮;`""`=未知。
- **`waitingForUser`**:该会话最后调了 `AskUserQuestion` 且未被回答(1h 内)。用来提示"该你出手了"。
- **`title`**:优先 aiTitle(= claude.ai 里显示的标题);没有则退回**首条真实用户消息**
  (跳过 isMeta、`<environment_context>` 这类信封、`Caveat:` 开场白;斜杠命令拼成 `/命令 参数`);
  再没有才用派生名。`titleSource` 告诉你这次用的是哪个。
- **`canReply`**:`true` = 这条能 `POST /reply`。有 `webUrl` → 走网页注入;没有但进程已退出 → 走
  `claude --resume -p`。**没桥又还开着的会话是唯一回不了的**(不能和终端抢同一份 transcript)。
- **性能**:列表只读每份 transcript 的头 64KB + 尾 256KB,并按文件 mtime 缓存;
  74 个会话首次约 1.1s,之后 0.9s 内返回。

### GET /pending
同 `/sessions` 结构,但只含 `waitingForUser=true` 的会话(方便设备只显示"等你答的")。

### GET /events
**agent 动态流**(Claude Code / Codex 的 `Stop` hook = 跑完一轮;Claude 的 `Notification` hook = 在等你回话)。游标式长轮询,
和 `/state` 一个路子:带上次拿到的 `version` 来问,只回比它新的事件。

| 参数 | 默认 | 说明 |
|---|---|---|
| `since` | 0 | 上次返回的 `version`。**0 = 首次连接**,回最近 `limit` 条历史 |
| `limit` | 20 | 最多回几条(上限 50,即服务端环形缓冲的容量) |
| `wait` | 0 | 0=立即返回快照;>0=挂起最多这么多秒等新事件(上限 60) |
| `plain` | 0 | 1=把 `summary` 里的 markdown 记号洗掉(`**粗体**`、行内代码、表格竖线、列表符号…),折行压平。给只能显示纯文本的客户端用;默认给原文 |

```json
{
  "version": 7,
  "enabled": true,
  "events": [
    { "seq": 7, "id": "F1E2…",
      "kind": "done",                        // done=跑完一轮 · waiting=在等你回话(Claude 的 Notification 事件)
      "source": "claude",                    // claude | codex
      "sessionId": "db26a1cd-…",
      "title": "修复审批逻辑切换失效",      // Claude: aiTitle → 首条真实用户消息 → 项目名
                                             // Codex : state_5.sqlite 的 name/title → 项目名
      "project": "gesture-approve",          // cwd 最后一段
      "cwd": "/Users/tank/LocalDev/gesture-approve",
      "summary": "已经改好并跑通测试:…",     // done: agent 最后那段话(原文 markdown,截断 800 字;见 plain)
                                             // waiting: Claude 给的提示原话,如 "Claude is waiting for your input"
      "webUrl": "https://claude.ai/code/session_019…",   // 无 bridge 时为 null
      "ts": 1786412345678 }
  ]
}
```
- `enabled=false` ⇒ 用户在 GestureApprove 设置里关了「Agent 完成通知」或「推送到远程 Hub」,不会再有新事件。
- 事件按 `seq` 递增(= 该条产生时的 `version`)。**丢事件不怕**:设备断线重连带旧 `version` 一问就补齐;
  超出缓冲(50 条)的旧事件会被丢弃。
- 典型用法:`GET /events?since=<上次version>&wait=25` 循环长轮询;超时空回也照常带最新 `version`。
- 事件只在 Mac 上产生,**桌面系统通知与这条流是同一来源、各自独立开关**。
- `waiting` 只覆盖"Claude 空闲等你回话"这类;**权限询问不会进来**(那是 GA 手势卡片的职责,重复通知没意义)。

### GET /session/&lt;sessionId&gt;/messages
聊天记录(解析本地 transcript)。查询参数:

| 参数 | 默认 | 说明 |
|---|---|---|
| `limit` | 40 | 返回条数 |
| `offset` | 0 | 0=最新一页;增大=往前翻 |
| `max_len` | 4000 | 每条文本最大字符(截断) |
| `include_tools` | 0 | 0=只人类提问+Claude 文字(推荐);1=含 `[工具: X]`/`[工具结果]` 管道 |

```json
{
  "sessionId": "db26a1cd-...",
  "total": 487,
  "offset": 0, "limit": 40,
  "title": "修复Claude审批逻辑切换失效问题",
  "messages": [
    { "role": "user", "text": "……", "ts": "2026-07-13T..." },
    { "role": "assistant", "text": "……", "ts": "..." }
  ]
}
```
消息按时间正序,最新在数组末尾。

### POST /asr
语音转写。**body = 原始音频字节**(不是 multipart),`Content-Type` 指明格式:

| Content-Type | 说明 |
|---|---|
| `audio/wav` | 推荐:16kHz 单声道 16-bit PCM + 44 字节 WAV 头 |
| `audio/m4a` / `audio/mpeg` | 也接受 |

hub 转发到 SiliconFlow SenseVoiceSmall(key 留 Mac),返回:
```json
{ "text": "打开客厅的灯", "model": "FunAudioLLM/SenseVoiceSmall" }
```
出错:`{"error":"...","detail":"..."}`。空/过短音频会被 SiliconFlow 拒(500)。

### POST /reply
把文本注入某会话的 claude.ai 输入框(hub 在 **Mac 上驱动 Chrome** 注入,走订阅计费)。
```json
POST /reply
{ "sessionId": "db26a1cd-...",   // 或直接给 "bridgeSessionId"
  "text": "识别出来的话",
  "send": true }                 // false=只填不发;true=填并点发送
```
返回:
```json
{ "ok": true, "sent": true, "sendResult": "clicked", "readback": "识别出来的话" }
```
**两条通道,自动选**:

| 情况 | 走哪条 | 返回里的 `via` |
|---|---|---|
| 会话有 `webUrl`/`bridgeSessionId` | Chrome 注入 claude.ai 网页(能落进用户正开着的那个会话,他看得见) | 无(旧字段) |
| 没有桥、且**进程已退出** | `claude --resume <id> -p <text>` —— 复用同一会话 id、续写同一份 transcript | `"resume"` |
| 没有桥、但**进程还活着** | 拒绝(`409`) | — |

`--resume` 那条的返回多带一个 **`reply`**:agent 这一轮的回答直接给你,不用再去轮询 transcript。
```json
{ "ok": true, "via": "resume", "sent": true, "sessionId": "8be7e427-…", "reply": "手机来的" }
```
agent 可能真的动手干活(调工具、等审批),所以只同步等 60 秒;超时先回 `{"ok":true,"pending":true}`,
进程继续跑,结果照常由 `Stop` hook 走 `/events` 推出来。

约束/说明:
- **网页通道**需要 Mac 上有已登录 claude.ai 的 Chrome;有几秒延迟(导航+等输入框渲染+点发送)。
  `sent:false` 且 `sendResult:"disabled"` 表示发送按钮那一刻还没就绪,重试即可。
- **resume 通道**为什么要求进程已退出:终端里那个 claude 有自己的内存状态,从外面 resume 会起第二个
  进程写同一份 transcript,两边历史打架,而且本人在终端里看不到这句话。活着的会话 → `409`,
  返回里带 `sessionAlive: true`。
- 会话 id 不存在 → `404`。
- 计费:两条都走**订阅额度**(claude CLI 是 oauth 登录),不是 API 按量;resume 通道还会显式清掉
  `ANTHROPIC_API_KEY` 等环境变量,防止误走按量付费。
- Hub 代发的这一轮**不会在 Mac 上弹桌面横幅**(人不在电脑前),但事件照样进 `/events`。

### （可选,暂缓)GET /ga/state · POST /ga/resolve
代理 GestureApprove 的审批设备 API(手势审批)。当前阶段先不用。

---

## 3. ESP32 典型流程

```
每 3~5s: GET /sessions        → 画列表;waitingForUser=true 的高亮"等你答"
选中会话: GET /session/<id>/messages?limit=20   → 显示最近对话(可选)
按住说话: I2S 录 16k 单声道 PCM → 停 →
         POST /asr (audio/wav, body=WAV字节)     → {"text": "..."}
         屏幕显示识别文本,按键确认 →
         POST /reply {"sessionId":"<id>","text":"<识别文本>","send":true}
                                                  → {"ok":true,"sent":true}
```
- 只对列表里 **`webUrl != null`** 的会话开放"回复";其余标"只读"。
- 全程 HTTP + Bearer token,**不需要 TLS**。

### WAV 头(PCM → wav,不用库)
16kHz 单声道 16-bit,采样数据前拼 44 字节头即可(参考 `app.html` 的 `encodeWav`):
```
RIFF <chunkSize=36+dataLen> WAVE
fmt  <16> <PCM=1> <ch=1> <rate=16000> <byteRate=32000> <blockAlign=2> <bits=16>
data <dataLen> <PCM样本...>
```

---

## 4. curl 速查(token 换成你的)

```bash
BASE=http://192.168.2.106:8787
TOKEN=<YOUR_HUB_TOKEN>
AUTH="Authorization: Bearer $TOKEN"

curl -s "$BASE/health"                                   # 探活(免认证)
curl -s "$BASE/sessions" -H "$AUTH"                      # 会话列表
curl -s "$BASE/pending"  -H "$AUTH"                      # 只看等你答的
curl -s "$BASE/events?since=0&limit=5&plain=1" -H "$AUTH" # agent 动态(最近 5 条,summary 去 markdown)
curl -s "$BASE/events?since=7&wait=25" -H "$AUTH"        # 长轮询等下一条完成
curl -s "$BASE/session/<sessionId>/messages?limit=20" -H "$AUTH"

# 语音转写(先备一个 16k 单声道 wav)
curl -s -X POST "$BASE/asr" -H "$AUTH" \
     -H "Content-Type: audio/wav" --data-binary @clip.wav

# 回复并发送(仅对有 bridge 的会话)
curl -s -X POST "$BASE/reply" -H "$AUTH" -H "Content-Type: application/json" \
     -d '{"sessionId":"<sessionId>","text":"你好","send":true}'
```

---

## 5. Arduino / ESP32 骨架(要点)

```cpp
// 依赖:WiFi.h + HTTPClient.h（+ ArduinoJson 解析返回；I2S 录音）
const char* BASE  = "http://192.168.2.106:8787";
const char* TOKEN = "<YOUR_HUB_TOKEN>";

// 通用带鉴权的 GET/POST：http.addHeader("Authorization", String("Bearer ")+TOKEN);

// 1) 列表：GET /sessions → 解析 sessions[]，画标题 + state + waitingForUser + 是否有 webUrl
// 2) 录音：I2S 采 16k/mono/16bit PCM 到缓冲；停 → 前面拼 44 字节 WAV 头
// 3) ASR：POST /asr，addHeader("Content-Type","audio/wav")，http.POST(wavBytes,len) → 取 "text"
// 4) 回复：POST /reply，body = {"sessionId":..,"text":..,"send":true}（仅 webUrl!=null 的会话）
```
- HTTP client 超时:`/asr`、`/reply` 设 30~45s(ASR 走云、reply 要驱动浏览器)。
- token/IP 做成可配置(NVS / 配网页),别写死。

---

## 6. 已知边界

- **只列运行中的会话**:进程退出的会话不在 `/sessions` 里。
- **只读会话**(`webUrl=null`,如 Claude 桌面 app 里起的会话):能看列表/记录,**不能回复**(本地无 share link,拼不出 claude.ai 地址)。
- **审批检测**:`waitingForUser` 只覆盖 `AskUserQuestion`("Claude 问你问题"),**不覆盖** Edit/Bash 的工具权限审批(那是 Claude Code TUI 的权限门,transcript 里没有)。
- **回复依赖 Mac 的 Chrome**:Mac 上要有登录 claude.ai 的 Chrome,且开启 `View → Developer → Allow JavaScript from Apple Events`。

## V2 本地监控

首页 `/` 与 `/monitor` 提供本地额度、日/月/会话 Token、API 等值、实时会话证据和能力原因。接口返回的 `reason`/`note` 等人读文案只有 zh/en 两套(跟随软件语言,非中文一律英文);`reasonCode` 保持稳定的英文常量。

PWA 外壳资源 `GET /manifest.webmanifest`、`GET /sw.js`、`GET /icons/<name>.png` **免 token**：浏览器取 manifest、注册 service worker、抓图标时都不会带 Authorization 头，挡住就装不上主屏。这三样不含任何用户数据；页面与所有数据接口的鉴权不变。manifest 的 `start_url` 会注入当前 token，主屏图标点开才不会被 403 挡住。

`GET /v2/messages` 回的是**原始文本**，不做任何渲染 —— markdown 交给客户端。消息里的图片不内联：base64 一张截图就 600KB，塞进列表会让手机拉不动，所以只带引用 `images: [{index, mediaType, bytes}]`，字节走 `GET /v2/attachment?session=&message=<uuid>&index=<n>`。该端点只回白名单内的图片类型（png/jpeg/gif/webp），并带长缓存头；因为 `<img>` 发不出 Authorization 头，它额外接受 `?token=`（其余端点不变，仍只认请求头）。

`/v2/quotas`、`/v2/usage`、`/v2/sessions`、`/v2/messages`、`/v2/attachment`、`/v2/events` 与 `/v2/actions` 均要求现有 Bearer token。接口字段、幂等操作和覆盖边界见 [本地监控实现](../docs/local-monitor-implementation.md)。采集安装 `/v2/install` 只允许 loopback。
