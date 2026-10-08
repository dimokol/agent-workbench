#!/usr/bin/env python3
"""UserPromptSubmit hook: say when a session's context has become expensive.

Two cases. Each is a one-line message to the user (never to the model, never a
block), shown at most once per threshold or idle gap:

1. Size. Past the size thresholds (250k, 400k and 600k tokens by default) every
   request re-reads all of the context. Finish the current step, then /compact
   or /clear with a short hand-off. The hook never compacts for you.
2. Cold cache. Typing into a big session after a long pause (60 minutes by
   default) re-writes the whole context at cache-write price. If the next thing
   is a new task, a fresh session with a hand-off is cheaper.

Settings, each read from CLAUDE_PLUGIN_OPTION_<KEY>, then CONTEXT_NUDGE_<KEY>,
then the default:
  SIZE_THRESHOLDS_K    comma-separated thousands of tokens   250,400,600
  IDLE_MINUTES         pause that counts as a cold cache      60
  IDLE_MIN_CONTEXT_K   smaller contexts are never nudged      150

State (which nudges were already shown) lives in CONTEXT_NUDGE_STATE_DIR, else
$CLAUDE_PLUGIN_DATA/state, else ~/.cache/context-nudge. Files older than 30 days
are removed.

Manual test:
  echo '{"session_id":"x","transcript_path":"/path/to.jsonl"}' | python3 context_nudge.py
"""
import json
import os
import sys
import time
from datetime import datetime

DEFAULT_THRESHOLDS_K = "250,400,600"
DEFAULT_IDLE_MINUTES = 60
DEFAULT_IDLE_MIN_CONTEXT_K = 150
TAIL_BYTES = 4 << 20  # the last usage record is near the end of the transcript
STATE_MAX_AGE = 30 * 24 * 3600


def option(key, default):
    for name in ("CLAUDE_PLUGIN_OPTION_" + key, "CONTEXT_NUDGE_" + key):
        value = os.environ.get(name, "").strip()
        if value:
            return value
    return default


def parse_thresholds(text):
    """'250,400,600' (thousands of tokens) -> sorted token counts. Bad input -> defaults."""
    values = []
    for part in str(text).split(","):
        try:
            k = float(part.strip())
        except ValueError:
            continue
        if k > 0:
            values.append(int(k * 1000))
    if not values:
        return parse_thresholds(DEFAULT_THRESHOLDS_K)
    return tuple(sorted(set(values)))


def number(text, default):
    try:
        value = float(text)
    except (TypeError, ValueError):
        return default
    return value if value > 0 else default


def state_dir():
    explicit = os.environ.get("CONTEXT_NUDGE_STATE_DIR")
    if explicit:
        return explicit
    data = os.environ.get("CLAUDE_PLUGIN_DATA")
    if data:
        return os.path.join(data, "state")
    return os.path.expanduser("~/.cache/context-nudge")


def last_usage(path):
    """(context tokens, epoch seconds or None) of the newest main-thread assistant message."""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            f.seek(max(0, size - TAIL_BYTES))
            chunk = f.read()
    except OSError:
        return None
    for raw in reversed(chunk.splitlines()):
        if b'"usage"' not in raw or b'"assistant"' not in raw:
            continue
        try:
            rec = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(rec, dict) or rec.get("isSidechain"):
            continue
        usage = (rec.get("message") or {}).get("usage")
        if not usage:
            continue
        ctx = (
            (usage.get("input_tokens") or 0)
            + (usage.get("cache_read_input_tokens") or 0)
            + (usage.get("cache_creation_input_tokens") or 0)
        )
        if ctx <= 0:
            continue  # an empty usage record says nothing about the size
        when = None
        ts = rec.get("timestamp")
        if ts:
            try:
                when = datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
            except ValueError:
                pass
        return ctx, when
    return None


def load_state(directory, sid):
    try:
        with open(os.path.join(directory, f"{sid}.json")) as f:
            state = json.load(f)
            return state if isinstance(state, dict) else {}
    except (OSError, ValueError):
        return {}


def save_state(directory, sid, state):
    try:
        os.makedirs(directory, exist_ok=True)
        tmp = os.path.join(directory, f"{sid}.json.tmp")
        with open(tmp, "w") as f:
            json.dump(state, f)
        os.replace(tmp, os.path.join(directory, f"{sid}.json"))
        cutoff = time.time() - STATE_MAX_AGE
        for name in os.listdir(directory):
            full = os.path.join(directory, name)
            if name.endswith(".json") and os.path.getmtime(full) < cutoff:
                os.remove(full)
    except OSError:
        pass


def build_messages(ctx, when, state, thresholds, idle_seconds, idle_min_context, now):
    """Returns the messages to show; mutates state to remember what was shown."""
    messages = []

    # Cold cache: judged against the previous reply, before this prompt lands.
    if when and ctx >= idle_min_context and now - when >= idle_seconds:
        if state.get("idle_warned_for") != when:
            state["idle_warned_for"] = when
            hours = (now - when) / 3600
            messages.append(
                f"Context: {ctx // 1000}k tokens and {hours:.1f}h idle, so the prompt cache has likely "
                "expired and this prompt re-reads all of it at full price. If this is a new task, "
                "/clear with a short hand-off is cheaper."
            )

    # Size: the highest threshold crossed that has not been mentioned yet.
    crossed = [t for t in thresholds if ctx >= t]
    current = crossed[-1] if crossed else 0
    if current < state.get("size_warned", 0):
        state["size_warned"] = current  # context shrank (/compact, /clear): re-arm
    if crossed and crossed[-1] > state.get("size_warned", 0):
        state["size_warned"] = crossed[-1]
        messages.append(
            f"Context is at {ctx // 1000}k tokens and every request re-reads it. At the next "
            "checkpoint (a step done, tests green), /compact or /clear with a hand-off."
        )
    return messages


def main():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return
    if not isinstance(data, dict):
        return
    sid = str(data.get("session_id") or "")
    path = data.get("transcript_path") or ""
    if not sid or not path or "/" in sid or "\\" in sid:
        return
    found = last_usage(path)
    if not found:
        return
    ctx, when = found

    thresholds = parse_thresholds(option("SIZE_THRESHOLDS_K", DEFAULT_THRESHOLDS_K))
    idle_seconds = number(option("IDLE_MINUTES", DEFAULT_IDLE_MINUTES), DEFAULT_IDLE_MINUTES) * 60
    idle_min_context = number(option("IDLE_MIN_CONTEXT_K", DEFAULT_IDLE_MIN_CONTEXT_K), DEFAULT_IDLE_MIN_CONTEXT_K) * 1000

    directory = state_dir()
    state = load_state(directory, sid)
    before = dict(state)
    messages = build_messages(ctx, when, state, thresholds, idle_seconds, idle_min_context, time.time())
    if messages or state != before:
        save_state(directory, sid, state)
    if messages:
        print(json.dumps({"systemMessage": " ".join(messages)}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # a nudge must never break a prompt
