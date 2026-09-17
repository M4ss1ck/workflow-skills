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

def read_policy(path=None):
    """Same semantics as delegate.sh resolve_policy: the last `KEY=` line wins,
    the value is the rest of the line verbatim, empty or absent means explicit,
    anything else is an error."""
    path = path or conf_file()
    value = ""
    if os.path.isfile(path):
        with open(path, "rb") as f:
            for raw in f.read().split(b"\n"):
                line = raw.decode("utf-8", "surrogateescape")
                if line.startswith(POLICY_KEY + "="):
                    value = line[len(POLICY_KEY) + 1:]
    value = value or DEFAULT_POLICY
    if value not in POLICIES:
        raise RoutingError(f"invalid {POLICY_KEY} in {path}: {value} (want off|explicit|auto)")
    return value


# ---------------------------------------------------------------- pure decision

def decide(policy, record, prior_assignment=None, excerpt_epoch=None):
    """Compute a route from recorded fields. Returns (route, reason).

    route is one of: native, opencode, local, none, clarify, invalid.
    `prior_assignment` is the stored assignment with the same name, if any.
    `excerpt_epoch` is the latest user-input epoch containing the source excerpt.
    """
    if policy == "off":
        return "none", "delegation policy is off; the user can enable it with: opencode-delegate policy explicit"
    if record["scope_status"] != "clear":
        return "clarify", f"scope is {record['scope_status']}; ask the user to resolve it or work locally"

    authorized_by_source = record["authorization"] in ("user", "workflow")
    requested = record["requested_provider"]
    kind = record["work_kind"]

    if prior_assignment and prior_assignment.get("provider") == "opencode":
        later_user_override = (
            requested == "native"
            and record["authorization"] == "user"
            and excerpt_epoch is not None
            and excerpt_epoch > prior_assignment["epoch"]
        )
        if not later_user_override:
            return "opencode", (
                f"assignment {record['assignment']} is recorded as OpenCode work; a native substitute "
                "needs a later explicit user instruction for native delegation"
            )
        return "native", "later explicit user override of an OpenCode assignment"

    if requested == "opencode":
        return "opencode", "explicit OpenCode assignment"
    if requested == "native" and record["authorization"] == "user":
        return "native", "explicit user request for native delegation"

    if not (policy == "auto" or authorized_by_source):
        return "local", "policy is explicit and nobody requested delegation; a model choosing to delegate is not authorization"

    if kind == "implementation":
        return "opencode", "bounded implementation goes to the OpenCode worker"
    if not record.get("native_reason", "").strip():
        return "invalid", f"native {kind} needs --native-reason: why the OpenCode implementation worker is unsuitable"
    return "native", f"independently scoped {kind}: {record['native_reason'].strip()}"


def validate_record(args):
    """Normalize CLI fields into a record, or raise RoutingError with the fix."""
    problems = []

    def need(name, value, choices=None):
        if value is None or (isinstance(value, str) and not value.strip()):
            problems.append(f"--{name.replace('_', '-')} is required")
        elif choices and value not in choices:
            problems.append(f"--{name.replace('_', '-')} must be one of {'|'.join(choices)} (got {value})")

    need("proposal", args.proposal)
    need("assignment", args.assignment)
    need("scope", args.scope)
    need("work_kind", args.work_kind, WORK_KINDS)
    need("authorization", args.authorization, AUTHORIZATIONS)
    need("requested_provider", args.requested_provider, PROVIDERS)
    need("scope_status", args.scope_status, SCOPE_STATUSES)
    need("skill_revision", args.skill_revision)
    if args.assignment and not re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,63}", args.assignment):
        problems.append("--assignment must be a lowercase slug ([a-z0-9._-], at most 64 chars)")
    if args.scope and len(args.scope) > 2000:
        problems.append("--scope is limited to 2000 characters")
    if args.authorization in ("user", "workflow"):
        excerpt = normalize_text(args.source_excerpt or "")
        if len(excerpt) < MIN_EXCERPT_CHARS:
            problems.append(f"--source-excerpt must quote at least {MIN_EXCERPT_CHARS} characters of the authorizing text")
    if args.authorization == "workflow" and not args.workflow_file:
        problems.append("--workflow-file is required with --authorization workflow")
    if args.authorization != "workflow" and args.workflow_file:
        problems.append("--workflow-file applies only to --authorization workflow")
    if args.authorization == "none" and args.requested_provider in ("opencode", "native"):
        problems.append("a requested provider needs its source: use --authorization user or workflow with --source-excerpt")
    if problems:
        raise RoutingError("; ".join(problems))
    return {
        "proposal": args.proposal,
        "assignment": args.assignment,
        "scope": args.scope.strip(),
        "work_kind": args.work_kind,
        "authorization": args.authorization,
        "source_excerpt": args.source_excerpt or "",
        "workflow_file": args.workflow_file or "",
        "requested_provider": args.requested_provider,
        "native_reason": (args.native_reason or "").strip(),
        "scope_status": args.scope_status,
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


def denial_text(proposal_id, operation, revision):
    what = "create a native agent" if operation == "create" else "give an existing native agent more work"
    return (
        f"opencode-subagent routing paused this call to {what} (proposal {proposal_id}). "
        "Native delegation needs a recorded routing decision first. Load the opencode-subagent skill, then run "
        f"`opencode-delegate route show {proposal_id}` and record the decision with "
        f"`opencode-delegate route record --proposal {proposal_id} ... --skill-revision {revision}`. "
        "If the route is native, repeat this call once: the hook runs this proposal exactly as first submitted. "
        "If the route is opencode or local, do not repeat this call."
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
                                 "Do the work yourself; only the user can change it (opencode-delegate policy explicit).")
        store.audit(event="deny", session=key, tool=tool, reason="policy_off")
        return remember(output, None)

    if capture_failed(store.root, session):
        retired = retire_grants(session, "user input capture failed")
        output = pre_tool_output("deny", "opencode-subagent routing failed to capture the latest user message, so no "
                                 "delegation decision can be trusted. Work locally, or ask the user to send their "
                                 "request again; run opencode-delegate route doctor if this repeats.")
        store.audit(event="deny", session=key, tool=tool, reason="capture_failed", retired_grants=retired)
        return remember(output, None)

    if session["epoch"] == 0:
        output = pre_tool_output("deny", "opencode-subagent routing has no captured user input for this session "
                                 "(hooks became active mid-session). Work locally, or ask the user to restate the "
                                 "delegation request in a new message so a decision can be recorded.")
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
    }
    output = pre_tool_output("deny", denial_text(proposal_id, operation, skill_revision()))
    store.audit(event="deny", session=key, proposal=proposal_id, tool=tool, reason="needs_decision")
    return remember(output, proposal_id)


def observe_host(store, host, event):
    data = store.load_hosts()
    entry = data["hosts"].setdefault(host, {"events": 0})
    entry.update({"last_event": event, "last_seen": now(), "runtime": runtime_identity(), "runtime_path": self_path()})
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
        return handle_hook(payload, host_flag, store)
    except Exception as e:  # noqa: BLE001 - every failure must still answer the host
        return failure_output(payload, f"{type(e).__name__}: {e}" if not isinstance(e, RoutingError) else str(e))


def failure_output(payload, message):
    if isinstance(payload, dict):
        if payload.get("hook_event_name") != "PreToolUse" or payload.get("tool_name") not in WORK_TOOLS:
            return None
    elif not any(f'"{name}"' in payload for name in WORK_TOOLS) or '"PreToolUse"' not in payload:
        return None
    return pre_tool_output("deny", f"opencode-subagent routing could not evaluate this delegation call: {message}. "
                           "Native delegation stays blocked until this is fixed (opencode-delegate route doctor); "
                           "work locally meanwhile.")


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
        route, reason = decide(policy, record, prior, epoch_of_excerpt)
        stored = {k: v for k, v in record.items() if k != "proposal"}
        stored["source_excerpt"] = record["source_excerpt"][:500]
        store.audit(event="record", session=session["key"], proposal=proposal["id"], route=route, reason=reason,
                    assignment=record["assignment"], work_kind=record["work_kind"], authorization=record["authorization"])
        if route == "invalid":
            raise RoutingError(reason)

        proposal["decision"] = {"time": now(), "route": route, "reason": reason, "policy": policy,
                                "record": stored, "source": source}
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
        return {"proposal": proposal["id"], "route": route, "reason": reason, "next": next_step(route, proposal)}


def next_step(route, proposal):
    return {
        "native": f"Repeat the native call once within {GRANT_TTL_SECONDS // 60} minutes, from the same worktree and "
                  "before the next user message. The hook runs the proposal exactly as first submitted.",
        "opencode": "Do not repeat the native call. Delegate through opencode-delegate start/run and verify the result.",
        "local": "Do not repeat the native call. Do the work yourself.",
        "none": "Do not repeat the native call. Do the work yourself; delegation is off.",
        "clarify": "Do not repeat the native call. Ask the user to resolve the scope, or work locally.",
    }[route]


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
        "--authorization": "user (quote the user) | workflow (quote a workflow file) | none",
        "--source-excerpt": f"verbatim quote, at least {MIN_EXCERPT_CHARS} characters",
        "--workflow-file": "path, with --authorization workflow",
        "--requested-provider": "|".join(PROVIDERS),
        "--native-reason": "why the OpenCode worker is unsuitable (native research/review)",
        "--scope-status": "|".join(SCOPE_STATUSES),
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
        if "route hook" in text:
            found[host].append({"source": label, "path": path, "mtime": os.path.getmtime(path)})

    scan(os.path.join(home, ".claude", "settings.json"), "claude", "local")
    scan(os.path.join(home, ".codex", "hooks.json"), "codex", "local")
    try:
        with open(os.path.join(home, ".claude", "plugins", "installed_plugins.json")) as f:
            plugins = json.load(f).get("plugins", {})
        for name, installs in plugins.items():
            if name.startswith("workflow-skills@"):
                for inst in installs:
                    hooks = os.path.join(inst.get("installPath", ""), "hooks", "hooks.json")
                    if os.path.exists(hooks):
                        found["claude"].append({"source": "plugin", "path": hooks, "mtime": os.path.getmtime(hooks)})
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
                 "workflow-file", "requested-provider", "native-reason", "scope-status", "skill-revision"):
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
        try:
            output = run_hook(args.host, sys.stdin.read())
        except Exception:  # noqa: BLE001 - e.g. undecodable stdin; never exit non-zero from a hook
            output = pre_tool_output("deny", "opencode-subagent routing could not read the hook input; native delegation stays blocked")
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
