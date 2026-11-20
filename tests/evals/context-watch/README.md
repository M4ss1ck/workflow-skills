# context-watch behavioral evals

Paid, live Claude Code sessions that check what the context-watch hook does to a real model. They are not part of CI. The deterministic gate is `python3 scripts/test-context-watch.py`.

```bash
python3 tests/evals/context-watch/run.py --model sonnet --runs 2
```

Each run loads `plugins/context-watch` with `--plugin-dir`, which exercises the plugin's `hooks.json` through `CLAUDE_PLUGIN_ROOT` and the symlinked `scripts/`, with `--setting-sources project,local` so an installed copy of the plugin in your user settings stays out. Thresholds are lowered through the environment. A fresh session has no usage row at its first prompt, so its first tool call is where the crossing happens, which is the long-autonomous-turn case the tool check exists for. Each run gets its own scratch directory and XDG state and config.

| Scenario | Checks |
|----------|--------|
| `urge-stops-with-a-handoff` | A three-file task in a fresh session with URGE at 1k: the model stops before `sum.txt` without reaching DONE, writes a handoff file that names the remaining work, and ends with a fenced prompt pointing at it. No hard stop. |
| `continue-after-stop` | The same, then "Continue the task.": the first reply carries the handoff prompt, and all three files are complete after continuing. |
| `warn-stops-after-the-step` | WARN at 1k, URGE out of reach: the host renders the WARN notice, the model stops before `sum.txt`, reports the context size, and hands off. |
| `urge-at-a-prompt-asks-first` | URGE crossed before a prompt: no file is written, the reply raises the context size, and the handoff names the whole task. |
| `keep-going-when-told` | The user said not to stop for context: all files are written, the reply reaches DONE, and the handoff file and prompt are there anyway. |
| `fallback-when-unwritable` | The handoffs directory is read-only: no handoff file exists, and the reply carries the whole handoff (the remaining work included) in a fenced block. Refuses to run as root. |

Runs pass no `--add-dir`: the handoff file is outside the project, as for a real user, so writing it depends on the hook's `PreToolUse` approval.

Grading is deterministic: the hook's state file shows what fired, the stream shows what the host rendered, and the reply and files show where the model stopped.

## Recorded results

The two oldest results predate the stop behaviour: they graded the earlier design (WARN user-only, URGE informational).

| File | Runtime | Runs | Result |
|------|---------|------|--------|
| `results/20261005-214409-claude.json` | Claude Code 2.1.289, Sonnet | 3 (`warn-is-user-only`) | 3/3 |
| `results/20261005-214538-claude.json` | same | 6 (all scenarios, 2 each) | 6/6 |
| `results/20261120-201153-claude.json` | Claude Code 2.1.322, Sonnet | 6 (all scenarios, 1 each) | 4/6: both failures were the grader, which matched "This isn't DONE yet" as DONE; the model had stopped and handed off correctly |
| `results/20261120-201341-claude.json` | same, fixed grader | 4 (`urge-stops-with-a-handoff`, `continue-after-stop`, 2 each) | 4/4 |

Both graders were mutation-checked: when the core was patched to also send WARN to the model, `warn-is-user-only` failed. An earlier wording of the WARN probe ("is there any message reporting the context size? YES/NO") was dropped: it answered YES once without a leak, probably because Claude Code's own context reminders also match that question.

What these runs do not show: rendering inside the VS Code extension and the desktop app. The stream event above is the host's own render signal, but a surface could still choose not to display it.

The handoff graders were checked against a wrong model: an earlier wording that also exempted headless runs from stopping made Sonnet (in `claude -p`) carry on to DONE, and `urge-stops-with-a-handoff` and `continue-after-stop` failed on "stopped before the last file". `PreToolUse:Write` approval of the handoff file was observed in the transcripts (`hook_success`), with no `--add-dir`.
