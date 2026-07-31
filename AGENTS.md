# AGENTS.md

This file provides guidance to coding agents (Claude Code, Codex, and others) when working with code
in this repository. `CLAUDE.md` is a symlink to it.

## What this repo is

crewboss is a ~550-line Bash tool published as an **agent skill**, not an application. There is no
build, no package manager, no dependency tree. The whole product is `SKILL.md` (what an agent reads)
plus `scripts/` (what it runs). Users install it with `npx skills add AhmedDaraz-Ignite/crewboss`,
which copies this repo into `.claude/skills/` or `.agents/skills/`.

Consequence: `SKILL.md` is a shipped interface, equal in weight to the code. Any change to a command,
a flag, or a rule for the orchestrating agent has to land in `SKILL.md` and `README.md` in the same
commit, or installed copies teach the wrong thing.

## Commands

There is no test suite and no CI. Checks are manual:

```bash
bash -n scripts/crewboss scripts/lib/*.sh     # syntax only
shellcheck scripts/crewboss scripts/lib/*.sh  # not pinned, not wired to anything yet
scripts/crewboss help
```

Real verification means running it inside a herdr pane against a git repo:

```bash
scripts/crewboss spawn "ABC-123 try something"   # needs herdr + wt + jq, and a herdr pane as cwd
scripts/crewboss list
scripts/crewboss remove ABC-123 -f
```

`~/.claude/tools/crewboss` is a symlink to this repo's `scripts/`, so edits here change the installed
tool immediately. Edit in this clone, never in the symlink target path.

## Architecture

Five modules, one dispatcher, sourced not exec'd:

| File | Owns |
| --- | --- |
| `scripts/crewboss` | argument parsing and the `do_*` command bodies. No external tool calls of its own except `herdr agent focus` |
| `lib/naming.sh` | task text to crew name and branch name |
| `lib/tree.sh` | worktree lifecycle, delegated to `wt` (worktrunk) |
| `lib/pane.sh` | pane lifecycle, delegated to `herdr` |
| `lib/agent.sh` | agent process lifecycle and the completion protocol, delegated to `herdr` |
| `lib/registry.sh` | the only state crewboss itself owns |

The layering rule that keeps this small: **crewboss owns no worktrees and no processes.** worktrunk
owns the worktree and its path template, herdr owns panes and agent processes. crewboss owns one JSON
file at `$CB_STATE_DIR/crew.json` (default `~/.local/state/crewboss/`) mapping a crew name to
`{branch, path, pane, agent, placement, token, status}`. That file is the reason `close` and `open`
can restore a crew. It is global across repos, not per-repo.

### Interface invariant

Every command takes a **crew name**. Never a pane id, never a path, never a timeout. Timeouts are
constants inside `lib/agent.sh` (`CB_START_TIMEOUT_MS` 120s, `CB_TASK_TIMEOUT_MS` 30 min). Pane ids
live in the registry and are looked up, never typed. Preserve this when adding commands.

### The completion protocol

`wait` is the load-bearing design decision. herdr 0.7.5's own `agent wait` and `prompt --wait` sample
agent state and miss edges, so crewboss does not use them. Instead `cb_agent_prompt` appends an
instruction to print `TASKDONE<random>` as the final line, and `cb_agent_wait` calls
`herdr pane wait-output --regex --source recent`. One blocking call, so an agent doing the waiting
spends zero tokens.

Two details in `cb_agent_prompt` look odd and are deliberate:

- The token word and the digits are written apart in the prompt text ("the word TASKDONE followed
  immediately by the digits 4231"). If they were joined, the echoed instruction in the pane would
  itself match the regex and `wait` would return instantly.
- After sending, it greps the pane for `digits $num` and resends up to 5 times. A freshly started
  agent silently swallows its first prompt often enough to matter.

`cb_agent_start` retries for 15 seconds on `agent_pane_busy` for the same class of reason: a
brand-new pane rejects an agent start until its shell is up.

Do not "simplify" any of these three loops. They are workarounds for observed races, not defensive
padding.

### Naming derivation

`cb_ticket` pulls a Jira-style key out of the task text; `cb_slug` strips that key and takes the first
four words. `cb_name` prefers the ticket and falls back to the slug, `cb_branch` joins
`$CB_PREFIX-$TICKET-$SLUG`. `CB_PREFIX` defaults to git `user.name` lowercased, `CB_BASE` to the
remote's default branch. `--branch` bypasses the whole chain.

### Reads are screen snapshots

`cb_agent_read` returns the visible pane buffer (`--source recent-unwrapped`), not a transcript. Any
code or instruction that consumes a read has to grep for what it expects rather than trust the tail.

## Conventions

- Both `README.md` and `SKILL.md` are written for a non-native English reader: short sentences, jargon
  defined at first use, no marketing register. Match it.
- The `description:` field in `SKILL.md` frontmatter is the only thing an agent reads before deciding
  to load the skill. Treat it as a trigger contract, and keep the README's "How your agent knows when
  to use crewboss" section in sync with it.
- `codex:resume` in `cb_agent_args` is unverified. It needs a machine with codex installed before any
  claim that it works.
