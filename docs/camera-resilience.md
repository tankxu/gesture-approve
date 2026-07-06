# 摄像头保活 / 看门狗 / 唤醒恢复策略

> 改动摄像头采集、睡眠/锁屏处理前先读这份。记录的是"**为什么这么设计**",代码里只有"怎么做"。

## 1. 要解决的根问题：会话静默失效

`AVCaptureSession` 会出现一种**没有任何报错**的失效：`session.isRunning` 仍为 `true`，但**不再吐 sample buffer**。审批卡的画面靠帧驱动（`CameraFrameSource.captureOutput` → `GestureEngine.submit` → `previewImage`），帧一停，刘海卡片就变纯黑、手势也识别不了，且**不会自愈**——以前只能重启 App。

两个已知触发源，机制相同：

- **USB 采集卡打嗝**（如 AVerMedia PW310）：USB 带宽/供电抖动后停吐帧。偶发，所以表现为"隔断时间就黑一次"。
- **系统睡眠 / 锁屏**：系统挂起复用的 capture session，唤醒后它经常回不到吐帧状态。

> 判断依据：日志 `/tmp/gestureapprove.log` 里出现黑屏时**没有** `运行时错误` / `被中断` 记录 —— 说明是静默失效，不是被捕获的报错。所以光靠 `AVCaptureSessionRuntimeError` 观察者救不了。

关键放大因素：`CameraFrameSource` 的 `session` 是**跨审批复用**的（`configured` 只配置一次，`start/stop` 只切运行状态，避免每次审批重建去抢占设备 / 第二次拿不到画面）。复用 = 一旦坏掉就一直坏。

## 2. 设计取舍：为什么不做"唤醒预热"

> 曾经试过"解锁就主动把摄像头拉起来预热"，**失败了**，这里记下来免得有人再走一遍。

USB 采集卡（AVerMedia 等）有个绕不过的物理事实：**`startRunning` 到吐出第一帧要约 2 秒**（设备启动视频流的固有 warm-up，日志可见 `camera 使用 …` 到收到首帧间隔 ~2s）。

"预热"的想法是解锁后先开摄像头、拿到帧、再 `stopRunning` 关掉，让首次审批秒开。但它**解决不了问题**：预热以 `stopRunning` 收尾，审批时还得重新 `startRunning` → 又要重等这 2 秒。预热唯一能省的是"重新枚举"的时间，省不掉首帧 warm-up。而要真正省掉，就得让摄像头**保持运行**（画面一直在流）——代价是解锁后摄像头指示灯长亮，隐私/观感不可接受。

**结论（产品决策）**：接受唤醒后首次审批 ~2s 延迟（USB 设备物理启动时间），不主动开摄像头、不无故亮灯。保证的是"**用对设备**"而不是"零延迟"。

**遮丑手法（v0.7.11）**：暖机延迟消除不了，但可以不让用户盯着黑卡片看——`requestApproval` 先 `source.start()` 开摄像头，卡片**等首帧到达才弹出**（监听 `engine.$previewImage` 首个非 nil，封顶 `cardShowCap`=2s 兜底强制弹出），弹出即有画面。内置 FaceTime 实测首帧 ~1.4s，都在封顶内。倒计时从请求起算；快捷键 ⌃⇧Y/⌃⇧N **卡片弹出后才生效**（看不见卡片就能批掉，怪且易误按——`resolveByHotkey` guard `cardShown`）。日志每次审批记一条 `card 弹出(首帧/封顶 +X.XXs)` 可核对。

## 3. 两条防线（互补，别只留一个）

### 防线一：唤醒/解锁时懒重建（不亮灯）

和**已有的 `ApprovalServer.restart()` 对称**——网络监听 `NWListener` 睡眠期间会静默失效，所以 `main.swift` 在 `didWake` / `screenIsUnlocked` 里 `server?.restart()`。摄像头是同一类问题，并排加 `controller.handleSystemWake()`：

```
case "com.apple.screenIsUnlocked":  server?.restart(); controller.handleSystemWake()
case didWake:    asleep=false;      server?.restart(); controller.handleSystemWake()
```

`handleSystemWake()` 按**当前选中的视频源**（`VideoInputs.savedOrDefaultID()`，见下节"用对设备"）：

- 选 ESP32 → `primeESP32()`，不碰摄像头；
- 选摄像头 → 把 `cameraSource` 对齐到选定设备后 `invalidate()`（拆掉睡眠期失效的会话、置 `configured=false`，**不重新启动、不亮灯**）。下次审批 `start()` 自然重新配置。

### 防线二：审批期间帧看门狗（把会话推到能吐帧）

`CameraFrameSource` 在审批期间（`active`）每 `watchdogInterval`(0.8s) 自检，两种情况都管：

- **设备还没枚举回来（`!configured`）**：USB 唤醒慢，`configureIfNeeded` 严格找选定设备会暂时失败 → 看门狗持续 `rebuild()` 重试，直到设备枚举回来、配置成功、`startRunning`。
- **已配置但无新帧**：用动态阈值——**还没出过首帧**用 `firstFrameGrace`(3.0s，必须 > USB 首帧 ~2s，否则看门狗会在首帧到达前就重建、陷入死循环)；**出过帧后断流**（USB 运行中打嗝、睡眠静默失效）用 `staleThreshold`(1.5s) 快速恢复。`deliveredFrame` 标志区分两者，在 `captureOutput` 里置位。

另外 `AVCaptureSessionRuntimeError` → 触发 `rebuild()`；`AVCaptureSessionInterruptionEnded` → 重新 `startRunning`（有报错的失效，顺手接住）。

**两条防线职责**：懒重建负责"唤醒后用对设备、不亮灯"，看门狗负责"把会话从未就绪/卡死推到能吐帧"。唤醒后首次审批的 ~2s 是设备物理启动，两条防线都不试图消除它（见上节决策）。

### 用对设备（这是反复踩坑的地方）

**读取选择只有一个口径：`VideoInputs.savedOrDefaultID()`**（坚持用户保存的选择，不回退）。`requestApproval`、`handleSystemWake`、设置窗都用它，否则各处用不同 id 会互相重建打架。曾经存在一个带回退的 `currentID()`（选定设备不在列表就回退内置）给设置窗用——结果 USB 被拔掉后，设置窗显示 FaceTime、预览有画面，持久值却还是死设备，审批黑屏，用户完全无从排查（2026-07 真实事故）。**别再引入第二个带回退的读取函数**；设置窗对失效设备的表达是插入"⚠️ 已断开"占位项 + 预览区提示文案。

`configureIfNeeded` 对选定设备缺席分两段处理（`missingSince` 计时，跨审批保留）：

- **缺席 ≤ `fallbackGrace`(4s)**：视为"唤醒后还没枚举完"，严格等它，**不 fallback**——立即回退会在唤醒瞬间把选定的 AVerMedia 误判成"不存在"而错开 FaceTime（还识别不准）。
- **缺席 > `fallbackGrace`**：判为**被永久拔掉**，**临时**回退到默认设备（`VideoInputs.preferredDefaultDevice()`，内置优先）让审批有画面。**不改写用户保存的选择**；看门狗每拍探测选定设备，插回即 `rebuild()` 切回（`start()` 时也检查一次）。`handleSystemWake` → `invalidate()` 发现设备缺席就提前起算 `missingSince`，"睡眠期间被拔走"时首次审批不用再黑等满宽限期。

> 曾经的取舍是"永久拔掉就一直黑屏（宁可黑也不用错设备）"——实际后果：审批功能整体瘫痪、无任何指示，用户以为摄像头坏了。教训：**"用对设备"靠宽限期就能保住，不需要无限死等。**

## 3.5 垂直视野最大化（方形格式）

内置 FaceTime 的默认 16:9 (1920x1080) 是从近方形传感器**裁切**的横条，上下——尤其手所在的下方——被切掉。`CameraFrameSource.tallFormat(for:)` 选 min(宽,高) 最大的横向/方形格式（本机 FaceTime HD 有 1552x1552，垂直视野 +44%），手放键盘附近也能入框；只有 16:9 的设备（OBS/Camo/采集卡）自动跳过。审批采集与设置窗预览都应用，取景一致。

**macOS 的坑（实测踩出来的，别回退）**：`activeFormat` 在 begin/commitConfiguration 事务内设置会被 sessionPreset 在 startRunning 时**打回 16:9**——`.high`、`.photo` 都压不住（iOS 的 `.inputPriority` 在 macOS 不存在）。唯一有效时机是 **startRunning 之后**再 lock+设置（`startSessionEnforcingTallFormat()`）。每次审批的 `camera 首帧 WxH` 日志就是核对项：出现 1920x1080 即回归。

## 4. 改代码时务必守住的安全点

- **`invalidate()` 里的 `guard !active`**：唤醒那一刻若正好有审批卡开着（罕见），**绝不**碰当前正在用的会话——交给看门狗处理。懒重建只在空闲时动手。
- **首帧宽限 `firstFrameGrace` 必须 > USB 首帧延迟**：USB 采集卡 `startRunning` 到首帧 ~2s，若看门狗用 `staleThreshold`(1.5s) 判它，会在首帧到达前就重建 → 重建后又 2s → **死循环永远拿不到帧**。所以"还没出过首帧"用 3.0s 宽限，"出过帧后断流"才用 1.5s。`deliveredFrame` 在 `captureOutput` 置位来区分。
- **看门狗要处理 `!configured`**：唤醒后设备没枚举回来时 `configureIfNeeded` 严格失败（`configured=false`），看门狗必须在这种状态下也 `rebuild()` 重试，否则会干等、永不重配。
- **用对设备**：实际打开设备走 `savedOrDefaultID()`（不回退）；`configureIfNeeded` 宽限期内严格等选定设备，超过 `fallbackGrace` 才临时回退且不写回持久选择。详见上节"用对设备"。
- **所有 session 操作串行在 `CameraFrameSource.queue` 上**：`start/stop/invalidate/rebuild/teardownIO`、`captureOutput`、看门狗回调都在这条 queue。`lastFrameAt`/`deliveredFrame` 因此无需加锁。通知观察者回调在任意线程，所以它们都先 `queue.async` 再碰状态。
- **观察者只注册一次**（`observersAdded` 标志）：`rebuild()` 复用同一个 `session` 实例（`let`，只拆/换 input/output），不能每次重配都重挂观察者，否则回调重复触发。
- **看门狗只在 `active` 时空转**：`stop()` 置 `active=false`，下一拍看门狗自然退出，不会平时空跑耗电。
- **睡眠/锁屏时本就不弹卡**：`ApprovalServer` 回调里 `systemSuspended`(=`screenLocked || asleep`) 为真时直接 `reply("ask")` 回退终端，所以那段时间摄像头不会开。

## 5. 关键参数与代码位置

| 参数 | 值 | 含义 |
|---|---|---|
| `staleThreshold` | 1.5s | 已出过首帧后，多久没新帧判为卡死并重建 |
| `firstFrameGrace` | 3.0s | 刚启动还没出首帧时的宽限（必须 > USB 首帧 ~2s，否则死循环） |
| `watchdogInterval` | 0.8s | 看门狗自检周期 |
| `fallbackGrace` | 4.0s | 选定设备缺席多久判为"已拔掉"、临时回退默认设备（必须 > USB 唤醒重枚举 ~2s） |

- `CameraFrameSource`（看门狗 / `invalidate` / `rebuild` / `teardownIO`）：`GestureApprove/Sources/GestureApprove/FrameSource.swift`
- `ApprovalController.handleSystemWake()`：`GestureApprove/Sources/GestureApprove/OverlayController.swift`
- 睡眠/锁屏/唤醒事件分发、`screenLocked` 实时查询：`GestureApprove/Sources/GestureApprove/main.swift`（`onSystemEvent` / `observeSystemState`）
- 网络监听的同类自愈（参考对称设计）：`GestureApprove/Sources/GestureApprove/ApprovalServer.swift`（`restart()`）

## 6. 怎么验证

看日志：

```
grep -E "系统事件|camera |看门狗|选定设备" /tmp/gestureapprove.log
```

- 唤醒后第一次审批，应只见 `camera 使用 <你选的设备>`，不该出现没选的设备——唯一例外是缺席超宽限后的 `camera 使用 …（临时回退）`，且它前面必有一条 `判为已拔出，临时回退`。
- `camera 选定设备未就绪(等待枚举)` = USB 还在重新枚举，看门狗在等它回来，属正常过渡（只记一次，不再刷屏）。
- `camera 选定设备缺席超 4s，判为已拔出，临时回退 <默认设备>` = 设备被拔走，审批临时用默认设备。
- `camera 选定设备已回归 <设备>` = 插回后自动切回了用户选择。
- `camera 看门狗：…s 无新帧，重建会话` = 接住了一次卡死/未就绪并救回。
- 唤醒后首次审批画面晚 ~2s 出现是**预期**（USB 设备物理启动时间，见第 2 节决策），不是 bug。
