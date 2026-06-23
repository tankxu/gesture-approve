"""常驻手势识别进程：用 MediaPipe 预训练模型，被 Swift app 通过管道调用。

协议（与 MediaPipeClassifier.swift 一致）：
  输入(stdin, 二进制)：4 字节小端长度 + 该长度的 JPEG 字节，循环。
  输出(stdout, 文本)：每帧一行 "<gesture> <x0> <y0> <x1> <y1> <conf>"
      gesture ∈ {thumbUp, openPalm, none}
      x0,y0,x1,y1 = 手部包围盒归一化坐标(0~1, y 向下)；无手为 -1
  就绪信号：启动加载模型后向 stderr 打印 "READY"。
"""
from __future__ import annotations

import os
import struct
import sys

import cv2
import numpy as np
import mediapipe as mp
from mediapipe.tasks import python as mp_python
from mediapipe.tasks.python import vision

MODEL = os.environ.get("GESTURE_MODEL") or os.path.join(os.path.dirname(__file__), "models", "gesture_recognizer.task")
GESTURE_MAP = {"Thumb_Up": "thumbUp", "Open_Palm": "openPalm"}
# daemon 总是输出 score；置信度门槛由 Swift 端（MediaPipeClassifier）按「识别精准度」档位过滤。
# 实测：MediaPipe 对清晰 Thumb_Up 的 score 仅 ~0.73，门槛设太高会让 thumbUp 直接失效。

_stdin = sys.stdin.buffer


def read_exact(n: int) -> bytes | None:
    buf = b""
    while len(buf) < n:
        chunk = _stdin.read(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def main() -> None:
    base = mp_python.BaseOptions(model_asset_path=MODEL)
    options = vision.GestureRecognizerOptions(
        base_options=base, running_mode=vision.RunningMode.IMAGE, num_hands=1,
        min_hand_detection_confidence=0.6,   # 更确信是手才检测，减少误检
        min_hand_presence_confidence=0.6)
    recognizer = vision.GestureRecognizer.create_from_options(options)

    sys.stderr.write("READY\n")
    sys.stderr.flush()

    while True:
        header = read_exact(4)
        if header is None:
            break
        (length,) = struct.unpack("<I", header)
        if length == 0 or length > 8_000_000:
            break
        data = read_exact(length)
        if data is None:
            break

        gesture, conf = "none", 0.0
        x0 = y0 = x1 = y1 = -1.0
        arr = np.frombuffer(data, dtype=np.uint8)
        bgr = cv2.imdecode(arr, cv2.IMREAD_COLOR)
        if bgr is not None:
            rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
            image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
            result = recognizer.recognize(image)
            if result.gestures:
                top = result.gestures[0][0]
                conf = float(top.score)
                # 总是输出映射后的手势 + 置信度，阈值由 Swift 端按滑杆实时过滤
                gesture = GESTURE_MAP.get(top.category_name, "none")
            if result.hand_landmarks:
                lms = result.hand_landmarks[0]
                xs = [p.x for p in lms]
                ys = [p.y for p in lms]
                x0, y0, x1, y1 = min(xs), min(ys), max(xs), max(ys)

        sys.stdout.write(f"{gesture} {x0:.3f} {y0:.3f} {x1:.3f} {y1:.3f} {conf:.2f}\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
