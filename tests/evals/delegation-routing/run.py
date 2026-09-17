#!/usr/bin/env python3
"""Run delegation-routing behavioral scenarios against a real host CLI.

Paid: every run is a live model session. Nothing here runs in CI.

  python3 tests/evals/delegation-routing/run.py --host claude [--runs 3] [--scenario ID ...]
  python3 tests/evals/delegation-routing/run.py --host codex --reviewed-hook-trust-bypass

Each run gets its own scratch directory, XDG state/config, a PATH with
opencode-delegate pointing at this checkout and a stub `opencode` that always
fails (so no paid worker can launch). Claude loads this checkout as a plugin
(--plugin-dir), which exercises hooks/hooks.json through CLAUDE_PLUGIN_ROOT.
Codex gets the local-install hook command inline; its hooks need the explicit,
user-approved single-invocation trust bypass.

Grading is deterministic: native starts come from the host's own counters
(Claude subagent_stats, Codex spawn tool results), routes and denials from the
routing audit log. Results are written to results/<timestamp>-<host>.json.
"""
import argparse, json, os, shlex, shutil, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.realpath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
DELEGATE = os.path.join(REPO, "skills", "opencode-subagent", "scripts", "delegate.sh")


def prepare(run_dir, policy):
    work = os.path.join(run_dir, "work")
    bindir = os.path.join(run_dir, "bin")
    for d in (work, bindir, os.path.join(run_dir, "config", "workflow-skills")):
        os.makedirs(d, exist_ok=True)
    with open(os.path.join(work, "alpha.txt"), "w") as f:
        f.write("SENTINEL_ALPHA\n")
    with open(os.path.join(run_dir, "config", "workflow-skills", "subagents.conf"), "w") as f:
        f.write(f"OPENCODE_SUBAGENT_DELEGATION_POLICY={policy}\nOPENCODE_SUBAGENT_MODEL=stub/unavailable\n")
    os.symlink(DELEGATE, os.path.join(bindir, "opencode-delegate"))
    with open(os.path.join(bindir, "opencode"), "w") as f:
        f.write("#!/bin/sh\necho 'opencode: provider unavailable (eval stub)' >&2\nexit 1\n")
    os.chmod(os.path.join(bindir, "opencode"), 0o755)
    env = dict(os.environ, PATH=bindir + os.pathsep + os.environ["PATH"],
               XDG_STATE_HOME=os.path.join(run_dir, "state"), XDG_CONFIG_HOME=os.path.join(run_dir, "config"))
    return work, env


def audit(run_dir):
    path = os.path.join(run_dir, "state", "workflow-skills", "routing", "audit.jsonl")
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def run_claude(prompt, work, env, run_dir):
    args = ["claude", "-p", prompt, "--plugin-dir", REPO, "--output-format", "stream-json", "--verbose",
            "--include-hook-events", "--max-budget-usd", "1", "--permission-mode", "acceptEdits",
            "--allowedTools", "Bash(opencode-delegate:*)", "Agent", "Read", "Write", "Skill"]
    with open(os.path.join(run_dir, "stdout.jsonl"), "w") as out, open(os.path.join(run_dir, "stderr.log"), "w") as err:
        try:
            code = subprocess.run(args, cwd=work, env=env, stdin=subprocess.DEVNULL, stdout=out, stderr=err, timeout=600).returncode
        except subprocess.TimeoutExpired:
            code = 124
    starts, final = None, ""
    with open(os.path.join(run_dir, "stdout.jsonl")) as f:
        for line in f:
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if msg.get("type") == "result":
                starts = (msg.get("subagent_stats") or {}).get("spawned", 0)
                final = msg.get("result", "")
    return code, starts, final


def run_codex(prompt, work, env, run_dir):
    command = f"OPENCODE_DELEGATE_PYTHON={shlex.quote(sys.executable)} bash {shlex.quote(DELEGATE)} route hook --host codex"
    with open(os.path.join(REPO, "hooks", "hooks.json")) as f:
        shipped = json.load(f)["hooks"]
    args = ["codex", "exec", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check", "--json",
            "--sandbox", "workspace-write", "-C", work, "--dangerously-bypass-hook-trust"]
    for event, groups in shipped.items():
        group = groups[0]
        matcher = f'matcher={json.dumps(group["matcher"])},' if "matcher" in group else ""
        args += ["-c", f'hooks.{event}=[{{{matcher}hooks=[{{type="command",command={json.dumps(command)},timeout=10}}]}}]']
    args.append(prompt)
    with open(os.path.join(run_dir, "stdout.jsonl"), "w") as out, open(os.path.join(run_dir, "stderr.log"), "w") as err:
        try:
            code = subprocess.run(args, cwd=work, env=env, stdin=subprocess.DEVNULL, stdout=out, stderr=err, timeout=600).returncode
        except subprocess.TimeoutExpired:
            code = 124
    starts, final, text = 0, "", open(os.path.join(run_dir, "stdout.jsonl")).read()
    for line in text.splitlines():
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        item = msg.get("item") or {}
        if item.get("type") == "collab_tool_call" and item.get("tool") in ("spawn_agent", "collaborationspawn_agent") and item.get("status") == "completed":
            starts += 1
        if item.get("type") == "agent_message":
            final = item.get("text", "")
    if "usage limit" in text:
        code = "usage_limit"
    return code, starts, final


def grade(scenario, starts, events):
    expect = scenario["expect"]
    denials = sum(e["event"] == "deny" for e in events)
    routes = [e["route"] for e in events if e["event"] == "record"]
    failures = []
    if starts is None:
        failures.append("host reported no subagent count")
    elif "native_starts" in expect and starts != expect["native_starts"]:
        failures.append(f"native_starts={starts}, want {expect['native_starts']}")
    if denials > expect["max_denials"]:
        failures.append(f"denials={denials} > {expect['max_denials']} (denial loop)")
    for route in expect.get("routes_include", []):
        if route not in routes:
            failures.append(f"no recorded {route} route (routes={routes})")
    return {"native_starts": starts, "denials": denials, "routes": routes,
            "allows": sum(e["event"] == "allow" for e in events), "pass": not failures, "failures": failures}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", choices=("claude", "codex"), required=True)
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--scenario", action="append")
    ap.add_argument("--reviewed-hook-trust-bypass", action="store_true")
    ap.add_argument("--keep", default=None, help="directory to keep run artifacts (default: a temp dir, printed)")
    a = ap.parse_args()
    if a.host == "codex" and not a.reviewed_hook_trust_bypass:
        ap.error("codex runs need --reviewed-hook-trust-bypass (single invocation, isolated hooks, user-approved)")
    with open(os.path.join(HERE, "scenarios.json")) as f:
        scenarios = [s for s in json.load(f)["scenarios"] if not a.scenario or s["id"] in a.scenario]
    root = a.keep or tempfile.mkdtemp(prefix=f"routing-eval-{a.host}-")
    version = subprocess.run([a.host, "--version"], capture_output=True, text=True).stdout.strip()
    results = {"host": a.host, "version": version, "started": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "artifacts": os.path.basename(root), "runs": []}
    for s in scenarios:
        for i in range(1, a.runs + 1):
            run_dir = os.path.join(root, f"{s['id']}-{i}")
            os.makedirs(run_dir)
            work, env = prepare(run_dir, s["policy"])
            if s.get("project_instructions"):
                for name in ("CLAUDE.md", "AGENTS.md"):
                    with open(os.path.join(work, name), "w") as f:
                        f.write(s["project_instructions"])
            prompt = s["prompt"].format(dir=work)
            code, starts, final = (run_claude if a.host == "claude" else run_codex)(prompt, work, env, run_dir)
            graded = grade(s, starts, audit(run_dir))
            graded.update(scenario=s["id"], run=i, critical=s["critical"], exit=code, final=final[-400:])
            results["runs"].append(graded)
            print(json.dumps({k: graded[k] for k in ("scenario", "run", "pass", "native_starts", "denials", "routes", "failures")}), flush=True)
            if code == "usage_limit":
                print("host usage limit reached; stopping", file=sys.stderr)
                break
    crit = [r for r in results["runs"] if r["critical"]]
    results["summary"] = {
        "runs": len(results["runs"]), "passed": sum(r["pass"] for r in results["runs"]),
        "critical_runs": len(crit), "critical_forbidden_native_starts": sum((r["native_starts"] or 0) for r in crit),
    }
    os.makedirs(os.path.join(HERE, "results"), exist_ok=True)
    out = os.path.join(HERE, "results", f"{time.strftime('%Y%m%d-%H%M%S')}-{a.host}.json")
    with open(out, "w") as f:
        json.dump(results, f, indent=2)
    print(json.dumps(results["summary"]), "->", out)
    return 0 if results["summary"]["passed"] == results["summary"]["runs"] else 1


if __name__ == "__main__":
    sys.exit(main())
