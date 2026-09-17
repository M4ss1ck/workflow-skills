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
                requested_provider="unspecified", native_reason=None, scope_status="clear", skill_revision=REVISION)
    base.update(fields)
    return argparse.Namespace(**base)


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


class Decide(unittest.TestCase):
    """The policy precedence table, row by row."""

    def test_matrix(self):
        rows = [
            # policy, record fields, prior assignment, excerpt epoch, expected route
            ("off", dict(requested_provider="native"), None, 1, "none"),
            ("off", dict(authorization="none", source_excerpt=""), None, None, "none"),
            ("explicit", dict(authorization="none", source_excerpt=""), None, None, "local"),
            ("explicit", dict(authorization="none", source_excerpt="", work_kind="research", native_reason="x"), None, None, "local"),
            ("explicit", dict(requested_provider="opencode"), None, 1, "opencode"),
            ("auto", dict(requested_provider="opencode", work_kind="research"), None, 1, "opencode"),
            ("explicit", dict(requested_provider="native"), None, 1, "native"),
            ("auto", dict(requested_provider="native", work_kind="implementation"), None, 1, "native"),
            ("explicit", dict(), None, 1, "opencode"),
            ("auto", dict(authorization="none", source_excerpt=""), None, None, "opencode"),
            ("explicit", dict(work_kind="research", native_reason="needs repo-wide reading"), None, 1, "native"),
            ("auto", dict(authorization="none", source_excerpt="", work_kind="review", native_reason="independent eyes"), None, None, "native"),
            ("auto", dict(work_kind="research"), None, 1, "invalid"),
            ("explicit", dict(scope_status="ambiguous", requested_provider="native"), None, 1, "clarify"),
            ("auto", dict(scope_status="conflicting"), None, 1, "clarify"),
            # workflow authorization acts as a generic delegation request
            ("explicit", dict(authorization="workflow", workflow_file="/x", requested_provider="native", work_kind="research", native_reason="r"), None, None, "native"),
            ("explicit", dict(authorization="workflow", workflow_file="/x", requested_provider="native"), None, None, "opencode"),
            # an OpenCode assignment keeps its provider...
            ("auto", dict(work_kind="research", native_reason="r"), {"provider": "opencode", "epoch": 2}, 3, "opencode"),
            ("auto", dict(requested_provider="native"), {"provider": "opencode", "epoch": 2}, 2, "opencode"),
            ("auto", dict(requested_provider="native", authorization="workflow", workflow_file="/x"), {"provider": "opencode", "epoch": 2}, None, "opencode"),
            # ...until a later explicit user override
            ("auto", dict(requested_provider="native"), {"provider": "opencode", "epoch": 2}, 3, "native"),
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

    def test_sources(self):
        self.assertInvalid("--source-excerpt must quote", source_excerpt="yes")
        self.assertInvalid("--workflow-file is required", authorization="workflow")
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

    def test_denial_is_actionable(self):
        self.prompt("anything at all here")
        reason = self.call()["hookSpecificOutput"]["permissionDecisionReason"]
        self.assertIn("opencode-delegate route record --proposal", reason)
        self.assertIn(REVISION, reason)
        self.assertIn("opencode-subagent skill", reason)
        self.assertLess(len(reason), 900)

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
        result = self.record(self.pid, authorization="none", source_excerpt="", work_kind="research", native_reason="faster")
        self.assertEqual(result["route"], "local")

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
        with self.assertRaisesRegex(routing.RoutingError, "--native-reason"):
            self.record(self.pid, work_kind="research")
        self.assertEqual(routing.show(self.pid, self.store)["status"], "pending")
        self.assertEqual(self.record(self.pid, work_kind="research", native_reason="survey only")["route"], "native")

    def test_decided_proposal_cannot_be_rerecorded(self):
        self.record(self.pid)
        with self.assertRaisesRegex(routing.RoutingError, "already routed"):
            self.record(self.pid, work_kind="research", native_reason="changed my mind")

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
                             source_excerpt="always get an independent native review", native_reason="independent review")
        self.assertEqual(result["route"], "native")
        shown = routing.show(self.pid, self.store)
        self.assertEqual(len(shown["decision"]["source"]["sha256"]), 64)

    def test_workflow_excerpt_must_be_in_file(self):
        wf = self.git_workflow("Nothing about delegation here.\n")
        with self.assertRaisesRegex(routing.RoutingError, "does not appear in"):
            self.record(self.pid, authorization="workflow", workflow_file=wf, source_excerpt="always delegate everything")

    def test_workflow_file_must_be_committed_in_the_worktree_repo(self):
        excerpt = dict(authorization="workflow", source_excerpt="root:x:0:0:root", work_kind="research", native_reason="r")
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
        result = self.record(pid, assignment="parser", work_kind="research", native_reason="look around first")
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

    def test_missing_interpreter_fails_closed_for_delegation_only(self):
        env = {"OPENCODE_DELEGATE_PYTHON": "python-does-not-exist"}
        payload = json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Agent", "tool_input": {}})
        out = self.run_route(["route", "hook"], stdin=payload, env_extra=env)
        self.assertEqual(out.returncode, 0)
        self.assertEqual(json.loads(out.stdout)["hookSpecificOutput"]["permissionDecision"], "deny")
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
        self.assertEqual(shape(self.configs["hooks.json"]), shape(self.configs["codex-hooks.json"]))

    def test_matcher_covers_every_work_tool_and_nothing_else(self):
        (group,) = self.config["hooks"]["PreToolUse"]
        matcher = re.compile(group["matcher"])
        for tool in routing.WORK_TOOLS:
            self.assertTrue(matcher.search(tool), tool)
        for tool in ("Bash", "TaskOutput", "TaskStop", "collaborationwait_agent", "AgentX", "mcp__s__Agent", "Read"):
            self.assertFalse(matcher.search(tool), tool)

    def test_commands_route_through_the_plugin_entrypoint(self):
        for name, (var, host) in PLUGIN_HOOKS.items():
            for event in ("UserPromptSubmit", "SessionStart", "PreToolUse"):
                for group in self.configs[name]["hooks"][event]:
                    for handler in group["hooks"]:
                        self.assertEqual(handler["type"], "command")
                        self.assertEqual(handler["command"], f'bash "${{{var}}}/skills/opencode-subagent/scripts/delegate.sh" route hook --host {host}')
        rel = "skills/opencode-subagent/scripts/delegate.sh"
        self.assertTrue(os.path.isfile(os.path.join(REPO, rel)))

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
                    self.assertTrue(event.get("cwd"), "live payloads carry cwd")
                    out = self.hook(event)
                    if event["hook_event_name"] != "PreToolUse" or event["tool_name"] not in routing.WORK_TOOLS:
                        self.assertIsNone(out)
                    else:
                        self.assertEqual(self.decision(out), "deny")
                        self.assertTrue(self.proposal_of(out).startswith(case["host"] + "-"))


if __name__ == "__main__":
    unittest.main(verbosity=1)
