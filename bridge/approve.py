"""审批编排：触发后持续抓帧识别手势，直到识别出 👍/🖐 或超时。

设计要点：
- 失败安全：超时 / 出错 / 设备不可用，一律返回 deny（绝不在异常时放行）。
- 需要稳定：同一判定连续命中 STABLE_HITS 帧才采纳，避免一帧误判。
- 有提示：触发时通过 macOS `say` 播报，并点亮 ESP32 状态灯提示“请举手势”。
"""
from __future__ import annotations

import os
import subprocess
import sys
import time
from dataclasses import dataclass

# 允许作为脚本或模块导入
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from esp32cam import ESP32Cam  # noqa: E402
from classify import GestureClassifier  # noqa: E402

# 配置（均可用环境变量覆盖）
TIMEOUT_SEC = float(os.environ.get("APPROVE_TIMEOUT", "12"))   # 等待手势的总时长
STABLE_HITS = int(os.environ.get("APPROVE_STABLE_HITS", "2"))  # 连续命中几帧才采纳
SPEAK = os.environ.get("APPROVE_SPEAK", "1") != "0"            # 是否语音播报
VOICE_TEXT = os.environ.get("APPROVE_VOICE_TEXT", "需要审批，请举手势")


@dataclass
class Verdict:
    decision: str            # "approve" | "deny"
    reason: str
    gesture: str = ""
    confidence: float = 0.0


def _speak(text: str) -> None:
    if not SPEAK:
        return
    try:
        # macOS 自带 say；非阻塞
        subprocess.Popen(["say", text],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


def get_verdict(context: str = "") -> Verdict:
    """触发一次手势审批，返回 Verdict。出现任何异常都返回 deny。"""
    try:
        classifier = GestureClassifier()
    except Exception as e:
        return Verdict("deny", f"分类器初始化失败: {e}")

    cam = ESP32Cam()
    try:
        cam.open()
    except Exception as e:
        classifier.close()
        return Verdict("deny", f"无法打开摄像头串口 {cam.port}: {e}")

    try:
        if not cam.ping():
            return Verdict("deny", "ESP32-CAM 无响应（PING 超时）")

        _speak(VOICE_TEXT)
        cam.led(True)  # 点亮提示灯

        deadline = time.time() + TIMEOUT_SEC
        run = {"approve": 0, "deny": 0}
        last_gesture, last_conf = "", 0.0

        while time.time() < deadline:
            frame = cam.capture()
            if frame is None:
                continue
            verdict, gesture, conf = classifier.classify_jpeg(frame)
            if verdict in run:
                run[verdict] += 1
                # 一旦另一判定出现，清掉对立计数，避免来回抖动叠加
                other = "deny" if verdict == "approve" else "approve"
                run[other] = 0
                last_gesture, last_conf = gesture, conf
                if run[verdict] >= STABLE_HITS:
                    return Verdict(verdict,
                                  f"识别到手势 {gesture} (conf={conf:.2f})",
                                  gesture, conf)
            else:
                run["approve"] = 0
                run["deny"] = 0

        return Verdict("deny", "超时未识别到明确手势，按拒绝处理",
                      last_gesture, last_conf)
    finally:
        try:
            cam.led(False)
        except Exception:
            pass
        cam.close()
        classifier.close()


def _cli() -> int:
    v = get_verdict()
    icon = "✅" if v.decision == "approve" else "🛑"
    print(f"{icon} {v.decision.upper()}  {v.reason}")
    return 0 if v.decision == "approve" else 1


if __name__ == "__main__":
    raise SystemExit(_cli())
