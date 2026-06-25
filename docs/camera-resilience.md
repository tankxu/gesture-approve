# 摄像头保活 / 看门狗 / 唤醒恢复策略

> 改动摄像头采集、睡眠/锁屏处理前先读这份。记录的是"**为什么这么设计**",代码里只有"怎么做"。

## 1. 要解决的根问题：会话静默失效

`AVCaptureSession` 会出现一种**没有任何报错**的失效：`session.isRunning` 仍为 `true`，但**不再吐 sample buffer**。审批卡的画面靠帧驱动（`CameraFrameSource.captureOutput` → `GestureEngine.submit` → `previewImage`），帧一停，刘海卡片就变纯黑、手势也识别不了，且**不会自愈**——以前只能重启 App。

两个已知触发源，机制相同：

- **USB 采集卡打嗝**（如 AVerMedia PW310）：USB 带宽/供电抖动后停吐帧。偶发，所以表现为"隔断时间就黑一次"。
- **系统睡眠 / 锁屏**：系统挂起复用的 capture session，唤醒后它经常回不到吐帧状态。

> 判断依据：日志 `/tmp/gestureapprove.log` 里出现黑屏时**没有** `运行时错误` / `被中断` 记录 —— 说明是静默失效，不是被捕获的报错。所以光靠 `AVCaptureSessionRuntimeError` 观察者救不了。

关键放大因素：`CameraFrameSource` 的 `session` 是**跨审批复用**的（`configured` 只配置一次，`start/stop` 只切运行状态，避免每次审批重建去抢占设备 / 第二次拿不到画面）。复用 = 一旦坏掉就一直坏。

## 2. 两层防护（互补，别只留一个）

### 第一层：唤醒/解锁时主动复位（快）

和**已有的 `ApprovalServer.restart()` 完全对称**——网络监听 `NWListener` 睡眠期间会静默失效，所以 `main.swift` 在 `didWake` / `screenIsUnlocked` 里 `server?.restart()`。摄像头是同一类问题，于是并排加了 `controller.handleSystemWake()`：

```
case "com.apple.screenIsUnlocked":  server?.restart(); controller.handleSystemWake()
case didWake:    asleep=false;      server?.restart(); controller.handleSystemWake()
```

`ApprovalController.handleSystemWake()` → `cameraSource.invalidate()`（拆掉输入/输出、`configured=false`，**不立即重建**，下次审批 `start()` 自然重配）+ `esp32Source.prime()`（串口复位，ESP32 原有逻辑）。

效果：**唤醒后第一次审批立刻有画面**，不用等看门狗。

### 第二层：审批期间帧看门狗（稳）

兜住第一层遗漏的情况——最典型的就是**唤醒通知丢失**（长睡眠 / Power Nap 后 `com.apple.screenIsUnlocked` 可能不送达；这也是 `screenLocked` 改成实时查 `CGSession` 而不缓存的原因）。

`CameraFrameSource` 在审批期间（`active`）每 `watchdogInterval`(0.8s) 自检：若距上一帧（`lastFrameAt`，在 `captureOutput` 打点）超过 `staleThreshold`(1.5s)，调 `rebuild()` 重建会话。`rebuild()` = `teardownIO()` + 重置宽限 + `configureIfNeeded()` + `startRunning`。

另外 `AVCaptureSessionRuntimeError` → 触发 `rebuild()`；`AVCaptureSessionInterruptionEnded` → 重新 `startRunning`（这两类是"有报错"的失效，顺手也接住）。

**两层职责**：主动复位负责"快"（唤醒即好），看门狗负责"稳"（任何遗漏都能在 ~1.5s 内自愈）。删任何一层都会留下一个无法自愈的缺口。

## 3. 改代码时务必守住的安全点

- **`invalidate()` 里的 `guard !active`**：唤醒那一刻若正好有审批卡开着（罕见），**绝不**拆当前正在用的会话——交给看门狗处理。主动复位只在空闲时动手。
- **所有 session 操作串行在 `CameraFrameSource.queue` 上**：`start/stop/invalidate/rebuild/teardownIO`、`captureOutput`、看门狗回调都在这条 queue。`lastFrameAt` 因此无需加锁。通知观察者回调在任意线程，所以它们都先 `queue.async` 再碰状态。
- **观察者只注册一次**（`observersAdded` 标志）：`rebuild()` 复用同一个 `session` 实例（`let`，只拆/换 input/output），不能每次重配都重挂观察者，否则回调重复触发。
- **看门狗只在 `active` 时空转**：`stop()` 置 `active=false`，下一拍看门狗自然退出，不会平时空跑耗电。启动时 `lastFrameAt=now()` 给首帧留宽限，避免刚 `start` 就误判卡死。
- **睡眠/锁屏时本就不弹卡**：`ApprovalServer` 回调里 `systemSuspended`(=`screenLocked || asleep`) 为真时直接 `reply("ask")` 回退终端，所以那段时间摄像头不会开——主动复位是为"刚唤醒、还没下一条命令"那一瞬间准备的。

## 4. 关键参数与代码位置

| 参数 | 值 | 含义 |
|---|---|---|
| `staleThreshold` | 1.5s | 多久没新帧判为卡死并重建 |
| `watchdogInterval` | 0.8s | 看门狗自检周期 |

- `CameraFrameSource`（看门狗 / `invalidate` / `rebuild` / `teardownIO`）：`GestureApprove/Sources/GestureApprove/FrameSource.swift`
- `ApprovalController.handleSystemWake()`：`GestureApprove/Sources/GestureApprove/OverlayController.swift`
- 睡眠/锁屏/唤醒事件分发、`screenLocked` 实时查询：`GestureApprove/Sources/GestureApprove/main.swift`（`onSystemEvent` / `observeSystemState`）
- 网络监听的同类自愈（参考对称设计）：`GestureApprove/Sources/GestureApprove/ApprovalServer.swift`（`restart()`）

## 5. 怎么验证

复现是偶发的，别指望立刻触发。看日志即可：

```
grep 看门狗 /tmp/gestureapprove.log
```

- 出现 `camera 看门狗：1.5s 无新帧，重建会话` = **它接住了一次卡死并救回**（以前这种情况就是永久黑屏）。这行出现是"好事"，说明兜底生效。
- 日常不出现这行、画面正常 = 第一层主动复位已经在唤醒时把问题挡掉了。
