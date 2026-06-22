#!/usr/bin/env bash
# 下载并安装本地 LLM「智能放行」守门员组件（GestureApprove 设置里点「下载」时调用）。
# 入参经环境变量：
#   GK_URL —— helper zip 的下载地址（GitHub Release，固定 tag）
#   GK_DIR —— 安装目录（~/Library/Application Support/GestureApprove/gatekeeper）
# zip 内容：GestureGatekeeper(已 ad-hoc 签名) + mlx-swift_Cmlx.bundle(含 metallib)。
# 模型权重不在 zip 里——helper 首次启动时自己从 HuggingFace 下载到 HF 缓存。
set -euo pipefail

: "${GK_URL:?需要 GK_URL}"
: "${GK_DIR:?需要 GK_DIR}"

echo "==> 下载守门员组件"
echo "    $GK_URL"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
zip="$tmp/helper.zip"
# -f 出错即失败，-L 跟随重定向（GitHub release 资产会 302），--progress-bar 显示进度
curl -fL --progress-bar -o "$zip" "$GK_URL"

echo "==> 解压到 $GK_DIR"
rm -rf "$GK_DIR"
mkdir -p "$GK_DIR"
/usr/bin/ditto -x -k "$zip" "$GK_DIR"

echo "==> 清除隔离属性（避免 Gatekeeper 拦截）"
xattr -dr com.apple.quarantine "$GK_DIR" 2>/dev/null || true

# 校验：二进制可执行 + bundle 在位 + ad-hoc 签名有效
bin="$GK_DIR/GestureGatekeeper"
if [ ! -x "$bin" ]; then
    echo "✗ 解压后缺少可执行文件 $bin"; exit 1
fi
if [ ! -d "$GK_DIR/mlx-swift_Cmlx.bundle" ]; then
    echo "✗ 缺少 mlx-swift_Cmlx.bundle（Metal 库），无法运行"; exit 1
fi
if codesign --verify --verbose=0 "$bin" 2>/dev/null; then
    echo "    签名校验通过"
else
    echo "    ⚠️ 签名校验未通过（ad-hoc 仍可 exec 运行）"
fi

echo ""
echo "==> 预取模型权重（约 1GB，首次较慢；已缓存则秒过）"
# 在这里一并把模型下载到位,而不是留到首次启用时静默卡顿。进度由 helper 打到 stderr。
if ! "$bin" --prefetch; then
    echo "✗ 模型预取失败（网络问题？）。helper 已就位，可稍后在设置里「重新下载」重试。"
    exit 1
fi

echo ""
echo "守门员 + 模型就绪 ✅"
