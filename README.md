# crewboss

crewboss lets one AI agent (or you) start other AI agents and give them tasks.

Each helper agent is called a **crew**. Every crew gets:

- its own copy of the repo (a git worktree), so crews never break each other's files
- its own terminal window inside [herdr](https://herdr.dev), so you can watch it work
- its own task, sent as plain text

You can close a crew and open it again later. It remembers the whole conversation.

## Quick example

```bash
crewboss spawn "ABC-123 make the footer sticky"
crewboss wait ABC-123          # waits until the crew says it is done, then prints its answer
crewboss send ABC-123 "also fix the mobile layout"
crewboss close ABC-123         # closes the window; files and conversation are kept
crewboss open  ABC-123         # opens it again, right where it stopped
crewboss remove ABC-123 -f     # discards local work and deletes everything for this crew
```

That is the whole idea: `spawn` a crew, `wait` for it, `send` more work, `close` when done.

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
2. When you ask for something that matches it - "spawn a crew", "delegate this to a
   parallel session", "work on these three tickets in parallel", or simply the word
   "crewboss" - the agent loads the full `SKILL.md` and runs the bundled script.
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

crewboss is a small bash script plus five modules. Each module does one job:

| Module            | Job                                                     |
| ----------------- | ------------------------------------------------------- |
| `lib/naming.sh`   | turns task text into a crew name and a branch name      |
| `lib/tree.sh`     | creates and removes worktrees (using worktrunk)         |
| `lib/pane.sh`     | opens, focuses, and closes windows (using herdr)        |
| `lib/agent.sh`    | starts the agent, sends the task, waits for the answer  |
| `lib/registry.sh` | remembers each crew, so close and open work later       |

**How `wait` knows the crew is done:** crewboss adds one line to every task, asking
the crew to print a secret code word when it finishes. Then it asks herdr to watch
the crew's window for that code word. This is one single blocking call. So if an AI
agent is the one waiting, it spends zero tokens during the wait - it does not need
to check again and again.

**How `open` brings a conversation back:** the worktree keeps the files, and the
agent saves its chat history per folder. So starting the agent again in the same
folder (`claude --continue`) brings the old conversation back.

crewboss also protects you from two timing bugs we hit while building it: a brand
new window can refuse to start an agent for a few seconds (crewboss retries), and a
brand new agent can lose the first message you send it (crewboss checks the message
arrived and sends it again if not).

Crew records live in `~/.local/state/crewboss/crew.json`.

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
