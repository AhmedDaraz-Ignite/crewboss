# AGENTS.md

This file provides guidance to coding agents (Claude Code, Codex, and others) when working with code
in this repository. `CLAUDE.md` is a symlink to it.

## What this repo is

crewboss is a small Bash tool published as an **agent skill**, not an application. There is no
build, no package manager, no dependency tree. The whole product is `SKILL.md` (what an agent reads)
plus `scripts/` (what it runs). Users install it with `npx skills add AhmedDaraz-Ignite/crewboss`,
which copies this repo into `.claude/skills/` or `.agents/skills/`.

Consequence: `SKILL.md` is a shipped interface, equal in weight to the code. Any change to a command,
a flag, or a rule for the orchestrating agent has to land in `SKILL.md` and `README.md` in the same
commit, or installed copies teach the wrong thing.

## Commit & Push
- NEVER commit or push to the main branch.

## Commands

Run the local check before handing off a change:

```bash
bash tests/run
```

Runtime verification means running it inside a disposable herdr pane against a git repo:

```bash
scripts/crewboss spawn "ABC-123 try something"   # needs herdr + wt + jq, and a herdr pane as cwd
scripts/crewboss list
scripts/crewboss remove ABC-123 -f
```

`~/.claude/tools/crewboss` is a symlink to this repo's `scripts/`, so edits here change the installed
tool immediately. Edit in this clone, never in the symlink target path.

## Architecture

Six modules, one dispatcher, sourced not exec'd:

| File | Owns |
| --- | --- |
| `scripts/crewboss` | argument parsing, public command flow, and output formatting |
| `lib/naming.sh` | task text to crew name and branch name |
| `lib/tree.sh` | worktree lifecycle, delegated to `wt` (worktrunk) |
| `lib/pane.sh` | pane lifecycle, delegated to `herdr` |
| `lib/agent.sh` | agent process and prompt lifecycle, delegated to `herdr` |
| `lib/registry.sh` | crew records, task text, identities, and current state |
| `lib/events.sh` | shared event append, FIFO reading, pending events, and checkpoints |

The layering rule that keeps this small: **crewboss owns no worktrees and no processes.** worktrunk
owns the worktree and its path template, and herdr owns panes and agent processes. CrewBoss owns
state under `$CB_STATE_DIR` (default `~/.local/state/crewboss/`). It is global across repos, not
per-repo:

- `crew.json` stores crew records, the exact initial task, and the latest prompt.
- `events.jsonl` is the shared append-only event source.
- `event-state.json` stores the read cursor and pending event checkpoint.

The crew record is why `close` and `open` can restore a crew.

### Interface invariant

Every public command that targets a crew takes a **crew name**. Never a pane ID, path, or timeout.
Pane IDs live in the registry and are looked up, never typed. `wait` accepts one or more crew names.
The internal `emit` command also takes stored crew and run identities. Preserve this boundary.

### Event supervision

Crews append events to one shared append-only log; CrewBoss reads them in strict FIFO insertion order and acts.
The events are `blocked` and `done`. FIFO means the oldest inserted event first. The event append is
the notification. CrewBoss does not use screen text as a completion signal.

`wait A B C` is the Phase 1 foreground listener. It returns the oldest current event for the
selected crews. The first output line is `NAME blocked` or `NAME done`. The exact payload follows
and can use more than one line. There is no task timeout or background watcher. It does not poll
screens.

Delivery is at least once after a crash. An event may be printed twice, but an appended event must
not be lost. `events.jsonl` remains the source. `event-state.json` is only a cursor and pending
checkpoint.

Two observed Herdr retries are deliberate:

- `cb_agent_start` retries when a new pane reports `agent_pane_busy`.
- `cb_agent_prompt` looks for the unique `CrewBoss run id: RUN_ID` marker. It tries prompt delivery
  up to five times because a new agent can silently swallow its first prompt.

Do not remove or shorten these retries without new runtime evidence. They work around observed
races.

`list` prints `NAME ENDPOINT TASK BRANCH SUMMARY`. Endpoint values are `open`, `closed`, and
`unknown`. Task values are `running`, `blocked`, `done`, and `unknown`. The summary uses the stored
initial task.

### Naming derivation

`cb_ticket` pulls a Jira-style key out of the task text; `cb_slug` strips that key and takes the first
four words. `cb_name` prefers the ticket and falls back to the slug, `cb_branch` joins
`$CB_PREFIX-$TICKET-$SLUG`. `CB_PREFIX` defaults to git `user.name` lowercased, `CB_BASE` to the
remote's default branch. `--branch` bypasses the whole chain.

### Reads are screen snapshots

`cb_agent_read` returns the visible pane buffer (`--source recent-unwrapped`), not a transcript or
notification. Any code or instruction that consumes a read has to grep for what it expects rather
than trust the tail.

## Conventions

- Both `README.md` and `SKILL.md` are written for a non-native English reader: short sentences, jargon
  defined at first use, no marketing register. Match it.
- The `description:` field in `SKILL.md` frontmatter is the only thing an agent reads before deciding
  to load the skill. Treat it as a trigger contract, and keep the README's "How your agent knows when
  to use crewboss" section in sync with it.
- `codex:resume` in `cb_agent_args` is unverified. It needs a machine with codex installed before any
  claim that it works.
