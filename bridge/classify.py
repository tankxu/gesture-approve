"""用 MediaPipe 自带的手势识别模型把一帧 JPEG 判成 approve / deny / none。

MediaPipe GestureRecognizer 预训练类别：
  None, Closed_Fist, Open_Palm, Pointing_Up, Thumb_Down, Thumb_Up, Victory, ILoveYou
映射：
  Thumb_Up   (👍) -> approve
  Open_Palm  (🖐) -> deny
其余 -> none（不构成决策，继续等下一帧）
"""
from __future__ import annotations

import os

import cv2  # 随 mediapipe 一起安装
import numpy as np
import mediapipe as mp
from mediapipe.tasks import python as mp_python
from mediapipe.tasks.python import vision

_MODEL_PATH = os.path.join(os.path.dirname(__file__), "models", "gesture_recognizer.task")

GESTURE_TO_VERDICT = {
    "Thumb_Up": "approve",
    "Open_Palm": "deny",
}


class GestureClassifier:
    def __init__(self, model_path: str = _MODEL_PATH, min_confidence: float = 0.5):
        if not os.path.exists(model_path):
            raise FileNotFoundError(
                f"找不到手势模型 {model_path}，请先运行 setup.sh 或 download_model.py 下载。"
            )
        self.min_confidence = min_confidence
        base = mp_python.BaseOptions(model_asset_path=model_path)
        options = vision.GestureRecognizerOptions(
            base_options=base,
            running_mode=vision.RunningMode.IMAGE,
            num_hands=1,
        )
        self.recognizer = vision.GestureRecognizer.create_from_options(options)

    def classify_jpeg(self, jpeg: bytes) -> tuple[str, str, float]:
        """返回 (verdict, gesture_name, confidence)。

        verdict ∈ {"approve","deny","none"}。
        """
        arr = np.frombuffer(jpeg, dtype=np.uint8)
        bgr = cv2.imdecode(arr, cv2.IMREAD_COLOR)
        if bgr is None:
            return ("none", "decode_error", 0.0)
        rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
        mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
        result = self.recognizer.recognize(mp_image)

        if not result.gestures:
            return ("none", "no_hand", 0.0)
        top = result.gestures[0][0]  # 第一只手的最高分类别
        gesture = top.category_name
        score = float(top.score)
        verdict = GESTURE_TO_VERDICT.get(gesture, "none")
        if verdict != "none" and score < self.min_confidence:
            verdict = "none"
        return (verdict, gesture, score)

    def close(self) -> None:
        try:
            self.recognizer.close()
        except Exception:
            pass
