# context-watch behavioral evals

Paid, live Claude Code sessions that check what the context-watch hook does to a real model. They are not part of CI. The deterministic gate is `python3 scripts/test-context-watch.py`.

```bash
python3 tests/evals/context-watch/run.py --model sonnet --runs 2
```

Each run loads `plugins/context-watch` with `--plugin-dir`, which exercises the plugin's `hooks.json` through `CLAUDE_PLUGIN_ROOT` and the symlinked `scripts/`. Thresholds are lowered through the environment, so a fresh session crosses them on its second turn: the first turn has no usage row to measure yet. Each run gets its own scratch directory and XDG state and config.

| Scenario | Checks |
|----------|--------|
| `warn-is-user-only` | The hook fired WARN. Claude Code rendered it as a `system`/`informational` stream event, which is what a UI shows. The model, asked to quote any `context-watch:` text, finds none. |
| `urge-reaches-model` | The hook fired URGE, and the model can quote the `[context-watch]` line. |
| `urge-keeps-working` | With URGE active, a three-file task is finished in full, and the turn ends with DONE rather than a question. |

Grading is deterministic: the hook's state file shows what fired, the stream shows what the host rendered, and the reply and files show what reached the model and what it did.

## Recorded results

| File | Runtime | Runs | Result |
|------|---------|------|--------|
| `results/20261005-214409-claude.json` | Claude Code 2.1.289, Sonnet | 3 (`warn-is-user-only`) | 3/3 |
| `results/20261005-214538-claude.json` | same | 6 (all scenarios, 2 each) | 6/6 |

Both graders were mutation-checked: when the core was patched to also send WARN to the model, `warn-is-user-only` failed. An earlier wording of the WARN probe ("is there any message reporting the context size? YES/NO") was dropped: it answered YES once without a leak, probably because Claude Code's own context reminders also match that question.

What these runs do not show: rendering inside the VS Code extension and the desktop app. The stream event above is the host's own render signal, but a surface could still choose not to display it.
