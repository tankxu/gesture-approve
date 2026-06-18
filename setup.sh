#!/usr/bin/env bash
# 主机端一键安装：建 venv、装依赖、下载手势模型。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$ROOT/bridge/.venv"

echo "==> 创建 venv: $VENV"
python3 -m venv "$VENV"

echo "==> 安装依赖"
"$VENV/bin/pip" install --upgrade pip >/dev/null
"$VENV/bin/pip" install -r "$ROOT/bridge/requirements.txt"

echo "==> 下载 MediaPipe 手势模型"
"$VENV/bin/python" "$ROOT/bridge/download_model.py"

echo ""
echo "完成。venv 解释器： $VENV/bin/python"
echo "自测串口抓帧（需先烧好固件）： $VENV/bin/python $ROOT/bridge/esp32cam.py"
echo "自测一次手势审批：           $VENV/bin/python $ROOT/bridge/approve.py"
