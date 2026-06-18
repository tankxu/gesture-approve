"""下载 MediaPipe 手势识别预训练模型到 bridge/models/gesture_recognizer.task。"""
from __future__ import annotations

import os
import urllib.request

URL = (
    "https://storage.googleapis.com/mediapipe-models/gesture_recognizer/"
    "gesture_recognizer/float16/latest/gesture_recognizer.task"
)
DEST_DIR = os.path.join(os.path.dirname(__file__), "models")
DEST = os.path.join(DEST_DIR, "gesture_recognizer.task")


def main() -> None:
    os.makedirs(DEST_DIR, exist_ok=True)
    if os.path.exists(DEST) and os.path.getsize(DEST) > 0:
        print(f"模型已存在: {DEST}")
        return
    print(f"下载手势模型 -> {DEST}")
    urllib.request.urlretrieve(URL, DEST)
    print(f"完成，{os.path.getsize(DEST)} 字节")


if __name__ == "__main__":
    main()
