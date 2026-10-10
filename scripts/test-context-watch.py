#!/usr/bin/env python3
"""Deterministic tests for the context-watch hook (no model calls, no network).

  python3 scripts/test-context-watch.py
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from concurrent.futures import ThreadPoolExecutor

REPO = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
SCRIPTS = os.path.join(REPO, "skills", "context-watch", "scripts")
CORE = os.path.join(SCRIPTS, "context_watch.py")
SHIM = os.path.join(SCRIPTS, "context-watch-shim.sh")
PLUGIN = os.path.join(REPO, "plugins", "context-watch")

spec = importlib.util.spec_from_file_location("context_watch", CORE)
cw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cw)

CFG = {"warn": 200_000, "urge": 400_000, "disabled": False}


def usage_row(total, model="claude-opus-5-5", sidechain=False, cached=True):
    usage = ({"input_tokens": 2, "cache_creation_input_tokens": 1000, "cache_read_input_tokens": total - 1002}
             if cached else {"input_tokens": total, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0})
    return {"type": "assistant", "isSidechain": sidechain,
            "message": {"model": model, "role": "assistant", "usage": dict(usage, output_tokens=300)}}


def synthetic_row():
    return {"type": "assistant", "isSidechain": False, "isApiErrorMessage": True,
            "message": {"model": "<synthetic>", "usage": {"input_tokens": 0, "cache_read_input_tokens": 0,
                                                          "cache_creation_input_tokens": 0, "output_tokens": 0}}}


def boundary_row(post):
    return {"type": "system", "subtype": "compact_boundary",
            "compactMetadata": {"trigger": "manual", "preTokens": 412000, "postTokens": post}}


def user_row(text="hi"):
    return {"type": "user", "message": {"role": "user", "content": text}}


class Tmp(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="cw-test-")
        self.env = {k: os.environ.get(k) for k in
                    ("XDG_STATE_HOME", "XDG_CONFIG_HOME", "CONTEXT_WATCH_WARN", "CONTEXT_WATCH_URGE",
                     "CONTEXT_WATCH_DISABLE")}
        os.environ["XDG_STATE_HOME"] = os.path.join(self.tmp, "state")
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self.tmp, "config")
        for k in ("CONTEXT_WATCH_WARN", "CONTEXT_WATCH_URGE", "CONTEXT_WATCH_DISABLE"):
            os.environ.pop(k, None)

    def tearDown(self):
        for k, v in self.env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.tmp)

    def transcript(self, rows, name="t.jsonl", tail=b""):
        path = os.path.join(self.tmp, name)
        with open(path, "wb") as f:
            for row in rows:
                f.write((row if isinstance(row, bytes) else json.dumps(row).encode()) + b"\n")
            f.write(tail)
        return path

    def payload(self, path, **extra):
        return dict({"hook_event_name": "UserPromptSubmit", "session_id": "sess-1",
                     "transcript_path": path, "prompt": "go"}, **extra)


class TranscriptReading(Tmp):
    def test_newest_usage_row_wins(self):
        path = self.transcript([user_row(), usage_row(50_000), user_row(), usage_row(230_000)])
        self.assertEqual(cw.current_size(path), 230_000)

    def test_all_three_input_fields_are_summed(self):
        self.assertEqual(cw.current_size(self.transcript([usage_row(123_456, cached=False)])), 123_456)

    def test_synthetic_zero_usage_rows_are_skipped(self):
        # The friend's script returned 0 here and went silent on the session in trouble.
        path = self.transcript([usage_row(420_000), synthetic_row(), user_row()])
        self.assertEqual(cw.current_size(path), 420_000)

    def test_sidechain_rows_are_skipped(self):
        path = self.transcript([usage_row(300_000), usage_row(9_000, sidechain=True)])
        self.assertEqual(cw.current_size(path), 300_000)

    def test_compact_boundary_after_usage_reports_compacted(self):
        # postTokens counts only the summary, not system prompt and tools: not a size.
        path = self.transcript([usage_row(450_000), boundary_row(12_345), user_row()])
        self.assertEqual(cw.current_size(path), cw.COMPACTED)

    def test_usage_after_compact_boundary_wins(self):
        path = self.transcript([usage_row(450_000), boundary_row(12_000), usage_row(30_000)])
        self.assertEqual(cw.current_size(path), 30_000)

    def test_baseline_ignores_compact_boundaries(self):
        path = self.transcript([boundary_row(3_000), usage_row(45_000)])
        self.assertEqual(cw.baseline_size(path), 45_000)

    def test_unfinished_last_row_is_ignored(self):
        partial = json.dumps(usage_row(999_000)).encode()[:-10]
        path = self.transcript([usage_row(210_000)], tail=partial)
        self.assertEqual(cw.current_size(path), 210_000)

    def test_malformed_lines_are_skipped(self):
        path = self.transcript([usage_row(205_000), b'{"usage": not json', b"\xff\xfe garbage \"usage\""])
        self.assertEqual(cw.current_size(path), 205_000)

    def test_empty_and_usage_free_transcripts_are_unknown(self):
        self.assertIsNone(cw.current_size(self.transcript([])))
        self.assertIsNone(cw.current_size(self.transcript([user_row(), synthetic_row()])))

    def test_usage_row_behind_megabytes_of_rows_is_found(self):
        # Image and tool-result rows between usage rows run to megabytes.
        filler = [user_row("x" * 500_000) for _ in range(6)]
        path = self.transcript([usage_row(260_000)] + filler)
        self.assertEqual(cw.current_size(path), 260_000)

    def test_scan_stops_at_the_cap(self):
        old = cw.SCAN_CAP
        cw.SCAN_CAP = 1024 * 1024
        try:
            path = self.transcript([usage_row(260_000)] + [user_row("x" * 400_000) for _ in range(4)])
            self.assertIsNone(cw.current_size(path))
        finally:
            cw.SCAN_CAP = old

    def test_chunk_edges_inside_rows_and_multibyte_text(self):
        # Every tail offset lands somewhere different: inside a row, inside a
        # multibyte character. The answer must not depend on where.
        rows = [usage_row(201_000), user_row("ñandú café " * 50), usage_row(202_000), user_row("ü€😀" * 300)]
        path = self.transcript(rows)
        old = cw.TAIL_START
        try:
            for start in (1, 7, 64, 333, 1000, 4096):
                cw.TAIL_START = start
                self.assertEqual(cw.current_size(path), 202_000, start)
        finally:
            cw.TAIL_START = old

    def test_baseline_is_the_first_real_call(self):
        path = self.transcript([user_row(), synthetic_row(), usage_row(40_000), usage_row(300_000)])
        self.assertEqual(cw.baseline_size(path), 40_000)

    def test_large_transcript_is_fast(self):
        rows = [usage_row(100_000 + i) for i in range(20_000)] + [user_row("y" * 200_000) for _ in range(40)]
        path = self.transcript(rows)
        self.assertGreater(os.path.getsize(path), 10 * 1024 * 1024)
        t = time.monotonic()
        self.assertEqual(cw.current_size(path), 119_999)
        self.assertLess(time.monotonic() - t, 0.5)


class Decisions(unittest.TestCase):
    def run_sizes(self, sizes, cfg=CFG):
        state = {}
        return [cw.decide(state, n, cfg) for n in sizes]

    def test_each_threshold_fires_once_per_crossing(self):
        self.assertEqual(self.run_sizes([150_000, 210_000, 250_000, 399_999, 410_000, 450_000]),
                         [None, "warn", None, None, "urge", None])

    def test_urge_fires_once_however_far_it_grows(self):
        # The stop hands the decision to the user; continuing past it is their call.
        self.assertEqual(self.run_sizes([410_000, 499_000, 500_000, 610_000, 900_000, 1_500_000]),
                         ["urge", None, None, None, None, None])

    def test_state_from_the_repeating_version_counts_as_urged(self):
        state = {"warned": True, "urge_level": 500_000}
        self.assertIsNone(cw.decide(state, 560_000, CFG))
        self.assertEqual(state, {"warned": True, "urged": True})

    def test_jumping_straight_past_urge_sends_one_urge(self):
        self.assertEqual(self.run_sizes([100_000, 450_000, 460_000]), [None, "urge", None])

    def test_compaction_below_warn_rearms_both(self):
        self.assertEqual(self.run_sizes([210_000, 410_000, 15_000, 210_000, 410_000]),
                         ["warn", "urge", None, "warn", "urge"])
        self.assertEqual(self.run_sizes([210_000, 410_000, cw.COMPACTED, 210_000, 410_000]),
                         ["warn", "urge", None, "warn", "urge"])

    def test_hovering_around_a_threshold_does_not_refire(self):
        # Tool-result trimming can shrink the context a little without a compaction.
        self.assertEqual(self.run_sizes([201_000, 199_000, 201_000, 185_000, 200_500]),
                         ["warn", None, None, None, None])
        self.assertEqual(self.run_sizes([505_000, 495_000, 505_000]), ["urge", None, None])
        self.assertEqual(self.run_sizes([201_000, 170_000, 201_000]), ["warn", None, "warn"])

    def test_partial_compaction_above_urge_does_not_rearm(self):
        self.assertEqual(self.run_sizes([520_000, 430_000, 510_000]), ["urge", None, None])

    def test_drop_into_warn_band_rearms_urge(self):
        self.assertEqual(self.run_sizes([410_000, 300_000, 410_000]), ["urge", None, "urge"])

    def test_equal_thresholds_send_urge(self):
        cfg = {"warn": 300_000, "urge": 300_000, "disabled": False}
        self.assertEqual(self.run_sizes([299_000, 300_000, 350_000], cfg), [None, "urge", None])


class Config(Tmp):
    def write_conf(self, text):
        d = os.path.join(os.environ["XDG_CONFIG_HOME"], "workflow-skills")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "context-watch.conf"), "w") as f:
            f.write(text)

    def test_defaults(self):
        self.assertEqual(cw.load_config(), {"warn": 200_000, "urge": 400_000, "disabled": False})

    def test_conf_file_and_suffixes(self):
        self.write_conf("# comment\nCONTEXT_WATCH_WARN=150k\nCONTEXT_WATCH_URGE='0.3m'\n")
        self.assertEqual(cw.load_config(), {"warn": 150_000, "urge": 300_000, "disabled": False})

    def test_env_beats_conf(self):
        self.write_conf("CONTEXT_WATCH_WARN=150k\nCONTEXT_WATCH_DISABLE=1\n")
        os.environ["CONTEXT_WATCH_WARN"] = "250000"
        os.environ["CONTEXT_WATCH_DISABLE"] = "0"
        cfg = cw.load_config()
        self.assertEqual((cfg["warn"], cfg["disabled"]), (250_000, False))

    def test_invalid_values_fall_back_and_urge_never_below_warn(self):
        os.environ["CONTEXT_WATCH_WARN"] = "lots"
        os.environ["CONTEXT_WATCH_URGE"] = "100k"
        self.assertEqual(cw.load_config(), {"warn": 200_000, "urge": 200_000, "disabled": False})

    def test_disable(self):
        for value in ("1", "true", "YES", "on"):
            os.environ["CONTEXT_WATCH_DISABLE"] = value
            self.assertTrue(cw.load_config()["disabled"], value)


class Hook(Tmp):
    def tool(self, path, **extra):
        return self.payload(path, **dict({"hook_event_name": "PostToolUse", "tool_name": "Bash",
                                          "tool_input": {"command": "ls"}, "tool_use_id": "t1"}, **extra))

    def test_warn_after_a_tool_call_tells_the_user_and_asks_the_model_to_stop(self):
        path = self.transcript([usage_row(40_000), usage_row(215_000)])
        out = cw.run_hook(self.tool(path), CFG)
        self.assertEqual(set(out), {"systemMessage", "hookSpecificOutput"})
        self.assertTrue(out["systemMessage"].startswith("context-watch: ~215k tokens (5.4x session start), past 200k."),
                        out["systemMessage"])
        ctx = out["hookSpecificOutput"]
        self.assertEqual(ctx["hookEventName"], "PostToolUse")
        for phrase in ("[context-watch]", "Finish the step you are on, then stop", "Do not start another step",
                       "Do not write a handoff", "never run /compact or /clear"):
            self.assertIn(phrase, ctx["additionalContext"])
        self.assertNotIn("continue", out)
        self.assertIsNone(cw.run_hook(self.tool(path), CFG))

    def test_urge_after_a_tool_call_stops_the_turn(self):
        path = self.transcript([usage_row(40_000), usage_row(412_000)])
        out = cw.run_hook(self.tool(path), CFG)
        self.assertEqual(set(out), {"continue", "stopReason"})
        self.assertIs(out["continue"], False)
        self.assertTrue(out["stopReason"].startswith(
            "context-watch stopped this turn: the context is ~412k tokens (10.3x session start), past 400k."),
            out["stopReason"])
        self.assertLess(len(out["stopReason"].split()), 40)
        # once per crossing: continuing after the stop is not stopped again
        self.assertIsNone(cw.run_hook(self.tool(path), CFG))
        grown = self.transcript([usage_row(40_000), usage_row(650_000)], name="grown.jsonl")
        self.assertIsNone(cw.run_hook(self.tool(grown), CFG))

    def test_compaction_rearms_the_stop(self):
        path = self.transcript([usage_row(40_000), usage_row(412_000)])
        self.assertIs(cw.run_hook(self.tool(path), CFG)["continue"], False)
        small = self.transcript([usage_row(40_000), usage_row(412_000), boundary_row(30_000)], name="c.jsonl")
        self.assertIsNone(cw.run_hook(self.tool(small), CFG))
        self.assertIn("hookSpecificOutput", cw.run_hook(self.tool(self.transcript(
            [usage_row(40_000), usage_row(230_000)], name="w.jsonl")), CFG))
        self.assertIs(cw.run_hook(self.tool(path), CFG)["continue"], False)

    def test_warn_at_a_prompt_goes_to_the_user_only(self):
        path = self.transcript([usage_row(40_000), usage_row(215_000)])
        out = cw.run_hook(self.payload(path), CFG)
        self.assertEqual(set(out), {"systemMessage"})
        self.assertLess(len(out["systemMessage"].split()), 35)
        self.assertIsNone(cw.run_hook(self.payload(path), CFG))

    def test_urge_at_a_prompt_asks_the_model_to_raise_it_first(self):
        # Stopping here would discard the user's message, so the model is told instead.
        path = self.transcript([usage_row(40_000), usage_row(412_000)])
        out = cw.run_hook(self.payload(path), CFG)
        self.assertNotIn("continue", out)
        self.assertIn("past 400k", out["systemMessage"])
        ctx = out["hookSpecificOutput"]
        self.assertEqual(ctx["hookEventName"], "UserPromptSubmit")
        self.assertIn("ask how they want to proceed", ctx["additionalContext"])
        self.assertIn("Do not start the work until they answer", ctx["additionalContext"])
        # the prompt spent the crossing: a tool call in the same turn does not stop it
        self.assertIsNone(cw.run_hook(self.tool(path), CFG))

    def test_a_failed_tool_call_also_counts(self):
        path = self.transcript([usage_row(412_000)])
        out = cw.run_hook(self.tool(path, hook_event_name="PostToolUseFailure", error="exit 1"), CFG)
        self.assertIs(out["continue"], False)
        warn = self.transcript([usage_row(215_000)], name="w.jsonl")
        out = cw.run_hook(self.tool(warn, hook_event_name="PostToolUseFailure", session_id="s2"), CFG)
        self.assertEqual(out["hookSpecificOutput"]["hookEventName"], "PostToolUseFailure")

    def test_one_crossing_fires_once_across_both_events(self):
        path = self.transcript([usage_row(215_000)])
        self.assertIsNotNone(cw.run_hook(self.tool(path), CFG))
        self.assertIsNone(cw.run_hook(self.payload(path), CFG))

    def test_subagents_neither_warn_nor_spend_the_warning(self):
        path = self.transcript([usage_row(420_000)])
        for payload in (self.payload(path, agent_id="a1", agent_type="general-purpose"),
                        self.tool(path, agent_id="a1", agent_type="general-purpose")):
            self.assertIsNone(cw.run_hook(payload, CFG))
        self.assertFalse(os.path.exists(cw._state_dir()))
        self.assertIs(cw.run_hook(self.tool(path), CFG)["continue"], False)

    def test_quiet_tool_calls_do_not_rewrite_state(self):
        path = self.transcript([usage_row(50_000)])
        cw.run_hook(self.tool(path), CFG)
        state = os.path.join(cw._state_dir(), "sess-1.json")
        before = os.stat(state).st_mtime_ns
        time.sleep(0.01)
        for _ in range(3):
            self.assertIsNone(cw.run_hook(self.tool(path), CFG))
        self.assertEqual(os.stat(state).st_mtime_ns, before)

    def test_silent_cases(self):
        path = self.transcript([usage_row(420_000)])
        self.assertIsNone(cw.run_hook(self.payload(path, hook_event_name="SessionStart"), CFG))
        self.assertIsNone(cw.run_hook(self.payload(path, hook_event_name="PreToolUse"), CFG))
        self.assertIsNone(cw.run_hook(self.payload(os.path.join(self.tmp, "missing.jsonl")), CFG))
        self.assertIsNone(cw.run_hook(self.payload(path, session_id=""), CFG))
        self.assertIsNone(cw.run_hook(self.payload(path), dict(CFG, disabled=True)))
        self.assertFalse(os.path.exists(cw._state_dir()))

    def test_token_formatting(self):
        self.assertEqual([cw._k(n) for n in (199_600, 1_000_000, 1_500_000, 2_040_000)],
                         ["200k", "1M", "1.5M", "2M"])

    def test_unknown_size_keeps_state(self):
        path = self.transcript([usage_row(210_000)])
        self.assertIsNotNone(cw.run_hook(self.payload(path), CFG))
        unknown = self.transcript([user_row()], name="u.jsonl")
        self.assertIsNone(cw.run_hook(self.payload(unknown), CFG))
        self.assertIsNone(cw.run_hook(self.payload(path), CFG))

    def test_sessions_are_independent(self):
        path = self.transcript([usage_row(210_000)])
        self.assertIsNotNone(cw.run_hook(self.payload(path, session_id="a"), CFG))
        self.assertIsNotNone(cw.run_hook(self.payload(path, session_id="b/../../x"), CFG))
        names = sorted(n for n in os.listdir(cw._state_dir()) if n.endswith(".json"))
        self.assertEqual(names, ["a.json", "b_.._.._x.json"])

    def test_corrupt_state_is_replaced(self):
        path = self.transcript([usage_row(210_000)])
        os.makedirs(cw._state_dir())
        with open(os.path.join(cw._state_dir(), "sess-1.json"), "w") as f:
            f.write("[not a dict")
        self.assertIsNotNone(cw.run_hook(self.payload(path), CFG))

    def test_old_state_is_pruned(self):
        os.makedirs(cw._state_dir())
        stale = os.path.join(cw._state_dir(), "old.json")
        with open(stale, "w") as f:
            f.write("{}")
        os.utime(stale, (time.time() - 40 * 86400,) * 2)
        cw.run_hook(self.payload(self.transcript([usage_row(210_000)])), CFG)
        self.assertFalse(os.path.exists(stale))


def run_shim(entry, payload, env=None):
    return subprocess.run(["bash", SHIM, entry], input=json.dumps(payload), capture_output=True, text=True,
                          env=env or os.environ, cwd="/")


class Shim(Tmp):
    def test_shim_passes_hook_json(self):
        path = self.transcript([usage_row(420_000)])
        out = run_shim(CORE, self.payload(path))
        self.assertEqual(out.returncode, 0)
        self.assertIn("additionalContext", json.loads(out.stdout)["hookSpecificOutput"])
        stop = run_shim(CORE, dict(self.payload(path), hook_event_name="PostToolUse", session_id="sess-2"))
        self.assertIs(json.loads(stop.stdout)["continue"], False)

    def test_a_broken_entry_never_blocks_the_prompt(self):
        # python exits 2 for a missing script; exit 2 from UserPromptSubmit blocks the prompt.
        broken = os.path.join(self.tmp, "broken.py")
        with open(broken, "w") as f:
            f.write("import sys\nprint('Traceback: boom')\nsys.exit(2)\n")
        for entry in (os.path.join(self.tmp, "missing.py"), broken):
            out = run_shim(entry, self.payload("x"))
            self.assertEqual((out.returncode, out.stdout), (0, ""), entry)

    def test_missing_python_is_silent(self):
        out = run_shim(CORE, self.payload("x"), dict(os.environ, CONTEXT_WATCH_PYTHON="/nonexistent/python3"))
        self.assertEqual((out.returncode, out.stdout), (0, ""))

    def test_garbage_payload_is_silent(self):
        out = subprocess.run(["bash", SHIM, CORE], input="not json", capture_output=True, text=True)
        self.assertEqual((out.returncode, out.stdout), (0, ""))

    def test_parallel_hooks_warn_exactly_once(self):
        # A plugin plus a local registration, or a batch of parallel tool calls,
        # runs several handlers at once.
        path = self.transcript([usage_row(420_000)])
        events = ["UserPromptSubmit", "PostToolUse"] * 4
        with ThreadPoolExecutor(8) as pool:
            outs = list(pool.map(lambda e: run_shim(CORE, dict(self.payload(path), hook_event_name=e)).stdout, events))
        self.assertEqual(sum(1 for o in outs if o.strip()), 1, outs)


class Plugin(Tmp):
    def test_plugin_ships_the_prompt_and_tool_hooks_and_they_run(self):
        with open(os.path.join(PLUGIN, "hooks", "hooks.json")) as f:
            hooks = json.load(f)["hooks"]
        self.assertEqual(sorted(hooks), ["PostToolUse", "PostToolUseFailure", "UserPromptSubmit"])
        commands = {e: hooks[e][0]["hooks"][0]["command"] for e in hooks}
        self.assertEqual(len(set(commands.values())), 1)
        for event in ("PostToolUse", "PostToolUseFailure"):
            self.assertNotIn("matcher", hooks[event][0])  # every tool
        command = commands["UserPromptSubmit"]
        path = self.transcript([usage_row(215_000)])
        # The way the host runs it: sh -c, from /, with a bare system PATH.
        env = {"HOME": self.tmp, "PATH": "/usr/bin:/bin", "CLAUDE_PLUGIN_ROOT": PLUGIN,
               "XDG_STATE_HOME": os.environ["XDG_STATE_HOME"], "XDG_CONFIG_HOME": os.environ["XDG_CONFIG_HOME"]}
        out = subprocess.run(["/bin/sh", "-c", command], input=json.dumps(self.payload(path)),
                             capture_output=True, text=True, env=env, cwd="/")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("past 200k", json.loads(out.stdout)["systemMessage"])

    def test_plugin_scripts_are_the_skill_scripts(self):
        # One core: the plugin links to the skill's scripts (plugin installs copy through the link).
        link = os.path.join(PLUGIN, "scripts")
        self.assertTrue(os.path.islink(link))
        self.assertEqual(os.path.realpath(link), os.path.realpath(SCRIPTS))

    def test_plugin_has_no_skill_copy(self):
        # The skill ships with the main plugin; a second copy here would load twice.
        self.assertFalse(os.path.exists(os.path.join(PLUGIN, "skills")))

    def test_marketplace_lists_the_plugin_without_a_version(self):
        with open(os.path.join(REPO, ".claude-plugin", "marketplace.json")) as f:
            entry = {p["name"]: p for p in json.load(f)["plugins"]}["context-watch"]
        self.assertEqual(entry["source"], "./plugins/context-watch")
        self.assertNotIn("version", entry)
        with open(os.path.join(PLUGIN, ".claude-plugin", "plugin.json")) as f:
            manifest = json.load(f)
        self.assertEqual(manifest["name"], "context-watch")
        self.assertNotIn("version", manifest)


class Status(Tmp):
    def status(self, *args, env=None):
        return subprocess.run([sys.executable, CORE, "status", *args], capture_output=True, text=True,
                              env=env or os.environ)

    def test_status_by_transcript(self):
        path = self.transcript([usage_row(40_000), usage_row(250_000)])
        out = self.status("--transcript", path)
        self.assertEqual(out.returncode, 0)
        self.assertIn("context: ~250k tokens (6.2x session start)", out.stdout)
        self.assertIn("status: past WARN", out.stdout)

    def test_status_after_compaction(self):
        out = self.status("--transcript", self.transcript([usage_row(450_000), boundary_row(3_000)]))
        self.assertIn("just compacted", out.stdout)

    def test_status_finds_the_session_by_id(self):
        home = os.path.join(self.tmp, "claude")
        proj = os.path.join(home, "projects", "-some-project")
        os.makedirs(proj)
        shutil.copy(self.transcript([usage_row(90_000)]), os.path.join(proj, "abc-123.jsonl"))
        env = dict(os.environ, CLAUDE_CONFIG_DIR=home, CLAUDE_CODE_SESSION_ID="abc-123")
        out = self.status(env=env)
        self.assertIn("110k below WARN", out.stdout)

    def test_status_without_a_session_explains(self):
        env = {k: v for k, v in os.environ.items() if k != "CLAUDE_CODE_SESSION_ID"}
        out = self.status(env=env)
        self.assertEqual(out.returncode, 2)
        self.assertIn("--transcript", out.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=1)
