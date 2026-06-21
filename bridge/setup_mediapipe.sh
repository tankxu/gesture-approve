#!/usr/bin/env bash
# MediaPipe 一键安装：在 Application Support 建 venv、装依赖、下载模型。
# 由 GestureApprove.app「下载 MediaPipe」按钮调用，路径全部通过环境变量传入：
#   GA_BRIDGE   = bundle 内 bridge 目录（requirements.txt / download_model.py 的只读源）
#   GA_VENV     = 目标 venv 目录（可写，~/Library/Application Support/GestureApprove/...）
#   GA_MODELDIR = 目标模型目录（可写）
set -euo pipefail

BRIDGE="${GA_BRIDGE:?need GA_BRIDGE}"
VENV="${GA_VENV:?need GA_VENV}"
MODELDIR="${GA_MODELDIR:?need GA_MODELDIR}"

echo "==> 创建 venv: $VENV"
mkdir -p "$(dirname "$VENV")"
python3 -m venv "$VENV"

echo "==> 安装依赖"
"$VENV/bin/pip" install --upgrade pip >/dev/null
"$VENV/bin/pip" install -r "$BRIDGE/requirements.txt"

echo "==> 下载 MediaPipe 手势模型"
mkdir -p "$MODELDIR"
GESTURE_MODEL_DIR="$MODELDIR" "$VENV/bin/python" "$BRIDGE/download_model.py"

echo ""
echo "完成。MediaPipe 已就绪。"
