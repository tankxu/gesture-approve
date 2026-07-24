#!/usr/bin/env python3
"""Claude Session Hub —— 独立于 GestureApprove 的本地中枢(可抽离)。

给 ESP32/网页等设备提供:
  · 会话列表 / 聊天记录(读本地 ~/.claude 文件,零风险)
  · 审批(GA 开着 → 代理 GA 设备 API;GA 没开 → 关键字解析,待接)
  · 语音转写 ASR(SiliconFlow,待接)
  · 回复注入(驱动 claude.ai/code 网页,待接)

设计原则:不 import GA 任何代码;只在需要时用 HTTP 调 GA 的设备 API。
整个 hub/ 目录拷走即可独立运行。GA 的 tray 只作它的开关/状态入口。

跑:python3 hub.py  然后 http://127.0.0.1:8787
"""
import glob
import json
import os
import subprocess
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import secrets
import socket

HUB_PORT = int(os.environ.get("HUB_PORT", "8787"))
HUB_BIND = os.environ.get("HUB_BIND", "0.0.0.0")   # 绑全网卡,ESP32 可连;设 127.0.0.1 可只本机
CLAUDE_HOME = os.path.expanduser("~/.claude")
GA_DEV_PORT = os.environ.get("GESTURE_DEVICE_PORT", "47602")   # GA 设备 API(审批)
GA_HOOK_PORT = os.environ.get("GESTURE_APPROVE_PORT", "47600")

# hub 自己的配置(token 等)存用户目录,不进仓库。
HUB_CONFIG_DIR = os.path.expanduser("~/.claude-session-hub")
HUB_CONFIG_PATH = os.path.join(HUB_CONFIG_DIR, "config.json")


def _load_config() -> dict:
    try:
        return json.load(open(HUB_CONFIG_PATH))
    except Exception:
        return {}


def hub_token() -> str:
    """hub 设备口 token:首次生成并持久化。ESP32 每个请求带 Authorization: Bearer <token>。"""
    if os.environ.get("HUB_TOKEN"):
        return os.environ["HUB_TOKEN"]
    cfg = _load_config()
    tok = cfg.get("token")
    if not tok:
        tok = secrets.token_hex(16)
        cfg["token"] = tok
        os.makedirs(HUB_CONFIG_DIR, exist_ok=True)
        with open(HUB_CONFIG_PATH, "w") as f:
            json.dump(cfg, f, indent=2)
        try:
            os.chmod(HUB_CONFIG_PATH, 0o600)
        except Exception:
            pass
    return tok


def local_ips() -> list:
    """真实网卡 IPv4(en0/en1…),过滤掉 ClashX TUN(198.18/198.19/100.64)、link-local、回环。
    不能用"连 8.8.8.8 看默认路由"的技巧——TUN 模式下会返回虚拟网关 198.18.0.1,手机连不上。"""
    def ok(ip):
        bad = ("198.18.", "198.19.", "100.64.", "169.254.", "127.")
        return ip and not any(ip.startswith(b) for b in bad)
    ips = []
    for i in range(0, 10):
        try:
            r = subprocess.run(["ipconfig", "getifaddr", f"en{i}"],
                               capture_output=True, text=True, timeout=1)
            ip = r.stdout.strip()
            if ip and ip not in ips and ok(ip):
                ips.append(ip)
        except Exception:
            pass
    if ips:
        return ips
    try:  # 兜底
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80)); ip = s.getsockname()[0]; s.close()
        if ok(ip):
            return [ip]
    except Exception:
        pass
    return []


HUB_TOKEN = hub_token()


def config_data() -> dict:
    ips = local_ips()
    base = f"http://{ips[0]}:{HUB_PORT}" if ips else ""
    key = siliconflow_key()
    masked = (key[:6] + "…" + key[-4:]) if len(key) > 12 else ("已设置" if key else "")
    return {
        "port": HUB_PORT,
        "bind": HUB_BIND,
        "token": HUB_TOKEN,
        "baseUrls": [f"http://{ip}:{HUB_PORT}" for ip in ips],
        "phoneUrl": (f"{base}/?token={HUB_TOKEN}" if base else ""),
        "siliconflowKeySet": bool(key),
        "siliconflowKeyMasked": masked,
        "configPath": HUB_CONFIG_PATH,
    }


def set_config(updates: dict) -> list:
    """把允许的字段写入 config.json(合并,保留其它)。返回改动过的键。"""
    cfg = _load_config()
    changed = []
    if "siliconflow_key" in updates:
        v = str(updates["siliconflow_key"]).strip()
        if v:
            cfg["siliconflow_key"] = v
            changed.append("siliconflow_key")
    if changed:
        os.makedirs(HUB_CONFIG_DIR, exist_ok=True)
        with open(HUB_CONFIG_PATH, "w") as f:
            json.dump(cfg, f, indent=2)
        try:
            os.chmod(HUB_CONFIG_PATH, 0o600)
        except Exception:
            pass
    return changed


def ga_token() -> str:
    if os.environ.get("GESTURE_DEVICE_TOKEN"):
        return os.environ["GESTURE_DEVICE_TOKEN"]
    try:
        out = subprocess.check_output(
            ["defaults", "read", "com.tankxu.gestureapprove", "deviceApiToken"],
            stderr=subprocess.DEVNULL)
        return out.decode().strip()
    except Exception:
        return ""


# ---------- 读本地会话数据 ----------

def _alive(pid) -> bool:
    try:
        os.kill(int(pid), 0)
        return True
    except Exception:
        return False


def _ai_title(sid: str) -> str:
    """从会话 transcript 里取最新 aiTitle(= 客户端 Recents 显示的标题)。"""
    f = _transcript_path(sid)
    if not f:
        return ""
    t = ""
    try:
        for line in open(f, errors="ignore"):
            line = line.strip()
            if not line or '"aiTitle"' not in line:
                continue
            try:
                d = json.loads(line)
                if d.get("aiTitle"):
                    t = d["aiTitle"]
            except Exception:
                pass
    except Exception:
        pass
    return t


def _transcript_path(sid: str):
    hits = glob.glob(os.path.join(CLAUDE_HOME, "projects", "*", sid + "*.jsonl"))
    return hits[0] if hits else None


def _first_user_text(sid: str, max_len: int = 40) -> str:
    """没有 aiTitle 时的兜底标题:首条用户消息(截断、去换行)。比派生名 localdev-30 可读得多。"""
    f = _transcript_path(sid)
    if not f:
        return ""
    try:
        for line in open(f, errors="ignore"):
            line = line.strip()
            if not line or '"user"' not in line:
                continue
            try:
                d = json.loads(line)
            except Exception:
                continue
            if d.get("type") != "user":
                continue
            m = d.get("message", {})
            c = m.get("content") if isinstance(m, dict) else None
            if isinstance(c, str) and c.strip():
                t = " ".join(c.split())
                return t[:max_len] + ("…" if len(t) > max_len else "")
    except OSError:
        pass
    return ""


# ---------- 会话状态检测(借鉴 taskhub:检测 AskUserQuestion 工具,不用关键字) ----------
# taskhub 的教训:纯关键字/问句文本会在"闲聊式提问结尾"误报 WAIT,故改用结构化工具信号。
HUMAN_INPUT_TOOLS = {"AskUserQuestion"}
TERMINAL_STOP_REASONS = {"end_turn", "stop_sequence", "max_tokens"}
QUESTION_STALE_MS = 3600000   # 超过 1h 的未答问题不再算"在等"

import time as _time
from datetime import datetime as _dt


def _now_ms() -> int:
    return int(_time.time() * 1000)


def _iso_to_ms(ts) -> int:
    if not ts:
        return 0
    try:
        s = str(ts).replace("Z", "+00:00")
        return int(_dt.fromisoformat(s).timestamp() * 1000)
    except Exception:
        return 0


def scan_state(sid: str) -> dict:
    """扫 transcript 判定会话回合状态:active(跑) / tool(在用工具) / wait(等你答问题) / done。
    wait 只在最后一次 AskUserQuestion 晚于终止且未被回答、且 1h 内时成立。"""
    f = _transcript_path(sid)
    if not f:
        return {"state": "", "waiting_for_user": False}
    latest_user_ms = latest_terminal_ms = latest_human_input_ms = 0
    latest_turn_ms = 0
    latest_turn_type = ""
    latest_stop = ""
    try:
        for line in open(f, errors="ignore"):
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except Exception:
                continue
            typ = d.get("type")
            if typ not in ("user", "assistant"):
                continue
            ms = _iso_to_ms(d.get("timestamp"))
            m = d.get("message", {})
            if not isinstance(m, dict):
                continue
            if typ == "user":
                if ms:
                    latest_user_ms = max(latest_user_ms, ms)
                    latest_turn_ms, latest_turn_type = ms, "user"
            else:  # assistant
                stop = str(m.get("stop_reason") or "")
                if ms:
                    latest_turn_ms, latest_turn_type = ms, "assistant"
                    latest_stop = stop
                content = m.get("content")
                names = [x.get("name") for x in content if isinstance(x, dict) and x.get("type") == "tool_use"] if isinstance(content, list) else []
                if ms and any(n in HUMAN_INPUT_TOOLS for n in names):
                    latest_human_input_ms = ms
                if ms and stop in TERMINAL_STOP_REASONS:
                    latest_terminal_ms = ms
    except OSError:
        return {"state": "", "waiting_for_user": False}

    waiting = (latest_human_input_ms > latest_terminal_ms
               and latest_human_input_ms > latest_user_ms
               and (_now_ms() - latest_human_input_ms) <= QUESTION_STALE_MS)
    active_turn = False
    if latest_turn_ms:
        if latest_turn_type == "assistant":
            active_turn = latest_stop not in TERMINAL_STOP_REASONS
        else:
            active_turn = latest_turn_ms > latest_terminal_ms
    if waiting:
        state = "wait"
    elif active_turn:
        state = "tool" if latest_stop == "tool_use" else "active"
    elif latest_stop in TERMINAL_STOP_REASONS:
        state = "done"
    else:
        state = ""
    return {"state": state, "waiting_for_user": waiting}


def list_sessions() -> list:
    """读 ~/.claude/sessions/*.json 活跃会话注册表,拼上 aiTitle。"""
    rows = []
    for f in glob.glob(os.path.join(CLAUDE_HOME, "sessions", "*.json")):
        try:
            d = json.load(open(f))
        except Exception:
            continue
        sid = d.get("sessionId", "")
        st = scan_state(str(sid))
        rows.append({
            "sessionId": sid,
            "bridgeSessionId": d.get("bridgeSessionId"),
            "title": _ai_title(str(sid)) or _first_user_text(str(sid)) or d.get("name", ""),
            "titleSource": ("aiTitle" if _ai_title(str(sid)) else ("firstMsg" if _first_user_text(str(sid)) else "name")),
            "name": d.get("name", ""),
            "entrypoint": d.get("entrypoint", ""),   # cli / claude-desktop
            "status": d.get("status", ""),           # busy / idle(注册表侧)
            "state": st["state"],                    # active/tool/wait/done(transcript 侧)
            "waitingForUser": st["waiting_for_user"],# 是否在等你回答(AskUserQuestion 未答)
            "cwd": d.get("cwd", ""),
            "pid": d.get("pid"),
            "alive": _alive(d.get("pid", 0)),
            "updatedAt": d.get("updatedAt", 0),
            # 接力/回复用:claude.ai 网页地址(桥接 id)
            "webUrl": (f"https://claude.ai/code/{d.get('bridgeSessionId')}"
                       if d.get("bridgeSessionId") else None),
        })
    rows.sort(key=lambda r: r.get("updatedAt", 0), reverse=True)
    return rows


def _message_parts(content):
    """把一条消息拆成 (人类可见文本, 工具标记列表)。
    人类文本 = str 内容 或 text 块;工具标记 = tool_use 名 / tool_result。thinking 跳过。"""
    if isinstance(content, str):
        return content, []
    human, tools = [], []
    if isinstance(content, list):
        for x in content:
            if not isinstance(x, dict):
                continue
            typ = x.get("type")
            if typ == "text":
                human.append(x.get("text", ""))
            elif typ == "tool_use":
                tools.append(f"[工具: {x.get('name', '')}]")
            elif typ == "tool_result":
                tools.append("[工具结果]")
    return "\n".join(p for p in human if p), tools


def session_messages(sid: str, limit: int, offset: int, max_len: int,
                     include_tools: bool = False) -> dict:
    """解析 transcript,返回按时间正序的消息(分页:最新在末尾)。
    默认只保留真正的人类提问 + Claude 文字回复;工具往返(tool_use/tool_result)默认滤掉
    (它们是模型与工具的内部管道,不是人对话)。include_tools=1 可看完整。"""
    f = _transcript_path(sid)
    if not f:
        return {"error": "transcript not found", "sessionId": sid}
    msgs = []
    for line in open(f, errors="ignore"):
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get("type") not in ("user", "assistant"):
            continue
        m = d.get("message", {})
        if not isinstance(m, dict):
            continue
        human, tools = _message_parts(m.get("content"))
        if human.strip():
            text = human[:max_len]
        elif include_tools and tools:
            text = " ".join(tools)   # 只有工具、且要求含工具时才显示标记
        else:
            continue                 # 纯工具往返 → 默认跳过(不再出现 [工具结果] 噪声)
        msgs.append({"role": m.get("role"), "text": text, "ts": d.get("timestamp")})
    total = len(msgs)
    # offset=0 表示最新一页;向前翻用 offset 增加
    end = total - offset
    start = max(0, end - limit)
    page = msgs[start:end] if end > 0 else []
    return {"sessionId": sid, "total": total, "offset": offset, "limit": limit,
            "title": _ai_title(sid), "messages": page}


# ---------- ASR(SiliconFlow SenseVoiceSmall) ----------

SF_ASR_URL = "https://api.siliconflow.cn/v1/audio/transcriptions"
SF_ASR_MODEL = os.environ.get("SILICONFLOW_ASR_MODEL", "FunAudioLLM/SenseVoiceSmall")


def siliconflow_key() -> str:
    return os.environ.get("SILICONFLOW_KEY") or _load_config().get("siliconflow_key", "")


def transcribe(audio: bytes, content_type: str, filename: str) -> tuple:
    """把原始音频转发给 SiliconFlow,返回 (status, {text}/{error})。key 留 Mac,不下发设备。"""
    key = siliconflow_key()
    if not key:
        return 400, {"error": "siliconflow_key 未配置(写入 ~/.claude-session-hub/config.json 或设 SILICONFLOW_KEY)"}
    boundary = "----hubasr" + secrets.token_hex(8)
    pre = (
        f'--{boundary}\r\nContent-Disposition: form-data; name="model"\r\n\r\n{SF_ASR_MODEL}\r\n'
        f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{filename}"\r\n'
        f'Content-Type: {content_type}\r\n\r\n'
    ).encode()
    body = pre + audio + f'\r\n--{boundary}--\r\n'.encode()
    req = urllib.request.Request(SF_ASR_URL, data=body, method="POST", headers={
        "Authorization": f"Bearer {key}",
        "Content-Type": f"multipart/form-data; boundary={boundary}",
    })
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.loads(resp.read().decode())
            return 200, {"text": data.get("text", ""), "model": SF_ASR_MODEL}
    except urllib.error.HTTPError as e:
        return e.code, {"error": "siliconflow " + str(e.code), "detail": e.read().decode(errors="ignore")[:300]}
    except Exception as e:
        return 599, {"error": f"asr failed: {e}"}


# ---------- 回复注入(驱动 claude.ai/code 网页,走订阅) ----------

def bridge_for(sid: str):
    for f in glob.glob(os.path.join(CLAUDE_HOME, "sessions", "*.json")):
        try:
            d = json.load(open(f))
        except Exception:
            continue
        if str(d.get("sessionId", "")) == sid:
            return d.get("bridgeSessionId")
    return None


def browser_reply(bridge_id: str, text: str, send: bool) -> tuple:
    """在 Chrome 里导航到 claude.ai/code/<bridge> 的标签、把 text 注入 ProseMirror 输入框。
    默认只填不发;send=True 时等按钮异步启用后点 button[aria-label=Send] 发送。
    text 走 base64,避开一切转义。"""
    import base64
    b64 = base64.b64encode(text.encode("utf-8")).decode("ascii")
    url = f"https://claude.ai/code/{bridge_id}"
    # 填入:全选替换旧草稿 → execCommand insertText(会进 ProseMirror/React 状态)
    fill = ("(function(){var b='" + b64 + "';var t=decodeURIComponent(escape(atob(b)));"
            "var eds=[].slice.call(document.querySelectorAll('.ProseMirror'));"
            "eds.sort(function(a,b){return b.getBoundingClientRect().width-a.getBoundingClientRect().width});"
            "var ed=eds[0];if(!ed)return 'NO_COMPOSER';ed.focus();"
            "var s=window.getSelection();s.selectAllChildren(ed);"
            "document.execCommand('insertText',false,t);"
            "return (ed.innerText||'').slice(0,80)})()")
    probe = "(function(){var e=document.querySelector('.ProseMirror');return e?'1':'0'})()"
    click = ("(function(){var b=document.querySelector('button[aria-label=Send]');"
             "if(!b)return 'no_btn';if(b.disabled)return 'disabled';b.click();return 'clicked'})()")
    tail = ('  delay 0.7\n  set clicked to execute found javascript "' + click + '"\n'
            '  return "SEND|" & clicked & "|" & filled') if send else '  return "FILL|" & filled'
    script = f'''tell application "Google Chrome"
  set target to "{url}"
  set found to missing value
  repeat with w in windows
    repeat with t in tabs of w
      try
        if (URL of t) contains "claude.ai/code" then set found to t
      end try
    end repeat
  end repeat
  if found is missing value then
    if (count of windows) is 0 then make new window
    set found to make new tab at end of tabs of front window with properties {{URL:target}}
  else
    if (URL of found) does not contain "{bridge_id}" then set URL of found to target
  end if
  set ok to false
  repeat 30 times
    delay 0.4
    try
      if (execute found javascript "{probe}") is "1" then set ok to true
    end try
    if ok then exit repeat
  end repeat
  if not ok then return "NO_COMPOSER"
  set filled to execute found javascript "{fill}"
{tail}
end tell'''
    try:
        p = subprocess.run(["osascript"], input=script, text=True,
                           capture_output=True, timeout=45)
    except Exception as e:
        return 500, {"error": f"osascript failed: {e}"}
    out = (p.stdout or "").strip()
    err = (p.stderr or "").strip()
    if p.returncode != 0:
        return 500, {"error": "osascript error", "detail": err[:300]}
    if out == "NO_COMPOSER" or out.endswith("NO_COMPOSER"):
        return 504, {"error": "输入框未出现(页面没加载好 / 未登录 claude.ai / bridgeSessionId 不对)"}
    if out.startswith("SEND|"):
        parts = out.split("|", 2)
        clicked = parts[1] if len(parts) > 1 else ""
        readback = parts[2] if len(parts) > 2 else ""
        sent = clicked == "clicked"
        return 200, {"ok": True, "sent": sent, "sendResult": clicked, "readback": readback}
    if out.startswith("FILL|"):
        return 200, {"ok": True, "sent": False, "readback": out.split("|", 1)[1]}
    return 200, {"ok": True, "sent": False, "readback": out}


# ---------- 代理 GA 设备 API(审批) ----------

def _ga_proxy(path: str, method="GET", body=None, token=True, timeout=35):
    headers = {"Content-Type": "application/json"}
    tok = ga_token()
    if token and tok:
        headers["Authorization"] = f"Bearer {tok}"
    url = f"http://127.0.0.1:{GA_DEV_PORT}{path}"
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception as e:
        return 599, json.dumps({"error": f"GA unreachable: {e}"}).encode()


# ---------- HTTP ----------

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _q(self):
        from urllib.parse import urlparse, parse_qs
        u = urlparse(self.path)
        return u.path, {k: v[0] for k, v in parse_qs(u.query).items()}

    def _json(self, obj, status=200):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _raw(self, status, body):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authed(self) -> bool:
        return self.headers.get("Authorization", "") == f"Bearer {HUB_TOKEN}"

    def _need_auth(self, path: str) -> bool:
        return path != "/health"   # 只有健康检查免认证

    def _is_loopback(self) -> bool:
        ip = self.client_address[0] if self.client_address else ""
        return ip in ("127.0.0.1", "::1", "::ffff:127.0.0.1")

    def _serve_demo(self, q):
        """demo 页面,token 内嵌。本机直接给;局域网(手机)需 URL 带 ?token=<token> 才给,
        避免任何 LAN 设备裸取到 token。"""
        if not self._is_loopback() and q.get("token") != HUB_TOKEN:
            self._json({"error": "从局域网访问请在 URL 后带 ?token=<你的token>"}, 403)
            return
        try:
            html = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "demo.html")).read()
        except Exception as e:
            self._json({"error": f"demo.html missing: {e}"}, 500)
            return
        html = html.replace("__HUB_TOKEN__", HUB_TOKEN)
        body = html.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path, q = self._q()
        if path == "/health":
            self._json({"ok": True, "service": "claude-session-hub",
                        "siliconflowKeySet": bool(siliconflow_key())})
            return
        if path in ("/", "/demo", "/index.html"):
            self._serve_demo(q)
            return
        if path in ("/config", "/config.html"):
            if not self._is_loopback():
                self._json({"error": "config page is loopback-only"}, 403); return
            try:
                html = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.html")).read()
            except Exception as e:
                self._json({"error": f"config.html missing: {e}"}, 500); return
            body = html.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path == "/config/data":
            if not self._is_loopback():
                self._json({"error": "loopback-only"}, 403); return
            self._json(config_data())
            return
        if self._need_auth(path) and not self._authed():
            self._json({"error": "unauthorized"}, 401)
            return
        if path == "/sessions":
            self._json({"sessions": list_sessions()})
            return
        if path == "/pending":
            self._json({"sessions": [s for s in list_sessions() if s["waitingForUser"]]})
            return
        if path.startswith("/session/") and path.endswith("/messages"):
            sid = path[len("/session/"):-len("/messages")]
            self._json(session_messages(
                sid,
                limit=int(q.get("limit", "40")),
                offset=int(q.get("offset", "0")),
                max_len=int(q.get("max_len", "4000")),
                include_tools=q.get("include_tools", "0") in ("1", "true")))
            return
        if path.startswith("/ga/state"):
            status, body = _ga_proxy("/state?" + self.path.split("?", 1)[-1] if "?" in self.path else "/state")
            self._raw(status, body)
            return
        self._json({"error": "not found", "path": path}, 404)

    def do_POST(self):
        path, _ = self._q()
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n) if n else b""
        if path == "/config/set":   # 仅 loopback,免 token(配置页在本机)
            if not self._is_loopback():
                self._json({"error": "loopback-only"}, 403); return
            try:
                o = json.loads(body) if body else {}
            except Exception:
                o = {}
            changed = set_config(o)
            self._json({"ok": True, "changed": changed})
            return
        if path == "/config/stop":   # 仅 loopback:停掉 hub 自身(启动由 GA tray 负责)
            if not self._is_loopback():
                self._json({"error": "loopback-only"}, 403); return
            self._json({"ok": True, "stopping": True})
            import threading
            import time as _t

            def _bye():
                _t.sleep(0.4)
                os._exit(0)
            threading.Thread(target=_bye, daemon=True).start()
            return
        if self._need_auth(path) and not self._authed():
            self._json({"error": "unauthorized"}, 401)
            return
        if path == "/asr":
            ct = self.headers.get("Content-Type", "audio/wav")
            if "wav" in ct:
                fn = "audio.wav"
            elif "mp4" in ct or "m4a" in ct or "aac" in ct:
                fn = "audio.m4a"
            elif "mpeg" in ct or "mp3" in ct:
                fn = "audio.mp3"
            else:
                ct, fn = "audio/wav", "audio.wav"
            status, obj = transcribe(body, ct, fn)
            self._json(obj, status)
            return
        if path == "/reply":
            try:
                o = json.loads(body) if body else {}
            except Exception:
                o = {}
            bridge = o.get("bridgeSessionId") or (bridge_for(o["sessionId"]) if o.get("sessionId") else None)
            text = o.get("text", "")
            if not bridge:
                self._json({"error": "缺 bridgeSessionId(或可解析的 sessionId)"}, 400); return
            if not text.strip():
                self._json({"error": "text 为空"}, 400); return
            status, obj = browser_reply(bridge, text, bool(o.get("send", False)))
            self._json(obj, status)
            return
        if path == "/ga/resolve":
            status, resp = _ga_proxy("/resolve", method="POST", body=body, timeout=10)
            self._raw(status, resp)
            return
        self._json({"error": "not found", "path": path}, 404)


if __name__ == "__main__":
    ips = local_ips()
    base = f"http://{ips[0]}:{HUB_PORT}" if ips else f"http://<本机IP>:{HUB_PORT}"
    print(f"Claude Session Hub  bind={HUB_BIND}:{HUB_PORT}")
    print(f"  设备连接地址: {base}")
    print(f"  Bearer token: {HUB_TOKEN}   (存于 {HUB_CONFIG_PATH})")
    print(f"  配置页: http://127.0.0.1:{HUB_PORT}/config   (仅本机)")
    print(f"  端点: /health /sessions /pending /session/<id>/messages /asr /reply")
    print(f"  GA 设备口 token: {'有' if ga_token() else '缺(审批代理不可用)'}")
    ThreadingHTTPServer((HUB_BIND, HUB_PORT), Handler).serve_forever()
