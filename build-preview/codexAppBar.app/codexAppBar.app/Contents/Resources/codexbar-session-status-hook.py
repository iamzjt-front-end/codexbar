#!/usr/bin/env python3
"""
Codex hook bridge for CodexAppBar's conversation traffic lights.

Configure Codex hooks to call this script with the hook event name:
python3 /absolute/path/to/codexbar-session-status-hook.py UserPromptSubmit
"""

import datetime as _dt
import json
import os
import re
import sys
import tempfile
from pathlib import Path


STATE_BY_EVENT = {
    "SessionStart": "ready",
    "UserPromptSubmit": "running",
    "PreToolUse": "running",
    "PermissionRequest": "needs_attention",
    "PostToolUse": "running",
    "Stop": "ready",
    "SubagentStart": "running",
    "SubagentStop": "running",
}

THREAD_ID_KEYS = [
    "thread_id",
    "threadId",
    "thread",
    "conversation_id",
    "conversationId",
    "conversation",
]

THREAD_ID_ENV_KEYS = [
    "CODEX_THREAD_ID",
    "CODEX_THREADID",
    "CODEX_CONVERSATION_ID",
    "CODEX_CONVERSATIONID",
]

COMPACT_KEYS = [
    "source",
    "reason",
    "start_reason",
    "startReason",
    "session_start_source",
    "sessionStartSource",
    "trigger",
    "matcher",
]

THREAD_ID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)


def _first_value(obj, keys):
    if isinstance(obj, dict):
        for key in keys:
            if key in obj and obj[key] not in (None, ""):
                return obj[key]
        for value in obj.values():
            found = _first_value(value, keys)
            if found not in (None, ""):
                return found
    elif isinstance(obj, list):
        for item in obj:
            found = _first_value(item, keys)
            if found not in (None, ""):
                return found
    return None


def _load_stdin():
    raw = sys.stdin.read()
    if not raw.strip():
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {"raw": raw[:1000]}


def _event_name():
    if len(sys.argv) > 1:
        return sys.argv[1]
    return os.environ.get("CODEX_HOOK_EVENT", "Unknown")


def _event_variant(payload):
    if len(sys.argv) > 2 and sys.argv[2]:
        return sys.argv[2]
    return _first_value(payload, COMPACT_KEYS)


def _is_compact(event, payload, variant):
    if event != "SessionStart":
        return False
    if variant and str(variant).lower() == "compact":
        return True
    marker = _first_value(payload, COMPACT_KEYS)
    return marker is not None and str(marker).lower() == "compact"


def _thread_id(payload):
    for key in THREAD_ID_ENV_KEYS:
        value = os.environ.get(key)
        if value and THREAD_ID_RE.match(value):
            return value

    value = _first_value(payload, THREAD_ID_KEYS)
    if value is None:
        return None
    value = str(value)
    return value if THREAD_ID_RE.match(value) else None


def _phase(event, payload, variant):
    if _is_compact(event, payload, variant):
        return "正在自动压缩上下文"

    tool = _first_value(payload, ["tool_name", "toolName", "tool", "name"])
    if event in ("PreToolUse", "PostToolUse") and tool:
        return f"执行 {tool}"
    if event == "PermissionRequest":
        return "等待权限确认"
    if event == "UserPromptSubmit":
        return "处理请求"
    if event == "SessionStart":
        return "连接会话"
    if event == "Stop":
        return "等待输入"
    return event


def _detail(event, state, payload, variant):
    if _is_compact(event, payload, variant):
        return "Codex 正在自动压缩上下文"

    if state == "needs_attention":
        tool = _first_value(payload, ["tool_name", "toolName", "tool", "name"])
        if event == "PermissionRequest" and tool:
            return f"Codex 等待权限确认：{tool}"
        err = _first_value(payload, ["error", "last_error", "lastError", "stderr"])
        if err:
            return str(err)[:180]
        return "Codex 需要你处理"
    return _first_value(payload, ["message", "statusMessage", "summary"])


def _state(event, payload, variant):
    if _is_compact(event, payload, variant):
        return "running"

    state = STATE_BY_EVENT.get(event, "running")
    exit_code = _first_value(payload, ["exit_code", "exitCode", "code"])
    if event == "PostToolUse" and exit_code not in (None, 0, "0"):
        return "needs_attention"
    return state


def main():
    event = _event_name()
    payload = _load_stdin()
    variant = _event_variant(payload)
    state = _state(event, payload, variant)
    out_dir = Path.home() / ".codex" / "codexbar"
    out_dir.mkdir(parents=True, exist_ok=True)
    source = f"{event}:{variant}" if variant else event

    status = {
        "threadId": _thread_id(payload),
        "state": state,
        "phase": _phase(event, payload, variant),
        "title": _first_value(payload, ["title", "thread_title", "threadTitle"]),
        "updatedAt": _dt.datetime.now(_dt.timezone.utc).isoformat(),
        "source": source,
        "detail": _detail(event, state, payload, variant),
    }

    target = out_dir / "session_status.json"
    with tempfile.NamedTemporaryFile("w", dir=out_dir, delete=False) as tmp:
        json.dump(status, tmp, ensure_ascii=False, separators=(",", ":"))
        tmp.write("\n")
        tmp_path = Path(tmp.name)
    tmp_path.replace(target)


if __name__ == "__main__":
    main()
