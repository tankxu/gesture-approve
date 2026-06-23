"""下载 MediaPipe 手势识别预训练模型到 bridge/models/gesture_recognizer.task。"""
from __future__ import annotations

import os
import urllib.request

URL = (
    "https://storage.googleapis.com/mediapipe-models/gesture_recognizer/"
    "gesture_recognizer/float16/latest/gesture_recognizer.task"
)
# 输出目录：优先环境变量（app 指向 Application Support），回退脚本旁 models/（源码开发）。
DEST_DIR = os.environ.get("GESTURE_MODEL_DIR") or os.path.join(os.path.dirname(__file__), "models")
DEST = os.path.join(DEST_DIR, "gesture_recognizer.task")


def main() -> None:
    os.makedirs(DEST_DIR, exist_ok=True)
    # 进度文案按界面语言（app 经环境变量传入），脱离 app 单独运行时回退英文。
    if os.path.exists(DEST) and os.path.getsize(DEST) > 0:
        print(f"{os.environ.get('MP_M_MODEL_EXISTS', 'Model already present:')} {DEST}")
        return
    print(f"{os.environ.get('MP_M_MODEL_DOWNLOAD', 'Downloading gesture model ->')} {DEST}")
    urllib.request.urlretrieve(URL, DEST)
    done = os.environ.get("MP_M_MODEL_DONE", "Done,")
    unit = os.environ.get("MP_M_BYTES", "bytes")
    print(f"{done} {os.path.getsize(DEST)} {unit}")


if __name__ == "__main__":
    main()
