"""ESP32-CAM 串口抓帧。

协议见 firmware/src/main.cpp 顶部注释：
  主机发送 "CAP\\n" -> ESP32 回 [0xA5,0x5A,0xA5,0x5A][4字节小端长度][JPEG]
"""
from __future__ import annotations

import os
import struct
import time

import serial  # pyserial

FRAME_MAGIC = b"\xA5\x5A\xA5\x5A"

# 默认串口设备与波特率，可用环境变量覆盖。
DEFAULT_PORT = os.environ.get("ESP32CAM_PORT", "/dev/cu.usbserial-FTB6SPL3")
DEFAULT_BAUD = int(os.environ.get("ESP32CAM_BAUD", "921600"))


class ESP32Cam:
    def __init__(self, port: str = DEFAULT_PORT, baud: int = DEFAULT_BAUD,
                 read_timeout: float = 2.0):
        self.port = port
        self.baud = baud
        self.read_timeout = read_timeout
        self.ser: serial.Serial | None = None

    def __enter__(self) -> "ESP32Cam":
        self.open()
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def open(self) -> None:
        # ESP32-CAM-MB 用 DTR/RTS 控制 GPIO0/EN。若不显式处理，pyserial 打开串口
        # 时的默认电平可能把芯片拽进下载模式而不运行固件。这里做一次“复位到运行模式”：
        #   GPIO0(DTR) 保持高 -> 运行模式；脉冲 EN(RTS) 复位。
        ser = serial.Serial()
        ser.port = self.port
        ser.baudrate = self.baud
        ser.timeout = self.read_timeout
        ser.dtr = False  # 打开前先定住电平，避免误入 bootloader
        ser.rts = False
        ser.open()
        ser.setDTR(False)   # GPIO0 高 = 运行模式
        ser.setRTS(True)    # EN 低 = 复位
        time.sleep(0.1)
        ser.setRTS(False)   # 释放复位，固件开始启动
        time.sleep(1.0)     # 等相机初始化 + 丢弃稳定帧
        ser.reset_input_buffer()
        self.ser = ser

    def close(self) -> None:
        if self.ser is not None:
            try:
                self.led(False)
            except Exception:
                pass
            self.ser.close()
            self.ser = None

    def _write_cmd(self, cmd: str) -> None:
        assert self.ser is not None
        self.ser.write((cmd + "\n").encode())
        self.ser.flush()

    def led(self, on: bool) -> None:
        """点亮/熄灭板载状态灯，用作“正在等待手势”的提示。"""
        self._write_cmd("L1" if on else "L0")

    def ping(self, timeout: float = 2.0) -> bool:
        """握手探活：发 PING 期待在数据流里看到 PONG。"""
        assert self.ser is not None
        self.ser.reset_input_buffer()
        self._write_cmd("PING")
        deadline = time.time() + timeout
        buf = b""
        while time.time() < deadline:
            chunk = self.ser.read(64)
            if chunk:
                buf += chunk
                if b"PONG" in buf:
                    return True
        return False

    def _read_exact(self, n: int, deadline: float) -> bytes | None:
        assert self.ser is not None
        buf = b""
        while len(buf) < n:
            if time.time() > deadline:
                return None
            chunk = self.ser.read(n - len(buf))
            if chunk:
                buf += chunk
        return buf

    def capture(self, timeout: float = 3.0) -> bytes | None:
        """请求并读取一帧 JPEG，失败返回 None。

        通过扫描魔数来跳过启动日志/PONG 等噪声字节。
        """
        assert self.ser is not None, "串口未打开，请先 open()"
        self.ser.reset_input_buffer()
        self._write_cmd("CAP")
        deadline = time.time() + timeout

        # 1) 滑动窗口扫描 4 字节魔数
        window = b""
        while True:
            if time.time() > deadline:
                return None
            b = self.ser.read(1)
            if not b:
                continue
            window = (window + b)[-4:]
            if window == FRAME_MAGIC:
                break

        # 2) 读 4 字节小端长度
        len_bytes = self._read_exact(4, deadline)
        if len_bytes is None:
            return None
        (length,) = struct.unpack("<I", len_bytes)
        if length == 0 or length > 2_000_000:  # 防御异常长度
            return None

        # 3) 读 JPEG 数据
        data = self._read_exact(length, deadline)
        if data is None:
            return None
        # 基本校验：JPEG 以 FFD8 开头、FFD9 结尾
        if not (data[:2] == b"\xff\xd8" and data[-2:] == b"\xff\xd9"):
            return None
        return data


def quick_test() -> None:
    """命令行自测：抓一帧存到 /tmp/esp32cam_test.jpg。"""
    with ESP32Cam() as cam:
        print(f"端口 {cam.port} @ {cam.baud}")
        print("PING:", "OK" if cam.ping() else "无响应")
        frame = cam.capture()
        if frame is None:
            print("抓帧失败")
            return
        path = "/tmp/esp32cam_test.jpg"
        with open(path, "wb") as f:
            f.write(frame)
        print(f"已抓到 {len(frame)} 字节 -> {path}")


if __name__ == "__main__":
    quick_test()
