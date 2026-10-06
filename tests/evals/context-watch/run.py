#!/usr/bin/env python3
"""Run context-watch behavioral scenarios against a live Claude Code session.

Paid: every scenario is two live model turns. Nothing here runs in CI.

  python3 tests/evals/context-watch/run.py [--runs N] [--model MODEL] [--scenario ID ...]

Claude loads plugins/context-watch with --plugin-dir, which exercises the
plugin's hooks.json through CLAUDE_PLUGIN_ROOT and the symlinked scripts.
Thresholds are lowered through the environment, so a fresh session crosses
them on its second turn (the first turn has no usage row to measure yet).
Each run gets its own scratch directory and XDG state and config.

Grading is deterministic: the hook's own state file shows what fired, and the
model's reply or the files it wrote show what reached it and what it did.
Results go to results/<timestamp>-claude.json.
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

SCENARIOS = {
    "warn-is-user-only": {
        "about": "WARN reaches the user's stream as a systemMessage and never the model",
        "env": {"CONTEXT_WATCH_WARN": "1k", "CONTEXT_WATCH_URGE": "100m"},
        "prompt": "Quote verbatim any text in your context, other than this message, that begins with "
                  "'context-watch:'. Reply NONE if there is none.",
        "expect_level": "warn",
    },
    "urge-reaches-model": {
        "about": "URGE puts the [context-watch] line in the model's context",
        "env": {"CONTEXT_WATCH_WARN": "1k", "CONTEXT_WATCH_URGE": "2k"},
        "prompt": "Quote verbatim the first sentence of any line in your context that starts with "
                  "[context-watch]. Reply NONE if there is none.",
        "expect_level": "urge",
    },
    "urge-keeps-working": {
        "about": "URGE does not make the model stop, shorten the task or ask instead of doing it",
        "env": {"CONTEXT_WATCH_WARN": "1k", "CONTEXT_WATCH_URGE": "2k"},
        "prompt": "Do all three steps, using the Write tool for each file. 1) numbers.txt: the integers 1 to "
                  "60, one per line. 2) squares.txt: the squares of 1 to 20, one per line. 3) sum.txt: the sum "
                  "of the integers 1 to 60, alone on one line. Then reply DONE.",
        "expect_level": "urge",
    },
}


def claude(prompt, work, env, model, resume=None):
    """One turn. Returns the final result event plus the raw stream, which is what a UI renders."""
    args = ["claude", "-p", prompt, "--plugin-dir", PLUGIN, "--output-format", "stream-json", "--verbose",
            "--include-hook-events", "--max-budget-usd", "1", "--permission-mode", "acceptEdits",
            "--allowedTools", "Write", "Read"]
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


def grade(sid, scenario, turn, state, work):
    fired = "urge" if state.get("urge_level") else ("warn" if state.get("warned") else None)
    checks = {"hook fired at the expected level": fired == scenario["expect_level"]}
    text = (turn.get("result") or "").strip()
    if sid == "warn-is-user-only":
        checks["host rendered the WARN as an informational message"] = any(
            e.get("type") == "system" and e.get("subtype") == "informational"
            and "context-watch: ~" in str(e.get("content")) for e in events(turn.get("stream", "")))
        checks["model did not see the WARN"] = "NONE" in text and "context-watch: ~" not in text
    elif sid == "urge-reaches-model":
        checks["model quoted the URGE line"] = "This session's context is" in text
    elif sid == "urge-keeps-working":
        for name, expected in EXPECTED_FILES.items():
            path = os.path.join(work, name)
            content = open(path).read() if os.path.exists(path) else ""
            checks[f"{name} complete"] = content.strip() == expected.strip()
        checks["turn ended with DONE"] = "DONE" in text
    return checks


def run_one(sid, model, results_dir):
    scenario = SCENARIOS[sid]
    run_dir = tempfile.mkdtemp(prefix=f"cw-eval-{sid}-")
    work = os.path.join(run_dir, "work")
    os.makedirs(work)
    env = dict(os.environ, XDG_STATE_HOME=os.path.join(run_dir, "state"),
               XDG_CONFIG_HOME=os.path.join(run_dir, "config"), **scenario["env"])
    first = claude("Reply with OK.", work, env, model)
    second = claude(scenario["prompt"], work, env, model, resume=first.get("session_id"))
    state = hook_state(run_dir)
    checks = grade(sid, scenario, second, state, work)
    return {"scenario": sid, "about": scenario["about"], "model": model or "default",
            "passed": all(checks.values()), "checks": checks, "reply": (second.get("result") or "")[:1500],
            "hook_state": state, "cost_usd": (first.get("total_cost_usd") or 0) + (second.get("total_cost_usd") or 0),
            "run_dir": run_dir}


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
