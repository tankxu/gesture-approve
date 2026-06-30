#!/usr/bin/env bash
# 构建 + 用 Apple Development 证书签名 + 安装到 /Applications。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# 自动选用本机的 Apple Development 证书（取第一条 codesigning 身份的指纹）
SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk 'NR==1{print $2}')"
if [ -z "$SIGN_ID" ]; then
    echo "未找到签名证书，回退 ad-hoc"; SIGN_ID="-"
fi
echo "==> 签名身份: $SIGN_ID"

SIGN_IDENTITY="$SIGN_ID" ./build_app.sh

DEST="/Applications/GestureApprove.app"
echo "==> 安装到 $DEST"
pkill -f "GestureApprove.app/Contents/MacOS/GestureApprove" 2>/dev/null || true
sleep 1
rm -rf "$DEST"
cp -R build/GestureApprove.app "$DEST"
# 从 iCloud 同步目录 cp 过来可能带 com.apple.FinderInfo，会让 codesign 校验失败——清掉。
xattr -cr "$DEST"

echo "==> 校验签名"
codesign --verify --deep --strict --verbose=1 "$DEST" && echo "签名有效 ✅"

echo "==> 启动"
open "$DEST"
echo ""
echo "已安装到 /Applications。首次启动会重新询问相机/通知权限，点允许即可。"
