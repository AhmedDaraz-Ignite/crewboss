# crewboss

Spawn isolated agent sessions in dedicated git worktrees and drive them from your
current session - or from your own terminal.

One command spawns a crew: worktree created on a convention-correct branch, pane
opened in [herdr](https://herdr.dev), agent started (Claude Code, Codex, or any of
herdr's supported agents), task delivered. You watch and click between crews in herdr
itself. Close any crew and reopen it later with its conversation intact.

```bash
crewboss spawn "ABC-123 make the footer sticky"
crewboss wait ABC-123          # blocks until the crew reports done, prints its reply
crewboss send ABC-123 "also fix the mobile layout"
crewboss close ABC-123         # pane gone; worktree and conversation kept
crewboss open  ABC-123         # resume right where it left off
crewboss remove ABC-123 -f     # full teardown
```

## Install as an agent skill

```bash
npx skills add AhmedDaraz-Ignite/crewboss
```

Target a specific agent (`npx skills add AhmedDaraz-Ignite/crewboss --agent claude-code`)
or all of them (`--agent '*'`). The skill teaches the installed agent the interface and
the orchestration rules (zero-token waiting, snapshot reads, close-over-remove).

## Install for direct shell use

```bash
git clone https://github.com/AhmedDaraz-Ignite/crewboss
ln -s "$PWD/crewboss/scripts/crewboss" ~/bin/crewboss   # or anywhere on PATH
```

## Requirements

- [herdr](https://herdr.dev) - terminal multiplexer; owns panes and agent processes.
  Run `crewboss` from inside herdr for `tab` and `split` placement.
- [worktrunk](https://worktrunk.dev) (`wt`) - owns worktree creation, the
  branch-to-path template, and post-switch hooks.
- `jq`, `bash`, `git`.

## How names are derived

You give the task, crewboss derives the rest:

| You type                              | Crew name | Branch                          |
| ------------------------------------- | --------- | ------------------------------- |
| `spawn "ABC-123 fix login redirect"`  | `ABC-123` | `<prefix>-ABC-123-fix-login-redirect` |
| `spawn "profile the import job"`      | `profile-the-import-job` | `<prefix>-profile-the-import-job` |
| `spawn --branch my-branch "..."`      | from task | `my-branch`                     |

- `CB_PREFIX` sets the prefix (default: your git `user.name`, lowercased).
- `CB_BASE` sets the base ref (default: the remote's default branch).
- The worktree path is never computed by crewboss; it asks worktrunk, so your
  `worktree-path` template stays the single source of truth.

## Design

A thin bash entry point plus five modules, each owning one concern:

| Module            | Owns                                                    |
| ----------------- | ------------------------------------------------------- |
| `lib/naming.sh`   | task text to crew name and branch (pure)                |
| `lib/tree.sh`     | worktree create, path lookup, remove (worktrunk)        |
| `lib/pane.sh`     | pane per placement, focus, close (herdr)                |
| `lib/agent.sh`    | start, resume, prompt, sentinel wait, read; all timeouts |
| `lib/registry.sh` | the crew record that makes close and reopen possible    |

Completion is detected with a sentinel the crew prints when finished, matched by
`herdr pane wait-output` - one blocking call, so an orchestrating agent spends zero
tokens while waiting. Conversation resume works because the worktree keeps the files
and the agent keys its history to the working directory (`claude --continue`).

Hardened against the races found while building it: a fresh pane rejects
`agent start` until its shell is up (retried), and a freshly started agent can
silently swallow its first prompt (crewboss verifies the prompt echoed and resends).

State lives in `~/.local/state/crewboss/crew.json`.

## License

MIT
