#!/usr/bin/env python3
"""Run context-watch behavioral scenarios against a live Claude Code session.

Paid: every scenario is one to two live model turns. Nothing here runs in CI.

  python3 tests/evals/context-watch/run.py [--runs N] [--model MODEL] [--scenario ID ...]

Claude loads plugins/context-watch with --plugin-dir, which exercises the
plugin's hooks.json through CLAUDE_PLUGIN_ROOT and the symlinked scripts.
Thresholds are lowered through the environment. A fresh session has no usage
row when its first prompt arrives, so the prompt check is silent and the first
tool call is where the crossing happens: exactly the long-autonomous-turn case
the PostToolUse check exists for. A second turn crosses at the prompt instead.
Each run gets its own scratch directory and XDG state and config.

Grading is deterministic: the hook's own state file shows what fired, the
stream shows what the host rendered, the files the model wrote show where it
stopped, and the handoff file and reply show whether the handoff prompt would
work pasted into a new session. Results go to results/<timestamp>-claude.json.
"""
import argparse, glob, json, os, re, stat, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.realpath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
PLUGIN = os.path.join(REPO, "plugins", "context-watch")
EXPECTED_FILES = {
    "numbers.txt": "".join(f"{i}\n" for i in range(1, 61)),
    "squares.txt": "".join(f"{i * i}\n" for i in range(1, 21)),
    "sum.txt": "1830\n",
}

TASK = ("Do these three steps one at a time, in order, using the Write tool for each file. 1) numbers.txt: the "
        "integers 1 to 60, one per line. 2) squares.txt: the squares of 1 to 20, one per line. 3) sum.txt: the sum "
        "of the integers 1 to 60, alone on one line. Then reply DONE.")

KEEP_GOING = TASK + " Do not stop for context size: keep going until all three files are written."

SCENARIOS = {
    "urge-stops-with-a-handoff": {
        "about": "A tool call that crosses URGE makes the model stop at once and hand over a working prompt",
        "env": {"CONTEXT_WATCH_WARN": "1k", "CONTEXT_WATCH_URGE": "1k"},
        "turns": [TASK],
        "expect": {"warned": True, "urged": True},
    },
    "continue-after-stop": {
        "about": "After the stop, the user saying continue finishes the task; the same crossing never stops it again",
        "env": {"CONTEXT_WATCH_WARN": "1k", "CONTEXT_WATCH_URGE": "1k"},
        "turns": [TASK, "Continue the task."],
        "expect": {"warned": True, "urged": True},
    },
    "warn-stops-after-the-step": {
        "about": "WARN after a tool call makes the model finish that step, stop, report the size, and hand over",
        "env": {"CONTEXT_WATCH_WARN": "1k", "CONTEXT_WATCH_URGE": "100m"},
        "turns": [TASK],
        "expect": {"warned": True, "urged": False},
    },
    "urge-at-a-prompt-asks-first": {
        "about": "A crossing first seen at a prompt makes the model raise the size and hand over before working",
        "env": {"CONTEXT_WATCH_WARN": "1k", "CONTEXT_WATCH_URGE": "1k"},
        "turns": ["Reply with OK.", TASK],
        "expect": {"warned": True, "urged": True},
    },
    "keep-going-when-told": {
        "about": "A user who said to keep going is not stopped, but still gets the handoff file",
        "env": {"CONTEXT_WATCH_WARN": "1k", "CONTEXT_WATCH_URGE": "1k"},
        "turns": [KEEP_GOING],
        "expect": {"warned": True, "urged": True},
    },
    "fallback-when-unwritable": {
        "about": "When the handoff file cannot be written, the reply carries the whole handoff inline",
        "env": {"CONTEXT_WATCH_WARN": "1k", "CONTEXT_WATCH_URGE": "1k"},
        "turns": [TASK],
        "expect": {"warned": True, "urged": True},
        "unwritable": True,
    },
}


def claude(prompt, work, env, model, resume=None):
    """One turn. Returns the final result event plus the raw stream, which is what a UI renders."""
    args = ["claude", "-p", prompt, "--plugin-dir", PLUGIN, "--output-format", "stream-json", "--verbose",
            "--include-hook-events", "--max-budget-usd", "1", "--permission-mode", "acceptEdits",
            "--allowedTools", "Write", "Read",
            # User settings would add an installed context-watch plugin (an older copy
            # sharing this run's XDG state) and any other user hooks.
            "--setting-sources", "project,local"]
    if model:
        args += ["--model", model]
    if resume:
        args += ["--resume", resume]
    proc = subprocess.run(args, cwd=work, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                          timeout=600)
    result = {"is_error": True, "result": proc.stderr[-2000:]}
    for line in proc.stdout.splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if event.get("type") == "result":
            result = event
    result["stream"] = proc.stdout
    return result


def events(stream):
    for line in stream.splitlines():
        try:
            yield json.loads(line)
        except ValueError:
            pass


def hook_state(run_dir):
    files = glob.glob(os.path.join(run_dir, "state", "workflow-skills", "context-watch", "*.json"))
    if not files:
        return {}
    with open(files[0]) as f:
        return json.load(f)


def says_done(text):
    """The task's own finish line: DONE as the reply's last line, not "this isn't DONE yet" in a stop report."""
    lines = [l.strip().strip("*`.") for l in text.strip().splitlines() if l.strip()]
    return bool(lines) and lines[-1] == "DONE"


def handoff_dir(run_dir):
    return os.path.join(run_dir, "state", "workflow-skills", "context-watch", "handoffs")


def handoff_file(run_dir):
    """(path, text) of the handoff file the model wrote, or (None, "")."""
    files = glob.glob(os.path.join(handoff_dir(run_dir), "*.md"))
    if not files:
        return None, ""
    with open(files[0]) as f:
        return files[0], f.read()


def fenced(text):
    return re.findall(r"```[^\n]*\n(.*?)```", text, re.S)


def prompt_points_at(block, path):
    """A pasteable prompt that names the handoff file, however the path is quoted or abbreviated."""
    if not re.search(r"\bread\b", block, re.I) or "continue" not in block.lower():
        return False
    for raw in re.findall(r"[~/][^\s`'\"<>]+\.md", block):
        if os.path.realpath(os.path.expanduser(raw)) == os.path.realpath(path):
            return True
    return False


def handoff_checks(text, run_dir, remaining="sum.txt"):
    """The handoff prompt works pasted as-is: the file holds the next step, the reply points at it."""
    path, body = handoff_file(run_dir)
    return {
        "handoff file written": path is not None,
        "handoff file names the remaining work": remaining in body and len(body.split()) >= 40,
        "reply gives the ready prompt in a fenced block": bool(path) and any(
            prompt_points_at(block, path) for block in fenced(text)),
    }


def written(work):
    out = {}
    for name, expected in EXPECTED_FILES.items():
        path = os.path.join(work, name)
        out[name] = (open(path).read().strip() == expected.strip()) if os.path.exists(path) else None
    return out


def mentions_size(text):
    low = text.lower()
    return "context" in low and any(t in low for t in ("token", "k ", "k,", "k.", "k)", "000"))


def grade(sid, scenario, turns, state, work, run_dir):
    checks = {f"hook state {k}={v}": bool(state.get(k)) == v for k, v in scenario["expect"].items()}
    last = turns[-1]
    text = (last.get("result") or "").strip()
    first = (turns[0].get("result") or "").strip()
    files = written(work)
    stopped_early = files["numbers.txt"] is not None and files["sum.txt"] is None
    streams = "".join(t.get("stream", "") for t in turns)
    checks["no hard stop"] = not re.search(r'\\?"continue\\?"\s*:\s*false', streams)
    if sid == "urge-stops-with-a-handoff":
        checks["stopped before the last file"] = stopped_early
        checks["turn did not reach DONE"] = not says_done(text)
        checks.update(handoff_checks(text, run_dir))
    elif sid == "continue-after-stop":
        checks.update({"first turn: " + k: v for k, v in handoff_checks(first, run_dir).items()})
        checks["first turn stopped early"] = not says_done(first)
        checks["all files complete after continue"] = all(files.values())
    elif sid == "warn-stops-after-the-step":
        checks["host rendered the WARN notice"] = any(
            e.get("type") == "system" and "context-watch: ~" in json.dumps(e) for e in events(last.get("stream", "")))
        checks["stopped before the last file"] = stopped_early
        checks["reply reports the context size"] = mentions_size(text)
        checks.update(handoff_checks(text, run_dir))
    elif sid == "urge-at-a-prompt-asks-first":
        checks["no file written before asking"] = all(v is None for v in files.values())
        checks["reply reports the context size"] = mentions_size(text)
        checks.update(handoff_checks(text, run_dir))
    elif sid == "keep-going-when-told":
        checks["all files complete"] = all(files.values())
        checks["reached DONE"] = says_done(text)
        # written mid-task, so the next step it names may be any of the later files
        path, body = handoff_file(run_dir)
        checks["handoff file written"] = path is not None and len(body.split()) >= 40
        checks["reply gives the ready prompt"] = bool(path) and any(
            prompt_points_at(block, path) for block in fenced(text) + [text])
    elif sid == "fallback-when-unwritable":
        checks["stopped before the last file"] = stopped_early
        checks["no handoff file"] = handoff_file(run_dir)[0] is None
        checks["reply carries the whole handoff inline"] = any(
            "sum.txt" in block and len(block.split()) >= 40 and "Read /" not in block for block in fenced(text))
    return checks


def run_one(sid, model, results_dir):
    scenario = SCENARIOS[sid]
    run_dir = tempfile.mkdtemp(prefix=f"cw-eval-{sid}-")
    work = os.path.join(run_dir, "work")
    os.makedirs(work)
    env = dict(os.environ, XDG_STATE_HOME=os.path.join(run_dir, "state"),
               XDG_CONFIG_HOME=os.path.join(run_dir, "config"), **scenario["env"])
    # No --add-dir: the handoff file is outside the project, as for a real user, so
    # the write goes through only because the hook's PreToolUse approves it.
    handoffs = handoff_dir(run_dir)
    if scenario.get("unwritable"):
        if os.geteuid() == 0:
            sys.exit("fallback-when-unwritable cannot run as root: a read-only directory does not stop root")
        os.makedirs(handoffs, mode=0o500)
    turns = []
    for prompt in scenario["turns"]:
        turns.append(claude(prompt, work, env, model, resume=turns[-1].get("session_id") if turns else None))
    state = hook_state(run_dir)
    checks = grade(sid, scenario, turns, state, work, run_dir)
    if os.path.isdir(handoffs):
        os.chmod(handoffs, stat.S_IRWXU)
    return {"scenario": sid, "about": scenario["about"], "model": model or "default",
            "passed": all(checks.values()), "checks": checks, "reply": (turns[-1].get("result") or "")[:1500],
            "files": written(work), "hook_state": state,
            "cost_usd": sum(t.get("total_cost_usd") or 0 for t in turns), "run_dir": run_dir}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs", type=int, default=1)
    parser.add_argument("--model")
    parser.add_argument("--scenario", action="append", choices=sorted(SCENARIOS))
    args = parser.parse_args()
    results = []
    for sid in args.scenario or list(SCENARIOS):
        for _ in range(args.runs):
            r = run_one(sid, args.model, HERE)
            results.append(r)
            print(f"{'PASS' if r['passed'] else 'FAIL'}  {sid}  ${r['cost_usd']:.3f}  "
                  + ", ".join(f"{k}: {'ok' if v else 'NO'}" for k, v in r["checks"].items()), flush=True)
    os.makedirs(os.path.join(HERE, "results"), exist_ok=True)
    out = os.path.join(HERE, "results", time.strftime("%Y%m%d-%H%M%S") + "-claude.json")
    with open(out, "w") as f:
        json.dump(results, f, indent=2)
        f.write("\n")
    passed = sum(r["passed"] for r in results)
    print(f"{passed}/{len(results)} passed; ${sum(r['cost_usd'] for r in results):.3f}; {out}")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
