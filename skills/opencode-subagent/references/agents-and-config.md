# The agents and configuration

## The agents

`agents/workflow-worker.md` and `agents/workflow-researcher.md` are installed into OpenCode's agent directory (by `scripts/install.sh --agent opencode`, and by `delegate.sh` before each launch). The worker enforces, in OpenCode's own permission system rather than by asking nicely:

- no recursive delegation (`task: deny`) and no questions to a user who is not there (`question: deny`);
- no web search or fetch (use the researcher for that);
- no writes outside the working tree;
- no `git commit`, `push`, `reset --hard`, `clean`, `rebase`, `checkout`, `switch`, `stash`, or branch deletion;
- normal read/search/edit/LSP/test/build access;
- temperature 0 and a bounded step count.

It ends its turn with `STATUS` / `FILES_CHANGED` / `VERIFICATION` / `QUESTION` / `CONCERNS`, which the wrapper parses into `outcome.worker` and `worker_question`.

The researcher has the same reporting contract, with its findings written above the block. Its shell runs only `git status/diff/log/show/blame/ls-files/rev-parse/merge-base`, `gh pr view/diff` and `gh issue view`, one plain command at a time. Pipes into anything else, redirection, `$`/backtick substitution, `--output`, `--ext-diff`, `--textconv`, `--no-index`, `difftool` and any argument naming `.env` are denied; files are read with OpenCode's own tools, whose `read` denies `.env` files. General tools such as `cat`, `find`, `rg` or `sort` are left out on purpose: several have flags that write files or run programs, and this agent also has the network. The `.env` blocking covers its tools, not every way a secret can sit in a tree, so do not point it at repositories whose secrets live in tracked files.

## Configuration

`~/.config/workflow-skills/subagents.conf` (shared with the other `*-subagent` skills):

```ini
OPENCODE_SUBAGENT_DELEGATION_POLICY=auto
OPENCODE_SUBAGENT_MODEL=provider/some-cheap-coding-model
OPENCODE_SUBAGENT_RESEARCH_MODEL=provider/some-cheap-model
OPENCODE_SUBAGENT_READONLY_AGENTS=*-reviewer *-explorer
OPENCODE_SUBAGENT_STALL_SECONDS=300
OPENCODE_SUBAGENT_RETENTION_DAYS=90
OPENCODE_SUBAGENT_RAW_RETENTION_DAYS=7
```

`OPENCODE_SUBAGENT_MODEL` is the worker model. Resolution is: `--model` → configured worker model → **error**. The wrapper never falls back to whatever model OpenCode uses globally; inheriting a frontier model would defeat the purpose. Set it once with `--model provider/model --save-default`. `OPENCODE_SUBAGENT_RESEARCH_MODEL` is the researcher's model (`--role researcher --model ... --save-default` sets it); unset, the researcher uses the worker model. With no policy key the policy is `explicit`.

A repository can layer its own file over the global one at `<repo>/.workflow-skills/subagents.conf`, in the same format:

- The file is the nearest one between the working directory and the repository root, so a monorepo can configure a single package. A linked worktree with no file of its own uses the main worktree's file, at the same path from its root.
- Precedence per key: the `--model`/`--stall-seconds` flag, then the repo file, then the global file, then the built-in default. An empty value in the repo file still overrides the global one.
- `DELEGATION_POLICY`, `MODEL`, `RESEARCH_MODEL`, `READONLY_AGENTS` and `STALL_SECONDS` are overridable. `RETENTION_DAYS` and `RAW_RETENTION_DAYS` are global only, because the state store is: a repo file that sets one gets a warning in `config` and `route doctor`, and the key is ignored. An unknown key is warned about and ignored the same way.
- An invalid policy value in either file is an error, naming the file.
- `opencode-delegate config` prints the effective config for the current directory and the source of each value. `policy <value> --repo` and `--save-default --repo` write the repo file, creating the directory with a `.gitignore` of `*` so the repository never sees it; `opencode-delegate config --repo unset KEY` removes a key.
- The trust model is the honor system, as for the global file: a repo file can loosen the policy (global `off`, repo `auto`). Check `opencode-delegate config` before trusting a repository you did not write.

