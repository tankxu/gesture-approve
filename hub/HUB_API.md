# Claude Session Hub — API 对接文档(给 ESP32 / 客户端)

一个跑在 Mac 上的本地服务(**GestureApprove 内置,Swift 原生**,零外部依赖),把本机的 Claude Code 会话
暴露成 HTTP API:**看会话列表、看聊天记录、语音转写(ASR)、回复注入**。设备(ESP32)
通过局域网 HTTP 调用即可,**不需要 HTTPS/TLS**(secure-context 那套只限浏览器;设备直接 HTTP+token)。

参考实现:`hub/demo.html`(浏览器版"虚拟设备",演示各端点用法 + WAV 编码)。

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
当前**正在运行**的会话列表(hub 只列活进程)。
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
    "updatedAt": 1783880154558,
    "webUrl": "https://claude.ai/code/session_019fHjasvYEAFxWCfVfpdJog"  // 无 bridge 时为 null
  }
]}
```
字段要点:
- **`webUrl` / `bridgeSessionId`**:非 null ⇒ 该会话**可回复**(有 claude.ai share link);null ⇒ **只读**(桌面原生会话等)。设备端应据此区分"可回复/只读"。
- **`state`**:`active`=模型在跑;`tool`=在用工具;`wait`=在等你回答;`done`=已结束一轮;`""`=未知。
- **`waitingForUser`**:该会话最后调了 `AskUserQuestion` 且未被回答(1h 内)。用来提示"该你出手了"。
- **`title`**:优先 aiTitle(= claude.ai 里显示的标题);没有则退回首条用户消息;再没有用派生名。

### GET /pending
同 `/sessions` 结构,但只含 `waitingForUser=true` 的会话(方便设备只显示"等你答的")。

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
约束/说明:
- **仅对有 `webUrl`/`bridgeSessionId` 的会话有效**;只读会话 → `400 缺 bridgeSessionId`。
- 需要 Mac 上有**已登录 claude.ai 的 Chrome**;hub 会自动导航到对应会话页再注入。
- 有几秒延迟(导航+等输入框渲染+点发送)。`sent:false` 且 `sendResult:"disabled"` 表示发送按钮那一刻还没就绪,重试即可。
- 计费:落在交互式 claude.ai 会话 = **订阅**,不是 API 按量。

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
16kHz 单声道 16-bit,采样数据前拼 44 字节头即可(参考 `demo.html` 的 `encodeWav`):
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
