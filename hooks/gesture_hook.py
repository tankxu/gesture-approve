#!/usr/bin/env python3
"""手势审批 hook（HTTP 版）：对接常驻的 GestureApprove.app。

被 Claude Code(PreToolUse) 与 Codex(PermissionRequest) 共用：
    gesture_hook.py claude   # 输出 Claude Code 格式
    gesture_hook.py codex    # 输出 Codex 格式

从 stdin 读 hook JSON -> POST 操作名到 app 的本地服务 -> 拿 allow/deny
-> 转成对应工具的 JSON 写 stdout。只用标准库，启动开销极小。

失败安全：app 未运行 / 超时 / 任何异常 -> deny。
"""
from __future__ import annotations

import json
import os
import sys
import urllib.request

PORT = os.environ.get("GESTURE_APPROVE_PORT", "47600")
URL = f"http://127.0.0.1:{PORT}/approve"
# 要略大于 app 端的卡片等待超时（默认 90s），到点 app 会回 ask、交回终端。
HTTP_TIMEOUT = float(os.environ.get("GESTURE_APPROVE_HTTP_TIMEOUT", "100"))


def read_input() -> dict:
    try:
        raw = sys.stdin.read()
        return json.loads(raw) if raw.strip() else {}
    except Exception:
        return {}


def operation_label(payload: dict) -> str:
    tool = payload.get("tool_name", "操作")
    ti = payload.get("tool_input", {}) or {}
    detail = ti.get("command") or ti.get("file_path") or ti.get("description") or ""
    label = f"{tool}: {detail}".strip(": ").strip()
    return label[:140]  # 卡片显示截断


def ask_app(operation: str, cwd: str = "", tool: str = "") -> tuple[str, str]:
    """返回 (decision, reason)，decision ∈ {"allow","deny","ask"}。"""
    body = json.dumps({"operation": operation, "cwd": cwd, "tool": tool}).encode()
    req = urllib.request.Request(URL, data=body,
                                headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        data = json.loads(resp.read().decode())
    decision = data.get("decision", "ask")
    if decision not in ("allow", "deny", "ask"):
        decision = "ask"
    return (decision, data.get("reason", ""))


def emit_claude(decision: str, reason: str) -> None:
    # decision ∈ {"allow","deny","ask"}；ask 即回退 Claude Code 正常审批流程
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": decision,
        "permissionDecisionReason": reason,
    }}))


def emit_codex(decision: str, reason: str) -> None:
    out = {"hookEventName": "PermissionRequest"}
    if decision == "allow":
        out["decision"] = {"behavior": "allow"}
    elif decision == "deny":
        out["decision"] = {"behavior": "deny", "message": reason}
    # ask：不返回 decision 字段 -> Codex 走正常审批流程
    print(json.dumps({"hookSpecificOutput": out}))


def main() -> int:
    target = sys.argv[1] if len(sys.argv) > 1 else "claude"
    payload = read_input()
    op = operation_label(payload)
    cwd = payload.get("cwd", "") or ""
    tool = payload.get("tool_name", "") or ""

    try:
        decision, reason = ask_app(op, cwd, tool)
        reason = f"手势审批: {reason}"
    except Exception as e:
        # app 没开/不可达：回退到终端正常审批（而非硬性拒绝），并在终端提示一行，
        # 避免用户误以为「手势审批静默失效是 bug」。stderr 不影响 hook 的 stdout 协议。
        decision = "ask"
        reason = f"手势审批不可用，交回终端: {e}"
        print("⚠️  GestureApprove 离线（未运行或端口不可达），本次交回终端正常审批。",
              file=sys.stderr)

    (emit_codex if target == "codex" else emit_claude)(decision, reason)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
