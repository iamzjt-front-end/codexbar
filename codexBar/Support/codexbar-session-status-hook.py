#!/usr/bin/env python3
"""Best-effort Codex hook bridge for CodexAppBar's task activity center.

Codex invokes this script with an event name and a JSON object on stdin, for
example:

    python3 codexbar-session-status-hook.py UserPromptSubmit

Only a small, privacy-safe projection of the hook payload is persisted. The
script deliberately produces no stdout/stderr output and always exits zero so
status reporting can never block a Codex turn.
"""

import datetime as _dt
import hashlib
import json
import os
import sys
import tempfile
import unicodedata
from pathlib import Path


SCHEMA_VERSION = 2

EVENT_STATUS = {
    "SessionStart": ("ready", "connecting"),
    "UserPromptSubmit": ("running", "processing"),
    "PermissionRequest": ("needs_attention", "awaiting_permission"),
    "Stop": ("ready", "waiting_input"),
}

LEGACY_PHASE = {
    "connecting": "连接会话",
    "processing": "处理请求",
    "compacting": "正在自动压缩上下文",
    "awaiting_permission": "等待权限确认",
    "waiting_input": "等待输入",
}


def _load_stdin():
    try:
        raw = sys.stdin.read()
    except Exception:
        return None

    if not raw.strip():
        return None

    try:
        payload = json.loads(raw)
    except (TypeError, ValueError):
        return None
    return payload if isinstance(payload, dict) else None


def _string_value(value):
    if not isinstance(value, str):
        return None
    value = value.strip()
    return value or None


def _clean_text(value, maximum_length, fallback=None):
    """Return a bounded display value that the Swift decoder will accept."""

    value = _string_value(value)
    if value is None:
        return fallback

    # The App rejects control/format characters before displaying hook data.
    # Remove them at the source so a valid event is never quarantined merely
    # because Codex supplied an unusual cwd or model label.
    value = "".join(
        character
        for character in value
        if not unicodedata.category(character).startswith("C")
    ).strip()
    if not value:
        return fallback
    return value[:maximum_length]


def _event_name(payload):
    if len(sys.argv) > 1:
        event = _string_value(sys.argv[1])
        if event:
            return event

    event = _string_value(payload.get("hook_event_name"))
    if event:
        return event
    return _string_value(os.environ.get("CODEX_HOOK_EVENT"))


def _event_variant(event, payload):
    if len(sys.argv) > 2:
        variant = _string_value(sys.argv[2])
        if variant:
            return variant
    if event == "SessionStart":
        return _string_value(payload.get("source"))
    return None


def _status_for_event(event, variant):
    if event == "SessionStart" and variant and variant.lower() == "compact":
        return "running", "compacting"
    return EVENT_STATUS.get(event, (None, None))


def _sha256(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _project_name(payload):
    cwd = _string_value(payload.get("cwd"))
    if not cwd:
        return "Unknown"

    # Path.name intentionally persists only the final component, never the full
    # path supplied by Codex.
    name = Path(cwd).name
    return _clean_text(name, 120, fallback="Unknown")


def _canonical_json(value):
    try:
        return json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
    except (TypeError, ValueError):
        return ""


def _event_key(payload, session_id, turn_id, event, variant):
    """Build a stable, opaque key for de-duplicating one logical hook event.

    Turn-scoped events use the raw turn id only as hash input. Permission
    requests also include the tool name/input so two distinct approvals in one
    turn remain distinct, while a retried delivery of the same approval keeps
    the same key. None of these source values are persisted.
    """

    parts = [
        "codexbar-task-event-v2",
        session_id,
        turn_id or "",
        event,
        variant or "",
    ]
    if event == "PermissionRequest":
        parts.append(_string_value(payload.get("tool_name")) or "")
        parts.append(_canonical_json(payload.get("tool_input")))
    return _sha256("\0".join(parts))


def _ensure_private_directory(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path, 0o700)


def _atomic_write_json(target, value):
    """Atomically replace ``target`` with a private, durable JSON file."""

    _ensure_private_directory(target.parent)
    file_descriptor = None
    temporary_path = None
    try:
        file_descriptor, temporary_name = tempfile.mkstemp(
            prefix=".%s." % target.name,
            dir=str(target.parent),
        )
        temporary_path = Path(temporary_name)
        os.fchmod(file_descriptor, 0o600)
        with os.fdopen(file_descriptor, "w", encoding="utf-8") as output:
            file_descriptor = None
            json.dump(value, output, ensure_ascii=False, separators=(",", ":"))
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(str(temporary_path), str(target))
        temporary_path = None
        os.chmod(target, 0o600)
    finally:
        if file_descriptor is not None:
            os.close(file_descriptor)
        if temporary_path is not None:
            try:
                temporary_path.unlink()
            except FileNotFoundError:
                pass


def _legacy_status(state, phase, project_name, updated_at, event):
    source = "%s:compact" % event if phase == "compacting" else event
    return {
        "state": state,
        "phase": LEGACY_PHASE[phase],
        "title": project_name,
        "updatedAt": updated_at,
        "source": source,
        "detail": "Codex 需要你处理" if state == "needs_attention" else None,
    }


def main():
    # New directories and temporary files must start private even before their
    # explicit chmod calls below.
    os.umask(0o077)

    payload = _load_stdin()
    if payload is None:
        return

    event = _event_name(payload)
    variant = _event_variant(event, payload)
    state, phase = _status_for_event(event, variant)
    if state is None:
        return

    session_id = _string_value(payload.get("session_id"))
    if not session_id:
        # Without Codex's stable session id we cannot safely distinguish tasks.
        return

    turn_id = _string_value(payload.get("turn_id"))
    task_key = _sha256(session_id)
    turn_key = _sha256(turn_id) if turn_id else None
    project_name = _project_name(payload)
    model = _clean_text(payload.get("model"), 160)
    updated_at = _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="milliseconds")

    status = {
        "schemaVersion": SCHEMA_VERSION,
        "taskKey": task_key,
        "turnKey": turn_key,
        "eventKey": _event_key(payload, session_id, turn_id, event, variant),
        "state": state,
        "phase": phase,
        "projectName": project_name,
        "model": model,
        "updatedAt": updated_at,
        "source": event,
    }

    out_dir = Path.home() / ".codex" / "codexbar"
    sessions_dir = out_dir / "sessions"
    _ensure_private_directory(out_dir)
    _ensure_private_directory(sessions_dir)

    # v2 is written first so a legacy-write failure cannot prevent the task
    # center from receiving the latest per-session state.
    _atomic_write_json(sessions_dir / (task_key + ".json"), status)
    _atomic_write_json(
        out_dir / "session_status.json",
        _legacy_status(state, phase, project_name, updated_at, event),
    )


if __name__ == "__main__":
    try:
        main()
    except BaseException:
        # The indicator is best-effort. Never make a Codex turn wait on, or
        # fail because of, this status bridge. Intentionally emit no output.
        pass
