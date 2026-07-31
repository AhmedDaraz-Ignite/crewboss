# crewboss

crewboss lets one AI agent (or you) start other AI agents and supervise their tasks.

Each helper agent is called a **crew**. Every crew gets:

- its own copy of the repo (a git worktree), so crews never break each other's files
- its own terminal window inside [herdr](https://herdr.dev), so you can watch it work
- its own task, sent as plain text

You can close a crew and open it again later. It remembers the whole conversation.

## Quick example

```bash
crewboss spawn "ABC-123 make the footer sticky"
crewboss spawn "ABC-124 fix the login redirect"
crewboss spawn "ABC-125 add an export button"
crewboss wait ABC-123 ABC-124 ABC-125
```

`wait` returns the first selected `blocked` or `done` event. The first line is the crew
name and event kind. The exact payload follows and can use more than one line:

```text
ABC-124 blocked
Should guests see the login page?
```

Relay the exact question to the user. Then send the answer:

```bash
crewboss send ABC-124 "Yes, guests should see it."
crewboss wait ABC-123 ABC-124 ABC-125
crewboss close ABC-123         # closes the window; files and conversation are kept
crewboss open  ABC-123         # opens it again, right where it stopped
crewboss remove ABC-123 -f     # discards local work and deletes everything for this crew
```

For a `done` event, act on the final answer. For example, review the files or report the result.
Spawn all crews first. Then use one blocking `wait A B C` call.

## Install as an agent skill

This teaches your AI agent (Claude Code, Codex, and others) how to use crewboss:

```bash
npx skills add AhmedDaraz-Ignite/crewboss
```

To install for one agent only:

```bash
npx skills add AhmedDaraz-Ignite/crewboss --agent claude-code
```

Or for all agents on your machine: `--agent '*'`.

## How your agent knows when to use crewboss

This follows the standard agent-skills protocol, so it works the same in any agent
that supports skills:

1. At the start of a session, your agent reads only the skill's one-line description.
2. When you ask to "spawn a crew", "delegate a task to a parallel agent session",
   "work on several tasks in parallel", or "orchestrate work across worktrees", the
   agent loads the full `SKILL.md`. The same happens when you ask to
   "wait for blocked or done crew events" or say "crewboss". The agent then runs the
   bundled script.
3. Normal tasks ("fix the footer") still run in the current session. Nothing is
   delegated unless you ask for it.

If you want your agent to delegate every task by default, add one line to your
project's `AGENTS.md` (or `CLAUDE.md`):

> For every implementation task, spawn a crew with crewboss and orchestrate from
> this session instead of editing files directly.

The tool stays generic. When to delegate is your project's policy, not crewboss's.

One requirement: the session that runs crewboss must itself be inside a
[herdr](https://herdr.dev) pane, because new crews are opened as herdr tabs or splits
next to it.

## Install for your own shell

If you want to type the commands yourself:

```bash
git clone https://github.com/AhmedDaraz-Ignite/crewboss
ln -s "$PWD/crewboss/scripts/crewboss" ~/bin/crewboss   # or any folder on your PATH
```

## What you need first

- [herdr](https://herdr.dev) - a terminal app that manages windows (panes) and agents.
  Run `crewboss` from inside herdr.
- [worktrunk](https://worktrunk.dev) (`wt`) - a tool that creates git worktrees.
- `jq`, `bash`, `git`.

## How crewboss picks names

You only type the task. crewboss finds the crew name and branch name by itself:

| You type                              | Crew name | Branch                          |
| ------------------------------------- | --------- | ------------------------------- |
| `spawn "ABC-123 fix login redirect"`  | `ABC-123` | `<prefix>-ABC-123-fix-login-redirect` |
| `spawn "profile the import job"`      | `profile-the-import-job` | `<prefix>-profile-the-import-job` |
| `spawn --branch my-branch "..."`      | from task | `my-branch`                     |

If the task starts with a ticket number (like `ABC-123`), that becomes the crew name.
If not, the first few words of the task become the name.

Two settings you can change:

- `CB_PREFIX` - the word at the start of every branch name. Default: your git `user.name`, in lowercase.
- `CB_BASE` - the branch new work starts from. Default: your repo's main branch.

## How it works inside

crewboss is a small bash script plus six modules. Each module does one job:

| Module            | Job                                                     |
| ----------------- | ------------------------------------------------------- |
| `lib/naming.sh`   | turns task text into a crew name and a branch name      |
| `lib/tree.sh`     | creates and removes worktrees (using worktrunk)         |
| `lib/pane.sh`     | opens, focuses, and closes windows (using herdr)        |
| `lib/agent.sh`    | starts the agent, sends prompts, and reads its screen    |
| `lib/registry.sh` | remembers each crew and its current task state           |
| `lib/events.sh`   | appends and reads crew events                            |

Every crew appends `blocked` and `done` events to one shared append-only log. CrewBoss
reads events in strict FIFO insertion order. FIFO means the oldest inserted event first.
It then acts on the event. `wait NAME...` returns the first event for the selected crews.
Events for other crews stay pending.

In Phase 1, `wait` is the foreground listener. It has no task timeout or background
watcher. It blocks in one shell process and does not poll crew screens. `read` only
returns a screen snapshot. Screen text is not a notification.

Event delivery is at least once after a crash. This means an event can be printed
again, but an appended event is not lost.

**How `open` brings a conversation back:** the worktree keeps the files, and the
agent saves its chat history per folder. So starting the agent again in the same
folder (`claude --continue`) brings the old conversation back.

crewboss also protects you from two timing bugs we hit while building it. A new pane
can report `agent_pane_busy`, so CrewBoss retries the agent start. A new agent can lose
its first prompt, so CrewBoss checks for the unique CrewBoss run ID and tries prompt
delivery up to five times.

State lives in `~/.local/state/crewboss/`:

| File | Contents |
| --- | --- |
| `crew.json` | crew records, the exact initial task, and the latest prompt |
| `events.jsonl` | the shared append-only event source |
| `event-state.json` | the read cursor and pending event checkpoint |

`crewboss list` prints these exact columns:

```text
NAME ENDPOINT TASK BRANCH SUMMARY
```

`ENDPOINT` is `open`, `closed`, or `unknown`. `TASK` is `running`, `blocked`, `done`,
or `unknown`. `SUMMARY` comes from the stored initial task. The exact initial task and
latest prompt remain in `crew.json`.

## Safe cleanup

`crewboss remove NAME` checks the worktree before it closes anything. It refuses
uncommitted files and commits that are not present on a known remote. Push or commit
the work and run the command again.

`-f` means that you accept discarding local work. It never lets crewboss close a pane
that belongs to another agent.

crewboss also refuses to start a crew when its branch is checked out in your primary
repo. A crew always runs in a separate worktree.

## Checks

```bash
bash tests/run
```

## License

MIT
