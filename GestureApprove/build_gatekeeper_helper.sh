#!/usr/bin/env bash
# 打包预编译的「智能放行」守门员 helper → GestureGatekeeper-helper.zip。
# 供一次性上传到 GitHub Release（固定 tag: gatekeeper-helper-v1，与 app 发版解耦）。
#
# 必须用 xcodebuild（swift build 编不出 Metal shaders）。ad-hoc 签名即可，
# 不需要 Apple Developer 账号——arm64 只要求「至少 ad-hoc 签名」才能 exec。
# 首次需安装 Metal 工具链：xcodebuild -downloadComponent MetalToolchain
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

TAG="gatekeeper-helper-v1"
ASSET="GestureGatekeeper-helper.zip"
DERIVED=".build/xcode"

echo "==> xcodebuild GestureGatekeeper (Release)"
xcodebuild -scheme GestureGatekeeper -destination 'platform=macOS' \
    -configuration Release -derivedDataPath "$DERIVED" -skipMacroValidation build

PROD="$DERIVED/Build/Products/Release"
BIN="$PROD/GestureGatekeeper"
BUNDLE="$PROD/mlx-swift_Cmlx.bundle"
[ -x "$BIN" ]    || { echo "✗ 找不到二进制 $BIN"; exit 1; }
[ -d "$BUNDLE" ] || { echo "✗ 找不到 metallib bundle $BUNDLE"; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp "$BIN" "$STAGE/"
cp -R "$BUNDLE" "$STAGE/"

echo "==> ad-hoc 签名（免账号；满足 arm64 exec 要求）"
codesign --force --sign - "$STAGE/GestureGatekeeper"
codesign --verify --verbose=0 "$STAGE/GestureGatekeeper" && echo "    签名 OK"

mkdir -p build
OUT="$(pwd)/build/$ASSET"
rm -f "$OUT"
echo "==> 打包 ${ASSET}（zip 根目录直接是 二进制 + bundle）"
( cd "$STAGE" && /usr/bin/zip -r -y -q -X "$OUT" GestureGatekeeper mlx-swift_Cmlx.bundle )

SIZE="$(du -h "$OUT" | awk '{print $1}')"
echo ""
echo "完成: $OUT  ($SIZE)"
echo ""
echo "上传到 Release（资产名务必保持 ${ASSET}，代码里写死的就是它）:"
echo "  gh release create $TAG \"$OUT\" --title \"Gatekeeper helper $TAG\" \\"
echo "      --notes \"Prebuilt local LLM gatekeeper (ad-hoc signed). Model weights download on first use.\""
echo "  # tag 已存在则改用: gh release upload $TAG \"$OUT\" --clobber"
