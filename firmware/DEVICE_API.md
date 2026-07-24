# GestureApprove 设备审批 API —— ESP32 对接文档

让 ESP32(或任何联网设备)通过 HTTP 远程处理审批：监听 Mac 上出现的待审批命令，
在设备上按键 **通过 / 拒绝**，效果与在电脑上比手势、按热键、点卡片完全等价（谁先响应谁生效）。

> 本文档描述 Mac 端已实现并验证的 API 契约。ESP32 固件按此实现即可。

---

## 0. 连接信息（本机当前值）

| 项 | 值 |
|---|---|
| Mac 局域网 IP | `192.168.2.10`（en0；DHCP 可能变，见 §6） |
| 设备口端口 | `47602` |
| Base URL | `http://192.168.2.10:47602` |
| Bearer token | `<YOUR_DEVICE_TOKEN>` |
| 前置条件 | Mac 与 ESP32 在**同一 Wi-Fi**；GestureApprove 设置里「远程审批设备」开关为**开** |

**每个请求都必须带认证头**：

```
Authorization: Bearer <YOUR_DEVICE_TOKEN>
```

缺失或错误 → `401 {"error":"unauthorized"}`。

> token 在 GestureApprove 设置窗「远程审批设备」一节可见（带复制按钮）。换机器/重置后 token 会变，做成可配置项别写死。

---

## 1. 两个端点

### 1.1 监听审批动态（下行）—— 长轮询

```
GET /state?since=<version>&wait=<seconds>
```

- `since`：设备**上次收到的 version**。首次用 `since=0`。
- `wait`：最长挂起秒数，服务端夹在 `[0, 60]`，缺省 25。
  - 若服务端 version 已比 `since` 新 → **立即返回**当前状态；
  - 否则**挂起连接**，直到状态变化（出现待审批 / 被解决 / 超时）或 `wait` 秒到，再返回当前状态；
  - `wait=0` → 只查一次不挂起（一次性读当前态）。

**返回：有待审批**

```json
{
  "version": 7,
  "state": "pending",
  "id": "9D2CF474",
  "operation": "Bash: rm -rf /tmp/build",
  "tool": "Bash",
  "cwd": "/Users/tank/proj",
  "deadline_ms": 87919,
  "dangerous": true
}
```

**返回：空闲**（没有待审批，或刚刚被解决/超时）

```json
{ "version": 8, "state": "idle" }
```

字段说明：

| 字段 | 含义 |
|---|---|
| `version` | 单调递增游标。**存下来**，下次请求作为 `since`。 |
| `state` | `"pending"` 或 `"idle"`。 |
| `id` | 本次审批的一次性标识。裁决时必须原样带回。 |
| `operation` | 待审批的完整操作串（可能很长、含换行，别截断判断）。 |
| `tool` | 工具名（`Bash` / `Edit` / `Write` 等），适合做标题。 |
| `cwd` | 发起项目的工作目录，可空。 |
| `deadline_ms` | 距该审批超时的**剩余毫秒**（初始约 90000）。到点服务端自动置回 idle。 |
| `dangerous` | 是否命中危险命令 deny-list（`true` 建议 UI 上红色警示）。 |

### 1.2 提交裁决（上行）

```
POST /resolve
Content-Type: application/json

{ "id": "9D2CF474", "decision": "allow" }
```

`decision` 取 `"allow"` 或 `"deny"`。

| 返回 | 含义 |
|---|---|
| `200 {"ok":true,"reason":"applied"}` | 生效。电脑上的手势卡随之通过/拒绝并收起。 |
| `409 {"ok":false,"reason":"no matching pending approval"}` | **id 不匹配当前待审批**——那条已被别人（手势/热键/超时）解决，或已换了新的一条。清屏、重新轮询即可。 |
| `400 {"ok":false,"error":"decision must be allow|deny"}` | decision 非法。 |
| `401 {"error":"unauthorized"}` | token 错。 |

> **`id` 校验是关键**：设备按键时那条审批可能已经被解决、并换上了新的一条。带 `id` 能防止旧按键误批到新命令上。收到 409 属正常，不是错误。

---

## 2. 推荐的设备主循环

```
version = 0
loop:
    resp = GET /state?since=version&wait=25      # 阻塞最多 25s
    if 网络错误 / 超时:
        显示「离线」; 退避 2s; continue
    version = resp.version                        # 永远更新游标
    if resp.state == "pending":
        显示 resp.operation / tool / dangerous / 倒计时(deadline_ms)
        # 等用户按键（下面 §3 并发处理）
    else:
        清屏，回到待机
```

- **长轮询让通知近乎实时**，平时不产生流量。`wait=25` 时，把 HTTP 客户端读超时设为 **>wait**（如 30s），否则会在服务端返回前自己先超时。
- 服务端每次响应后 `Connection: close`，即每次都是独立请求，ESP32 无需保持长连接。
- **version 游标不怕丢事件**：设备断线重连后带着旧 `version` 一问，立刻对齐到最新状态，不会漏掉一次。

---

## 3. 按键与裁决

用户在 pending 期间按「通过 / 拒绝」→ 立刻 `POST /resolve` 带当前 `id`：

- 成功(200)：清屏，继续轮询（下一轮会看到 idle）。
- 409：说明这条已被别处解决/超时——清屏即可，别报错。
- 建议：并发跑一个短 `wait=0` 的状态检查或让主轮询继续，一旦 `id` 变化或转 idle 就撤掉按键界面（这条被别人抢先解决了）。

---

## 4. Arduino 参考骨架（ESP32 core）

依赖：`WiFi.h`、`HTTPClient.h`、`ArduinoJson`（v6）。

```cpp
#include <WiFi.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>

const char* WIFI_SSID = "你的Wi-Fi";
const char* WIFI_PASS = "密码";
const char* BASE      = "http://192.168.2.10:47602";
const char* TOKEN     = "<YOUR_DEVICE_TOKEN>";

const int PIN_ALLOW = 12;   // 通过按钮
const int PIN_DENY  = 14;   // 拒绝按钮

uint32_t version = 0;
String    pendingId = "";

void setup() {
  Serial.begin(115200);
  pinMode(PIN_ALLOW, INPUT_PULLUP);
  pinMode(PIN_DENY,  INPUT_PULLUP);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  while (WiFi.status() != WL_CONNECTED) { delay(300); }
}

// 长轮询一次；更新 version 与 pendingId
void pollState() {
  HTTPClient http;
  String url = String(BASE) + "/state?since=" + version + "&wait=25";
  http.begin(url);
  http.addHeader("Authorization", String("Bearer ") + TOKEN);
  http.setTimeout(30000);                        // > wait(25s)
  int code = http.GET();
  if (code == 200) {
    StaticJsonDocument<2048> doc;                // operation 可能很长，按需加大
    if (!deserializeJson(doc, http.getString())) {
      version = doc["version"] | version;
      if (String(doc["state"] | "") == "pending") {
        pendingId = String((const char*)(doc["id"] | ""));
        showPending(doc["tool"] | "", doc["operation"] | "",
                    doc["dangerous"] | false, doc["deadline_ms"] | 0);
      } else {
        pendingId = "";
        showIdle();
      }
    }
  } else {
    showOffline();                               // 401 / 连接失败 / 超时
    delay(2000);
  }
  http.end();
}

// 提交裁决；返回是否生效
bool resolve(const String& decision) {
  if (pendingId == "") return false;
  HTTPClient http;
  http.begin(String(BASE) + "/resolve");
  http.addHeader("Authorization", String("Bearer ") + TOKEN);
  http.addHeader("Content-Type", "application/json");
  http.setTimeout(8000);
  String body = String("{\"id\":\"") + pendingId + "\",\"decision\":\"" + decision + "\"}";
  int code = http.POST(body);
  bool ok = (code == 200);                        // 409 = 已被别处解决，属正常
  http.end();
  if (ok) { pendingId = ""; showIdle(); }
  return ok;
}

void loop() {
  // 有待审批且按下按钮 -> 裁决
  if (pendingId != "") {
    if (digitalRead(PIN_ALLOW) == LOW) { resolve("allow"); delay(200); return; }
    if (digitalRead(PIN_DENY)  == LOW) { resolve("deny");  delay(200); return; }
  }
  pollState();   // 阻塞最多 ~25s；期间可用中断/双核处理按键以求更跟手
}

// 下面按你的屏幕/LED 实现：
void showPending(const char* tool, const char* op, bool danger, long deadlineMs) {}
void showIdle() {}
void showOffline() {}
```

> 提示：`pollState()` 会阻塞最多 ~25s。想让按键更跟手，可把长轮询放到一个 FreeRTOS 任务/另一个核，按键在主循环即时响应；或把 `wait` 调小（如 5s）用轮询间隔换取按键响应，代价是稍多请求。

---

## 5. 重要行为与约束

- **单待审批模型**：Mac 端同一时刻只处理**一个**审批。多个来源（多个 CLI 会话）并发时，后到的会被直接拒绝——设备端始终只会看到"当前那一个"。
- **抢答**：设备的裁决与电脑手势/热键/点击竞争，先到者生效，晚到者拿 409。
- **超时**：审批约 90s 无人处理会自动超时（`deadline_ms` 归零、state 转 idle，交回终端正常审批）。设备到点应自动清屏。
- **安全**：命令内容以**明文**经局域网传输，仅在可信网络使用。token 是唯一门禁，别泄露、别写进公开仓库。hook 本地口（47600）不对外，设备只用 47602。

---

## 6. IP 会变怎么办

`192.168.2.10` 是当前 DHCP 分配值，重启路由/换网可能变。三选一：

1. 给 Mac 设**静态/保留 IP**（路由器里按 MAC 绑定），最省事。
2. ESP32 端把 IP 做成**可配置**（AP 配网页 / 串口设置 / NVS 存储）。
3. （待 Mac 端支持）mDNS/Bonjour 发现——目前 app 尚未广播 `_gestureapprove._tcp`，需要的话可以加，ESP32 用 `ESPmDNS` 按名字解析。

---

## 7. 快速自测（不用 ESP32）

Mac 上直接 curl（token 换成你的）：

```bash
TOKEN=<YOUR_DEVICE_TOKEN>
BASE=http://192.168.2.10:47602

# 读当前状态（首次 since=0 立即返回）
curl -s "$BASE/state?since=0&wait=0" -H "Authorization: Bearer $TOKEN"

# 长轮询等下一次变化（最多 25s）
curl -s "$BASE/state?since=1&wait=25" -H "Authorization: Bearer $TOKEN"

# 裁决（id 换成 /state 拿到的）
curl -s "$BASE/resolve" -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" -d '{"id":"XXXX","decision":"allow"}'
```

想产生一条待审批做测试：点 GestureApprove 菜单栏「测试审批卡片」，它会立即出现在 `/state` 里，
可在设备/curl 端裁决（这条路径不需要打开全局「审批拦截」，不会干扰其它会话）。
仓库里 `GestureApprove/`（scratchpad 的 `gesture-monitor/monitor.py`）还有一个网页版监控器可参考交互。
