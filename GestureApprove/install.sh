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
PATTERN="GestureApprove.app/Contents/MacOS/GestureApprove"
echo "==> 安装到 $DEST"
# 关旧实例，并**确认它真的没了**。开了「开机自启」时系统会在几百毫秒内把它拉起来，
# 只 pkill 一次 + sleep 就会剩一个复活的旧进程；末尾的 open 见到已有实例只是把它激活，
# 于是新版本装上了却还跑着老代码（"改了没生效"查半天的真凶就是这个）。
for _ in $(seq 1 20); do
    pgrep -f "$PATTERN" >/dev/null 2>&1 || break
    pkill -f "$PATTERN" 2>/dev/null || true
    sleep 0.5
done
if pgrep -f "$PATTERN" >/dev/null 2>&1; then
    echo "⚠️  旧实例杀不掉（可能被登录项反复拉起），继续安装，但请手动退出后重开。"
fi
rm -rf "$DEST"
cp -R build/GestureApprove.app "$DEST"
# 从 iCloud 同步目录 cp 过来可能带 com.apple.FinderInfo，会让 codesign 校验失败——清掉。
xattr -cr "$DEST"

echo "==> 校验签名"
codesign --verify --deep --strict --verbose=1 "$DEST" && echo "签名有效 ✅"

echo "==> 启动"
open "$DEST"
# 确认起来的确实是刚装的这一份：打印 pid 与启动时间，没起来就直说，别让人以为装好了。
PID=""
for _ in $(seq 1 20); do
    PID="$(pgrep -f "$PATTERN" 2>/dev/null | head -1 || true)"
    [ -n "$PID" ] && break
    sleep 0.5
done
if [ -n "$PID" ]; then
    # ${PID} 的花括号不能省：后面紧跟全角「（」，bash 3.2 会把这个多字节字符算进变量名。
    echo "已启动 pid=${PID}（$(ps -o lstart= -p "$PID" | xargs)）"
else
    echo "⚠️  没检测到新进程，请手动打开 $DEST"
fi
echo ""
echo "已安装到 /Applications。首次启动会重新询问相机/通知权限，点允许即可。"
