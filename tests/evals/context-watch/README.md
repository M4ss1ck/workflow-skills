# context-watch behavioral evals

Paid, live Claude Code sessions that check what the context-watch hook does to a real model. They are not part of CI. The deterministic gate is `python3 scripts/test-context-watch.py`.

```bash
python3 tests/evals/context-watch/run.py --model sonnet --runs 2
```

Each run loads `plugins/context-watch` with `--plugin-dir`, which exercises the plugin's `hooks.json` through `CLAUDE_PLUGIN_ROOT` and the symlinked `scripts/`, with `--setting-sources project,local` so an installed copy of the plugin in your user settings stays out. Thresholds are lowered through the environment. A fresh session has no usage row at its first prompt, so its first tool call is where the crossing happens, which is the long-autonomous-turn case the tool check exists for. Each run gets its own scratch directory and XDG state and config.

| Scenario | Checks |
|----------|--------|
| `urge-stops-the-turn` | A three-file task in a fresh session with URGE at 1k: the first tool call stops the turn, so `numbers.txt` exists and `sum.txt` does not, the stream carries the hook's stop message, and the reply never reaches DONE. |
| `continue-after-stop` | The same, then "Continue the task.": all three files are complete and no second stop appears. |
| `warn-stops-after-the-step` | WARN at 1k, URGE out of reach: the host renders the WARN notice, the model stops before `sum.txt` and reports the context size, with no hard stop needed. |
| `urge-at-a-prompt-asks-first` | URGE crossed before a prompt: no file is written, and the reply raises the context size. |

Grading is deterministic: the hook's state file shows what fired, the stream shows what the host rendered, and the reply and files show where the model stopped.

## Recorded results

The results below predate the stop behaviour: they graded the earlier design (WARN user-only, URGE informational). The current scenarios have not been run yet.

| File | Runtime | Runs | Result |
|------|---------|------|--------|
| `results/20261005-214409-claude.json` | Claude Code 2.1.289, Sonnet | 3 (`warn-is-user-only`) | 3/3 |
| `results/20261005-214538-claude.json` | same | 6 (all scenarios, 2 each) | 6/6 |

Both graders were mutation-checked: when the core was patched to also send WARN to the model, `warn-is-user-only` failed. An earlier wording of the WARN probe ("is there any message reporting the context size? YES/NO") was dropped: it answered YES once without a leak, probably because Claude Code's own context reminders also match that question.

What these runs do not show: rendering inside the VS Code extension and the desktop app. The stream event above is the host's own render signal, but a surface could still choose not to display it.
