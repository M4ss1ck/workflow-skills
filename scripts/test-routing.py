#!/usr/bin/env python3
"""Deterministic tests for opencode-subagent native delegation routing.

No model, network or host CLI calls. Run: python3 scripts/test-routing.py
"""

import argparse
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
SCRIPTS = os.path.join(REPO, "skills", "opencode-subagent", "scripts")
DELEGATE = os.path.join(SCRIPTS, "delegate.sh")
FIXTURES = os.path.join(REPO, "tests", "routing", "fixtures")
sys.dont_write_bytecode = True  # keep __pycache__ out of the skill directory
sys.path.insert(0, SCRIPTS)
import routing  # noqa: E402

REVISION = routing.skill_revision()
BASH = shutil.which("bash")


def record_args(**fields):
    base = dict(proposal=None, assignment="task-a", scope="add the parser", work_kind="implementation",
                authorization="user", source_excerpt="please delegate the parser work", workflow_file=None,
                requested_provider="unspecified", native_reason=None, opencode_task=None, scope_status="clear",
                skill_revision=REVISION)
    base.update(fields)
    return argparse.Namespace(**base)


AGENT_ID = "a47b8347f3aeb273e"
OTHER_ID = "a9737b40bcb8c449b"


def rec(**fields):
    return routing.validate_record(record_args(proposal="p", **fields))


class Env(unittest.TestCase):
    """Isolated XDG dirs and a store for each test."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="routing-test ")  # a space, on purpose
        self.old_env = {k: os.environ.get(k) for k in ("XDG_STATE_HOME", "XDG_CONFIG_HOME")}
        os.environ["XDG_STATE_HOME"] = os.path.join(self.tmp, "state")
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self.tmp, "config")
        self.worktree = os.path.join(self.tmp, "work tree")
        os.makedirs(self.worktree)
        self.store = routing.Store()

    def tearDown(self):
        for k, v in self.old_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.tmp)

    def set_policy(self, value):
        path = routing.conf_file()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(f"OPENCODE_SUBAGENT_MODEL=stub/model\n{routing.POLICY_KEY}={value}\n")

    # -- host events

    def hook(self, payload, host="auto"):
        return routing.run_hook(host, json.dumps(payload) if not isinstance(payload, str) else payload, self.store)

    def prompt(self, text, session="s1", host_extra=None):
        payload = {"hook_event_name": "UserPromptSubmit", "session_id": session, "cwd": self.worktree, "prompt": text}
        payload.update(host_extra or {})
        return self.hook(payload)

    def call(self, tool="Agent", tool_input=None, session="s1", cwd=None, tool_use_id=None, extra=None):
        payload = {"hook_event_name": "PreToolUse", "session_id": session, "cwd": cwd or self.worktree,
                   "tool_name": tool, "tool_input": tool_input if tool_input is not None else {"prompt": "read a.txt", "subagent_type": "x"}}
        if tool_use_id:
            payload["tool_use_id"] = tool_use_id
        payload.update(extra or {})
        return self.hook(payload)

    def post(self, tool_use_id, tool_input, agent_id=None, tool="Agent", session="s1", response=None, extra=None):
        """A live-shaped PostToolUse for an Agent call (Claude Code 2.1.296)."""
        if response is None:
            response = {"status": "completed", "prompt": tool_input.get("prompt"), "agentId": agent_id,
                        "agentType": tool_input.get("subagent_type"), "content": [{"type": "text", "text": "done"}]}
        payload = {"hook_event_name": "PostToolUse", "session_id": session, "cwd": self.worktree, "tool_name": tool,
                   "tool_input": tool_input, "tool_response": response, "tool_use_id": tool_use_id, "duration_ms": 5}
        payload.update(extra or {})
        return self.hook(payload)

    def decision(self, out):
        return out["hookSpecificOutput"]["permissionDecision"]

    def proposal_of(self, out):
        m = re.search(r"proposal ((?:claude|codex)-[0-9a-f]{12}-\d+)", out["hookSpecificOutput"]["permissionDecisionReason"])
        self.assertIsNotNone(m, out)
        return m.group(1)

    def record(self, proposal, **fields):
        return routing.record_decision(record_args(proposal=proposal, **fields), self.store)

    def grant_native(self, tool_input=None, **call_kw):
        """Deny, record a native user request, return the proposal id."""
        out = self.call(tool_input=tool_input, **call_kw)
        pid = self.proposal_of(out)
        result = self.record(pid, requested_provider="native", work_kind="research",
                             source_excerpt="use a native agent for the research")
        self.assertEqual(result["route"], "native", result)
        return pid


class PolicyParity(Env):
    """read_policy must agree with delegate.sh on every config shape."""

    CASES = [
        None,  # no file
        "",
        "OPENCODE_SUBAGENT_DELEGATION_POLICY=auto\n",
        "OPENCODE_SUBAGENT_DELEGATION_POLICY=off\nOPENCODE_SUBAGENT_DELEGATION_POLICY=auto\n",
        "OPENCODE_SUBAGENT_DELEGATION_POLICY=\n",
        "OPENCODE_SUBAGENT_DELEGATION_POLICY=auto \n",
        "OPENCODE_SUBAGENT_DELEGATION_POLICY=auto\r\n",
        " OPENCODE_SUBAGENT_DELEGATION_POLICY=off\n",
        "# OPENCODE_SUBAGENT_DELEGATION_POLICY=off\nOPENCODE_SUBAGENT_DELEGATION_POLICY=explicit",
        "OPENCODE_SUBAGENT_DELEGATION_POLICY=AUTO\n",
        "OPENCODE_SUBAGENT_DELEGATION_POLICY=bogus\n",
        "OPENCODE_SUBAGENT_DELEGATION_POLICYX=off\n",
    ]

    def test_parity_with_delegate_sh(self):
        path = routing.conf_file()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        for content in self.CASES:
            with self.subTest(content=content):
                if content is None:
                    if os.path.exists(path):
                        os.remove(path)
                else:
                    with open(path, "w", newline="") as f:
                        f.write(content)
                env = dict(os.environ, PATH=os.environ["PATH"])
                sh = subprocess.run([BASH, DELEGATE, "policy", "--json"], capture_output=True, text=True, env=env)
                try:
                    py = routing.read_policy()
                except routing.RoutingError:
                    py = None
                sh_value = json.loads(sh.stdout)["delegation_policy"] if sh.returncode == 0 else None
                self.assertEqual(py, sh_value, sh.stderr)


def shlex_like(path):
    return "'" + path.replace("'", "'\\''") + "'"


class Decide(unittest.TestCase):
    """The policy precedence table, row by row."""

    def test_matrix(self):
        none = dict(authorization="none", source_excerpt="")
        failed = dict(native_reason="opencode-failed", opencode_task="task_20261010-120000-1")
        rows = [
            # policy, record fields, prior assignment, excerpt epoch, expected route
            ("off", dict(requested_provider="native"), None, 1, "none"),
            ("off", dict(none), None, None, "none"),
            ("off", dict(none, work_kind="review"), None, None, "none"),
            ("explicit", dict(none), None, None, "local"),
            ("explicit", dict(none, work_kind="research"), None, None, "local"),
            ("explicit", dict(none, work_kind="research", native_reason="needs-host-tools"), None, None, "local"),
            # a review is never the author's: unauthorized, it still goes to a reviewer
            ("explicit", dict(none, work_kind="review"), None, None, "opencode"),
            # ...but a native agent needs authorization, even for a review
            ("explicit", dict(none, work_kind="review", native_reason="needs-host-tools"), None, None, "clarify"),
            ("explicit", dict(requested_provider="opencode"), None, 1, "opencode"),
            ("auto", dict(requested_provider="opencode", work_kind="research"), None, 1, "opencode"),
            ("explicit", dict(requested_provider="native"), None, 1, "native"),
            ("auto", dict(requested_provider="native", work_kind="implementation"), None, 1, "native"),
            ("explicit", dict(), None, 1, "opencode"),
            ("auto", dict(none), None, None, "opencode"),
            # research and review default to the OpenCode researcher
            ("auto", dict(none, work_kind="research"), None, None, "opencode"),
            ("auto", dict(none, work_kind="review"), None, None, "opencode"),
            ("explicit", dict(work_kind="research"), None, 1, "opencode"),
            # native only for a closed reason
            ("explicit", dict(work_kind="research", native_reason="needs-host-tools"), None, 1, "native"),
            ("auto", dict(none, work_kind="review", native_reason="needs-host-tools"), None, None, "native"),
            ("auto", dict(work_kind="review", **failed), None, 1, "invalid"),
            ("explicit", dict(scope_status="ambiguous", requested_provider="native"), None, 1, "clarify"),
            ("auto", dict(scope_status="conflicting"), None, 1, "clarify"),
            # workflow authorization acts as a generic delegation request, and may ask for native research/review
            ("explicit", dict(authorization="workflow", workflow_file="/x", requested_provider="native", work_kind="research"), None, None, "native"),
            ("explicit", dict(authorization="workflow", workflow_file="/x", requested_provider="native", work_kind="review"), None, None, "native"),
            ("explicit", dict(authorization="workflow", workflow_file="/x", requested_provider="native"), None, None, "opencode"),
            # an OpenCode assignment keeps its provider...
            ("auto", dict(work_kind="research", native_reason="needs-host-tools"), {"provider": "opencode", "epoch": 2}, 3, "opencode"),
            ("auto", dict(requested_provider="native"), {"provider": "opencode", "epoch": 2}, 2, "opencode"),
            ("auto", dict(requested_provider="native", authorization="workflow", workflow_file="/x"), {"provider": "opencode", "epoch": 2}, None, "opencode"),
            # ...until a later explicit user override, or (research/review) a proven OpenCode failure
            ("auto", dict(requested_provider="native"), {"provider": "opencode", "epoch": 2}, 3, "native"),
            ("auto", dict(work_kind="review", **failed), {"provider": "opencode", "epoch": 2}, 1, "native"),
            ("off", dict(requested_provider="native"), {"provider": "opencode", "epoch": 2}, 3, "none"),
            # a native assignment does not restrict later OpenCode use
            ("explicit", dict(requested_provider="opencode"), {"provider": "native", "epoch": 1}, 2, "opencode"),
        ]
        for policy, fields, prior, epoch, expected in rows:
            with self.subTest(policy=policy, fields=fields, prior=prior):
                route, reason = routing.decide(policy, rec(**fields), prior, epoch)
                self.assertEqual(route, expected, reason)
                self.assertTrue(reason)


class Validation(unittest.TestCase):
    def assertInvalid(self, fragment, **fields):
        with self.assertRaises(routing.RoutingError) as ctx:
            routing.validate_record(record_args(proposal="p", **fields))
        self.assertIn(fragment, str(ctx.exception))

    def test_required_and_enums(self):
        with self.assertRaises(routing.RoutingError) as ctx:
            routing.validate_record(record_args())
        self.assertIn("--proposal is required", str(ctx.exception))
        self.assertInvalid("--work-kind must be one of", work_kind="coding")
        self.assertInvalid("--authorization must be one of", authorization="model")
        self.assertInvalid("--requested-provider must be one of", requested_provider="gpt")
        self.assertInvalid("--scope-status must be one of", scope_status="fine")
        self.assertInvalid("--scope is required", scope="  ")
        self.assertInvalid("--skill-revision is required", skill_revision="")
        self.assertInvalid("--assignment must be a lowercase slug", assignment="Task A")
        self.assertInvalid("limited to 2000", scope="x" * 2001)

    def test_defaults_are_the_cautious_values(self):
        r = routing.validate_record(record_args(proposal="p", authorization=None, source_excerpt=None,
                                                requested_provider=None, scope_status=None))
        self.assertEqual((r["authorization"], r["requested_provider"], r["scope_status"]), ("none", "unspecified", "clear"))

    def test_native_reasons_are_a_closed_set(self):
        self.assertInvalid("--native-reason must be one of", work_kind="review", native_reason="independent eyes")
        self.assertInvalid("applies to research and review", native_reason="needs-host-tools")
        self.assertInvalid("needs --opencode-task", work_kind="review", native_reason="opencode-failed")
        self.assertInvalid("needs --opencode-task", work_kind="review", native_reason="opencode-failed", opencode_task="x")
        self.assertInvalid("applies only to --native-reason opencode-failed", work_kind="review",
                           opencode_task="task_20261010-120000-1")

    def test_sources(self):
        self.assertInvalid("--source-excerpt must quote", source_excerpt="yes")
        self.assertInvalid("applies only to", workflow_file="/x")
        self.assertInvalid("a requested provider needs its source", authorization="none", source_excerpt="", requested_provider="native")
        self.assertInvalid("a requested provider needs its source", authorization="none", source_excerpt="", requested_provider="opencode")


class HookProtocol(Env):
    def test_unrelated_events_and_tools_pass_untouched(self):
        self.prompt("hello there")
        for tool in ("Bash", "Read", "TaskOutput", "TaskStop", "collaborationwait_agent", "mcp__x__Agent"):
            self.assertIsNone(self.call(tool=tool))
        self.assertIsNone(self.hook({"hook_event_name": "PostToolUse", "session_id": "s1", "tool_name": "Agent", "tool_input": {}}))
        self.assertIsNone(self.hook({"hook_event_name": "Stop", "session_id": "s1"}))
        self.assertIsNone(self.hook("not json at all"))

    def test_creation_denied_then_native_grant_replays_the_proposal_once(self):
        self.prompt("use a native agent for the research on the parser")
        first = {"prompt": "read alpha.txt", "subagent_type": "x"}
        pid = self.grant_native(tool_input=first)
        retry = {"prompt": "read bravo.txt", "subagent_type": "x"}
        out = self.call(tool_input=retry)
        self.assertEqual(self.decision(out), "allow")
        self.assertEqual(out["hookSpecificOutput"]["updatedInput"], first)
        self.assertNotIn("permissionDecisionReason", out["hookSpecificOutput"])
        # single use: the next call is a new proposal
        again = self.call(tool_input=first)
        self.assertEqual(self.decision(again), "deny")
        self.assertNotEqual(self.proposal_of(again), pid)
        shown = routing.show(pid, self.store)
        self.assertEqual(shown["status"], "consumed")
        self.assertFalse(shown["decision"]["record"]["source_excerpt"] == "")

    def test_denial_is_one_actionable_command(self):
        self.prompt("anything at all here")
        reason = self.call()["hookSpecificOutput"]["permissionDecisionReason"]
        pid = self.proposal_of({"hookSpecificOutput": {"permissionDecisionReason": reason}})
        self.assertIn(f"`opencode-delegate route record --proposal {pid} --skill-revision {REVISION} --assignment SLUG "
                      "--work-kind KIND --scope 'SCOPE'`", reason)
        self.assertNotIn("<", reason.split("`")[1])  # nothing a shell would read as a redirect or pipe
        self.assertNotIn("|", reason.split("`")[1])
        # explicit policy: the unauthorized and authorized routes differ, and both are shown
        self.assertIn("if nobody asked for delegation, that routes implementation -> you, locally, "
                      "research -> you, locally, review -> OpenCode researcher", reason)
        self.assertIn("implementation -> OpenCode worker, research -> OpenCode researcher, review -> OpenCode researcher", reason)
        self.assertIn("--native-reason needs-host-tools", reason)
        self.assertIn("Never review your own work", reason)
        self.assertLess(len(reason), 1600)
        self.set_policy("auto")
        reason = self.call()["hookSpecificOutput"]["permissionDecisionReason"]
        self.assertIn("Under policy auto that routes implementation -> OpenCode worker", reason)

    def test_the_preview_is_what_record_returns(self):
        self.set_policy("auto")
        self.prompt("review the parser diff please")
        pid = self.proposal_of(self.call())
        result = routing.record_decision(record_args(proposal=pid, work_kind="review", authorization=None,
                                                     source_excerpt=None, requested_provider=None,
                                                     scope_status=None), self.store)
        self.assertEqual((result["route"], result["role"]), ("opencode", "researcher"))
        self.assertIn("opencode-delegate start --role researcher --cwd", result["next"])
        self.assertIn(shlex_like(self.worktree), result["next"])

    def test_every_denial_without_a_work_kind_forbids_self_review(self):
        self.prompt("anything at all here")
        outs = [self.call()]
        self.set_policy("off")
        outs.append(self.call())
        outs.append(self.call(session="never-prompted"))
        outs.append(routing.failure_output({"hook_event_name": "PreToolUse", "tool_name": "Agent"}, "boom"))
        for out in outs:
            self.assertIn("review your own work", out["hookSpecificOutput"]["permissionDecisionReason"])

    def test_continuation_binds_to_its_target(self):
        self.prompt("use a native agent for the research follow-up")
        pid_a = self.proposal_of(self.call(tool="SendMessage", tool_input={"to": "agent-a", "message": "more"}))
        self.record(pid_a, requested_provider="native", work_kind="research", source_excerpt="use a native agent for the research")
        self.assertEqual(self.decision(self.call(tool="SendMessage", tool_input={"to": "agent-b", "message": "more"})), "deny")
        self.assertEqual(self.decision(self.call(tool="SendMessage", tool_input={"to": "agent-a", "message": "x"})), "allow")

    def test_continuation_without_target_is_denied(self):
        self.prompt("use a native agent for the research follow-up")
        out = self.call(tool="collaborationfollowup_task", tool_input={"message": "gAAAA"})
        self.assertEqual(self.decision(out), "deny")
        self.assertIn("names no target", out["hookSpecificOutput"]["permissionDecisionReason"])

    def test_codex_opaque_message_retry_still_consumes(self):
        codex = {"turn_id": "t1"}
        self.prompt("use a native agent for the research on hooks", host_extra=codex)
        first = {"task_name": "probe", "fork_turns": "none", "agent_type": "default", "message": "gAAAAfirst"}
        out = self.call(tool="collaborationspawn_agent", tool_input=first, extra=codex)
        pid = self.proposal_of(out)
        self.assertTrue(pid.startswith("codex-"))
        self.record(pid, requested_provider="native", work_kind="research", source_excerpt="use a native agent for the research")
        out = self.call(tool="collaborationspawn_agent", tool_input=dict(first, message="gAAAAsecond"), extra=codex)
        self.assertEqual(self.decision(out), "allow")
        self.assertEqual(out["hookSpecificOutput"]["updatedInput"]["message"], "gAAAAfirst")
        self.assertFalse(routing.show(pid, self.store)["decision"] is None)

    def test_wrong_worktree_tool_or_session_gets_no_grant(self):
        self.prompt("use a native agent for the research please")
        self.grant_native()
        other = os.path.join(self.tmp, "other")
        os.makedirs(other)
        self.assertEqual(self.decision(self.call(cwd=other)), "deny")
        self.assertEqual(self.decision(self.call(tool="Task")), "deny")
        self.prompt("use a native agent for the research please", session="s2")
        self.assertEqual(self.decision(self.call(session="s2")), "deny")
        # the original grant is still there for the right call
        self.assertEqual(self.decision(self.call()), "allow")

    def test_symlinked_worktree_is_the_same_worktree(self):
        link = os.path.join(self.tmp, "link")
        os.symlink(self.worktree, link)
        self.prompt("use a native agent for the research please")
        self.grant_native()
        self.assertEqual(self.decision(self.call(cwd=link)), "allow")

    def test_new_user_input_retires_grants_and_pending_proposals(self):
        self.prompt("use a native agent for the research please")
        pid = self.grant_native()
        self.prompt("actually, never mind that")
        self.assertEqual(routing.show(pid, self.store)["retired_reason"], "new user input")
        self.assertEqual(self.decision(self.call()), "deny")
        pending = self.proposal_of(self.call())
        self.prompt("one more message from the user")
        with self.assertRaisesRegex(routing.RoutingError, "predates the latest user message"):
            self.record(pending, requested_provider="native", work_kind="research",
                        source_excerpt="use a native agent for the research")

    def test_session_restore_retires_grants(self):
        self.prompt("use a native agent for the research please")
        pid = self.grant_native()
        self.hook({"hook_event_name": "SessionStart", "session_id": "s1", "source": "compact"})
        self.assertEqual(routing.show(pid, self.store)["status"], "retired")
        self.assertEqual(self.decision(self.call()), "deny")

    def test_session_startup_keeps_grants(self):
        self.prompt("use a native agent for the research please")
        pid = self.grant_native()
        self.hook({"hook_event_name": "SessionStart", "session_id": "s1", "source": "startup"})
        self.assertEqual(routing.show(pid, self.store)["status"], "granted")

    def test_policy_change_retires_grant(self):
        self.set_policy("explicit")
        self.prompt("use a native agent for the research please")
        pid = self.grant_native()
        self.set_policy("auto")
        self.assertEqual(self.decision(self.call()), "deny")
        self.assertEqual(routing.show(pid, self.store)["retired_reason"], "policy changed")

    def test_policy_off_denies_without_proposal(self):
        self.set_policy("off")
        self.prompt("use a native agent for the research please")
        out = self.call()
        self.assertEqual(self.decision(out), "deny")
        self.assertIn("policy is off", out["hookSpecificOutput"]["permissionDecisionReason"])
        self.assertEqual(routing.show(None, self.store)["open_proposals"], [])

    def test_invalid_policy_denies(self):
        self.set_policy("sometimes")
        self.prompt("use a native agent for the research please")
        out = self.call()
        self.assertEqual(self.decision(out), "deny")
        self.assertIn("invalid OPENCODE_SUBAGENT_DELEGATION_POLICY", out["hookSpecificOutput"]["permissionDecisionReason"])

    def test_expired_grant(self):
        self.prompt("use a native agent for the research please")
        pid = self.grant_native()
        with self.store:
            session, p = routing.find_proposal(self.store, pid)
            p["grant"]["expires"] = time.time() - 1
            self.store.save_session(session)
        self.assertEqual(self.decision(self.call()), "deny")
        self.assertEqual(routing.show(pid, self.store)["retired_reason"], "grant expired")

    def test_runtime_change_retires_grant_and_refuses_record(self):
        self.prompt("use a native agent for the research please")
        pid = self.grant_native()
        pending = self.proposal_of(self.call(tool="Task"))
        with self.store:
            session, p = routing.find_proposal(self.store, pid)
            p["grant"]["runtime"] = "s1-0000000000000000"
            session["proposals"][pending]["runtime"] = "s1-0000000000000000"
            self.store.save_session(session)
        self.assertEqual(self.decision(self.call()), "deny")
        self.assertEqual(routing.show(pid, self.store)["retired_reason"], "routing runtime changed")
        with self.assertRaisesRegex(routing.RoutingError, "routing runtime mismatch"):
            self.record(pending, requested_provider="native", work_kind="research", source_excerpt="use a native agent for the research")

    def test_no_captured_input_denies(self):
        out = self.call()
        self.assertEqual(self.decision(out), "deny")
        self.assertIn("no captured user input", out["hookSpecificOutput"]["permissionDecisionReason"])

    def test_duplicate_delivery_same_answer(self):
        self.prompt("use a native agent for the research please")
        a = self.call(tool_use_id="call-1")
        b = self.call(tool_use_id="call-1")
        self.assertEqual(a, b)
        self.assertEqual(len(routing.show(None, self.store)["open_proposals"]), 1)
        pid = self.proposal_of(a)
        self.record(pid, requested_provider="native", work_kind="research", source_excerpt="use a native agent for the research")
        allow_1 = self.call(tool_use_id="call-2")
        allow_2 = self.call(tool_use_id="call-2")
        self.assertEqual(self.decision(allow_1), "allow")
        self.assertEqual(allow_1, allow_2)
        self.assertEqual(self.decision(self.call(tool_use_id="call-3")), "deny")

    def test_parallel_identical_calls_spend_a_grant_once(self):
        self.prompt("use a native agent for the research please")
        self.grant_native()
        payload = json.dumps({"hook_event_name": "PreToolUse", "session_id": "s1", "cwd": self.worktree,
                              "tool_name": "Agent", "tool_input": {"prompt": "p"}})
        env = dict(os.environ)
        def run(i):
            p = json.loads(payload)
            p["tool_use_id"] = f"parallel-{i}"
            out = subprocess.run([BASH, DELEGATE, "route", "hook"], input=json.dumps(p), capture_output=True, text=True, env=env)
            return json.loads(out.stdout)["hookSpecificOutput"]["permissionDecision"]
        with concurrent.futures.ThreadPoolExecutor(8) as pool:
            results = list(pool.map(run, range(8)))
        self.assertEqual(results.count("allow"), 1, results)
        self.assertEqual(results.count("deny"), 7, results)

    def test_parallel_grants_each_run_their_own_proposal(self):
        self.prompt("use a native agent for the research please")
        a, b = {"prompt": "survey A"}, {"prompt": "survey B"}
        first = self.proposal_of(self.call(tool_input=a, tool_use_id="a"))
        second = self.proposal_of(self.call(tool_input=b, tool_use_id="b"))
        for pid in (first, second):
            self.record(pid, requested_provider="native", work_kind="research", source_excerpt="use a native agent for the research")
        # identical input picks its own grant even though it is the newer one
        out = self.call(tool_input=b)
        self.assertEqual(out["hookSpecificOutput"]["updatedInput"], b)
        # anything else takes the oldest remaining grant; nothing deadlocks
        out = self.call(tool_input={"prompt": "reworded"})
        self.assertEqual(out["hookSpecificOutput"]["updatedInput"], a)
        self.assertEqual(self.decision(self.call(tool_input=a)), "deny")

    def test_child_agent_cannot_spend_the_parent_grant(self):
        self.prompt("use a native agent for the research please")
        self.grant_native()
        self.assertEqual(self.decision(self.call(extra={"agent_id": "child-1"})), "deny")
        self.assertEqual(self.decision(self.call()), "allow")

    def test_missing_cwd_denies(self):
        self.prompt("use a native agent for the research please")
        payload = {"hook_event_name": "PreToolUse", "session_id": "s1", "tool_name": "Agent", "tool_input": {"prompt": "p"}}
        out = self.hook(payload)
        self.assertEqual(self.decision(out), "deny")
        self.assertIn("no cwd", out["hookSpecificOutput"]["permissionDecisionReason"])

    def test_failed_prompt_capture_fails_closed(self):
        self.prompt("use a native agent for the research please")
        pid = self.grant_native()
        pending = self.proposal_of(self.call(tool="Task"))
        # the user's next message arrives while the state lock is held
        lock = os.open(os.path.join(self.store.root, "lock"), os.O_RDWR)
        import fcntl
        fcntl.flock(lock, fcntl.LOCK_EX)
        old_wait, routing.LOCK_WAIT_SECONDS = routing.LOCK_WAIT_SECONDS, 0.1
        try:
            self.assertIsNone(self.prompt("STOP, do not delegate anything"))
        finally:
            routing.LOCK_WAIT_SECONDS = old_wait
            fcntl.flock(lock, fcntl.LOCK_UN)
            os.close(lock)
        out = self.call()
        self.assertEqual(self.decision(out), "deny")
        self.assertIn("failed to capture", out["hookSpecificOutput"]["permissionDecisionReason"])
        self.assertEqual(routing.show(pid, self.store)["retired_reason"], "user input capture failed")
        with self.assertRaisesRegex(routing.RoutingError, "was not captured"):
            self.record(pending, requested_provider="native", work_kind="research", source_excerpt="use a native agent for the research")
        # the next captured message clears it
        self.prompt("use a native agent for the research again")
        self.assertIn("proposal", self.call()["hookSpecificOutput"]["permissionDecisionReason"])

    def test_prompt_without_text_fails_closed(self):
        self.prompt("use a native agent for the research please")
        self.grant_native()
        self.assertIsNone(self.hook({"hook_event_name": "UserPromptSubmit", "session_id": "s1", "cwd": self.worktree}))
        self.assertIn("failed to capture", self.call()["hookSpecificOutput"]["permissionDecisionReason"])

    def test_duplicate_prompt_delivery_counts_once(self):
        payload = {"hook_event_name": "UserPromptSubmit", "session_id": "s1", "cwd": self.worktree,
                   "prompt": "use a native agent for the research please", "prompt_id": "p-1"}
        self.hook(payload)
        self.grant_native()
        self.hook(payload)
        with self.store:
            self.assertEqual(self.store.load_session(routing.session_key("claude", "s1"))["epoch"], 1)

    def test_hostile_nesting_denies_instead_of_crashing(self):
        text = '{"hook_event_name": "PreToolUse", "tool_name": "Agent", "tool_input": ' + "[" * 100000 + "]" * 100000 + "}"
        self.assertEqual(self.decision(self.hook(text)), "deny")

    def test_same_turn_different_message_is_new_input(self):
        codex = {"turn_id": "T1"}
        self.prompt("use a native agent for the research please", host_extra=codex)
        pid = self.proposal_of(self.call(extra=codex))
        self.record(pid, requested_provider="native", work_kind="research", source_excerpt="use a native agent for the research")
        self.prompt("STOP, do not spawn anything", host_extra=codex)
        self.assertEqual(self.decision(self.call(extra=codex)), "deny")
        with self.store:
            self.assertEqual(self.store.load_session(routing.session_key("codex", "s1"))["epoch"], 2)

    def test_duplicate_delivery_still_retires_grants(self):
        payload = {"hook_event_name": "UserPromptSubmit", "session_id": "s1", "cwd": self.worktree,
                   "prompt": "use a native agent for the research please", "prompt_id": "p-1"}
        self.hook(payload)
        pid = self.grant_native()
        self.hook(payload)
        self.assertEqual(routing.show(pid, self.store)["status"], "retired")

    def test_shim_swallowed_prompt_failure_fails_closed(self):
        self.prompt("use a native agent for the research please")
        pid = self.grant_native()
        shim = os.path.join(SCRIPTS, "route-hook-shim.sh")
        broken = os.path.join(self.tmp, "missing", "delegate.sh")
        payload = json.dumps({"hook_event_name": "UserPromptSubmit", "session_id": "s1", "prompt": "STOP, no subagents"})
        out = subprocess.run([BASH, shim, broken, "claude"], input=payload, capture_output=True, text=True, env=dict(os.environ))
        self.assertEqual((out.returncode, out.stdout), (0, ""))
        time.sleep(0.01)
        out = self.call()
        self.assertEqual(self.decision(out), "deny")
        self.assertIn("failed to capture", out["hookSpecificOutput"]["permissionDecisionReason"])
        self.assertEqual(routing.show(pid, self.store)["retired_reason"], "user input capture failed")
        # a later captured message restores normal routing
        time.sleep(0.01)
        self.prompt("use a native agent for the research now")
        self.assertIn("proposal", self.call()["hookSpecificOutput"]["permissionDecisionReason"])

    def test_shim_denies_delegation_when_entry_is_broken(self):
        shim = os.path.join(SCRIPTS, "route-hook-shim.sh")
        payload = json.dumps({"hook_event_name": "PreToolUse", "session_id": "s1", "tool_name": "Agent", "tool_input": {}})
        out = subprocess.run([BASH, shim, "/nonexistent/delegate.sh", "claude"], input=payload, capture_output=True, text=True)
        self.assertEqual(out.returncode, 0)
        self.assertEqual(json.loads(out.stdout)["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertIn("review your own work", json.loads(out.stdout)["hookSpecificOutput"]["permissionDecisionReason"])

    def test_malformed_recognized_payloads_deny(self):
        self.prompt("use a native agent for the research please")
        for payload in (
            {"hook_event_name": "PreToolUse", "session_id": "s1", "tool_name": "Agent", "tool_input": "oops"},
            {"hook_event_name": "PreToolUse", "tool_name": "Agent", "tool_input": {}},
            '{"hook_event_name": "PreToolUse", "tool_name": "Agent", "tool_input": {',
        ):
            with self.subTest(payload=payload):
                out = self.hook(payload)
                self.assertEqual(self.decision(out), "deny")

    def test_corrupt_or_unknown_state_denies(self):
        self.prompt("use a native agent for the research please")
        path = self.store.session_path(routing.session_key("claude", "s1"))
        with open(path, "w") as f:
            f.write("{broken")
        out = self.call()
        self.assertEqual(self.decision(out), "deny")
        self.assertIn("unreadable routing state", out["hookSpecificOutput"]["permissionDecisionReason"])
        with open(path, "w") as f:
            json.dump({"schema": 99}, f)
        out = self.call()
        self.assertIn("unsupported routing state schema", out["hookSpecificOutput"]["permissionDecisionReason"])

    def test_unwritable_state_denies(self):
        if os.geteuid() == 0:
            self.skipTest("root ignores permissions")
        self.prompt("use a native agent for the research please")
        os.chmod(os.path.join(self.store.root, "sessions"), 0o500)
        try:
            self.assertEqual(self.decision(self.call()), "deny")
        finally:
            os.chmod(os.path.join(self.store.root, "sessions"), 0o700)

    def test_state_is_user_only(self):
        self.prompt("secret-ish user text for the research")
        self.assertEqual(os.stat(self.store.root).st_mode & 0o777, 0o700)
        for name in os.listdir(os.path.join(self.store.root, "sessions")):
            self.assertEqual(os.stat(os.path.join(self.store.root, "sessions", name)).st_mode & 0o777, 0o600)
        with open(os.path.join(self.store.root, "audit.jsonl")) as f:
            self.assertNotIn("secret-ish", f.read())

    def test_bounded_retention(self):
        for i in range(routing.MAX_PROMPTS + 5):
            self.prompt(f"message number {i}")
        for i in range(routing.MAX_PROPOSALS + 5):
            self.call(tool_use_id=f"c{i}")
        with self.store:
            session = self.store.load_session(routing.session_key("claude", "s1"))
        self.assertEqual(len(session["prompts"]), routing.MAX_PROMPTS)
        self.assertLessEqual(len(session["proposals"]), routing.MAX_PROPOSALS)


class Recording(Env):
    def setUp(self):
        super().setUp()
        self.prompt("please delegate the parser work to whoever fits")
        self.pid = self.proposal_of(self.call())

    def test_explicit_policy_generic_request_routes_implementation_to_opencode(self):
        result = self.record(self.pid)
        self.assertEqual(result["route"], "opencode")
        self.assertIn("opencode-delegate start", result["next"])
        self.assertEqual(self.decision(self.call()), "deny")

    def test_supervisor_cannot_self_authorize_under_explicit(self):
        result = self.record(self.pid, authorization="none", source_excerpt="", work_kind="research",
                             native_reason="needs-host-tools")
        self.assertEqual(result["route"], "local")

    def test_unauthorized_review_still_gets_a_reviewer(self):
        result = self.record(self.pid, authorization="none", source_excerpt="", work_kind="review")
        self.assertEqual((result["route"], result["role"]), ("opencode", "researcher"))
        self.assertIn("never the author", result["reason"])

    def test_forged_user_excerpt_rejected(self):
        with self.assertRaisesRegex(routing.RoutingError, "does not appear in any captured user message"):
            self.record(self.pid, requested_provider="native", source_excerpt="use a native agent for everything")

    def test_excerpt_whitespace_normalized(self):
        result = self.record(self.pid, source_excerpt="please   delegate\nthe parser work")
        self.assertEqual(result["route"], "opencode")

    def test_later_excerpt_cannot_be_quoted_from_the_future(self):
        self.prompt("use a native agent for the research now")
        # pid was captured at epoch 1; the new prompt makes it stale anyway
        with self.assertRaises(routing.RoutingError):
            self.record(self.pid, requested_provider="native", source_excerpt="use a native agent for the research now")

    def test_skill_revision_must_match(self):
        with self.assertRaisesRegex(routing.RoutingError, "not the current opencode-subagent skill revision"):
            self.record(self.pid, skill_revision="000000000000")

    def test_invalid_route_keeps_proposal_pending(self):
        with self.assertRaisesRegex(routing.RoutingError, "routed to OpenCode first"):
            self.record(self.pid, work_kind="research", native_reason="opencode-failed",
                        opencode_task="task_20261010-120000-1")
        self.assertEqual(routing.show(self.pid, self.store)["status"], "pending")
        self.assertEqual(self.record(self.pid, work_kind="research", native_reason="needs-host-tools")["route"], "native")

    def test_decided_proposal_cannot_be_rerecorded(self):
        self.record(self.pid)
        with self.assertRaisesRegex(routing.RoutingError, "already routed"):
            self.record(self.pid, work_kind="research", native_reason="needs-host-tools")

    def test_unknown_proposal(self):
        for bad in ("nope", "claude-000000000000-9", "../../etc-1"):
            with self.assertRaisesRegex(routing.RoutingError, "unknown proposal"):
                self.record(bad)

    def git_workflow(self, text):
        wf = os.path.join(self.worktree, "AGENTS.md")
        with open(wf, "w") as f:
            f.write(text)
        with open(os.path.join(self.worktree, "LICENSE"), "w") as f:
            f.write("Permission is hereby granted, free of charge\n")
        for argv in (["init", "-q"], ["add", "AGENTS.md", "LICENSE"],
                     ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "wf"]):
            subprocess.run(["git", "-C", self.worktree] + argv, check=True, capture_output=True)
        return wf

    def test_workflow_authorization(self):
        wf = self.git_workflow("Reviews: always get an independent native review of the diff before merging.\n")
        result = self.record(self.pid, authorization="workflow", workflow_file=wf, work_kind="review",
                             source_excerpt="always get an independent native review", requested_provider="native")
        self.assertEqual(result["route"], "native")
        shown = routing.show(self.pid, self.store)
        self.assertEqual(len(shown["decision"]["source"]["sha256"]), 64)

    def test_workflow_excerpt_must_be_in_file(self):
        wf = self.git_workflow("Nothing about delegation here.\n")
        with self.assertRaisesRegex(routing.RoutingError, "does not appear in"):
            self.record(self.pid, authorization="workflow", workflow_file=wf, source_excerpt="always delegate everything")

    def test_workflow_file_must_be_committed_in_the_worktree_repo(self):
        excerpt = dict(authorization="workflow", source_excerpt="root:x:0:0:root", work_kind="research",
                       requested_provider="native")
        with self.assertRaisesRegex(routing.RoutingError, "agent instruction file"):
            self.record(self.pid, workflow_file="/etc/passwd", **excerpt)
        with self.assertRaisesRegex(routing.RoutingError, "git repository"):
            self.record(self.pid, workflow_file="AGENTS.md", **excerpt)
        wf = self.git_workflow("Always delegate research natively.\n")
        os.makedirs(os.path.join(self.tmp, "elsewhere"))
        outside = os.path.join(self.tmp, "elsewhere", "AGENTS.md")
        with open(outside, "w") as f:
            f.write("root:x:0:0:root\n")
        with self.assertRaisesRegex(routing.RoutingError, "inside the repository"):
            self.record(self.pid, workflow_file=outside, **excerpt)
        os.makedirs(os.path.join(self.worktree, "sub"))
        untracked = os.path.join(self.worktree, "sub", "CLAUDE.md")
        with open(untracked, "w") as f:
            f.write("root:x:0:0:root\n")
        with self.assertRaisesRegex(routing.RoutingError, "not tracked"):
            self.record(self.pid, workflow_file=untracked, **excerpt)
        with open(wf, "a") as f:
            f.write("root:x:0:0:root\n")
        with self.assertRaisesRegex(routing.RoutingError, "uncommitted changes"):
            self.record(self.pid, workflow_file="AGENTS.md", **excerpt)
        with self.assertRaisesRegex(routing.RoutingError, "agent instruction file"):
            self.record(self.pid, workflow_file="LICENSE", **dict(excerpt, source_excerpt="Permission is hereby granted"))

    def test_opencode_assignment_blocks_native_substitute_until_later_override(self):
        self.prompt("have opencode implement the parser change")
        pid = self.proposal_of(self.call())
        self.assertEqual(self.record(pid, assignment="parser", requested_provider="opencode",
                                     source_excerpt="have opencode implement the parser")["route"], "opencode")
        # same epoch: a native request for the same assignment is not an override
        pid = self.proposal_of(self.call())
        result = self.record(pid, assignment="parser", work_kind="research", native_reason="needs-host-tools")
        self.assertEqual(result["route"], "opencode")
        # OpenCode failed; a later explicit user message overrides it
        self.prompt("opencode is down, use a native agent for the parser")
        pid = self.proposal_of(self.call())
        stale = self.record(pid, assignment="parser", requested_provider="native",
                            source_excerpt="have opencode implement the parser change")
        self.assertEqual(stale["route"], "opencode")
        pid = self.proposal_of(self.call())
        result = self.record(pid, assignment="parser", requested_provider="native",
                             source_excerpt="use a native agent for the parser")
        self.assertEqual(result["route"], "native")
        self.assertEqual(self.decision(self.call()), "allow")

    # -- research/review that failed on OpenCode

    def opencode_task(self, task_id, cwd=None, state="rejected", worker="done", failure=None, created=None,
                      agent="workflow-researcher", transport="finished"):
        d = os.path.join(os.environ["XDG_STATE_HOME"], "workflow-skills", "subagents", task_id)
        os.makedirs(d)
        with open(os.path.join(d, "task.json"), "w") as f:
            json.dump({"task_id": task_id, "cwd": self.worktree if cwd is None else cwd, "state": state, "failure_class": failure,
                       "agent": agent, "outcome": {"worker": worker, "transport": transport},
                       "created_at": created or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 5))}, f)

    def route_review_to_opencode(self):
        self.record(self.pid, assignment="parser-review", work_kind="review")
        return self.proposal_of(self.call())

    def test_opencode_failed_needs_a_failed_task_from_after_the_routing(self):
        pid = self.route_review_to_opencode()
        failed = dict(assignment="parser-review", work_kind="review", native_reason="opencode-failed")
        with self.assertRaisesRegex(routing.RoutingError, "is not an OpenCode Task"):
            self.record(pid, opencode_task="task_20261010-120000-1", **failed)
        self.opencode_task("task_20261010-120000-2", state="accepted")
        with self.assertRaisesRegex(routing.RoutingError, "did not fail"):
            self.record(pid, opencode_task="task_20261010-120000-2", **failed)
        self.opencode_task("task_20261010-120000-3", cwd=self.tmp)
        with self.assertRaisesRegex(routing.RoutingError, "not in this worktree"):
            self.record(pid, opencode_task="task_20261010-120000-3", **failed)
        self.opencode_task("task_20261010-120000-4", created="2020-01-01T00:00:00Z")
        with self.assertRaisesRegex(routing.RoutingError, "predates"):
            self.record(pid, opencode_task="task_20261010-120000-4", **failed)
        self.assertEqual(routing.show(pid, self.store)["status"], "pending")
        self.opencode_task("task_20261010-120000-9", cwd="", worker="blocked")
        with self.assertRaisesRegex(routing.RoutingError, "not in this worktree"):
            self.record(pid, opencode_task="task_20261010-120000-9", **failed)
        self.opencode_task("task_20261010-120000-6", agent="workflow-worker", worker="blocked")
        with self.assertRaisesRegex(routing.RoutingError, "not a researcher Task"):
            self.record(pid, opencode_task="task_20261010-120000-6", **failed)
        self.opencode_task("task_20261010-120000-7", transport="not_started")
        with self.assertRaisesRegex(routing.RoutingError, "never ran"):
            self.record(pid, opencode_task="task_20261010-120000-7", **failed)
        # cancelling is the supervisor's own act: it proves nothing without a failure class
        self.opencode_task("task_20261010-120000-8", state="cancelled", transport="cancelled")
        with self.assertRaisesRegex(routing.RoutingError, "did not fail"):
            self.record(pid, opencode_task="task_20261010-120000-8", **failed)
        self.assertEqual(routing.show(pid, self.store)["status"], "pending")
        self.opencode_task("task_20261010-120000-5", state="running", worker="blocked")
        result = self.record(pid, opencode_task="task_20261010-120000-5", **failed)
        self.assertEqual(result["route"], "native", result)
        self.assertEqual(self.decision(self.call()), "allow")
        # one failed Task unlocks one assignment once
        pid = self.proposal_of(self.call())
        self.record(pid, assignment="lexer-review", work_kind="review")
        pid = self.proposal_of(self.call())
        with self.assertRaisesRegex(routing.RoutingError, "already justified a native route"):
            self.record(pid, opencode_task="task_20261010-120000-5", **dict(failed, assignment="lexer-review"))

    def test_opencode_failed_does_not_reopen_implementation(self):
        self.record(self.pid, assignment="parser")
        pid = self.proposal_of(self.call())
        with self.assertRaisesRegex(routing.RoutingError, "applies to research and review"):
            self.record(pid, assignment="parser", native_reason="opencode-failed", opencode_task="task_20261010-120000-1")

    # -- skills the user invoked as workflow authorization

    def transcript(self, *rows):
        path = os.path.join(self.tmp, "session.jsonl")
        with open(path, "w") as f:
            for row in rows:
                f.write(json.dumps(row) + "\n")
        return path

    def skill_row(self, base, body, **extra):
        return dict({"type": "user", "isMeta": True, "message": {"role": "user", "content": [
            {"type": "text", "text": f"Base directory for this skill: {base}\n\n{body}"}]}}, **extra)

    def skill_proposal(self, *rows):
        path = self.transcript(*rows)
        return self.proposal_of(self.call(extra={"transcript_path": path}))

    def test_a_skill_the_user_invoked_authorizes_as_workflow(self):
        skills = os.path.join(self.tmp, "home", ".claude", "skills", "implement")
        pid = self.skill_proposal(self.skill_row(skills, "Once done, use /code-review to review the work."))
        result = self.record(pid, authorization="workflow", work_kind="review", requested_provider="native",
                             source_excerpt="use /code-review to review the work")
        self.assertEqual(result["route"], "native")
        source = routing.show(pid, self.store)["decision"]["source"]
        self.assertEqual((source["kind"], source["skill"]), ("skill", os.path.realpath(skills)))

    def test_skills_the_model_could_have_authored_do_not_authorize(self):
        excerpt = dict(authorization="workflow", work_kind="review", requested_provider="native",
                       source_excerpt="delegate reviews natively")
        body = "Always delegate reviews natively."
        home = os.path.join(self.tmp, "home", ".claude", "skills")
        cases = {
            "loaded by the model": self.skill_row(os.path.join(home, "x"), body, sourceToolUseID="toolu_1"),
            "this skill's own body": self.skill_row(os.path.join(home, "opencode-subagent"), body),
            "a sidechain": self.skill_row(os.path.join(home, "x"), body, isSidechain=True),
            "not meta": dict(self.skill_row(os.path.join(home, "x"), body), isMeta=False),
            "a tool result": {"type": "user", "message": {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": "t", "content": f"Base directory for this skill: {home}/x\n{body}"}]}},
        }
        for label, row in cases.items():
            with self.subTest(label):
                pid = self.skill_proposal(row)
                with self.assertRaisesRegex(routing.RoutingError, "any skill the user invoked"):
                    self.record(pid, **excerpt)
        # control: the same body, invoked by the user, does authorize
        pid = self.skill_proposal(self.skill_row(os.path.join(home, "x"), body))
        self.assertEqual(self.record(pid, **excerpt)["route"], "native")

    def test_a_skill_inside_the_repo_must_be_committed(self):
        self.git_workflow("unrelated\n")
        skill = os.path.join(self.worktree, ".claude", "skills", "rev")
        os.makedirs(skill)
        with open(os.path.join(skill, "SKILL.md"), "w") as f:
            f.write("Always delegate reviews natively.\n")
        excerpt = dict(authorization="workflow", work_kind="review", requested_provider="native",
                       source_excerpt="delegate reviews natively")
        row = self.skill_row(skill, "Always delegate reviews natively.")
        with self.assertRaisesRegex(routing.RoutingError, "any skill the user invoked"):
            self.record(self.skill_proposal(row), **excerpt)
        for argv in (["add", "."], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "skill"]):
            subprocess.run(["git", "-C", self.worktree] + argv, check=True, capture_output=True)
        self.assertEqual(self.record(self.skill_proposal(row), **excerpt)["route"], "native")

    def test_an_oversized_transcript_says_so(self):
        pid = self.skill_proposal(self.skill_row(os.path.join(self.tmp, "s"), "Always delegate reviews natively."))
        old, routing.TRANSCRIPT_SCAN_CAP = routing.TRANSCRIPT_SCAN_CAP, 10
        try:
            with self.assertRaisesRegex(routing.RoutingError, "larger than"):
                self.record(pid, authorization="workflow", work_kind="review", requested_provider="native",
                            source_excerpt="delegate reviews natively")
        finally:
            routing.TRANSCRIPT_SCAN_CAP = old

    def test_codex_proposals_never_use_transcripts(self):
        path = self.transcript(self.skill_row(os.path.join(self.tmp, "s"), "Always delegate reviews natively."))
        self.prompt("codex session prompt here", session="cx", host_extra={"turn_id": "t1"})
        pid = self.proposal_of(self.call(session="cx", extra={"turn_id": "t2", "transcript_path": path}))
        with self.assertRaisesRegex(routing.RoutingError, "any skill the user invoked"):
            self.record(pid, authorization="workflow", work_kind="review", requested_provider="native",
                        source_excerpt="delegate reviews natively")


class ReadOnlyAgents(Env):
    def setUp(self):
        super().setUp()
        self.set_policy("explicit")
        self.prompt("explore the parser module, use a native agent for the research")

    def test_default_readonly_types_run_without_a_decision(self):
        for kind in ("Explore", "Plan", "claude-code-guide", "adversarial-reviewer", "mini-explorer"):
            with self.subTest(kind):
                self.assertIsNone(self.call(tool_input={"prompt": "look", "subagent_type": kind}))
        for kind in ("general-purpose", "explore", "mini-implementer", "reviewer-writer"):
            with self.subTest(kind):
                self.assertEqual(self.decision(self.call(tool_input={"prompt": "x", "subagent_type": kind})), "deny")
        self.assertEqual(self.decision(self.call(tool_input={"prompt": "no type"})), "deny")
        events = [json.loads(l) for l in open(os.path.join(self.store.root, "audit.jsonl"))]
        self.assertEqual(sum(1 for e in events if e["event"] == "allow_readonly"), 5)

    def test_a_readonly_call_never_spends_an_open_grant(self):
        pid = self.grant_native(tool_input={"prompt": "implement it", "subagent_type": "general-purpose"})
        self.assertIsNone(self.call(tool_input={"prompt": "look", "subagent_type": "Explore"}))
        self.assertEqual(routing.show(pid, self.store)["status"], "granted")

    def test_follow_ups_by_name_are_gated(self):
        # The host allocates and reassigns names (an unnamed agent is registered
        # under its type), so a name is never proof of a read-only target.
        explore = {"prompt": "look", "subagent_type": "Explore", "name": "scout"}
        self.assertIsNone(self.call(tool_input=explore, tool_use_id="tu-scout"))
        self.assertIsNone(self.post("tu-scout", explore, AGENT_ID))
        for tool_input in ({"to": "scout", "message": "x"},
                           {"to": "scout", "recipient": "scout", "recipient_kind": "name", "message": "x"}):
            with self.subTest(tool_input=tool_input):
                self.assertEqual(self.decision(self.call(tool="SendMessage", tool_input=tool_input)), "deny")
    def test_the_key_adds_to_the_builtins(self):
        path = routing.conf_file()
        with open(path, "a") as f:
            f.write("OPENCODE_SUBAGENT_READONLY_AGENTS=x-*\nOPENCODE_SUBAGENT_READONLY_AGENTS=scout-*, my-agent\n")
        for kind in ("scout-1", "my-agent", "Explore", "Plan", "claude-code-guide"):
            with self.subTest(kind):
                self.assertIsNone(self.call(tool_input={"prompt": "x", "subagent_type": kind}))
        for kind in ("x-1", "mini-explorer", "adversarial-reviewer"):  # last line wins; default replaced
            with self.subTest(kind):
                self.assertEqual(self.decision(self.call(tool_input={"prompt": "x", "subagent_type": kind})), "deny")

    def test_an_empty_key_leaves_only_the_builtins(self):
        with open(routing.conf_file(), "a") as f:
            f.write("OPENCODE_SUBAGENT_READONLY_AGENTS=\n")
        for kind in routing.BUILTIN_READONLY_AGENTS:
            with self.subTest(kind):
                self.assertIsNone(self.call(tool_input={"prompt": "x", "subagent_type": kind}))
        for kind in ("adversarial-reviewer", "mini-explorer", "general-purpose"):
            with self.subTest(kind):
                self.assertEqual(self.decision(self.call(tool_input={"prompt": "x", "subagent_type": kind})), "deny")

    def test_not_under_policy_off_and_not_for_codex(self):
        self.set_policy("off")
        self.assertEqual(self.decision(self.call(tool_input={"prompt": "x", "subagent_type": "Explore"})), "deny")
        self.set_policy("auto")
        self.prompt("codex prompt goes here", session="cx", host_extra={"turn_id": "t1"})
        for tool in ("Agent", "spawn_agent"):  # Agent: only the host check stops it
            out = self.call(tool=tool, session="cx", tool_input={"message": "x", "subagent_type": "Explore"},
                            extra={"turn_id": "t2"})
            self.assertEqual(self.decision(out), "deny", tool)


class ReadOnlyFollowUps(Env):
    """Follow-ups to an exempt agent, addressed by the host-assigned id that the
    PostToolUse of the call the hook itself exempted reports."""

    EXPLORE = {"description": "scan", "prompt": "look", "subagent_type": "Explore", "run_in_background": True}

    def setUp(self):
        super().setUp()
        self.set_policy("explicit")
        self.prompt("explore the parser module, use a native agent for the research")

    def by_id(self, agent_id, **extra):
        tool_input = {"to": agent_id, "recipient": agent_id, "recipient_kind": "agent", "message": "and the lexer?"}
        tool_input.update(extra)
        return self.call(tool="SendMessage", tool_input=tool_input)

    def launch(self, tool_use_id="tu-1", tool_input=None, agent_id=AGENT_ID, background=True):
        tool_input = tool_input or self.EXPLORE
        self.assertIsNone(self.call(tool_input=tool_input, tool_use_id=tool_use_id))
        response = ({"isAsync": True, "status": "async_launched", "agentId": agent_id, "description": "scan",
                     "prompt": "look", "canContinueAgent": True} if background else None)
        self.assertIsNone(self.post(tool_use_id, tool_input, agent_id, response=response))

    def audit_events(self, kind):
        path = os.path.join(self.store.root, "audit.jsonl")
        if not os.path.exists(path):
            return []
        with open(path) as f:
            return [e for e in map(json.loads, f) if e["event"] == kind]

    def test_a_follow_up_by_id_passes_after_a_background_launch(self):
        self.assertEqual(self.decision(self.by_id(AGENT_ID)), "deny")  # unknown before PostToolUse
        self.launch()
        self.assertIsNone(self.by_id(AGENT_ID))
        self.assertEqual(self.decision(self.by_id(OTHER_ID)), "deny")
        self.assertEqual([e["agent"] for e in self.audit_events("readonly_registered")], [AGENT_ID])

    def test_a_follow_up_by_id_passes_after_a_foreground_run(self):
        self.launch(background=False)
        self.assertIsNone(self.by_id(AGENT_ID))

    def test_a_writing_agent_never_registers(self):
        writer = {"prompt": "implement it", "subagent_type": "general-purpose", "run_in_background": True}
        self.grant_native(tool_input=writer)
        self.assertEqual(self.decision(self.call(tool_input=writer, tool_use_id="tu-w")), "allow")
        self.assertIsNone(self.post("tu-w", writer, AGENT_ID))
        self.assertEqual(self.decision(self.by_id(AGENT_ID)), "deny")

    def test_only_a_call_the_hook_exempted_registers(self):
        # A PostToolUse with no exempt PreToolUse behind it: unknown id, wrong
        # session, codex, a missing or non-string agentId, a non-dict response.
        self.assertIsNone(self.post("tu-never-seen", self.EXPLORE, AGENT_ID))
        self.assertIsNone(self.call(tool_input=self.EXPLORE, tool_use_id="tu-1"))
        self.assertIsNone(self.post("tu-1", self.EXPLORE, AGENT_ID, session="other"))
        self.assertIsNone(self.post("tu-1", self.EXPLORE, AGENT_ID, extra={"turn_id": "t"}))
        for response in ({"status": "completed"}, {"agentId": 7}, {"agentId": ""}, "text", None):
            with self.subTest(response=response):
                self.assertIsNone(self.post("tu-1", self.EXPLORE, response=response if response is not None else []))
        self.assertEqual(self.decision(self.by_id(AGENT_ID)), "deny")

    def test_post_rechecks_the_type_it_ran(self):
        # Another hook may rewrite the input after this one exempted it.
        self.assertIsNone(self.call(tool_input=self.EXPLORE, tool_use_id="tu-1"))
        rewritten = dict(self.EXPLORE, subagent_type="general-purpose")
        self.assertIsNone(self.post("tu-1", rewritten, AGENT_ID))
        self.assertEqual(self.decision(self.by_id(AGENT_ID)), "deny")
        self.assertIsNone(self.call(tool_input=self.EXPLORE, tool_use_id="tu-2"))
        response = {"status": "completed", "agentId": AGENT_ID, "agentType": "general-purpose"}
        self.assertIsNone(self.post("tu-2", self.EXPLORE, response=response))
        self.assertEqual(self.decision(self.by_id(AGENT_ID)), "deny")

    def test_names_and_ids_do_not_cross(self):
        # A read-only agent named like a writer's id must not open that id.
        self.launch(tool_input=dict(self.EXPLORE, name=OTHER_ID), agent_id=AGENT_ID)
        self.assertEqual(self.decision(self.by_id(OTHER_ID)), "deny")
        self.assertEqual(self.decision(self.call(tool="SendMessage", tool_input={"to": OTHER_ID, "message": "x"})), "deny")
        # ...and an id is not a name.
        self.assertEqual(self.decision(self.call(tool="SendMessage", tool_input={
            "to": AGENT_ID, "recipient": AGENT_ID, "recipient_kind": "name", "message": "x"})), "deny")
        self.assertIsNone(self.by_id(AGENT_ID))

    def test_a_writer_named_like_a_readonly_id_closes_it(self):
        # If the host ever resolved that id string to the writer's name, the
        # follow-up would reach a writer; so the id stops being exempt.
        self.launch()
        writer = {"prompt": "implement it", "subagent_type": "general-purpose", "name": AGENT_ID}
        self.grant_native(tool_input=writer)
        self.assertEqual(self.decision(self.call(tool_input=writer)), "allow")
        self.assertEqual(self.decision(self.by_id(AGENT_ID)), "deny")

    def test_only_a_plain_message_by_id_passes(self):
        self.launch()
        self.assertIsNone(self.by_id(AGENT_ID, type="message"))
        for extra in ({"type": "broadcast"}, {"recipient_kind": None}, {"recipient_kind": "name"}):
            with self.subTest(extra=extra):
                self.assertEqual(self.decision(self.by_id(AGENT_ID, **extra)), "deny")

    def test_disagreeing_target_fields_are_not_exempt(self):
        self.launch()
        self.assertEqual(self.decision(self.by_id(AGENT_ID, recipient=OTHER_ID)), "deny")
        self.assertEqual(self.decision(self.by_id(AGENT_ID, recipient_kind="team")), "deny")

    def test_a_non_string_target_gets_a_proposal_not_a_crash(self):
        self.launch()
        for value in ({"kind": "name", "value": "bob"}, ["bob"], 7, None):
            with self.subTest(value=value):
                out = self.call(tool="SendMessage", tool_input={"to": AGENT_ID, "recipient": value, "message": "x"})
                self.assertEqual(self.decision(out), "deny")
                self.proposal_of(out)

    def test_policy_off_gates_follow_ups_too(self):
        self.launch()
        self.set_policy("off")
        self.assertEqual(self.decision(self.by_id(AGENT_ID)), "deny")

    def test_duplicate_post_delivery_is_harmless(self):
        self.launch()
        self.assertIsNone(self.post("tu-1", self.EXPLORE, AGENT_ID))
        self.assertIsNone(self.by_id(AGENT_ID))
        self.assertEqual(len(self.audit_events("readonly_registered")), 1)

    def test_state_stays_bounded(self):
        for i in range(routing.MAX_TOOL_USES + 30):  # exempt creates whose PostToolUse never came
            self.assertIsNone(self.call(tool_input=self.EXPLORE, tool_use_id=f"tu-{i}"))
        for i in range(routing.MAX_READONLY_AGENTS + 10):
            self.launch(tool_use_id=f"tu-l{i}", agent_id=f"a{i:017x}")
        for i in range(5):  # exempt follow-ups record nothing to wait for
            self.assertIsNone(self.by_id(f"a{routing.MAX_READONLY_AGENTS + 9:017x}"))
        session = self.store.load_session(routing.session_key("claude", "s1"))
        self.assertLessEqual(len(session["readonly_uses"]), routing.MAX_TOOL_USES)
        self.assertEqual(len(session["readonly_ids"]), routing.MAX_READONLY_AGENTS)
        self.assertEqual(self.decision(self.by_id(f"a{0:017x}")), "deny")  # oldest evicted: fails closed

    def test_post_tool_use_never_answers(self):
        broken = [
            {"hook_event_name": "PostToolUse", "tool_name": "Agent", "tool_input": {}},  # no session
            {"hook_event_name": "PostToolUse", "session_id": "s1", "tool_name": "Agent", "tool_input": "x"},
            {"hook_event_name": "PostToolUse", "session_id": "s1", "tool_name": "SendMessage", "tool_input": {}},
            '{"hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"description":"PreToolUse"',
            '{"hook_event_name": "PostToolUse", "tool_name": "Agent", "x": "\\"PreToolUse\\"",',
        ]
        for payload in broken:
            with self.subTest(payload=payload):
                self.assertIsNone(self.hook(payload))
        os.makedirs(self.store.root, exist_ok=True)
        with open(self.store.session_path(routing.session_key("claude", "s1")), "w") as f:
            f.write("{broken")
        self.assertIsNone(self.post("tu-1", self.EXPLORE, AGENT_ID))

    def test_post_for_an_unrelated_call_takes_no_lock(self):
        with self.store:  # another process holds the lock
            start = time.monotonic()
            self.assertIsNone(self.post("tu-unrelated", self.EXPLORE, AGENT_ID))
            self.assertLess(time.monotonic() - start, 1.0)

    def test_a_lock_timeout_on_post_is_audited(self):
        self.assertIsNone(self.call(tool_input=self.EXPLORE, tool_use_id="tu-1"))
        old = routing.LOCK_WAIT_SECONDS
        routing.LOCK_WAIT_SECONDS = 0.05
        try:
            with routing.Store(self.store.root):
                self.assertIsNone(self.post("tu-1", self.EXPLORE, AGENT_ID))
        finally:
            routing.LOCK_WAIT_SECONDS = old
        self.assertEqual(len(self.audit_events("readonly_register_failed")), 1)


class Entrypoint(Env):
    """The installed shapes: PATH symlinks, arbitrary cwd, no worker setup."""

    def run_route(self, argv, stdin="", env_extra=None, via=DELEGATE, cwd="/"):
        env = dict(os.environ, **(env_extra or {}))
        return subprocess.run([BASH, via] + argv if via.endswith(".sh") else [via] + argv,
                              input=stdin, capture_output=True, text=True, env=env, cwd=cwd)

    def test_route_skips_worker_preflight(self):
        # no opencode, no jq, no worker model configured: routing still works
        bare = os.path.join(self.tmp, "bin")
        os.makedirs(bare)
        for tool in ("python3", "cat", "dirname", "basename", "readlink"):
            src = shutil.which(tool)
            if src:
                os.symlink(src, os.path.join(bare, tool))
        out = self.run_route(["route", "identity"], env_extra={"PATH": bare})
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(json.loads(out.stdout)["identity"], routing.runtime_identity())
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "state", "workflow-skills", "subagents")))

    def test_symlink_chain_and_space_in_path(self):
        a = os.path.join(self.tmp, "bin dir", "opencode-delegate")
        b = os.path.join(self.tmp, "relative link")
        os.makedirs(os.path.dirname(a))
        os.symlink(DELEGATE, b)
        os.symlink(os.path.join("..", "relative link"), a)
        out = self.run_route(["route", "identity"], via=a)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(json.loads(out.stdout)["path"], routing.self_path())

    def test_fallbacks_key_on_the_event_field_not_a_bare_word(self):
        # A tool_input value that is exactly an event name serializes with bare
        # quotes; it must not make a delegation call pass as another event.
        env = {"OPENCODE_DELEGATE_PYTHON": "python-does-not-exist"}
        for word in ("PostToolUse", "UserPromptSubmit", "SessionStart"):
            for sep in (":", ": ", " :\n\t"):
                payload = ('{"hook_event_name"' + sep + '"PreToolUse","tool_name":"Agent",'
                           '"tool_input":{"description":"' + word + '"}}')
                with self.subTest(word=word, sep=sep):
                    out = self.run_route(["route", "hook"], stdin=payload, env_extra=env)
                    self.assertEqual(json.loads(out.stdout)["hookSpecificOutput"]["permissionDecision"], "deny")
        payload = json.dumps({"hook_event_name": "PostToolUse", "tool_name": "Agent", "tool_input": {"description": "PreToolUse"}},
                             separators=(",", ":"))
        out = self.run_route(["route", "hook"], stdin=payload, env_extra=env)
        self.assertEqual((out.returncode, out.stdout), (0, ""))

    def test_undecodable_input_denies_only_a_pre_tool_use(self):
        # An unreadable user message still retires earlier grants: only it leaves the marker.
        marker = os.path.join(self.store.root, "capture-failed-any")
        for event, expect in (("PreToolUse", "deny"), ("PostToolUse", None), ("UserPromptSubmit", None)):
            raw = b'{"hook_event_name":"' + event.encode() + b'","tool_name":"Agent","tool_input":{"prompt":"\xff"}}'
            out = subprocess.run([BASH, DELEGATE, "route", "hook", "--host", "claude"], input=raw, capture_output=True,
                                 env=os.environ, cwd="/")
            with self.subTest(event):
                self.assertEqual(out.returncode, 0)
                self.assertEqual(os.path.exists(marker), event == "UserPromptSubmit")
                if expect:
                    self.assertEqual(json.loads(out.stdout)["hookSpecificOutput"]["permissionDecision"], expect)
                else:
                    self.assertEqual(out.stdout, b"")

    def test_an_unreadable_stdin_denies(self):
        # With no input there is no event to tell by, so it is denied: a
        # PreToolUse must not pass, and a deny on PostToolUse changes nothing.
        out = subprocess.run([BASH, "-c", f'exec 0<&-; "{BASH}" "{DELEGATE}" route hook --host claude'],
                             capture_output=True, text=True, cwd="/")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(json.loads(out.stdout)["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_missing_interpreter_fails_closed_for_delegation_only(self):
        env = {"OPENCODE_DELEGATE_PYTHON": "python-does-not-exist"}
        payload = json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Agent", "tool_input": {}})
        out = self.run_route(["route", "hook"], stdin=payload, env_extra=env)
        self.assertEqual(out.returncode, 0)
        self.assertEqual(json.loads(out.stdout)["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertIn("review your own work", json.loads(out.stdout)["hookSpecificOutput"]["permissionDecisionReason"])
        out = self.run_route(["route", "hook"], stdin=json.dumps({"hook_event_name": "UserPromptSubmit"}), env_extra=env)
        self.assertEqual((out.returncode, out.stdout), (0, ""))
        out = self.run_route(["route", "show"], env_extra=env)
        self.assertEqual(out.returncode, 2)

    def test_record_cli_end_to_end(self):
        self.prompt("use a native agent for the research on the cache")
        pid = self.proposal_of(self.call())
        out = self.run_route(["route", "record", "--proposal", pid, "--assignment", "cache-survey", "--scope", "survey cache users",
                              "--work-kind", "research", "--authorization", "user", "--source-excerpt",
                              "use a native agent for the research", "--requested-provider", "native",
                              "--scope-status", "clear", "--skill-revision", REVISION, "--json"])
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(json.loads(out.stdout)["route"], "native")
        out = self.run_route(["route", "record", "--proposal", pid])
        self.assertEqual(out.returncode, 2)
        self.assertIn("ERROR:", out.stderr)
        out = self.run_route(["route", "show", pid, "--json"])
        self.assertEqual(json.loads(out.stdout)["status"], "granted")

    def test_doctor_reports_path_command_and_registrations(self):
        home = os.path.join(self.tmp, "home")
        bindir = os.path.join(self.tmp, "pathbin")
        os.makedirs(os.path.join(home, ".claude"))
        os.makedirs(bindir)
        with open(os.path.join(home, ".claude", "settings.json"), "w") as f:
            json.dump({"hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "'/x/delegate.sh' route hook"}]}]}}, f)
        env = {"HOME": home, "PATH": os.environ["PATH"]}
        out = self.run_route(["route", "doctor", "--json"], env_extra=dict(env, PATH=bindir + ":/usr/bin:/bin"))
        report = json.loads(out.stdout)
        self.assertEqual(out.returncode, 1)
        self.assertEqual(report["command"]["status"], "missing")
        self.assertEqual(report["hosts"]["claude"]["status"], "installed-unverified")
        self.assertEqual(report["hosts"]["codex"]["status"], "not-installed")
        os.symlink(DELEGATE, os.path.join(bindir, "opencode-delegate"))
        os.chmod(DELEGATE, os.stat(DELEGATE).st_mode | 0o111)
        path = bindir + ":" + os.environ["PATH"]
        with open(os.path.join(home, ".claude", "settings.json"), "a"):
            pass
        time.sleep(0.01)
        self.run_route(["route", "hook"], stdin=json.dumps({"hook_event_name": "UserPromptSubmit", "session_id": "d", "prompt": "hi"}),
                       env_extra=dict(env, PATH=path))
        report = json.loads(self.run_route(["route", "doctor", "--json"], env_extra=dict(env, PATH=path)).stdout)
        self.assertEqual(report["command"]["status"], "match")
        self.assertEqual(report["hosts"]["claude"]["status"], "active-observed")

    def test_doctor_detects_installed_hook_shim(self):
        home = os.path.join(self.tmp, "shim-home")
        os.makedirs(os.path.join(home, ".codex"))
        with open(os.path.join(home, ".codex", "hooks.json"), "w") as f:
            json.dump({"hooks": {"PreToolUse": [{"hooks": [{"type": "command",
                "command": "/usr/bin/bash /x/route-hook-shim.sh /x/delegate.sh codex # workflow-skills-routing"}]}]}}, f)
        out = self.run_route(["route", "doctor", "--json"], env_extra={"HOME": home})
        report = json.loads(out.stdout)
        self.assertEqual(report["hosts"]["codex"]["status"], "installed-unverified")


    def test_doctor_flags_a_registration_missing_an_event(self):
        # A symlink install updates the router in place; settings written by an
        # older install.sh lack PostToolUse, so follow-ups by id stay gated.
        home = os.path.join(self.tmp, "stale-home")
        command = "/usr/bin/bash /x/route-hook-shim.sh /x/delegate.sh {} # workflow-skills-routing"
        for host, path in (("claude", (".claude", "settings.json")), ("codex", (".codex", "hooks.json"))):
            os.makedirs(os.path.join(home, path[0]))
            with open(os.path.join(home, *path), "w") as f:
                json.dump({"hooks": {e: [{"hooks": [{"type": "command", "command": command.format(host)}]}]
                                     for e in ("UserPromptSubmit", "SessionStart", "PreToolUse")}}, f)
        plugin = os.path.join(home, "plugin", "hooks")
        os.makedirs(plugin)
        shutil.copy(os.path.join(REPO, "hooks", "hooks.json"), plugin)
        os.makedirs(os.path.join(home, ".claude", "plugins"))
        with open(os.path.join(home, ".claude", "plugins", "installed_plugins.json"), "w") as f:
            json.dump({"plugins": {"workflow-skills@x": [{"installPath": os.path.dirname(plugin)}]}}, f)
        report = routing.doctor(self.store, home)
        self.assertEqual(report["hosts"]["claude"]["registrations"][1]["missing_events"], [])
        with open(os.path.join(plugin, "hooks.json")) as f:
            stale = json.load(f)
        del stale["hooks"]["PostToolUse"]
        with open(os.path.join(plugin, "hooks.json"), "w") as f:
            json.dump(stale, f)
        report = routing.doctor(self.store, home)
        self.assertIn("claude: the plugin hook registration lacks PostToolUse; update the plugin", report["problems"])
        self.assertEqual(report["hosts"]["claude"]["registrations"][0]["missing_events"], ["PostToolUse"])
        self.assertEqual(report["hosts"]["codex"]["registrations"][0]["missing_events"], [])
        self.assertIn("claude: the local hook registration lacks PostToolUse; re-run scripts/install.sh", report["problems"])
        self.assertFalse([p for p in report["problems"] if p.startswith("codex:") and "lacks" in p])


PLUGIN_HOOKS = {"hooks.json": ("CLAUDE_PLUGIN_ROOT", "claude"), "codex-hooks.json": ("PLUGIN_ROOT", "codex")}


class HooksConfig(unittest.TestCase):
    def setUp(self):
        self.configs = {}
        for name in PLUGIN_HOOKS:
            with open(os.path.join(REPO, "hooks", name)) as f:
                self.configs[name] = json.load(f)
        self.config = self.configs["hooks.json"]

    def test_codex_manifest_selects_codex_hooks_and_files_agree(self):
        with open(os.path.join(REPO, ".codex-plugin", "plugin.json")) as f:
            self.assertEqual(json.load(f)["hooks"], "./hooks/codex-hooks.json")
        shape = lambda c: {e: [g.get("matcher") for g in gs] for e, gs in c["hooks"].items()}
        claude, codex = shape(self.configs["hooks.json"]), shape(self.configs["codex-hooks.json"])
        self.assertEqual({e: m for e, m in claude.items() if e in codex}, codex)
        self.assertEqual(set(claude) - set(codex), set(routing.CLAUDE_ONLY_EVENTS))

    def test_router_knows_the_registered_events(self):
        for name, (var, host) in PLUGIN_HOOKS.items():
            self.assertEqual(set(self.configs[name]["hooks"]), set(routing.HOOK_EVENTS[host]), name)

    def test_post_tool_use_matcher_covers_only_readonly_create_tools(self):
        (group,) = self.config["hooks"]["PostToolUse"]
        matcher = re.compile(group["matcher"])
        for tool in routing.WORK_TOOLS:
            self.assertEqual(bool(matcher.search(tool)), tool in routing.READONLY_CREATE_TOOLS, tool)
        for tool in ("Bash", "AgentX", "mcp__s__Agent", "TaskOutput"):
            self.assertFalse(matcher.search(tool), tool)
        self.assertEqual({t for t, (op, _) in routing.WORK_TOOLS.items() if t in routing.READONLY_CREATE_TOOLS and op == "create"},
                         set(routing.READONLY_CREATE_TOOLS))

    def test_matcher_covers_every_work_tool_and_nothing_else(self):
        (group,) = self.config["hooks"]["PreToolUse"]
        matcher = re.compile(group["matcher"])
        for tool in routing.WORK_TOOLS:
            self.assertTrue(matcher.search(tool), tool)
        for tool in ("Bash", "TaskOutput", "TaskStop", "collaborationwait_agent", "AgentX", "mcp__s__Agent", "Read"):
            self.assertFalse(matcher.search(tool), tool)

    def test_commands_route_through_the_plugin_entrypoint(self):
        for name, (var, host) in PLUGIN_HOOKS.items():
            for event, groups in self.configs[name]["hooks"].items():
                for group in groups:
                    for handler in group["hooks"]:
                        self.assertEqual(handler["type"], "command")
                        self.assertEqual(handler["command"], f'bash "${{{var}}}/skills/opencode-subagent/scripts/route-hook-shim.sh" '
                                                             f'"${{{var}}}/skills/opencode-subagent/scripts/delegate.sh" {host}')
        for rel in ("skills/opencode-subagent/scripts/delegate.sh", "skills/opencode-subagent/scripts/route-hook-shim.sh"):
            self.assertTrue(os.path.isfile(os.path.join(REPO, rel)), rel)

    def test_plugin_commands_survive_a_broken_entry(self):
        # A local-path plugin runs from the checkout. On a branch from before
        # routing, delegate.sh exits 2 for `route hook`, and a raw exit 2 from
        # UserPromptSubmit blocks every prompt. Through the shim the prompt
        # passes and delegation is denied.
        for name, (var, host) in PLUGIN_HOOKS.items():
            handler = self.configs[name]["hooks"]["UserPromptSubmit"][0]["hooks"][0]["command"]
            root = tempfile.mkdtemp()
            try:
                scripts = os.path.join(root, "skills", "opencode-subagent", "scripts")
                os.makedirs(scripts)
                shutil.copy(os.path.join(SCRIPTS, "route-hook-shim.sh"), scripts)
                with open(os.path.join(scripts, "delegate.sh"), "w") as f:
                    f.write('echo "unknown command: $1" >&2\nexit 2\n')
                env = {k: v for k, v in os.environ.items() if k not in ("CLAUDE_PLUGIN_ROOT", "PLUGIN_ROOT")}
                env.update({var: root, "XDG_STATE_HOME": root})
                prompt = json.dumps({"hook_event_name": "UserPromptSubmit", "session_id": "x", "prompt": "hi"})
                out = subprocess.run(["sh", "-c", handler], input=prompt, capture_output=True, text=True, env=env, cwd="/")
                self.assertEqual((out.returncode, out.stdout), (0, ""), (name, out.stderr))
                self.assertTrue(os.path.exists(os.path.join(root, "workflow-skills", "routing", "capture-failed-any")), name)
                for word, indent in (("", None), ("PostToolUse", None), ("UserPromptSubmit", None),
                                     ("SessionStart", None), ("SessionStart", "\t")):
                    payload = json.dumps({"hook_event_name": "PreToolUse", "session_id": "x", "tool_name": "Agent",
                                          "tool_input": {"description": word}}, separators=(",", " :  "), indent=indent)
                    out = subprocess.run(["sh", "-c", handler], input=payload, capture_output=True, text=True, env=env, cwd="/")
                    self.assertEqual(out.returncode, 0, name)
                    self.assertEqual(json.loads(out.stdout)["hookSpecificOutput"]["permissionDecision"], "deny", (name, word))
                payload = json.dumps({"hook_event_name": "PostToolUse", "session_id": "x", "tool_name": "Agent",
                                      "tool_input": {"description": "PreToolUse"}}, separators=(",", ":"))
                out = subprocess.run(["sh", "-c", handler], input=payload, capture_output=True, text=True, env=env, cwd="/")
                self.assertEqual((out.returncode, out.stdout), (0, ""), name)
            finally:
                shutil.rmtree(root)

    def test_claude_manifest_does_not_pin_a_version(self):
        # A pinned version keeps GitHub installs on the cached copy until the
        # string changes, so new hooks never reach them. Without it Claude Code
        # versions the plugin by commit.
        with open(os.path.join(REPO, ".claude-plugin", "plugin.json")) as f:
            self.assertNotIn("version", json.load(f))
        with open(os.path.join(REPO, ".claude-plugin", "marketplace.json")) as f:
            for plugin in json.load(f)["plugins"]:
                self.assertNotIn("version", plugin)

    def test_plugin_commands_run_with_their_root_variable(self):
        for name, (var, host) in PLUGIN_HOOKS.items():
            handler = self.configs[name]["hooks"]["PreToolUse"][0]["hooks"][0]["command"]
            tmp = tempfile.mkdtemp()
            try:
                env = {k: v for k, v in os.environ.items() if k not in ("CLAUDE_PLUGIN_ROOT", "PLUGIN_ROOT")}
                env.update({var: REPO, "XDG_STATE_HOME": tmp, "XDG_CONFIG_HOME": tmp})
                prompt = json.dumps({"hook_event_name": "UserPromptSubmit", "session_id": "x", "cwd": tmp, "prompt": "hi"})
                subprocess.run(["sh", "-c", handler], input=prompt, capture_output=True, text=True, env=env, cwd="/")
                payload = json.dumps({"hook_event_name": "PreToolUse", "session_id": "x", "cwd": tmp, "tool_name": "Agent", "tool_input": {}})
                out = subprocess.run(["sh", "-c", handler], input=payload, capture_output=True, text=True, env=env, cwd="/")
                reason = json.loads(out.stdout)["hookSpecificOutput"]["permissionDecisionReason"]
                self.assertIn(f"proposal {host}-", reason, (name, out.stderr))
            finally:
                shutil.rmtree(tmp)


class Fixtures(Env):
    """Sanitized payloads captured from the live host probes."""

    def test_captured_payloads(self):
        names = sorted(os.listdir(FIXTURES))
        self.assertTrue(names)
        for name in names:
            with open(os.path.join(FIXTURES, name)) as f:
                case = json.load(f)
            with self.subTest(fixture=name):
                for event in case["events"]:
                    expect = event.pop("expect", None)
                    self.assertTrue(event.get("cwd"), "live payloads carry cwd")
                    out = self.hook(event)
                    if event["hook_event_name"] != "PreToolUse" or event["tool_name"] not in routing.WORK_TOOLS:
                        self.assertIsNone(out)
                    elif expect == "pass":  # read-only, or a follow-up to one
                        self.assertIsNone(out, event)
                    else:
                        self.assertEqual(self.decision(out), "deny")
                        self.assertTrue(self.proposal_of(out).startswith(case["host"] + "-"))


if __name__ == "__main__":
    unittest.main(verbosity=1)
