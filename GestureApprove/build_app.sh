#!/usr/bin/env bash
# 编译 GestureApprove 并打包成可用的 .app（含相机权限说明 + ad-hoc 签名）。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "==> swift build (release)"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/GestureApprove"
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

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>GestureApprove</string>
    <key>CFBundleDisplayName</key><string>GestureApprove</string>
    <key>CFBundleIdentifier</key><string>com.tankxu.gestureapprove</string>
    <key>CFBundleExecutable</key><string>GestureApprove</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.3.4</string>
    <key>CFBundleVersion</key><string>7</string>
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
make_lproj en      "GestureApprove"   "Used to recognize your approval gestures (👍 approve / 🖐 deny)."
make_lproj zh-Hans "手势审批"          "用于识别你的审批手势（👍 通过 / 🖐 拒绝）。"
make_lproj ja      "ジェスチャー承認"   "承認ジェスチャー（👍 承認 / 🖐 拒否）の認識に使用します。"
make_lproj ko      "제스처 승인"       "승인 제스처(👍 승인 / 🖐 거부) 인식에 사용됩니다."
make_lproj es      "GestureApprove"   "Se usa para reconocer tus gestos de aprobación (👍 aprobar / 🖐 rechazar)."
make_lproj fr      "GestureApprove"   "Utilisé pour reconnaître vos gestes d'approbation (👍 approuver / 🖐 refuser)."

SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # 默认 ad-hoc；可用环境变量指定证书
echo "==> 签名 ($SIGN_IDENTITY)"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"

echo ""
echo "完成： $(pwd)/$APP"
echo "启动： open \"$(pwd)/$APP\"   （首次会弹相机授权，点允许）"
