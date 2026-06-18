# GestureApprove · 手势审批

Approve or reject **Claude Code / Codex** tool calls with a **hand gesture**. When the AI wants to run something with side effects, a black card slides out from the **notch**; you show a gesture to the camera:

- 👍 **thumbs-up** → allow
- 🖐 **open-palm** → deny
- timeout / app not running / error → **falls back to the normal terminal prompt** (nothing is lost)

A native macOS menu-bar app. Recognition runs on-device. No cloud.

[中文说明见下方](#中文) ↓

---

## How it works

```
AI runs a tool ─► hook (tiny HTTP) ─► GestureApprove.app
                     ▲                     │ notch card + camera
        allow/deny/  │                     ▼ gesture recognition 👍/🖐
        ask ─────────┴───────── verdict ◄── lock gesture / hotkey / click / timeout
```

- **Hook**: a tiny `PreToolUse` (Claude Code) / `PermissionRequest` (Codex) hook POSTs the operation to the app and waits for a verdict. App not running / disabled / timeout → returns `ask` so the terminal handles it normally.
- **App**: menu-bar agent (SwiftUI + AppKit). Shows the notch card, runs the camera + recognition, returns allow/deny.

## Features

- **Two recognition engines** (switchable in Settings):
  - **Apple Vision (built-in, ~44 KB)** — Vision extracts 21 hand keypoints → a tiny Core ML model classifies them. Zero dependencies, robust to lighting/background, camera-tilt tolerant. (Model & training pipeline: [hand-gesture-coreml](https://github.com/tankxu/hand-gesture-coreml).)
  - **MediaPipe (optional, ~300 MB)** — Google's pretrained model, downloadable on demand from Settings.
- **Multiple camera sources**: FaceTime / USB / Continuity / **ESP32-CAM (serial)**. Per-frame **rotation** option; preview is **mirrored** (like a mirror).
- **Respond fast**: gesture, **global hotkeys ⌃⇧Y / ⌃⇧N**, or click the card icons.
- **Auto-allow list**: safe commands (e.g. `ls`, `git status`) pass without a card — editable regex rules.
- **Notch card**: live camera behind "black glass", zooms toward the detected hand, countdown ring, sound + system-notification feedback.
- **6 languages**: English, 简体中文, 日本語, 한국어, Español, Français (follows the system language).
- **Launch at login**, one-click **enable/disable**, in-app **hook install** for Claude Code & Codex.
- **ESP32-CAM** is optional: flash its firmware from inside the app (no PlatformIO needed) and use it as a dedicated approval camera.

## Build & install

Requires macOS 14+ and Xcode (Swift toolchain).

```bash
cd GestureApprove
./install.sh          # build + sign + install to /Applications + launch
```

Then from the menu-bar 👍 icon → **Settings** to pick a camera, choose an engine, and connect Claude Code / Codex. Turn on **Enable approval gating** when you want gestures to actually gate tools.

> The app is signed with a local Apple Development cert and depends on this repo (the Vision model is bundled; MediaPipe/ESP32 paths reference the repo). It is **not** a notarized public distribution.

## Repo layout

| Path | What |
|---|---|
| `GestureApprove/` | The macOS app (SwiftPM). `install.sh` builds + signs + installs. |
| `GestureApprove/Assets/HandGesture.mlmodelc` | Bundled Vision gesture model (~44 KB). |
| `GestureApprove/train/` | Training script + sample landmarks (see also [hand-gesture-coreml](https://github.com/tankxu/hand-gesture-coreml)). |
| `hooks/gesture_hook.py` | Stdlib-only hook bridging Claude Code / Codex to the app. |
| `bridge/` | Optional MediaPipe daemon + ESP32 serial helpers (`setup.sh` installs MediaPipe). |
| `firmware/` | Optional ESP32-CAM firmware + one-click flasher. |
| `config/` | Manual hook config snippets (the app installs hooks automatically). |

## License

MIT (see `LICENSE`). The bundled Vision model derives from [HaGRID](https://github.com/hukenovs/hagrid) (CC BY-SA 4.0).

---

<a name="中文"></a>

# 中文

用**手势**给 **Claude Code / Codex** 的工具调用做审批。AI 要执行有副作用的操作时，屏幕**刘海下方**滑出一张黑色卡片，你对摄像头比手势：

- 👍 **大拇指** → 通过
- 🖐 **张开手掌** → 拒绝
- 超时 / app 没开 / 出错 → **回退到终端正常审批**（不丢任何东西）

原生 macOS 菜单栏 app，识别全程在本机，不上云。

## 原理

```
AI 跑工具 ─► hook(轻量HTTP) ─► GestureApprove.app
               ▲                   │ 刘海卡片 + 摄像头
   allow/deny/ │                   ▼ 手势识别 👍/🖐
   ask ────────┴────── 判定 ◄── 锁定手势 / 热键 / 点击 / 超时
```

- **hook**：极简的 `PreToolUse`(Claude Code) / `PermissionRequest`(Codex) hook，把操作 POST 给 app 等判定。app 没开 / 关闭 / 超时 → 返回 `ask`，交回终端正常处理。
- **app**：菜单栏常驻（SwiftUI + AppKit），弹刘海卡片、跑摄像头识别、回 allow/deny。

## 功能

- **两种识别引擎**（设置里切换）：
  - **Apple Vision（内置，~44 KB）**——Vision 取 21 个手部关键点 → 小 Core ML 模型分类。零依赖、抗光照/背景、容忍相机倾斜。（模型与训练流程：[hand-gesture-coreml](https://github.com/tankxu/hand-gesture-coreml)）
  - **MediaPipe（可选，~300 MB）**——Google 预训练模型，设置里按需下载。
- **多摄像头源**：FaceTime / USB / 连续互通 / **ESP32-CAM（串口）**。可设**画面旋转**；预览**镜像**（像照镜子）。
- **多种回应方式**：比手势、**全局热键 ⌃⇧Y / ⌃⇧N**、或点卡片图标。
- **自动放行白名单**：安全命令（如 `ls`、`git status`）直接通过不弹卡片，规则可编辑（正则）。
- **刘海卡片**：黑玻璃后透出实时画面、推近到手部、倒计时环、音效 + 系统通知反馈。
- **6 国语言**：English、简体中文、日本語、한국어、Español、Français（跟随系统语言）。
- **开机自启**、一键**开关**、设置里**一键接入** Claude Code / Codex 的 hook。
- **ESP32-CAM** 可选：app 内一键刷固件（无需 PlatformIO），当作独立审批摄像头。

## 构建安装

需要 macOS 14+ 和 Xcode（Swift 工具链）。

```bash
cd GestureApprove
./install.sh          # 构建 + 签名 + 装到 /Applications + 启动
```

然后从菜单栏 👍 图标 →「设置」选摄像头、选引擎、接入 Claude Code / Codex。想让手势真正拦工具时，勾上「**启用审批拦截**」。

> app 用本机 Apple Development 证书签名，且依赖本仓库（Vision 模型已内置；MediaPipe/ESP32 路径引用仓库）。**不是**经过公证的对外分发版。

## 目录结构

| 路径 | 作用 |
|---|---|
| `GestureApprove/` | macOS app（SwiftPM）。`install.sh` 构建+签名+安装。 |
| `GestureApprove/Assets/HandGesture.mlmodelc` | 内置 Vision 手势模型（~44 KB）。 |
| `GestureApprove/train/` | 训练脚本 + 样本关键点（另见 [hand-gesture-coreml](https://github.com/tankxu/hand-gesture-coreml)）。 |
| `hooks/gesture_hook.py` | 仅用标准库的 hook，桥接 Claude Code / Codex 与 app。 |
| `bridge/` | 可选 MediaPipe 守护进程 + ESP32 串口工具（`setup.sh` 装 MediaPipe）。 |
| `firmware/` | 可选 ESP32-CAM 固件 + 一键刷写。 |
| `config/` | 手动 hook 配置片段（app 会自动装 hook）。 |

## 许可

MIT（见 `LICENSE`）。内置 Vision 模型派生自 [HaGRID](https://github.com/hukenovs/hagrid)（CC BY-SA 4.0）。
