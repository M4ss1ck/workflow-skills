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
stream shows what the host rendered, and the files the model wrote show where
it stopped. Results go to results/<timestamp>-claude.json.
"""
import argparse, glob, json, os, subprocess, sys, tempfile, time

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

SCENARIOS = {
    "urge-stops-the-turn": {
        "about": "A tool call that crosses URGE stops the turn there; the user sees the hook's message",
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
        "about": "WARN after a tool call makes the model finish that step, stop, and report the size",
        "env": {"CONTEXT_WATCH_WARN": "1k", "CONTEXT_WATCH_URGE": "100m"},
        "turns": [TASK],
        "expect": {"warned": True, "urged": False},
    },
    "urge-at-a-prompt-asks-first": {
        "about": "A crossing first seen at a prompt makes the model raise the size before starting the work",
        "env": {"CONTEXT_WATCH_WARN": "1k", "CONTEXT_WATCH_URGE": "1k"},
        "turns": ["Reply with OK.", TASK],
        "expect": {"warned": True, "urged": True},
    },
}
STOP_TEXT = "context-watch stopped this turn"


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


def written(work):
    out = {}
    for name, expected in EXPECTED_FILES.items():
        path = os.path.join(work, name)
        out[name] = (open(path).read().strip() == expected.strip()) if os.path.exists(path) else None
    return out


def mentions_size(text):
    low = text.lower()
    return "context" in low and any(t in low for t in ("token", "k ", "k,", "k.", "k)", "000"))


def grade(sid, scenario, turns, state, work):
    checks = {f"hook state {k}={v}": bool(state.get(k)) == v for k, v in scenario["expect"].items()}
    last = turns[-1]
    text = (last.get("result") or "").strip()
    files = written(work)
    if sid == "urge-stops-the-turn":
        checks["stopped after the first file"] = files["numbers.txt"] is not None and files["sum.txt"] is None
        checks["host carried the stop message"] = STOP_TEXT in last.get("stream", "")
        checks["turn did not reach DONE"] = "DONE" not in text
    elif sid == "continue-after-stop":
        checks["first turn stopped early"] = STOP_TEXT in turns[0].get("stream", "")
        checks["all files complete after continue"] = all(files.values())
        checks["no second stop"] = STOP_TEXT not in last.get("stream", "")
    elif sid == "warn-stops-after-the-step":
        checks["host rendered the WARN notice"] = any(
            e.get("type") == "system" and "context-watch: ~" in json.dumps(e) for e in events(last.get("stream", "")))
        checks["stopped before the last file"] = files["numbers.txt"] is not None and files["sum.txt"] is None
        checks["reply reports the context size"] = mentions_size(text)
        checks["no stop was needed"] = STOP_TEXT not in last.get("stream", "")
    elif sid == "urge-at-a-prompt-asks-first":
        checks["no file written before asking"] = all(v is None for v in files.values())
        checks["reply reports the context size"] = mentions_size(text)
    return checks


def run_one(sid, model, results_dir):
    scenario = SCENARIOS[sid]
    run_dir = tempfile.mkdtemp(prefix=f"cw-eval-{sid}-")
    work = os.path.join(run_dir, "work")
    os.makedirs(work)
    env = dict(os.environ, XDG_STATE_HOME=os.path.join(run_dir, "state"),
               XDG_CONFIG_HOME=os.path.join(run_dir, "config"), **scenario["env"])
    turns = []
    for prompt in scenario["turns"]:
        turns.append(claude(prompt, work, env, model, resume=turns[-1].get("session_id") if turns else None))
    state = hook_state(run_dir)
    checks = grade(sid, scenario, turns, state, work)
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
