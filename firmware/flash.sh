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
    echo "==> ${FW_M_PREP_ESPTOOL:-First run: preparing the esptool flasher (~20MB, one time)…}"
    PY3="$(command -v python3 || true)"
    if [ -z "$PY3" ]; then echo "${FW_M_NO_PYTHON:-python3 not found; cannot install esptool.}" >&2; exit 1; fi
    "$PY3" -m venv "$VENV" || { echo "${FW_M_VENV_FAIL:-Failed to create venv.}" >&2; exit 1; }
    "$PYBIN" -m pip install --upgrade pip >/dev/null 2>&1
    "$PYBIN" -m pip install esptool || { echo "${FW_M_ESPTOOL_FAIL:-Failed to install esptool (check network).}" >&2; exit 1; }
    echo "==> ${FW_M_ESPTOOL_READY:-esptool ready.}"
fi

# 2) 探测串口
PORT="${ESP32CAM_PORT:-}"
if [ -z "$PORT" ]; then
    PORT="$(ls /dev/cu.usbserial-* /dev/cu.SLAB_USBtoUART* /dev/cu.wchusbserial* /dev/cu.usbmodem* 2>/dev/null | head -1 || true)"
fi
if [ -z "$PORT" ]; then
    echo "${FW_M_NO_PORT:-No serial port found. Make sure the ESP32-CAM is plugged in via a USB-to-serial adapter.}" >&2
    exit 1
fi
echo "==> ${FW_M_PORT:-Serial port:} $PORT"

# 3) 烧录预编译固件
echo "==> ${FW_M_FLASHING:-Flashing firmware…}"
"$PYBIN" -m esptool --chip esp32 --port "$PORT" --baud 460800 \
    --before default_reset --after hard_reset write_flash -z \
    0x1000 "$PREBUILT/bootloader.bin" \
    0x8000 "$PREBUILT/partitions.bin" \
    0xe000 "$PREBUILT/boot_app0.bin" \
    0x10000 "$PREBUILT/firmware.bin"
RC=$?

if [ $RC -eq 0 ]; then
    echo ""
    echo "${FW_M_SUCCESS:-✅ Flash succeeded. Back in Settings, set the video source to \"ESP32-CAM (serial)\".}"
else
    echo ""
    echo "❌ ${FW_M_FAILED:-Flash failed} (rc=$RC). ${FW_M_FAIL_HINT:-If a bare FTDI has no auto-reset: tie GPIO0 to GND → reset → click \"Flash again\".}" >&2
fi
exit $RC
