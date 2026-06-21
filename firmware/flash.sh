#!/usr/bin/env bash
# 一键刷写 ESP32-CAM 配套固件（新手友好版）：
#   - 直接烧录仓库里的预编译固件 prebuilt/*.bin，无需在本机编译；
#   - 仅依赖 esptool（小工具）；首次运行自动建一个小 venv 安装它（约 20MB，仅一次）；
#   - 不需要安装 PlatformIO，也不会下载几百 MB 的工具链。
# 被 GestureApprove.app 的「开始刷写」按钮调用，也可单独运行。
set -uo pipefail

FW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREBUILT="$FW_DIR/prebuilt"   # 只读取，放 bundle 里也没问题
# venv 不能建在只读 bundle：app 通过 FLASH_VENV 指向 Application Support，回退脚本旁（源码开发）。
VENV="${FLASH_VENV:-$FW_DIR/.flashenv}"
PYBIN="$VENV/bin/python"

# 1) 准备 esptool（首次自动安装）
if ! { [ -x "$PYBIN" ] && "$PYBIN" -m esptool version >/dev/null 2>&1; }; then
    echo "==> 首次使用：正在准备烧录工具 esptool（约 20MB，仅此一次）…"
    PY3="$(command -v python3 || true)"
    if [ -z "$PY3" ]; then echo "未找到 python3，无法安装 esptool。" >&2; exit 1; fi
    "$PY3" -m venv "$VENV" || { echo "创建 venv 失败。" >&2; exit 1; }
    "$PYBIN" -m pip install --upgrade pip >/dev/null 2>&1
    "$PYBIN" -m pip install esptool || { echo "安装 esptool 失败（检查网络）。" >&2; exit 1; }
    echo "==> esptool 就绪。"
fi

# 2) 探测串口
PORT="${ESP32CAM_PORT:-}"
if [ -z "$PORT" ]; then
    PORT="$(ls /dev/cu.usbserial-* /dev/cu.SLAB_USBtoUART* /dev/cu.wchusbserial* /dev/cu.usbmodem* 2>/dev/null | head -1 || true)"
fi
if [ -z "$PORT" ]; then
    echo "没找到串口。请确认 ESP32-CAM 已通过 USB-串口适配器插入电脑。" >&2
    exit 1
fi
echo "==> 串口: $PORT"

# 3) 烧录预编译固件
echo "==> 开始刷写固件…"
"$PYBIN" -m esptool --chip esp32 --port "$PORT" --baud 460800 \
    --before default_reset --after hard_reset write_flash -z \
    0x1000 "$PREBUILT/bootloader.bin" \
    0x8000 "$PREBUILT/partitions.bin" \
    0xe000 "$PREBUILT/boot_app0.bin" \
    0x10000 "$PREBUILT/firmware.bin"
RC=$?

if [ $RC -eq 0 ]; then
    echo ""
    echo "✅ 刷写成功。回到设置，把视频输入源选成「ESP32-CAM（串口）」即可。"
else
    echo ""
    echo "❌ 刷写失败 (rc=$RC)。裸 FTDI 接线若没自动复位：GPIO0 接 GND → 复位 → 点「重新刷写」。" >&2
fi
exit $RC
