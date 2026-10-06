#!/usr/bin/env python3
"""context-watch: tell the user when a Claude Code session's context gets large.

  context_watch.py hook      UserPromptSubmit handler: JSON payload on stdin, hook JSON on stdout
  context_watch.py status    print the current session's context size, ratio and thresholds

Context size is the newest real assistant usage row in the transcript:
input_tokens + cache_read_input_tokens + cache_creation_input_tokens. It is
what the model re-read on its last call, which is what every next turn pays for.

Past WARN the user gets a systemMessage (shown in the UI, never sent to the
model). Past URGE the model also gets one informational line, so it can raise
the point at its next natural stop. WARN fires once per crossing; URGE fires at
the crossing and again every URGE_STEP tokens of growth. Dropping below WARN
(after /compact) re-arms both. Any failure is silent: the shim around this file
always exits 0, because exit 2 from UserPromptSubmit blocks the user's prompt.
"""
import argparse
import fcntl
import glob
import json
import os
import re
import sys
import time

DEFAULT_WARN = 200_000
DEFAULT_URGE = 400_000
URGE_STEP = 100_000
TAIL_START = 256 * 1024          # first backward read; doubles until it finds a row
SCAN_CAP = 16 * 1024 * 1024      # never read more than this from either end
STATE_TTL_DAYS = 30
TRUTHY = {"1", "true", "yes", "on"}
COMPACTED = "compacted"          # newest row is a compaction: small, exact size unknown yet


# ---------------------------------------------------------------- config

def _config_home():
    return os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")


def _state_dir():
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, "workflow-skills", "context-watch")


def _read_conf(path):
    values = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                values[key.strip()] = value.strip().strip("'\"")
    except OSError:
        pass
    return values


def _tokens(value):
    """'250000', '250k', '1m' -> int; anything else -> None."""
    m = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*([kKmM]?)\s*", value or "")
    if not m:
        return None
    n = float(m.group(1)) * {"": 1, "k": 1_000, "m": 1_000_000}[m.group(2).lower()]
    return int(n) if n > 0 else None


def load_config():
    """Env wins over ~/.config/workflow-skills/context-watch.conf, which wins over defaults."""
    conf = _read_conf(os.path.join(_config_home(), "workflow-skills", "context-watch.conf"))

    def get(key):
        return os.environ.get(key) if os.environ.get(key) is not None else conf.get(key)

    warn = _tokens(get("CONTEXT_WATCH_WARN")) or DEFAULT_WARN
    urge = _tokens(get("CONTEXT_WATCH_URGE")) or DEFAULT_URGE
    return {
        "warn": warn,
        "urge": max(urge, warn),
        "disabled": (get("CONTEXT_WATCH_DISABLE") or "").strip().lower() in TRUTHY,
    }


# ---------------------------------------------------------------- transcript

def _row_size(row):
    """Context size a transcript row proves, COMPACTED, or None if the row proves nothing.

    A real assistant row carries the size of the request it answered. A
    compact_boundary means the context was just cut; its postTokens counts only
    the summary (system prompt and tools come on top), so the true size is
    known only after the next reply. Synthetic rows (API errors, interrupts)
    carry all-zero usage and must not count as "the context is empty".
    """
    if row.get("type") == "system" and row.get("subtype") == "compact_boundary":
        return COMPACTED
    if row.get("type") != "assistant" or row.get("isSidechain"):
        return None
    msg = row.get("message") or {}
    if msg.get("model") == "<synthetic>":
        return None
    usage = msg.get("usage")
    if not isinstance(usage, dict):
        return None
    total = sum(int(usage.get(k) or 0) for k in
                ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
    return total or None


def _candidate(line):
    return b'"usage"' in line or b'"compact_boundary"' in line


def _parse(line):
    try:
        return json.loads(line.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return None


def current_size(path):
    """Newest context size in the transcript: tokens, COMPACTED, or None when nothing in the last SCAN_CAP bytes proves one.

    Reads backwards in doubling binary chunks: rows between usage rows can be
    megabytes (base64 images, big tool results), and a text-mode seek can land
    inside a multibyte character. A first segment that does not start at byte 0
    is a fragment and is dropped; so is a last segment without its newline,
    which Claude Code may still be writing.
    """
    size = os.path.getsize(path)
    span = min(TAIL_START, size)
    with open(path, "rb") as f:
        while True:
            start = size - span
            f.seek(start)
            lines = f.read(span).split(b"\n")
            lines.pop()                      # after the final \n, or an unfinished row
            if start > 0 and lines:
                lines.pop(0)                 # fragment of a row that began earlier
            for line in reversed(lines):
                if _candidate(line):
                    row = _parse(line)
                    found = _row_size(row) if isinstance(row, dict) else None
                    if found is not None:
                        return found
            if start == 0 or span >= SCAN_CAP:
                return None
            span = min(span * 2, size, SCAN_CAP)


def baseline_size(path):
    """Context of the session's first real call: system prompt, tools, memory and first prompt."""
    read = 0
    with open(path, "rb") as f:
        for line in f:
            read += len(line)
            if read > SCAN_CAP:
                return None
            if _candidate(line):
                row = _parse(line)
                if isinstance(row, dict) and row.get("type") == "assistant":
                    found = _row_size(row)
                    if isinstance(found, int):
                        return found
    return None


# ---------------------------------------------------------------- state

def _safe_id(session_id):
    return re.sub(r"[^A-Za-z0-9_.-]", "_", session_id)[:128] or "unknown"


class SessionState:
    """Per-session JSON state, serialized with flock so parallel hooks see each other's writes."""

    def __init__(self, session_id):
        self.dir = _state_dir()
        self.path = os.path.join(self.dir, _safe_id(session_id) + ".json")

    def __enter__(self):
        os.makedirs(self.dir, exist_ok=True)
        self.lock = open(self.path + ".lock", "a")
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        try:
            with open(self.path, encoding="utf-8") as f:
                self.data = json.load(f)
            if not isinstance(self.data, dict):
                self.data = {}
        except (OSError, ValueError):
            self.data = {}
            _prune(self.dir)
        return self

    def save(self):
        tmp = f"{self.path}.{os.getpid()}.tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.data, f)
        os.replace(tmp, self.path)

    def __exit__(self, *exc):
        fcntl.flock(self.lock, fcntl.LOCK_UN)
        self.lock.close()
        return False


def _prune(directory):
    cutoff = time.time() - STATE_TTL_DAYS * 86400
    for path in glob.glob(os.path.join(directory, "*.json*")):
        try:
            if os.path.getmtime(path) < cutoff:
                os.remove(path)
        except OSError:
            pass


# ---------------------------------------------------------------- decision

def decide(state, size, cfg):
    """Advance the per-session state for a measured size; return None, "warn" or "urge".

    WARN fires once per crossing. URGE fires at each URGE_STEP level it has not
    fired at yet. Re-arming needs a real drop, a margin below the mark (a
    compaction, not tool-result trimming hovering around it): falling below
    WARN re-arms everything, and falling well below an announced URGE level
    lowers the mark, so regrowth after a partial compaction is announced again.
    """
    warn, urge = cfg["warn"], cfg["urge"]
    margin = warn // 10
    if size == COMPACTED:
        size = 0
    if size < warn:
        if size < warn - margin:
            state["warned"] = False
            state["urge_level"] = 0
        return None
    if size < urge:
        if size < urge - margin:
            state["urge_level"] = 0
        if state.get("warned"):
            return None
        state["warned"] = True
        return "warn"
    level = urge + (size - urge) // URGE_STEP * URGE_STEP
    mark = int(state.get("urge_level") or 0)
    state["warned"] = True
    if level > mark:
        state["urge_level"] = level
        return "urge"
    if size < mark - margin:
        state["urge_level"] = level
    return None


def _k(n):
    return f"{n / 1_000_000:.1f}M".replace(".0M", "M") if n >= 1_000_000 else f"{round(n / 1000)}k"


def describe(size, baseline):
    ratio = size / baseline if baseline else 0
    if ratio >= 1.5:
        return f"~{_k(size)} tokens ({ratio:.1f}x session start)"
    return f"~{_k(size)} tokens"


def user_message(level, size, mark, baseline):
    lead = "still growing, " if level == "urge" else ""
    return (f"context-watch: {lead}{describe(size, baseline)}, past {_k(mark)}. Each turn re-reads all of it: "
            f"costlier, and recall slips. When convenient: /compact if available, or save notes and /clear.")


def agent_message(size):
    return (f"[context-watch] This session's context is ~{_k(size)} tokens. This is informational: continue "
            "the current task at full quality and do not shorten, rush or skip steps because of it. At the "
            "next natural stopping point, mention once to the user that the context is large and that "
            "/compact or /clear would make later turns cheaper and sharper. Never run /compact or /clear "
            "yourself, and do not repeat this unless asked.")


# ---------------------------------------------------------------- commands

def run_hook(payload, cfg):
    """The hook decision for one payload: a dict to print, or None for silence."""
    if cfg["disabled"] or payload.get("hook_event_name") != "UserPromptSubmit":
        return None
    # Subagent prompts carry the parent's transcript and session id: measuring
    # them would spend the main session's one-time warning on an agent with no user.
    if payload.get("agent_id"):
        return None
    path, session_id = payload.get("transcript_path"), payload.get("session_id")
    if not path or not session_id or not os.path.isfile(path):
        return None
    size = current_size(path)
    if size is None:
        return None
    with SessionState(session_id) as st:
        level = decide(st.data, size, cfg)
        if level and not st.data.get("baseline"):
            st.data["baseline"] = baseline_size(path)
        baseline = st.data.get("baseline")
        mark = st.data["urge_level"] if level == "urge" else cfg["warn"]
        st.save()
    if level is None:
        return None
    out = {"systemMessage": user_message(level, size, mark, baseline)}
    if level == "urge":
        out["hookSpecificOutput"] = {"hookEventName": "UserPromptSubmit",
                                     "additionalContext": agent_message(size)}
    return out


def find_transcript(session_id):
    root = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    pattern = os.path.join(glob.escape(root), "projects", "*", glob.escape(session_id) + ".jsonl")
    matches = sorted(glob.glob(pattern), key=os.path.getmtime)
    return matches[-1] if matches else None


def run_status(args, cfg):
    path = args.transcript
    if not path:
        session_id = args.session_id or os.environ.get("CLAUDE_CODE_SESSION_ID")
        if not session_id:
            print("context-watch: no session: pass --transcript PATH or --session-id ID "
                  "(Claude Code sets CLAUDE_CODE_SESSION_ID for its tools)", file=sys.stderr)
            return 2
        path = find_transcript(session_id)
        if not path:
            print(f"context-watch: no transcript found for session {session_id}", file=sys.stderr)
            return 2
    size = current_size(path)
    if size is None:
        print(f"context: unknown (no usage row yet)\ntranscript: {path}")
        return 0
    if size == COMPACTED:
        print(f"context: just compacted; the exact size is known after the next reply\ntranscript: {path}")
        return 0
    if size >= cfg["urge"]:
        zone = "past URGE"
    elif size >= cfg["warn"]:
        zone = "past WARN"
    else:
        zone = f"{_k(cfg['warn'] - size)} below WARN"
    print(f"context: {describe(size, baseline_size(path))}\n"
          f"thresholds: WARN {_k(cfg['warn'])}, URGE {_k(cfg['urge'])} (then every {_k(URGE_STEP)}){' [disabled]' if cfg['disabled'] else ''}\n"
          f"status: {zone}\n"
          f"transcript: {path}")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(prog="context_watch.py", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("hook", help="UserPromptSubmit handler (payload on stdin)")
    status = sub.add_parser("status", help="print the current session's context size")
    status.add_argument("--transcript")
    status.add_argument("--session-id")
    args = parser.parse_args(argv)
    cfg = load_config()
    if args.cmd == "hook":
        try:
            payload = json.loads(sys.stdin.read() or "{}")
            out = run_hook(payload, cfg) if isinstance(payload, dict) else None
        except Exception:
            return 0                         # a broken watcher must never break a session
        if out:
            print(json.dumps(out))
        return 0
    return run_status(args, cfg)


if __name__ == "__main__":
    sys.exit(main())
