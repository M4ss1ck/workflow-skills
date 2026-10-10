#!/usr/bin/env python3
"""Route native delegation calls through a recorded, policy-checked decision.

Reached only through delegate.sh (`opencode-delegate route ...`):

  route hook [--host claude|codex]   host hook adapter; reads one event on stdin
  route record --proposal ID ...     record the routing decision for a denied call
  route show [ID] [--json]           a proposal, or the recent open proposals
  route doctor [--json]              runtime, PATH command, policy, host hooks
  route identity                     this runtime's identity (used by doctor)

Protocol. A native agent-creation or work-assignment call without a grant is
denied and stored as a proposal: the exact tool input plus the session, worktree,
user-input epoch and target it arrived with. The supervisor records a decision
for that proposal; the router computes the route from the recorded fields and
the current policy. Only a native route issues a grant. The next matching native
call consumes the grant once and the hook replaces its input with the stored
proposal, so what runs is exactly what was decided on (Codex re-encrypts the
message on every retry, so the retry's own arguments can never be compared).

This enforces a procedure, not the truth of the recorded classification, and it
is not a security boundary against an agent that can edit these files.
Standard library only; no model or network calls.
"""

import argparse
import datetime
import fcntl
import fnmatch
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

SCHEMA = 1
POLICY_KEY = "OPENCODE_SUBAGENT_DELEGATION_POLICY"
DEFAULT_POLICY = "explicit"
POLICIES = ("off", "explicit", "auto")
WORK_KINDS = ("implementation", "research", "review")
AUTHORIZATIONS = ("user", "workflow", "none")
PROVIDERS = ("opencode", "native", "unspecified")
SCOPE_STATUSES = ("clear", "ambiguous", "conflicting")
# Why research or review must run natively instead of on the OpenCode
# researcher. A closed set: free text let every agent justify native work.
NATIVE_REASONS = ("needs-host-tools", "opencode-failed")
# Agent types that cannot change anything run without a routing decision. The
# host's own read-only types always do; the conf key adds patterns to them
# (absent: the default; empty: built-ins only).
READONLY_KEY = "OPENCODE_SUBAGENT_READONLY_AGENTS"
BUILTIN_READONLY_AGENTS = ("Explore", "Plan", "claude-code-guide")
DEFAULT_READONLY_AGENTS = "*-reviewer *-explorer"
# Tools whose PostToolUse reports the id of an agent the hook exempted
# (verified live: Claude Code 2.1.296 tool_response.agentId, foreground and
# background). hooks/hooks.json registers PostToolUse for exactly these.
READONLY_CREATE_TOOLS = ("Agent", "Task")
# Claude Code agent ids: "a" + hex, assigned by the host and never reused.
# Follow-ups pass by id only: the host allocates, normalizes and reassigns
# names (an unnamed agent is registered under its type), so a name the hook
# saw on a read-only create can come to mean a writer.
AGENT_ID_RE = re.compile(r"a[0-9a-f]{8,}")
MAX_READONLY_AGENTS = 50
# Events each host's hook file registers; doctor flags a registration missing one.
HOOK_EVENTS = {
    "claude": ("UserPromptSubmit", "SessionStart", "PreToolUse", "PostToolUse"),
    "codex": ("UserPromptSubmit", "SessionStart", "PreToolUse"),
}
CLAUDE_ONLY_EVENTS = ("PostToolUse",)
# Claude Code injects an invoked skill's body as a meta user row starting so.
SKILL_BODY_PREFIX = "Base directory for this skill:"
TRANSCRIPT_SCAN_CAP = 512 * 1024 * 1024
# Appended to every denial that cannot know the work kind: a review that cannot
# be delegated must not quietly become the author reviewing their own work.
REVIEW_NOTE = ("If this was a review, do not review your own work instead: tell the user no independent "
               "review ran.")
# opencode-delegate outcomes that show an OpenCode run happened and failed. A
# cancel or take-over is the supervisor's own act, so on its own it proves
# nothing: those need a recorded failure class as well.
RAN_TRANSPORTS = ("finished", "incomplete", "failed", "timeout", "cancelled")
FAILED_WORKER_OUTCOMES = ("blocked", "no_report", "failed")

GRANT_TTL_SECONDS = 1800
LOCK_WAIT_SECONDS = 4.0
MAX_PROMPTS = 20
MAX_PROMPT_CHARS = 32000
MAX_PROPOSALS = 50
MAX_TOOL_USES = 200
MIN_EXCERPT_CHARS = 12
AUDIT_MAX_BYTES = 1_000_000

# Tool name -> (operation, field naming the existing agent). Every name that can
# create an agent or hand an existing one more work. Status, wait and cancel
# tools are deliberately absent: they never assign work.
# Verified live: Claude Code 2.1.270 Agent, SendMessage; Codex 0.151.0
# collaborationspawn_agent, collaborationfollowup_task. The rest are documented
# or legacy names, intercepted so a rename cannot silently bypass routing.
WORK_TOOLS = {
    "Agent": ("create", None),
    "Task": ("create", None),
    "SendMessage": ("continue", "to"),
    "collaborationspawn_agent": ("create", None),
    "spawn_agent": ("create", None),
    "collaborationfollowup_task": ("continue", "target"),
    "collaborationsend_message": ("continue", "target"),
    "send_input": ("continue", "target"),
    "collaborationresume_agent": ("continue", "id"),
    "resume_agent": ("continue", "id"),
}
TARGET_FALLBACKS = ("to", "target", "recipient", "id", "agent_id")

SUPPORT_MATRIX = {
    "claude": {"tested_version": "2.1.270", "create": "verified", "continue": "verified", "replay": "verified"},
    "codex": {"tested_version": "0.151.0", "create": "verified", "continue": "verified", "replay": "unverified"},
}


class RoutingError(Exception):
    """A condition the caller can act on; the message says how."""


# ---------------------------------------------------------------- locations

def self_path():
    return os.path.realpath(__file__)


def skill_dir():
    return os.path.dirname(os.path.dirname(self_path()))


def state_dir():
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, "workflow-skills", "routing")


def conf_file():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "workflow-skills", "subagents.conf")


def file_digest(path, length=16):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()[:length]


def runtime_identity():
    return f"s{SCHEMA}-{file_digest(self_path())}"


def skill_revision():
    return file_digest(os.path.join(skill_dir(), "SKILL.md"), 12)


def now():
    return time.time()


def iso(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------- policy

def conf_value(key, path=None):
    """Same semantics as delegate.sh conf_get: the last `KEY=` line wins and the
    value is the rest of the line verbatim. None when the key is absent."""
    path = path or conf_file()
    value = None
    if os.path.isfile(path):
        with open(path, "rb") as f:
            for raw in f.read().split(b"\n"):
                line = raw.decode("utf-8", "surrogateescape")
                if line.startswith(key + "="):
                    value = line[len(key) + 1:]
    return value


def read_policy(path=None):
    """Same semantics as delegate.sh resolve_policy: empty or absent means
    explicit, anything else is an error."""
    path = path or conf_file()
    value = conf_value(POLICY_KEY, path) or DEFAULT_POLICY
    if value not in POLICIES:
        raise RoutingError(f"invalid {POLICY_KEY} in {path}: {value} (want off|explicit|auto)")
    return value


def readonly_agents(path=None):
    """Patterns naming agent types that skip routing: the built-ins, plus the
    configured patterns (absent means the default, empty means none)."""
    value = conf_value(READONLY_KEY, path)
    if value is None:
        value = DEFAULT_READONLY_AGENTS
    return list(BUILTIN_READONLY_AGENTS) + [p for p in re.split(r"[\s,]+", value) if p]


def is_readonly_agent(tool, operation, tool_input, patterns):
    """Only a new agent of a named read-only type: a continuation names an
    agent instance, whose type the hook cannot see."""
    if operation != "create" or tool not in READONLY_CREATE_TOOLS:
        return False
    kind = tool_input.get("subagent_type")
    return isinstance(kind, str) and any(fnmatch.fnmatchcase(kind, p) for p in patterns)


# ---------------------------------------------------------------- pure decision

def decide(policy, record, prior_assignment=None, excerpt_epoch=None):
    """Compute a route from recorded fields. Returns (route, reason).

    route is one of: native, opencode, local, none, clarify, invalid. For
    opencode, role_for() names the OpenCode agent.
    `prior_assignment` is the stored assignment with the same name, if any.
    `excerpt_epoch` is the latest user-input epoch containing the source excerpt.

    A review is never routed local: an author reviewing their own work is not a
    review. Research and review go to the OpenCode researcher unless a closed
    reason (or the user) asks for a native agent.
    """
    if policy == "off":
        return "none", "delegation policy is off; the user can enable it with: opencode-delegate policy explicit"
    if record["scope_status"] != "clear":
        return "clarify", f"scope is {record['scope_status']}; ask the user to resolve it or work locally"

    authorized_by_source = record["authorization"] in ("user", "workflow")
    requested = record["requested_provider"]
    kind = record["work_kind"]
    native_reason = record.get("native_reason", "")

    if prior_assignment and prior_assignment.get("provider") == "opencode":
        later_user_override = (
            requested == "native"
            and record["authorization"] == "user"
            and excerpt_epoch is not None
            and excerpt_epoch > prior_assignment["epoch"]
        )
        if later_user_override:
            return "native", "later explicit user override of an OpenCode assignment"
        if native_reason == "opencode-failed" and kind != "implementation":
            return "native", (f"assignment {record['assignment']} ran on OpenCode as "
                              f"{record.get('opencode_task') or 'a failed Task'} and failed")
        return "opencode", (
            f"assignment {record['assignment']} is recorded as OpenCode work; a native substitute "
            "needs a later explicit user instruction for native delegation"
        )
    if native_reason == "opencode-failed":
        return "invalid", (f"--native-reason opencode-failed needs assignment {record['assignment']} to have been "
                           "routed to OpenCode first; record the OpenCode attempt under the same --assignment")

    if requested == "opencode":
        return "opencode", "explicit OpenCode assignment"
    if requested == "native" and record["authorization"] == "user":
        return "native", "explicit user request for native delegation"
    if requested == "native" and record["authorization"] == "workflow" and kind != "implementation":
        return "native", f"workflow instruction asks for native {kind}"

    if not (policy == "auto" or authorized_by_source) and kind != "review":
        return "local", "policy is explicit and nobody requested delegation; a model choosing to delegate is not authorization"

    if kind == "implementation":
        return "opencode", "bounded implementation goes to the OpenCode worker"
    if native_reason == "needs-host-tools":
        if not (policy == "auto" or authorized_by_source):
            # An unauthorized review may go to the cheap researcher, but a
            # native agent is the model granting itself delegation.
            return "clarify", (f"policy is explicit and nobody authorized delegation; a native {kind} needs the "
                               "user's go-ahead, so ask them")
        return "native", f"{kind} needs tools only the host agent has"
    if kind == "review" and not (policy == "auto" or authorized_by_source):
        return "opencode", "a review needs an independent reviewer, never the author: it goes to the OpenCode researcher"
    return "opencode", f"{kind} goes to the OpenCode researcher"


def role_for(kind):
    return "worker" if kind == "implementation" else "researcher"


def validate_record(args):
    """Normalize CLI fields into a record, or raise RoutingError with the fix."""
    problems = []

    def need(name, value, choices=None):
        if value is None or (isinstance(value, str) and not value.strip()):
            problems.append(f"--{name.replace('_', '-')} is required")
        elif choices and value not in choices:
            problems.append(f"--{name.replace('_', '-')} must be one of {'|'.join(choices)} (got {value})")

    # The common case needs only what the agent alone knows: the deny message
    # hands out a one-line command, and every omitted field is the cautious one.
    authorization = args.authorization or "none"
    requested_provider = args.requested_provider or "unspecified"
    scope_status = args.scope_status or "clear"
    native_reason = (args.native_reason or "").strip()
    need("proposal", args.proposal)
    need("assignment", args.assignment)
    need("scope", args.scope)
    need("work_kind", args.work_kind, WORK_KINDS)
    need("authorization", authorization, AUTHORIZATIONS)
    need("requested_provider", requested_provider, PROVIDERS)
    need("scope_status", scope_status, SCOPE_STATUSES)
    need("skill_revision", args.skill_revision)
    if native_reason and native_reason not in NATIVE_REASONS:
        problems.append(f"--native-reason must be one of {'|'.join(NATIVE_REASONS)} (got {native_reason}); "
                        "research and review otherwise go to the OpenCode researcher")
    opencode_task = (getattr(args, "opencode_task", None) or "").strip()
    if native_reason == "opencode-failed" and not re.fullmatch(r"task_[0-9]{8}-[0-9]{6}-[0-9]+", opencode_task):
        problems.append("--native-reason opencode-failed needs --opencode-task TASK: the failed OpenCode Task "
                        "(opencode-delegate list)")
    if opencode_task and native_reason != "opencode-failed":
        problems.append("--opencode-task applies only to --native-reason opencode-failed")
    if native_reason and args.work_kind == "implementation":
        problems.append("--native-reason applies to research and review; implementation goes to the OpenCode worker "
                        "unless the user asks for native")
    if args.assignment and not re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,63}", args.assignment):
        problems.append("--assignment must be a lowercase slug ([a-z0-9._-], at most 64 chars)")
    if args.scope and len(args.scope) > 2000:
        problems.append("--scope is limited to 2000 characters")
    if authorization in ("user", "workflow"):
        excerpt = normalize_text(args.source_excerpt or "")
        if len(excerpt) < MIN_EXCERPT_CHARS:
            problems.append(f"--source-excerpt must quote at least {MIN_EXCERPT_CHARS} characters of the authorizing text")
    if authorization != "workflow" and args.workflow_file:
        problems.append("--workflow-file applies only to --authorization workflow")
    if authorization == "none" and requested_provider in ("opencode", "native"):
        problems.append("a requested provider needs its source: use --authorization user or workflow with --source-excerpt")
    if problems:
        raise RoutingError("; ".join(problems))
    return {
        "proposal": args.proposal,
        "assignment": args.assignment,
        "scope": args.scope.strip(),
        "work_kind": args.work_kind,
        "authorization": authorization,
        "source_excerpt": args.source_excerpt or "",
        "workflow_file": args.workflow_file or "",
        "requested_provider": requested_provider,
        "native_reason": native_reason,
        "opencode_task": opencode_task,
        "scope_status": scope_status,
        "skill_revision": args.skill_revision,
    }


def normalize_text(text):
    return " ".join(text.split())


# ---------------------------------------------------------------- state

class Store:
    """One lock for all routing state: decisions are rare and small, and a
    single lock makes grant consumption trivially atomic across concurrent
    hook processes (duplicate registrations, parallel tool calls)."""

    def __init__(self, root=None):
        self.root = root or state_dir()
        self.lock_fd = None

    def __enter__(self):
        os.makedirs(os.path.join(self.root, "sessions"), mode=0o700, exist_ok=True)
        os.chmod(self.root, 0o700)
        self.lock_fd = os.open(os.path.join(self.root, "lock"), os.O_RDWR | os.O_CREAT, 0o600)
        deadline = now() + LOCK_WAIT_SECONDS
        while True:
            try:
                fcntl.flock(self.lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except BlockingIOError:
                if now() > deadline:
                    os.close(self.lock_fd)
                    raise RoutingError(f"routing state is locked by another process ({self.root}/lock)")
                time.sleep(0.02)

    def __exit__(self, *exc):
        fcntl.flock(self.lock_fd, fcntl.LOCK_UN)
        os.close(self.lock_fd)

    def _write_json(self, path, data):
        tmp = f"{path}.{os.getpid()}.tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=1, sort_keys=True)
            f.write("\n")
        os.replace(tmp, path)

    def _read_json(self, path, default):
        if not os.path.exists(path):
            return default
        try:
            with open(path) as f:
                data = json.load(f)
        except (OSError, ValueError) as e:
            raise RoutingError(f"unreadable routing state {path}: {e}")
        if not isinstance(data, dict) or data.get("schema") != SCHEMA:
            raise RoutingError(f"unsupported routing state schema in {path} (want {SCHEMA}); move the file aside to reset")
        return data

    def session_path(self, key):
        return os.path.join(self.root, "sessions", f"{key}.json")

    def load_session(self, key):
        return self._read_json(self.session_path(key), None)

    def save_session(self, session):
        self._write_json(self.session_path(session["key"]), session)

    def all_sessions(self):
        folder = os.path.join(self.root, "sessions")
        out = []
        for name in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
            if name.endswith(".json"):
                out.append(self._read_json(os.path.join(folder, name), None))
        return [s for s in out if s]

    def load_hosts(self):
        return self._read_json(os.path.join(self.root, "hosts.json"), {"schema": SCHEMA, "hosts": {}})

    def save_hosts(self, data):
        self._write_json(os.path.join(self.root, "hosts.json"), data)

    def audit(self, **event):
        path = os.path.join(self.root, "audit.jsonl")
        if os.path.exists(path) and os.path.getsize(path) > AUDIT_MAX_BYTES:
            os.replace(path, path + ".1")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(fd, "a") as f:
            f.write(json.dumps({"time": iso(now()), **event}, sort_keys=True) + "\n")


def capture_marker(root, key):
    return os.path.join(root, "sessions", f"{key}.capture-failed")


def global_capture_failure(root):
    """Written by route-hook-shim.sh when the router could not even start for a
    user message: which session it belonged to is unknown, so it applies to all."""
    try:
        return os.path.getmtime(os.path.join(root, "capture-failed-any"))
    except OSError:
        return None


def mark_global_capture_failure():
    try:
        os.makedirs(state_dir(), mode=0o700, exist_ok=True)
        os.close(os.open(os.path.join(state_dir(), "capture-failed-any"), os.O_WRONLY | os.O_CREAT, 0o600))
        os.utime(os.path.join(state_dir(), "capture-failed-any"))
    except OSError:
        pass


def capture_failed(root, session):
    if os.path.exists(capture_marker(root, session["key"])):
        return True
    failed_at = global_capture_failure(root)
    last = session["prompts"][-1]["time"] if session["prompts"] else 0
    return failed_at is not None and last <= failed_at


def mark_capture_started(root, key):
    """Lock-free, before anything that can fail: if capturing this user message
    fails, the marker survives and grants from before it are never usable."""
    os.makedirs(os.path.join(root, "sessions"), mode=0o700, exist_ok=True)
    fd = os.open(capture_marker(root, key), os.O_WRONLY | os.O_CREAT, 0o600)
    os.close(fd)


def session_key(host, session_id):
    return f"{host}-" + hashlib.sha256(f"{host}\0{session_id}".encode()).hexdigest()[:12]


def new_session(host, session_id):
    return {
        "schema": SCHEMA, "key": session_key(host, session_id), "host": host, "session_id": session_id,
        "epoch": 0, "prompts": [], "proposals": {}, "assignments": {}, "tool_uses": {}, "next": 1,
    }


def retire_grants(session, reason):
    count = 0
    for p in session["proposals"].values():
        if p["status"] == "granted":
            p["status"] = "retired"
            p["retired_reason"] = reason
            count += 1
    return count


def prune_session(session):
    proposals = session["proposals"]
    if len(proposals) > MAX_PROPOSALS:
        ordered = sorted(proposals.values(), key=lambda p: p["created"])
        for p in ordered[: len(proposals) - MAX_PROPOSALS]:
            if p["status"] != "granted":
                del proposals[p["id"]]
    uses = session["tool_uses"]
    if len(uses) > MAX_TOOL_USES:
        for k in sorted(uses, key=lambda k: uses[k]["time"])[: len(uses) - MAX_TOOL_USES]:
            del uses[k]
    # Exempt creates waiting for their PostToolUse; a failed or refused call never gets one.
    pending = session.get("readonly_uses", {})
    if len(pending) > MAX_TOOL_USES:
        for k in sorted(pending, key=pending.get)[: len(pending) - MAX_TOOL_USES]:
            del pending[k]


# ---------------------------------------------------------------- hook adapter

def detect_host(payload, requested):
    if requested in ("claude", "codex"):
        return requested
    # turn_id is a documented Codex-only payload field. Every registered hook
    # passes --host; this fallback only serves manual invocations.
    return "codex" if "turn_id" in payload else "claude"


def canonical_cwd(cwd):
    return os.path.realpath(cwd) if cwd else ""


def input_digest(tool_input):
    return hashlib.sha256(json.dumps(tool_input, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def pre_tool_output(decision, reason=None, updated_input=None):
    out = {"hookEventName": "PreToolUse", "permissionDecision": decision}
    if reason is not None:
        out["permissionDecisionReason"] = reason
    if updated_input is not None:
        out["updatedInput"] = updated_input
    return {"hookSpecificOutput": out}


ROUTE_LABELS = {"opencode": "OpenCode", "local": "you, locally", "native": "native", "none": "nobody"}


def route_preview(policy, authorization="none"):
    """What a record with no requested provider and no native reason routes to
    under this policy, per work kind: the same decide() the record will run, so
    the preview cannot drift from the decision."""
    parts = []
    for kind in WORK_KINDS:
        record = {"assignment": "preview", "work_kind": kind, "authorization": authorization, "requested_provider": "unspecified",
                  "native_reason": "", "scope_status": "clear"}
        route, _ = decide(policy, record)
        label = f"OpenCode {role_for(kind)}" if route == "opencode" else ROUTE_LABELS.get(route, route)
        parts.append(f"{kind} -> {label}")
    return ", ".join(parts)


def denial_text(proposal_id, operation, revision, policy):
    what = "create a native agent" if operation == "create" else "give an existing native agent more work"
    plain, asked = route_preview(policy), route_preview(policy, "user")
    routes = (f"Under policy {policy} that routes {plain}" if plain == asked else
              f"Under policy {policy}, if nobody asked for delegation, that routes {plain}; if the user or a skill "
              f"they invoked asked for it (see below), {asked}")
    return (
        f"opencode-subagent routing paused this call to {what} (proposal {proposal_id}). Record a decision in one "
        f"command, then follow the route it prints: `opencode-delegate route record --proposal {proposal_id} "
        f"--skill-revision {revision} --assignment SLUG --work-kind KIND --scope 'SCOPE'`, where KIND is "
        f"implementation, research or review and SCOPE says what the agent would do. {routes} (an assignment "
        "already routed to OpenCode stays there). "
        "Add --native-reason needs-host-tools only if the work needs tools only you have (MCP servers, the browser). "
        "If the user, or a skill they invoked, asked for delegation or named a provider, add --authorization user "
        "(or workflow, for a skill) --source-excerpt 'THEIR EXACT WORDS', and --requested-provider opencode or native "
        "if they named one. "
        "Route native: repeat this call once; the hook runs it exactly as first submitted. Any other route: do not "
        "repeat it. Never review your own work instead: if no reviewer can run, say no independent review ran. "
        "Details: the opencode-subagent skill."
    )


def handle_hook(payload, host_flag, store):
    """Return a JSON-serializable hook response, or None for no decision."""
    if not isinstance(payload, dict):
        raise RoutingError("hook payload is not a JSON object")
    event = payload.get("hook_event_name")
    host = detect_host(payload, host_flag)
    session_id = payload.get("session_id")

    if event == "PreToolUse" and payload.get("tool_name") not in WORK_TOOLS:
        return None
    if event == "PostToolUse":
        post_tool_use(payload, host, store)
        return None
    if event not in ("PreToolUse", "UserPromptSubmit", "SessionStart"):
        return None
    if not isinstance(session_id, str) or not session_id:
        raise RoutingError("hook payload has no session_id")
    key = session_key(host, session_id)
    if event == "UserPromptSubmit":
        mark_capture_started(store.root, key)

    with store:
        observe_host(store, host, event)
        session = store.load_session(key) or new_session(host, session_id)

        if event == "UserPromptSubmit":
            prompt = payload.get("prompt")
            if not isinstance(prompt, str):
                raise RoutingError("UserPromptSubmit payload has no prompt")
            # Duplicate registrations deliver one message twice; count it once.
            # turn_id names a turn, not a message, so the text is part of the key;
            # grants are retired either way.
            delivery_id = payload.get("prompt_id") or payload.get("turn_id")
            delivery = f"{delivery_id}:{hashlib.sha256(prompt.encode()).hexdigest()[:16]}" if delivery_id else None
            last = session["prompts"][-1] if session["prompts"] else None
            if delivery and last and last.get("delivery") == delivery:
                retire_grants(session, "new user input")
                last["time"] = now()
                store.save_session(session)
                os.unlink(capture_marker(store.root, key))
                return None
            session["epoch"] += 1
            session["prompts"].append({
                "epoch": session["epoch"], "time": now(),
                "text": prompt[:MAX_PROMPT_CHARS], "truncated": len(prompt) > MAX_PROMPT_CHARS,
                "delivery": delivery,
            })
            session["prompts"] = session["prompts"][-MAX_PROMPTS:]
            retired = retire_grants(session, "new user input")
            store.save_session(session)
            os.unlink(capture_marker(store.root, key))
            store.audit(event="user_input", session=key, epoch=session["epoch"], retired_grants=retired)
            return None

        if event == "SessionStart":
            source = payload.get("source", "")
            if source != "startup":
                retired = retire_grants(session, f"session {source or 'restart'}")
                store.save_session(session)
                store.audit(event="session_start", session=key, source=source, retired_grants=retired)
            return None

        return pre_tool_use(payload, host, session, store)


def pre_tool_use(payload, host, session, store):
    key = session["key"]
    tool = payload["tool_name"]
    tool_input = payload.get("tool_input")
    tool_use_id = payload.get("tool_use_id") if isinstance(payload.get("tool_use_id"), str) else ""
    if not isinstance(tool_input, dict):
        raise RoutingError(f"{tool} payload has no tool_input object")

    # The same host tool call delivered twice (duplicate registration, host
    # retry) gets the same answer instead of a second proposal or consumption.
    if tool_use_id and tool_use_id in session["tool_uses"]:
        seen = session["tool_uses"][tool_use_id]
        store.audit(event="duplicate_delivery", session=key, tool_use_id=tool_use_id, result=seen["output"]["hookSpecificOutput"]["permissionDecision"])
        return seen["output"]

    policy = read_policy()
    operation, target_field = WORK_TOOLS[tool]
    target = None
    if operation == "continue":
        fields = (target_field,) + TARGET_FALLBACKS
        target = next((tool_input[f] for f in fields if isinstance(tool_input.get(f), str) and tool_input[f]), None)
        if target is None:
            raise RoutingError(f"{tool} call names no target agent")
    if not isinstance(payload.get("cwd"), str) or not payload["cwd"]:
        raise RoutingError(f"{tool} payload has no cwd, so the call cannot be bound to a worktree")
    cwd = canonical_cwd(payload["cwd"])
    # Children run in the parent's session; a grant belongs to the agent that asked.
    agent = payload.get("agent_id") if isinstance(payload.get("agent_id"), str) else ""
    runtime = runtime_identity()

    def remember(output, proposal_id):
        if tool_use_id:
            session["tool_uses"][tool_use_id] = {"time": now(), "proposal": proposal_id, "output": output}
        prune_session(session)
        store.save_session(session)
        return output

    if policy == "off":
        output = pre_tool_output("deny", "Native delegation is disabled: the delegation policy is off. "
                                 "Do the work yourself; only the user can change it (opencode-delegate policy explicit). "
                                 + REVIEW_NOTE)
        store.audit(event="deny", session=key, tool=tool, reason="policy_off")
        return remember(output, None)

    # Read-only agent types run untouched: no proposal, no grant, nothing to
    # replay. This comes before grant matching, or an open grant for another
    # Agent call would be spent replaying that call in place of this one.
    # Follow-up messages to a read-only agent pass too, by id: routing them
    # elsewhere would throw away the context it built. The id is remembered
    # only once the host ran the exempted call (post_tool_use).
    exempt_create = is_readonly_agent(tool, operation, tool_input, readonly_agents())
    session.pop("readonly_agents", None)  # names remembered before follow-ups went id-only
    if operation == "create" and not exempt_create:
        forget_readonly_id(session, tool_input.get("name"))
    if host == "claude" and (exempt_create or readonly_follow_up(tool, tool_input, session)):
        if exempt_create and tool_use_id:
            session.setdefault("readonly_uses", {})[tool_use_id] = now()
        store.audit(event="allow_readonly", session=key, tool=tool,
                    subagent_type=tool_input.get("subagent_type"), target=target)
        prune_session(session)
        store.save_session(session)
        return None

    if capture_failed(store.root, session):
        retired = retire_grants(session, "user input capture failed")
        output = pre_tool_output("deny", "opencode-subagent routing failed to capture the latest user message, so no "
                                 "delegation decision can be trusted. Work locally, or ask the user to send their "
                                 "request again; run opencode-delegate route doctor if this repeats. " + REVIEW_NOTE)
        store.audit(event="deny", session=key, tool=tool, reason="capture_failed", retired_grants=retired)
        return remember(output, None)

    if session["epoch"] == 0:
        output = pre_tool_output("deny", "opencode-subagent routing has no captured user input for this session "
                                 "(hooks became active mid-session). Work locally, or ask the user to restate the "
                                 "delegation request in a new message so a decision can be recorded. " + REVIEW_NOTE)
        store.audit(event="deny", session=key, tool=tool, reason="no_epoch")
        return remember(output, None)

    matches = [
        p for p in session["proposals"].values()
        if p["status"] == "granted" and p["operation"] == operation and p["cwd"] == cwd
        and p["target"] == target and p["tool_name"] == tool and p.get("agent", "") == agent
    ]
    usable = []
    for p in matches:
        g = p["grant"]
        stale = (
            "user input changed" if g["epoch"] != session["epoch"] else
            "policy changed" if g["policy"] != policy else
            "routing runtime changed" if g["runtime"] != runtime else
            "grant expired" if g["expires"] < now() else None
        )
        if stale:
            p["status"] = "retired"
            p["retired_reason"] = stale
        else:
            usable.append(p)

    if usable:
        # Several open grants for the same kind of call (parallel Agent calls):
        # prefer the one whose input is identical, else the oldest. Each replays
        # its own recorded input, so any choice runs only decided work.
        digest = input_digest(tool_input)
        usable.sort(key=lambda p: (p["digest"] != digest, p["created"]))
        p = usable[0]
        p["status"] = "consumed"
        forget_readonly_id(session, p["tool_input"].get("name"))  # the replayed input is what runs
        p["consumed"] = {"time": now(), "tool_use_id": tool_use_id, "input_matched": input_digest(tool_input) == p["digest"]}
        # Only the probe-verified output shape: no reason alongside updatedInput.
        output = pre_tool_output("allow", updated_input=p["tool_input"])
        store.audit(event="allow", session=key, proposal=p["id"], tool=tool, input_matched=p["consumed"]["input_matched"])
        return remember(output, p["id"])
    proposal_id = f"{key}-{session['next']}"
    session["next"] += 1
    session["proposals"][proposal_id] = {
        "id": proposal_id, "status": "pending", "created": now(), "host": host, "session": key,
        "cwd": cwd, "agent": agent, "epoch": session["epoch"], "operation": operation, "tool_name": tool, "target": target,
        "tool_input": tool_input, "digest": input_digest(tool_input), "tool_use_id": tool_use_id,
        "runtime": runtime, "runtime_path": self_path(),
        "transcript_path": payload.get("transcript_path") if isinstance(payload.get("transcript_path"), str) else "",
    }
    output = pre_tool_output("deny", denial_text(proposal_id, operation, skill_revision(), policy))
    store.audit(event="deny", session=key, proposal=proposal_id, tool=tool, reason="needs_decision")
    return remember(output, proposal_id)


def forget_readonly_id(session, name):
    """A possibly writing agent named like a read-only agent's id: the string
    could now resolve to the writer, so it stops being an exempt target."""
    ids = session.get("readonly_ids", [])
    if isinstance(name, str) and name in ids:
        ids.remove(name)


def readonly_follow_up(tool, tool_input, session):
    """A plain SendMessage to a remembered read-only agent, addressed by id: the
    host sets recipient_kind "agent" for an id (verified live, 2.1.296). Every
    target field present must name that same agent."""
    if tool != "SendMessage" or tool_input.get("recipient_kind") != "agent":
        return False
    if tool_input.get("type") not in (None, "message"):
        return False
    values = [tool_input[f] for f in ("to",) + TARGET_FALLBACKS if f in tool_input]
    if not values or not all(isinstance(v, str) for v in values) or len(set(values)) != 1:
        return False
    return values[0] in session.get("readonly_ids", [])


def post_tool_use(payload, host, store):
    """Remember the id of an agent the PreToolUse hook exempted, so a follow-up
    to it passes. Never answers the host: PostToolUse cannot undo the
    call, and a broken hook must stay silent here."""
    tool = payload.get("tool_name")
    session_id = payload.get("session_id")
    tool_use_id = payload.get("tool_use_id")
    if host != "claude" or tool not in READONLY_CREATE_TOOLS or not isinstance(session_id, str) or not session_id:
        return
    if not isinstance(tool_use_id, str) or not tool_use_id:
        return
    key = session_key(host, session_id)
    # Every Agent call reaches here: look without the lock first, so unrelated
    # ones never contend with PreToolUse hooks in other sessions.
    try:
        peek = store.load_session(key)
    except RoutingError:
        return
    if not peek or tool_use_id not in peek.get("readonly_uses", {}):
        return
    try:
        with store:
            observe_host(store, host, "PostToolUse")  # doctor's evidence that this hook fires
            session = store.load_session(key)
            if not session or session.get("readonly_uses", {}).pop(tool_use_id, None) is None:
                return
            tool_input = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
            response = payload.get("tool_response") if isinstance(payload.get("tool_response"), dict) else {}
            agent_id = response.get("agentId")
            ran = response.get("agentType", tool_input.get("subagent_type"))
            # Re-check what ran: another PreToolUse hook may have rewritten the input.
            if not (is_readonly_agent(tool, "create", tool_input, readonly_agents())
                    and ran == tool_input.get("subagent_type")):
                store.audit(event="readonly_not_registered", session=key, tool_use_id=tool_use_id, reason="type changed")
                store.save_session(session)
                return
            if isinstance(agent_id, str) and AGENT_ID_RE.fullmatch(agent_id):
                ids = session.setdefault("readonly_ids", [])
                if agent_id in ids:
                    ids.remove(agent_id)
                ids.append(agent_id)
                del ids[:-MAX_READONLY_AGENTS]
                store.audit(event="readonly_registered", session=key, tool_use_id=tool_use_id, agent=agent_id)
            store.save_session(session)
    except RoutingError as e:
        store.audit(event="readonly_register_failed", session=key, tool_use_id=tool_use_id, error=str(e))


def observe_host(store, host, event):
    data = store.load_hosts()
    entry = data["hosts"].setdefault(host, {"events": 0})
    entry.update({"last_event": event, "last_seen": now(), "runtime": runtime_identity(), "runtime_path": self_path()})
    entry.setdefault("seen", {})[event] = now()
    entry["events"] += 1
    store.save_hosts(data)


def run_hook(host_flag, stdin_text, store=None):
    """Never raises. A recognized delegation call that cannot be routed is
    denied; anything else is left to the host."""
    store = store or Store()
    try:
        payload = json.loads(stdin_text)
    except Exception:  # noqa: BLE001 - ValueError, RecursionError on hostile nesting
        return failure_output(stdin_text, "hook input is not valid JSON")
    try:
        output = handle_hook(payload, host_flag, store)
    except Exception as e:  # noqa: BLE001 - every failure must still answer the host
        output = failure_output(payload, f"{type(e).__name__}: {e}" if not isinstance(e, RoutingError) else str(e))
    # Only a PreToolUse ever gets an answer, whatever a branch above returns.
    return output if isinstance(payload, dict) and payload.get("hook_event_name") == "PreToolUse" else None


# The event key as JSON writes it. Its quotes are bare, so it cannot come from
# inside a string value; a value that is just an event name ("PostToolUse")
# can, which is why the bare word is never matched.
PRE_TOOL_USE_KEY = re.compile(r'"hook_event_name"\s*:\s*"PreToolUse"')
USER_INPUT_KEY = re.compile(r'"hook_event_name"\s*:\s*"(UserPromptSubmit|SessionStart)"')


def failure_output(payload, message):
    if isinstance(payload, dict):
        if payload.get("hook_event_name") != "PreToolUse" or payload.get("tool_name") not in WORK_TOOLS:
            return None
    elif not any(f'"{name}"' in payload for name in WORK_TOOLS) or not PRE_TOOL_USE_KEY.search(payload):
        return None
    return pre_tool_output("deny", f"opencode-subagent routing could not evaluate this delegation call: {message}. "
                           "Native delegation stays blocked until this is fixed (opencode-delegate route doctor); "
                           "work locally meanwhile. " + REVIEW_NOTE)


# ---------------------------------------------------------------- record

def find_proposal(store, proposal_id):
    key = proposal_id.rsplit("-", 1)[0] if "-" in proposal_id else ""
    session = store.load_session(key) if re.fullmatch(r"(claude|codex)-[0-9a-f]{12}", key) else None
    if not session or proposal_id not in session["proposals"]:
        raise RoutingError(f"unknown proposal {proposal_id}; repeat the native call to get a new one")
    return session, session["proposals"][proposal_id]


def excerpt_epoch(session, excerpt, max_epoch):
    wanted = normalize_text(excerpt)
    epochs = [p["epoch"] for p in session["prompts"] if p["epoch"] <= max_epoch and wanted in normalize_text(p["text"])]
    return max(epochs) if epochs else None


WORKFLOW_FILES = ("AGENTS.md", "CLAUDE.md", "GEMINI.md", "SKILL.md")


def check_workflow_file(path, cwd):
    """A workflow source must be a committed, unmodified file of the repository
    the delegation happens in; an arbitrary readable file authorizes nothing."""
    if os.path.basename(path) not in WORKFLOW_FILES:
        raise RoutingError(f"--workflow-file must be an agent instruction file ({', '.join(WORKFLOW_FILES)})")

    def git(*argv):
        return subprocess.run(["git", "-C", cwd, *argv], capture_output=True, text=True, timeout=10)
    try:
        top = git("rev-parse", "--show-toplevel")
    except (OSError, subprocess.SubprocessError) as e:
        raise RoutingError(f"--workflow-file needs git to verify the file: {e}")
    if top.returncode != 0:
        raise RoutingError("--workflow-file needs the delegation worktree to be a git repository")
    root = os.path.realpath(top.stdout.strip())
    if os.path.commonpath([root, path]) != root:
        raise RoutingError(f"--workflow-file must be inside the repository {root}")
    if git("ls-files", "--error-unmatch", "--", path).returncode != 0:
        raise RoutingError(f"--workflow-file {path} is not tracked by git")
    if git("diff", "--quiet", "HEAD", "--", path).returncode != 0:
        raise RoutingError(f"--workflow-file {path} has uncommitted changes")


def loaded_skill_with(proposal, excerpt):
    """The base directory of a skill the user invoked in this session whose body
    contains the excerpt, or None.

    Claude Code injects an invoked skill's body as a meta user row, which
    UserPromptSubmit never sees. Only a skill the user typed counts: a skill the
    model loaded through the Skill tool carries a sourceToolUseID, and quoting
    it would be the model authorizing itself. The same goes for this skill's
    own body, which the denial tells the model to load, and for a skill inside
    the delegation repository that is not committed unmodified (the model can
    write that one). Tool results are user rows too, but never meta text rows.
    """
    path = proposal.get("transcript_path") or ""
    if proposal.get("host") != "claude" or not path or not os.path.isfile(path):
        return None
    wanted = normalize_text(excerpt)
    read = 0
    with open(path, "rb") as f:
        for line in f:
            read += len(line)
            if read > TRANSCRIPT_SCAN_CAP:
                raise RoutingError(f"the session transcript is larger than {TRANSCRIPT_SCAN_CAP >> 20} MB, so invoked "
                                   "skills cannot be checked; quote a committed instruction file with --workflow-file")
            if b"isMeta" not in line or SKILL_BODY_PREFIX.encode() not in line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if (not isinstance(row, dict) or row.get("type") != "user" or row.get("isMeta") is not True
                    or row.get("sourceToolUseID") or row.get("isSidechain")):
                continue
            content = (row.get("message") or {}).get("content")
            texts = [content] if isinstance(content, str) else [
                b.get("text", "") for b in content or [] if isinstance(b, dict) and b.get("type") == "text"]
            for text in texts:
                if not (isinstance(text, str) and text.startswith(SKILL_BODY_PREFIX) and wanted in normalize_text(text)):
                    continue
                skill = os.path.realpath(text[len(SKILL_BODY_PREFIX):].split("\n", 1)[0].strip())
                if os.path.basename(skill) == "opencode-subagent" or not trusted_skill(skill, proposal["cwd"]):
                    continue
                return skill
    return None


def trusted_skill(skill, cwd):
    """A skill outside the delegation repository is the user's install; one
    inside it must be committed unmodified, like any workflow file."""
    try:
        top = subprocess.run(["git", "-C", cwd, "rev-parse", "--show-toplevel"], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return False
    if top.returncode != 0:
        return True
    root = os.path.realpath(top.stdout.strip())
    if os.path.commonpath([root, skill]) != root:
        return True
    try:
        check_workflow_file(os.path.join(skill, "SKILL.md"), cwd)
    except RoutingError:
        return False
    return True


def subagents_state_dir():
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, "workflow-skills", "subagents")


def check_failed_task(task_id, cwd, since):
    """--native-reason opencode-failed must point at an OpenCode Task that ran
    in this worktree after the assignment was routed to OpenCode, and failed."""
    path = os.path.join(subagents_state_dir(), task_id, "task.json")
    try:
        with open(path) as f:
            task = json.load(f)
    except (OSError, ValueError):
        raise RoutingError(f"--opencode-task {task_id} is not an OpenCode Task (no readable {path})")
    if not isinstance(task, dict):
        raise RoutingError(f"--opencode-task {task_id}: unreadable task.json")
    if not task.get("cwd") or os.path.realpath(task["cwd"]) != cwd:
        raise RoutingError(f"--opencode-task {task_id} ran in {task.get('cwd')}, not in this worktree")
    created = task.get("created_at") or ""
    try:
        created_ts = datetime.datetime.strptime(created, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()
    except ValueError:
        raise RoutingError(f"--opencode-task {task_id} has no creation time")
    if created_ts + 1 < since:
        raise RoutingError(f"--opencode-task {task_id} predates this assignment's OpenCode routing")
    if task.get("agent") != "workflow-researcher":
        raise RoutingError(f"--opencode-task {task_id} is not a researcher Task; research and review run on the "
                           "OpenCode researcher (start --role researcher)")
    outcome = task.get("outcome") or {}
    if outcome.get("transport") not in RAN_TRANSPORTS:
        raise RoutingError(f"--opencode-task {task_id} never ran (transport {outcome.get('transport')})")
    state = task.get("state")
    failed = (outcome.get("worker") in FAILED_WORKER_OUTCOMES or bool(task.get("failure_class"))
              or state == "rejected")
    if not failed:
        raise RoutingError(f"--opencode-task {task_id} did not fail (state {state}, worker {outcome.get('worker')}, "
                           "no failure class); verify and decide it first")


def record_decision(args, store=None):
    store = store or Store()
    record = validate_record(args)
    revision = skill_revision()
    if record["skill_revision"] != revision:
        raise RoutingError(f"--skill-revision {record['skill_revision']} is not the current opencode-subagent skill "
                           f"revision ({revision}); reload the skill and follow its routing procedure")
    policy = read_policy()
    runtime = runtime_identity()
    with store:
        session, proposal = find_proposal(store, record["proposal"])
        if proposal["status"] != "pending":
            raise RoutingError(f"proposal {proposal['id']} is already {proposal['status']}; repeat the native call to get a new proposal")
        if proposal["runtime"] != runtime:
            raise RoutingError(
                f"routing runtime mismatch: the hook ran {proposal['runtime']} ({proposal['runtime_path']}) but this "
                f"command is {runtime} ({self_path()}). Update opencode-delegate on PATH to the same install as the hooks.")
        if capture_failed(store.root, session):
            raise RoutingError("the latest user message was not captured; ask the user to send the request again")
        if proposal["epoch"] != session["epoch"]:
            proposal["status"] = "retired"
            proposal["retired_reason"] = "user input changed before the decision"
            store.save_session(session)
            raise RoutingError(f"proposal {proposal['id']} predates the latest user message; repeat the native call to get a new proposal")

        source = {}
        epoch_of_excerpt = None
        if record["authorization"] == "user":
            epoch_of_excerpt = excerpt_epoch(session, record["source_excerpt"], proposal["epoch"])
            if epoch_of_excerpt is None:
                raise RoutingError("--source-excerpt does not appear in any captured user message of this session; "
                                   "quote the user's words verbatim")
            source = {"kind": "user", "epoch": epoch_of_excerpt}
        elif record["authorization"] == "workflow" and not record["workflow_file"]:
            skill = loaded_skill_with(proposal, record["source_excerpt"])
            if skill is None:
                raise RoutingError("--source-excerpt does not appear in any skill the user invoked in this session "
                                   "(Claude Code only; skills you loaded yourself do not count); quote the skill's "
                                   "words verbatim, or name a committed instruction file with --workflow-file")
            source = {"kind": "skill", "skill": skill, "transcript": proposal["transcript_path"]}
        elif record["authorization"] == "workflow":
            path = os.path.realpath(os.path.join(proposal["cwd"], record["workflow_file"]))
            check_workflow_file(path, proposal["cwd"])
            try:
                with open(path, encoding="utf-8", errors="replace") as f:
                    content = f.read()
            except OSError as e:
                raise RoutingError(f"--workflow-file unreadable: {e}")
            if normalize_text(record["source_excerpt"]) not in normalize_text(content):
                raise RoutingError(f"--source-excerpt does not appear in {path}")
            source = {"kind": "workflow", "path": path, "sha256": file_digest(path, 64)}

        prior = session["assignments"].get(record["assignment"])
        failed_task = None
        if record["native_reason"] == "opencode-failed" and prior and prior.get("provider") == "opencode":
            failed_task = record["opencode_task"]
            if failed_task in session.setdefault("spent_failed_tasks", []):
                raise RoutingError(f"--opencode-task {failed_task} already justified a native route; one failed "
                                   "Task unlocks one assignment once")
            check_failed_task(failed_task, proposal["cwd"], prior["time"])
        route, reason = decide(policy, record, prior, epoch_of_excerpt)
        stored = {k: v for k, v in record.items() if k != "proposal"}
        stored["source_excerpt"] = record["source_excerpt"][:500]
        store.audit(event="record", session=session["key"], proposal=proposal["id"], route=route, reason=reason,
                    assignment=record["assignment"], work_kind=record["work_kind"], authorization=record["authorization"])
        if route == "invalid":
            raise RoutingError(reason)

        proposal["decision"] = {"time": now(), "route": route, "reason": reason, "policy": policy,
                                "record": stored, "source": source}
        if route == "native" and failed_task:
            session["spent_failed_tasks"].append(failed_task)
            del session["spent_failed_tasks"][:-MAX_PROPOSALS]
        if route == "native":
            proposal["status"] = "granted"
            proposal["grant"] = {"epoch": session["epoch"], "policy": policy, "runtime": runtime,
                                 "expires": now() + GRANT_TTL_SECONDS}
        else:
            proposal["status"] = "routed"
        # An assignment keeps the epoch it first got its provider: re-affirming
        # OpenCode must not push the "later user override" bar forward.
        if route in ("native", "opencode") and not (prior and prior.get("provider") == route):
            session["assignments"][record["assignment"]] = {
                "provider": route, "epoch": proposal["epoch"], "proposal": proposal["id"], "time": now()}
        store.save_session(session)
        result = {"proposal": proposal["id"], "route": route, "reason": reason,
                  "next": next_step(route, record["work_kind"], proposal["cwd"])}
        if route == "opencode":
            result["role"] = role_for(record["work_kind"])
        return result


def next_step(route, kind, cwd):
    role = role_for(kind)
    review = kind == "review"
    return {
        "native": f"Repeat the native call once within {GRANT_TTL_SECONDS // 60} minutes, from the same worktree and "
                  "before the next user message. The hook runs the proposal exactly as first submitted.",
        "opencode": "Do not repeat the native call. Delegate it to the OpenCode " + role + ", then wait and check the "
                    f"report: opencode-delegate start --role {role} --cwd {shlex_quote(cwd)} 'TASK SPEC'" +
                    (". If the launch itself fails (no model configured, OpenCode missing), tell the user no "
                     "independent review ran; do not review your own work." if review else ""),
        "local": "Do not repeat the native call. Do the work yourself.",
        "none": ("Do not repeat the native call. Delegation is off, so no independent review can run: do not review "
                 "your own work, and tell the user no review ran.") if review else
                "Do not repeat the native call. Do the work yourself; delegation is off.",
        "clarify": "Do not repeat the native call. Ask the user to resolve the scope" +
                   (" before the review runs." if review else ", or work locally."),
    }[route]


def shlex_quote(text):
    return text if re.fullmatch(r"[A-Za-z0-9_./=:@,+-]+", text) else "'" + text.replace("'", "'\\''") + "'"


# ---------------------------------------------------------------- show / doctor

def describe_proposal(p):
    brief = {}
    for k, v in p["tool_input"].items():
        text = v if isinstance(v, str) else json.dumps(v)
        brief[k] = text if len(text) <= 160 else text[:157] + "..."
    out = {
        "proposal": p["id"], "status": p["status"], "created": iso(p["created"]), "operation": p["operation"],
        "tool": p["tool_name"], "target": p["target"], "cwd": p["cwd"], "epoch": p["epoch"], "input": brief,
    }
    for extra in ("decision", "retired_reason"):
        if extra in p:
            out[extra] = p[extra]
    if "grant" in p:
        out["grant_expires"] = iso(p["grant"]["expires"])
    return out


def show(proposal_id, store=None):
    store = store or Store()
    with store:
        if proposal_id:
            _, p = find_proposal(store, proposal_id)
            result = describe_proposal(p)
        else:
            pending = [p for s in store.all_sessions() for p in s["proposals"].values() if p["status"] in ("pending", "granted")]
            pending.sort(key=lambda p: p["created"], reverse=True)
            result = {"open_proposals": [describe_proposal(p) for p in pending[:10]]}
    result["skill_revision"] = skill_revision()
    try:
        result["policy"] = read_policy()
    except RoutingError as e:
        result["policy_error"] = str(e)
    result["record_fields"] = {
        "--assignment": "slug naming this piece of work (reuse it for the same work later)",
        "--scope": "what the assigned work is",
        "--work-kind": "|".join(WORK_KINDS),
        "--authorization": "none (default) | user (quote the user) | workflow (quote a skill loaded in this session, "
                           "or a committed instruction file with --workflow-file)",
        "--source-excerpt": f"verbatim quote, at least {MIN_EXCERPT_CHARS} characters",
        "--workflow-file": "committed AGENTS.md/CLAUDE.md/GEMINI.md/SKILL.md, with --authorization workflow",
        "--requested-provider": "|".join(PROVIDERS) + " (default unspecified)",
        "--native-reason": "|".join(NATIVE_REASONS) + " (research/review only; otherwise they go to the OpenCode researcher)",
        "--opencode-task": "the failed OpenCode Task, with --native-reason opencode-failed",
        "--scope-status": "|".join(SCOPE_STATUSES) + " (default clear)",
        "--skill-revision": result["skill_revision"],
    }
    return result


def host_registrations(home):
    """Which hook registrations exist, by host. Only reads files."""
    found = {"claude": [], "codex": []}

    def scan(path, host, label):
        try:
            with open(path, encoding="utf-8") as f:
                text = f.read()
        except OSError:
            return
        # Local installs invoke the router through route-hook-shim.sh, marked
        # workflow-skills-routing. `route hook` matches older direct registrations.
        ours = lambda c: "route hook" in c or ("route-hook-shim.sh" in c and "workflow-skills-routing" in c)
        if label == "plugin":  # plugin commands carry no marker
            ours = lambda c: "route-hook-shim.sh" in c or "route hook" in c
        if ours(text):
            events = set()
            try:
                for event, groups in json.loads(text).get("hooks", {}).items():
                    if any(ours(h.get("command", "")) for g in groups for h in g.get("hooks", [])):
                        events.add(event)
            except (ValueError, AttributeError, TypeError):
                pass
            found[host].append({"source": label, "path": path, "mtime": os.path.getmtime(path),
                                "missing_events": [e for e in HOOK_EVENTS[host] if e not in events]})

    scan(os.path.join(home, ".claude", "settings.json"), "claude", "local")
    scan(os.path.join(home, ".codex", "hooks.json"), "codex", "local")
    try:
        with open(os.path.join(home, ".claude", "plugins", "installed_plugins.json")) as f:
            plugins = json.load(f).get("plugins", {})
        for name, installs in plugins.items():
            if name.startswith("workflow-skills@"):
                for inst in installs:
                    scan(os.path.join(inst.get("installPath", ""), "hooks", "hooks.json"), "claude", "plugin")
    except (OSError, ValueError, AttributeError):
        pass
    try:
        with open(os.path.join(home, ".codex", "config.toml"), encoding="utf-8") as f:
            if re.search(r'^\[plugins\."workflow-skills@', f.read(), re.M):
                found["codex"].append({"source": "plugin", "path": os.path.join(home, ".codex", "config.toml"), "mtime": 0})
    except OSError:
        pass
    return found


def doctor(store=None, home=None):
    store = store or Store()
    home = home or os.path.expanduser("~")
    report = {
        "runtime": {"path": self_path(), "identity": runtime_identity(), "python": sys.executable,
                    "python_version": ".".join(map(str, sys.version_info[:3]))},
        "skill_revision": skill_revision(), "conf_file": conf_file(), "state_dir": store.root, "problems": [],
    }
    try:
        report["policy"] = read_policy()
    except RoutingError as e:
        report["problems"].append(str(e))

    command = shutil.which("opencode-delegate")
    cmd = {"path": command}
    if not command:
        cmd["status"] = "missing"
        report["problems"].append("opencode-delegate is not on PATH: supervisors cannot record decisions (run scripts/install.sh)")
    else:
        try:
            out = subprocess.run([command, "route", "identity"], capture_output=True, text=True, timeout=10)
            if out.returncode != 0:
                raise ValueError((out.stderr.strip().splitlines() or ["no output"])[-1] + " (an install without routing?)")
            ident = json.loads(out.stdout)
            cmd.update(resolved=ident["path"], identity=ident["identity"])
            cmd["status"] = "match" if ident["identity"] == report["runtime"]["identity"] else "mismatch"
            if cmd["status"] == "mismatch":
                report["problems"].append(f"opencode-delegate on PATH runs a different routing runtime ({ident['path']}); "
                                          "decisions recorded through it will be refused")
        except (OSError, ValueError, KeyError, subprocess.SubprocessError) as e:
            cmd["status"] = "broken"
            report["problems"].append(f"opencode-delegate on PATH does not run `route identity`: {e}")
    report["command"] = cmd

    try:
        with store:
            observed = store.load_hosts()["hosts"]
    except RoutingError as e:
        observed = {}
        report["problems"].append(str(e))
    registrations = host_registrations(home)
    hosts = {}
    for host, regs in registrations.items():
        seen = observed.get(host)
        newest_config = max((r["mtime"] for r in regs), default=0)
        if not regs:
            status = "not-installed"
        elif seen and seen["runtime"] == report["runtime"]["identity"] and seen["last_seen"] >= newest_config:
            status = "active-observed"
        else:
            status = "installed-unverified"
        entry = {"status": status, "registrations": regs, "support": SUPPORT_MATRIX[host]}
        if seen:
            entry["last_seen"] = iso(seen["last_seen"])
            entry["last_event"] = seen["last_event"]
            entry["events_seen"] = {e: iso(t) for e, t in sorted(seen.get("seen", {}).items())}
        for r in regs:
            if r.get("missing_events"):
                fix = "re-run scripts/install.sh" if r["source"] == "local" else "update the plugin"
                report["problems"].append(f"{host}: the {r['source']} hook registration lacks "
                                          f"{', '.join(r['missing_events'])}; {fix}")
        if len(regs) > 1:
            report["problems"].append(f"{host}: {len(regs)} hook registrations ({', '.join(r['source'] for r in regs)}); keep one")
        hosts[host] = entry
    report["hosts"] = hosts
    return report


# ---------------------------------------------------------------- CLI

def print_human(data, indent=0):
    pad = "  " * indent
    for k, v in data.items():
        if isinstance(v, dict):
            print(f"{pad}{k}:")
            print_human(v, indent + 1)
        elif isinstance(v, list) and v and all(isinstance(x, dict) for x in v):
            print(f"{pad}{k}:")
            for item in v:
                print(f"{pad}  -")
                print_human(item, indent + 2)
        else:
            print(f"{pad}{k}: {v if not isinstance(v, list) else ', '.join(map(str, v)) or '(none)'}")


def main(argv):
    parser = argparse.ArgumentParser(prog="opencode-delegate route", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="op", required=True)
    hook = sub.add_parser("hook")
    hook.add_argument("--host", choices=("auto", "claude", "codex"), default="auto")
    rec = sub.add_parser("record")
    for name in ("proposal", "assignment", "scope", "work-kind", "authorization", "source-excerpt",
                 "workflow-file", "requested-provider", "native-reason", "opencode-task", "scope-status", "skill-revision"):
        rec.add_argument(f"--{name}")
    rec.add_argument("--json", action="store_true")
    sh = sub.add_parser("show")
    sh.add_argument("proposal", nargs="?")
    sh.add_argument("--json", action="store_true")
    doc = sub.add_parser("doctor")
    doc.add_argument("--json", action="store_true")
    sub.add_parser("identity")
    args = parser.parse_args(argv)

    if args.op == "hook":
        deny = pre_tool_output("deny", "opencode-subagent routing could not read the hook input; native "
                               "delegation stays blocked. " + REVIEW_NOTE)
        try:
            raw = sys.stdin.buffer.read()
        except Exception:  # noqa: BLE001 - nothing to tell the event by: fail closed
            raw, output = None, deny
        if raw is not None:
            try:
                output = run_hook(args.host, raw.decode("utf-8"))
            except Exception:  # noqa: BLE001 - e.g. undecodable stdin; never exit non-zero from a hook
                text = raw.decode("utf-8", "replace")
                output = deny if PRE_TOOL_USE_KEY.search(text) else None
                if output is None and USER_INPUT_KEY.search(text):
                    mark_global_capture_failure()  # as route-hook-shim.sh does when the router cannot start
        if output is not None:
            print(json.dumps(output))
        return 0
    if args.op == "identity":
        print(json.dumps({"identity": runtime_identity(), "path": self_path(), "schema": SCHEMA}))
        return 0
    try:
        if args.op == "record":
            result = record_decision(args)
        elif args.op == "show":
            result = show(args.proposal)
        else:
            result = doctor()
    except RoutingError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print_human(result)
    if args.op == "doctor" and result["problems"]:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
