import concurrent.futures
import hashlib
import json
import os
import stat
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
HOOK = REPOSITORY_ROOT / "codexBar" / "Support" / "codexbar-session-status-hook.py"


def digest(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


class HookV2Tests(unittest.TestCase):
    def setUp(self):
        self.temporary_home = tempfile.TemporaryDirectory()
        self.home = Path(self.temporary_home.name)
        self.environment = os.environ.copy()
        self.environment["HOME"] = str(self.home)

    def tearDown(self):
        self.temporary_home.cleanup()

    def invoke(self, event, payload, variant=None, raw=None):
        command = ["python3", str(HOOK), event]
        if variant is not None:
            command.append(variant)
        input_value = raw if raw is not None else json.dumps(payload)
        return subprocess.run(
            command,
            input=input_value,
            text=True,
            capture_output=True,
            env=self.environment,
            timeout=2,
            check=False,
        )

    def session_file(self, session_id):
        return self.home / ".codex" / "codexbar" / "sessions" / (
            digest(session_id) + ".json"
        )

    def read_session(self, session_id):
        return json.loads(self.session_file(session_id).read_text(encoding="utf-8"))

    def read_legacy(self):
        path = self.home / ".codex" / "codexbar" / "session_status.json"
        return json.loads(path.read_text(encoding="utf-8"))

    def base_payload(self, session_id="session-alpha", turn_id="turn-one"):
        return {
            "session_id": session_id,
            "turn_id": turn_id,
            "cwd": "/Users/private/work/secret-project",
            "model": "gpt-5.6-codex",
            "hook_event_name": "UserPromptSubmit",
        }

    def assert_success_without_output(self, result):
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "")

    def test_fixed_event_mapping_and_schema(self):
        cases = [
            ("SessionStart", None, "ready", "connecting"),
            ("SessionStart", "compact", "running", "compacting"),
            ("UserPromptSubmit", None, "running", "processing"),
            (
                "PermissionRequest",
                None,
                "needs_attention",
                "awaiting_permission",
            ),
            ("Stop", None, "ready", "waiting_input"),
        ]

        allowed_keys = {
            "schemaVersion",
            "taskKey",
            "turnKey",
            "eventKey",
            "state",
            "phase",
            "projectName",
            "model",
            "updatedAt",
            "source",
        }
        for index, (event, variant, state, phase) in enumerate(cases):
            with self.subTest(event=event, variant=variant):
                session_id = "session-%d" % index
                turn_id = None if event == "SessionStart" else "turn-%d" % index
                payload = self.base_payload(session_id, turn_id or "unused")
                if turn_id is None:
                    payload.pop("turn_id")
                if variant is not None:
                    payload["source"] = variant

                result = self.invoke(event, payload, variant)
                self.assert_success_without_output(result)
                output = self.read_session(session_id)
                self.assertEqual(set(output), allowed_keys)
                self.assertEqual(output["schemaVersion"], 2)
                self.assertEqual(output["taskKey"], digest(session_id))
                self.assertEqual(
                    output["turnKey"], digest(turn_id) if turn_id else None
                )
                self.assertEqual(output["state"], state)
                self.assertEqual(output["phase"], phase)
                self.assertEqual(output["projectName"], "secret-project")
                self.assertEqual(output["model"], "gpt-5.6-codex")
                self.assertEqual(output["source"], event)
                self.assertRegex(output["eventKey"], r"^[0-9a-f]{64}$")

    def test_two_sessions_create_two_independent_files(self):
        self.assert_success_without_output(
            self.invoke("UserPromptSubmit", self.base_payload("session-a", "turn-a"))
        )
        self.assert_success_without_output(
            self.invoke("Stop", self.base_payload("session-b", "turn-b"))
        )

        files = list(
            (self.home / ".codex" / "codexbar" / "sessions").glob("*.json")
        )
        self.assertEqual({item.name for item in files}, {
            digest("session-a") + ".json",
            digest("session-b") + ".json",
        })
        self.assertEqual(self.read_session("session-a")["state"], "running")
        self.assertEqual(self.read_session("session-b")["state"], "ready")

    def test_same_session_is_atomically_replaced_with_latest_state(self):
        payload = self.base_payload()
        self.invoke("UserPromptSubmit", payload)
        first = self.read_session("session-alpha")
        self.invoke("Stop", payload)
        second = self.read_session("session-alpha")

        self.assertEqual(first["state"], "running")
        self.assertEqual(second["state"], "ready")
        self.assertEqual(second["phase"], "waiting_input")
        self.assertNotEqual(first["eventKey"], second["eventKey"])

    def test_permission_event_key_deduplicates_retries_but_not_distinct_requests(self):
        payload = self.base_payload()
        payload.update({
            "tool_name": "Bash",
            "tool_input": {"command": "private-command", "description": "secret"},
        })
        self.invoke("PermissionRequest", payload)
        first_key = self.read_session("session-alpha")["eventKey"]

        self.invoke("PermissionRequest", payload)
        retry_key = self.read_session("session-alpha")["eventKey"]

        payload["tool_input"] = {"command": "a-different-private-command"}
        self.invoke("PermissionRequest", payload)
        distinct_key = self.read_session("session-alpha")["eventKey"]

        self.assertEqual(first_key, retry_key)
        self.assertNotEqual(first_key, distinct_key)

    def test_v2_and_legacy_outputs_never_persist_sensitive_fields(self):
        payload = self.base_payload("raw-session-id", "raw-turn-id")
        payload.update({
            "prompt": "highly sensitive prompt",
            "transcript_path": "/Users/private/.codex/transcript.jsonl",
            "title": "private task title",
            "error": "private error body",
            "last_assistant_message": "private conversation body",
            "tool_name": "Bash",
            "tool_input": {"command": "private shell command"},
        })
        self.invoke("PermissionRequest", payload)

        v2 = self.read_session("raw-session-id")
        legacy = self.read_legacy()
        persisted = json.dumps([v2, legacy], ensure_ascii=False)
        forbidden_values = [
            "raw-session-id",
            "raw-turn-id",
            "/Users/private/work/secret-project",
            "highly sensitive prompt",
            "/Users/private/.codex/transcript.jsonl",
            "private task title",
            "private error body",
            "private conversation body",
            "private shell command",
        ]
        for forbidden in forbidden_values:
            self.assertNotIn(forbidden, persisted)
        self.assertIn("secret-project", persisted)
        self.assertEqual(legacy["detail"], "Codex 需要你处理")

    def test_direct_model_and_project_basename_are_preserved(self):
        payload = self.base_payload()
        payload["cwd"] = "/tmp/工程/样例项目/"
        payload["model"] = "custom/provider-model"
        self.invoke("UserPromptSubmit", payload)
        output = self.read_session("session-alpha")
        self.assertEqual(output["projectName"], "样例项目")
        self.assertEqual(output["model"], "custom/provider-model")

    def test_display_fields_are_sanitized_to_repository_limits(self):
        payload = self.base_payload()
        payload["cwd"] = "/tmp/" + ("项" * 140) + "\u0000hidden"
        payload["model"] = ("m" * 170) + "\nprivate"

        result = self.invoke("UserPromptSubmit", payload)

        self.assert_success_without_output(result)
        output = self.read_session("session-alpha")
        self.assertEqual(len(output["projectName"]), 120)
        self.assertEqual(len(output["model"]), 160)
        self.assertNotIn("\u0000", output["projectName"])
        self.assertNotIn("\n", output["model"])

    def test_private_permissions_are_enforced_for_existing_paths(self):
        out_dir = self.home / ".codex" / "codexbar"
        sessions_dir = out_dir / "sessions"
        sessions_dir.mkdir(parents=True)
        os.chmod(out_dir, 0o755)
        os.chmod(sessions_dir, 0o755)

        self.invoke("UserPromptSubmit", self.base_payload())

        self.assertEqual(stat.S_IMODE(out_dir.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(sessions_dir.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(self.session_file("session-alpha").stat().st_mode), 0o600)
        legacy_path = out_dir / "session_status.json"
        self.assertEqual(stat.S_IMODE(legacy_path.stat().st_mode), 0o600)

    def test_malformed_or_missing_session_input_is_ignored_and_exits_zero(self):
        malformed = self.invoke("UserPromptSubmit", {}, raw="{not-json")
        missing_session = self.invoke("UserPromptSubmit", {"turn_id": "turn"})
        non_object = self.invoke("UserPromptSubmit", [], raw="[]")

        for result in (malformed, missing_session, non_object):
            self.assert_success_without_output(result)
        self.assertFalse((self.home / ".codex" / "codexbar").exists())

    def test_unknown_event_is_ignored(self):
        result = self.invoke("UnknownEvent", self.base_payload())
        self.assert_success_without_output(result)
        self.assertFalse((self.home / ".codex" / "codexbar").exists())

    def test_filesystem_failure_is_silent_and_exits_zero(self):
        # Make the expected directory component a regular file so every write
        # must fail. Hook reporting must still never fail the Codex turn.
        (self.home / ".codex").write_text("not-a-directory", encoding="utf-8")
        result = self.invoke("UserPromptSubmit", self.base_payload())
        self.assert_success_without_output(result)

    def test_event_can_be_read_from_official_payload_field(self):
        payload = self.base_payload()
        command = ["python3", str(HOOK)]
        result = subprocess.run(
            command,
            input=json.dumps(payload),
            text=True,
            capture_output=True,
            env=self.environment,
            timeout=2,
            check=False,
        )
        self.assert_success_without_output(result)
        self.assertEqual(self.read_session("session-alpha")["phase"], "processing")

    def test_concurrent_writers_never_expose_partial_json(self):
        session_id = "shared-session"
        target = self.session_file(session_id)
        stop_reading = threading.Event()
        decode_errors = []

        def reader():
            while not stop_reading.is_set():
                try:
                    if target.exists():
                        json.loads(target.read_text(encoding="utf-8"))
                except (OSError, ValueError) as error:
                    decode_errors.append(error)
                    return
                time.sleep(0.0005)

        reader_thread = threading.Thread(target=reader)
        reader_thread.start()
        events = ["UserPromptSubmit", "PermissionRequest", "Stop"] * 12
        try:
            with concurrent.futures.ThreadPoolExecutor(max_workers=12) as executor:
                futures = []
                for index, event in enumerate(events):
                    payload = self.base_payload(session_id, "turn-%d" % index)
                    payload["tool_name"] = "Bash"
                    payload["tool_input"] = {"command": "command-%d" % index}
                    futures.append(executor.submit(self.invoke, event, payload))
                for future in futures:
                    self.assert_success_without_output(future.result())
        finally:
            stop_reading.set()
            reader_thread.join(timeout=2)

        self.assertEqual(decode_errors, [])
        final_value = json.loads(target.read_text(encoding="utf-8"))
        self.assertEqual(final_value["taskKey"], digest(session_id))
        temporary_files = list(target.parent.glob(".%s.*" % target.name))
        self.assertEqual(temporary_files, [])


if __name__ == "__main__":
    unittest.main()
