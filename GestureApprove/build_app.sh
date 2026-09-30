#!/usr/bin/env bash
# 编译 GestureApprove 并打包成可用的 .app（含相机权限说明 + ad-hoc 签名）。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "==> swift build (release)"
# --disable-sandbox: SwiftPM always runs sandbox-exec around the manifest
# compile. That cannot nest inside Claude Code's Bash sandbox (sandbox_apply
# EPERM). The outer sandbox still confines the build; this only drops the
# inner layer. Same shape as cargo, which does not nest a second seatbelt.
#
# --build-path under ~/Library/Caches: Claude's Bash sandbox blocks writes
# inside any workspace `.git/` (including SwiftPM checkouts). Keep checkouts
# out of the repo so git clone can populate them.
BUILD_PATH="${GESTURE_APPROVE_SWIFT_BUILD_PATH:-$HOME/Library/Caches/gesture-approve/swiftpm}"
swift build --product GestureApprove -c release --disable-sandbox --build-path "$BUILD_PATH"

BIN="$(swift build --product GestureApprove -c release --disable-sandbox --build-path "$BUILD_PATH" --show-bin-path)/GestureApprove"
APP="build/GestureApprove.app"
echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GestureApprove"

# 图标资源
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Assets/TrayIcon.png "$APP/Contents/Resources/TrayIcon.png"
# 内置手势模型（Vision 引擎用）
cp -R Assets/HandGesture.mlmodelc "$APP/Contents/Resources/HandGesture.mlmodelc"
# 通知提示音。**必须放在 Contents/Resources 根目录**：UNNotificationSound(named:) 只按文件名找，
# 扫的是 Resources 根和 ~/Library/Sounds，不会进子目录——放进 Sounds/ 的话 Bundle.url 找得到、
# 通知系统却找不到，于是静悄悄退回系统默认音（听上去就是"提示音没生效"）。
# 音频由 Assets/sounds/render_agent_done.swift 生成。
cp Assets/sounds/AgentDone.aiff "$APP/Contents/Resources/AgentDone.aiff"

# 打包脚本/固件进 bundle，让 release 下载即用（零仓库依赖）。
# 只拷只读资源；venv/模型/esptool 环境等可写产物运行时落到 ~/Library/Application Support/GestureApprove。
RES="$APP/Contents/Resources"
mkdir -p "$RES/hooks" "$RES/bridge" "$RES/firmware" "$RES/config"
cp ../hooks/gesture_hook.py "$RES/hooks/"
# 审批规则配置（deny-list / 白名单 / 拼接符的单一来源，方便查看与修改）。
cp ../config/gatekeeper-rules.json ../config/monitor-pricing.json "$RES/config/"
for f in ../bridge/*.py ../bridge/requirements.txt ../bridge/setup_mediapipe.sh ../bridge/download_gatekeeper.sh; do
    [ -e "$f" ] && cp "$f" "$RES/bridge/"
done
cp ../firmware/flash.sh "$RES/firmware/"
cp -R ../firmware/prebuilt "$RES/firmware/prebuilt"

# Remote Hub 现为 Swift 原生(HubServer/HubApp),只需打包两个网页(由 Swift 直接托管)。
mkdir -p "$RES/hub"
cp ../hub/app.html ../hub/monitor.html ../hub/config.html ../hub/sw.js "$RES/hub/"
# PWA 图标：主屏图标、Android 遮罩图标、iOS touch icon。少一个，"添加到主屏幕"就装不上。
mkdir -p "$RES/hub/icons"
cp ../hub/icons/*.png "$RES/hub/icons/"

REPO_ROOT="$(cd .. && pwd)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Gesture Approve</string>
    <key>CFBundleDisplayName</key><string>Gesture Approve</string>
    <key>CFBundleIdentifier</key><string>com.tankxu.gestureapprove</string>
    <key>CFBundleExecutable</key><string>GestureApprove</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.10.0</string>
    <key>CFBundleVersion</key><string>29</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string><string>zh-Hans</string><string>ja</string>
        <string>ko</string><string>es</string><string>fr</string>
    </array>
    <key>NSCameraUsageDescription</key>
    <string>Used to recognize your approval gestures (👍 approve / 🖐 deny).</string>
    <!-- 专注状态：只用来在「勿扰/专注」开启时**不播**完成提示音（系统唯一的公开查询途径）。 -->
    <key>NSFocusStatusUsageDescription</key>
    <string>Checked only to stay quiet: when a Focus is on, GestureApprove skips the completion sound.</string>
    <key>RepoRoot</key><string>${REPO_ROOT}</string>
</dict>
</plist>
PLIST

# 本地化系统层文案（相机授权说明 + 显示名）：每个语言一份 InfoPlist.strings。
# 应用内 UI 文案由 Localization.swift 的代码字典处理。
make_lproj() {  # $1=目录名 $2=显示名 $3=相机授权说明
    local d="$APP/Contents/Resources/$1.lproj"
    mkdir -p "$d"
    cat > "$d/InfoPlist.strings" <<STR
"CFBundleDisplayName" = "$2";
"NSCameraUsageDescription" = "$3";
STR
}
make_lproj en      "Gesture Approve"  "Used to recognize your approval gestures (👍 approve / 🖐 deny)."
make_lproj zh-Hans "手势审批"          "用于识别你的审批手势（👍 通过 / 🖐 拒绝）。"
make_lproj ja      "ジェスチャー承認"   "承認ジェスチャー（👍 承認 / 🖐 拒否）の認識に使用します。"
make_lproj ko      "제스처 승인"       "승인 제스처(👍 승인 / 🖐 거부) 인식에 사용됩니다."
make_lproj es      "Gesture Approve"  "Se usa para reconocer tus gestos de aprobación (👍 aprobar / 🖐 rechazar)."
make_lproj fr      "Gesture Approve"  "Utilisé pour reconnaître vos gestes d'approbation (👍 approuver / 🖐 refuser)."

SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # 默认 ad-hoc；可用环境变量指定证书
# iCloud 同步目录会给文件打 com.apple.FinderInfo 等 xattr，codesign 会因此报
# "resource fork / Finder information not allowed" 校验失败——签名前先清干净。
xattr -cr "$APP"
echo "==> 签名 ($SIGN_IDENTITY)"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"

echo ""
echo "完成： $(pwd)/$APP"
echo "启动： open \"$(pwd)/$APP\"   （首次会弹相机授权，点允许）"
