#!/usr/bin/env python3
"""手势审批 hook 适配器：被 Claude Code(PreToolUse) 与 Codex(PermissionRequest) 共用。

用法：
    gesture_decision.py claude   # 输出 Claude Code 格式
    gesture_decision.py codex    # 输出 Codex 格式

从 stdin 读取 hook 的 JSON（含 tool_name / tool_input），调用摄像头手势审批，
按目标工具的格式把 allow/deny 决策写到 stdout，exit 0。

失败安全：任何异常 -> deny。
"""
from __future__ import annotations

import json
import os
import sys

# 把 bridge/ 加入 import 路径
_HERE = os.path.dirname(os.path.abspath(__file__))
_BRIDGE = os.path.join(os.path.dirname(_HERE), "bridge")
sys.path.insert(0, _BRIDGE)


def _read_input() -> dict:
    try:
        raw = sys.stdin.read()
        return json.loads(raw) if raw.strip() else {}
    except Exception:
        return {}


def _context(payload: dict) -> str:
    tool = payload.get("tool_name", "")
    ti = payload.get("tool_input", {}) or {}
    detail = ti.get("command") or ti.get("file_path") or ti.get("description") or ""
    return f"{tool}: {detail}".strip(": ").strip()


def _emit_claude(decision: str, reason: str) -> None:
    # decision: "allow" | "deny"
    out = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": decision,
            "permissionDecisionReason": reason,
        }
    }
    print(json.dumps(out))


def _emit_codex(decision: str, reason: str) -> None:
    inner = {"behavior": decision}
    if decision == "deny":
        inner["message"] = reason
    out = {
        "hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": inner,
        }
    }
    print(json.dumps(out))


def main() -> int:
    target = sys.argv[1] if len(sys.argv) > 1 else "claude"
    payload = _read_input()
    ctx = _context(payload)

    try:
        from approve import get_verdict
        v = get_verdict(ctx)
        decision = "allow" if v.decision == "approve" else "deny"
        reason = f"手势审批: {v.reason}"
    except Exception as e:  # 失败安全
        decision = "deny"
        reason = f"手势审批异常，默认拒绝: {e}"

    if target == "codex":
        _emit_codex(decision, reason)
    else:
        _emit_claude(decision, reason)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
