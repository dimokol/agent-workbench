import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
HOOKS = os.path.join(HERE, "..", "hooks")
sys.path.insert(0, HOOKS)
import context_nudge  # noqa: E402

WRAPPER = os.path.join(HOOKS, "context-nudge.sh")


def iso(seconds_ago):
    return datetime.fromtimestamp(time.time() - seconds_ago, timezone.utc).isoformat().replace("+00:00", "Z")


def assistant(tokens, seconds_ago=5, sidechain=False):
    """A transcript line whose context adds up to `tokens`."""
    return {
        "type": "assistant",
        "isSidechain": sidechain,
        "timestamp": iso(seconds_ago),
        "message": {
            "role": "assistant",
            "usage": {
                "input_tokens": 10,
                "cache_read_input_tokens": tokens - 1010,
                "cache_creation_input_tokens": 1000,
            },
        },
    }


class HookTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.transcript = os.path.join(self.dir, "t.jsonl")
        self.state = os.path.join(self.dir, "state")
        self.sid = "session-1"

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def write(self, *records, junk=True):
        with open(self.transcript, "w") as f:
            if junk:
                f.write("not json at all\n")
                f.write(json.dumps({"type": "user", "message": {"content": "hi"}}) + "\n")
            for rec in records:
                f.write(json.dumps(rec) + "\n")

    def run_hook(self, stdin=None, env=None):
        payload = stdin if stdin is not None else json.dumps(
            {"session_id": self.sid, "transcript_path": self.transcript}
        )
        full = dict(os.environ, CONTEXT_NUDGE_STATE_DIR=self.state)
        for key in list(full):
            if key.startswith("CLAUDE_PLUGIN_OPTION_") or key.startswith("CONTEXT_NUDGE_") and key != "CONTEXT_NUDGE_STATE_DIR":
                del full[key]
        full.update(env or {})
        proc = subprocess.run(["sh", WRAPPER], input=payload, capture_output=True, text=True, env=full, timeout=20)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return json.loads(proc.stdout)["systemMessage"] if proc.stdout.strip() else ""

    # size

    def test_small_context_is_silent(self):
        self.write(assistant(100_000))
        self.assertEqual(self.run_hook(), "")

    def test_each_threshold_speaks_once(self):
        self.write(assistant(260_000))
        first = self.run_hook()
        self.assertIn("260k tokens", first)
        self.assertIn("/compact", first)
        self.assertEqual(self.run_hook(), "")
        self.write(assistant(300_000))
        self.assertEqual(self.run_hook(), "")
        self.write(assistant(410_000))
        self.assertIn("410k tokens", self.run_hook())
        self.write(assistant(650_000))
        self.assertIn("650k tokens", self.run_hook())
        self.assertEqual(self.run_hook(), "")

    def test_nudges_again_after_the_context_shrinks(self):
        self.write(assistant(300_000))
        self.assertIn("300k tokens", self.run_hook())
        self.write(assistant(20_000))  # after /compact
        self.assertEqual(self.run_hook(), "")
        self.write(assistant(310_000))
        self.assertIn("310k tokens", self.run_hook())

    def test_partial_shrink_rearms_the_higher_thresholds(self):
        self.write(assistant(650_000))
        self.assertIn("650k", self.run_hook())
        self.write(assistant(300_000))
        self.assertEqual(self.run_hook(), "")
        self.write(assistant(420_000))
        self.assertIn("420k", self.run_hook())

    def test_empty_usage_record_is_skipped(self):
        empty = assistant(1010)
        empty["message"]["usage"] = {"input_tokens": 0, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}
        self.write(assistant(300_000), empty)
        self.assertIn("300k tokens", self.run_hook())

    def test_jumping_past_several_thresholds_speaks_once(self):
        self.write(assistant(700_000))
        self.assertEqual(self.run_hook().count("Context is at"), 1)
        self.assertEqual(self.run_hook(), "")

    def test_sessions_are_tracked_separately(self):
        self.write(assistant(300_000))
        self.assertNotEqual(self.run_hook(), "")
        other = json.dumps({"session_id": "session-2", "transcript_path": self.transcript})
        self.assertNotEqual(self.run_hook(stdin=other), "")

    def test_subagent_messages_are_ignored(self):
        self.write(assistant(100_000), assistant(900_000, sidechain=True))
        self.assertEqual(self.run_hook(), "")

    def test_custom_thresholds_from_env_var(self):
        self.write(assistant(120_000))
        msg = self.run_hook(env={"CONTEXT_NUDGE_SIZE_THRESHOLDS_K": "100, 200"})
        self.assertIn("120k tokens", msg)

    def test_plugin_option_wins_over_env_var(self):
        self.write(assistant(120_000))
        env = {"CLAUDE_PLUGIN_OPTION_SIZE_THRESHOLDS_K": "500", "CONTEXT_NUDGE_SIZE_THRESHOLDS_K": "100"}
        self.assertEqual(self.run_hook(env=env), "")

    def test_bad_threshold_text_falls_back_to_defaults(self):
        self.write(assistant(300_000))
        self.assertIn("300k tokens", self.run_hook(env={"CONTEXT_NUDGE_SIZE_THRESHOLDS_K": "lots"}))

    # idle

    def test_idle_in_a_big_session_warns_once(self):
        self.write(assistant(200_000, seconds_ago=2 * 3600))
        msg = self.run_hook()
        self.assertIn("2.0h idle", msg)
        self.assertIn("/clear", msg)
        self.assertEqual(self.run_hook(), "")

    def test_idle_in_a_small_session_is_silent(self):
        self.write(assistant(100_000, seconds_ago=5 * 3600))
        self.assertEqual(self.run_hook(), "")

    def test_a_short_pause_is_silent(self):
        self.write(assistant(200_000, seconds_ago=30 * 60))
        self.assertEqual(self.run_hook(), "")

    def test_idle_minutes_setting(self):
        self.write(assistant(200_000, seconds_ago=30 * 60))
        self.assertIn("idle", self.run_hook(env={"CONTEXT_NUDGE_IDLE_MINUTES": "10"}))

    def test_idle_minimum_setting(self):
        self.write(assistant(100_000, seconds_ago=2 * 3600))
        self.assertIn("idle", self.run_hook(env={"CONTEXT_NUDGE_IDLE_MIN_CONTEXT_K": "50"}))

    def test_idle_and_size_in_one_message(self):
        self.write(assistant(300_000, seconds_ago=2 * 3600))
        msg = self.run_hook()
        self.assertIn("idle", msg)
        self.assertIn("Context is at 300k", msg)

    # robustness

    def test_missing_transcript_is_silent(self):
        self.assertEqual(self.run_hook(), "")

    def test_transcript_without_usage_is_silent(self):
        self.write()
        self.assertEqual(self.run_hook(), "")

    def test_bad_stdin_is_silent(self):
        self.assertEqual(self.run_hook(stdin="{nope"), "")
        self.assertEqual(self.run_hook(stdin="[]"), "")
        self.assertEqual(self.run_hook(stdin=json.dumps({"session_id": "../x", "transcript_path": self.transcript})), "")

    def test_a_huge_transcript_is_read_from_the_tail(self):
        with open(self.transcript, "w") as f:
            f.write(("x" * 1000 + "\n") * 6000)
            f.write(json.dumps(assistant(300_000)) + "\n")
        self.assertIn("300k", self.run_hook())

    def test_old_state_files_are_removed(self):
        os.makedirs(self.state)
        old = os.path.join(self.state, "ancient.json")
        with open(old, "w") as f:
            f.write("{}")
        long_ago = time.time() - 40 * 24 * 3600
        os.utime(old, (long_ago, long_ago))
        self.write(assistant(300_000))
        self.run_hook()
        self.assertFalse(os.path.exists(old))

    def test_without_python_it_allows_and_says_so_once(self):
        empty = os.path.join(self.dir, "empty")
        os.makedirs(empty)
        script = 'for i in 1 2; do echo "[$i]"; printf "{}" | /bin/sh "$0"; done'
        proc = subprocess.run(
            ["/bin/sh", "-c", script, WRAPPER],
            capture_output=True, text=True, env={"PATH": empty, "TMPDIR": self.dir}, timeout=20,
        )
        self.assertEqual(proc.returncode, 0)
        out = proc.stdout
        self.assertIn("python3 is not installed", out)
        self.assertEqual(out.count("python3 is not installed"), 1)
        self.assertTrue(out.rstrip().endswith("[2]"))


class UnitTest(unittest.TestCase):
    def test_parse_thresholds(self):
        self.assertEqual(context_nudge.parse_thresholds("250,400,600"), (250_000, 400_000, 600_000))
        self.assertEqual(context_nudge.parse_thresholds("600, 100 ,x, -5, 100"), (100_000, 600_000))
        self.assertEqual(context_nudge.parse_thresholds(""), (250_000, 400_000, 600_000))

    def test_number(self):
        self.assertEqual(context_nudge.number("15", 60), 15.0)
        self.assertEqual(context_nudge.number("0", 60), 60)
        self.assertEqual(context_nudge.number("abc", 60), 60)


if __name__ == "__main__":
    unittest.main()
