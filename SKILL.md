---
name: crewboss
description: Spawn and supervise isolated agent sessions (Claude, Codex, or any herdr-supported agent) in dedicated git worktrees. Use when the user asks to spawn a crew, delegate a task to a parallel agent session, work on several tasks in parallel, orchestrate work across worktrees, wait for blocked or done crew events, or says "crewboss".
---

# crewboss

crewboss turns the current session into an orchestrator (a "First Mate"): it spawns
crew sessions, each in its own git worktree with its own agent process, visible as a
pane in the herdr terminal multiplexer. The human can watch and click between crews;
the orchestrator prompts, waits for events, reads screen snapshots, and relays questions.

## Resolve the bundled tool

Resolve `SKILL_ROOT` to the absolute directory containing this `SKILL.md`, then:

```bash
CREWBOSS="$SKILL_ROOT/scripts/crewboss"
"$CREWBOSS" help
```

Requirements (fail loudly if missing, do not improvise around them):

- `herdr` - the terminal multiplexer that owns panes and agent processes; the
  orchestrating session must itself run inside herdr for `tab` and `split` placement.
- `wt` (worktrunk) - owns worktree creation and the branch-to-path template.
- `jq`, `bash`, `git`.

## The interface

Every command that targets a crew takes a crew name. `wait` takes one or more names.
Never type a pane ID, path, or timeout:

```bash
"$CREWBOSS" spawn <task...>    # start a crew on a task (--in tab|space|split, --agent KIND, --branch NAME)
"$CREWBOSS" list               # columns: NAME ENDPOINT TASK BRANCH SUMMARY
"$CREWBOSS" send  <name> <text...>
"$CREWBOSS" wait  <name>...    # first selected blocked or done event
"$CREWBOSS" read  <name> [lines]
"$CREWBOSS" focus <name>       # jump herdr to that crew's pane
"$CREWBOSS" close <name>       # pane goes away; worktree and conversation are kept
"$CREWBOSS" open  <name>       # reopen the pane, resume the conversation
"$CREWBOSS" remove <name> [-f] # full teardown: pane, worktree, registry entry
```

The crew name and branch are derived from the task text. A Jira-style key makes the
name (`spawn "ABC-123 fix login"` creates crew `ABC-123` on branch
`<prefix>-ABC-123-fix-login`); otherwise a slug of the first words. `CB_PREFIX`
overrides the prefix (default: git user.name, lowercased), `CB_BASE` overrides the
base ref (default: the remote's default branch), `--branch` overrides everything.

Normal `remove` checks for uncommitted files and commits not found on a known remote.
It refuses cleanup if either exists. `-f` is explicit discard authority: it means the
human accepts losing local work. A refusal leaves the registry and worktree recoverable.
Before closing, crewboss verifies that the live pane still belongs to this crew. It also
refuses to start a crew if its branch is checked out in the primary repo, so crews run
in separate worktrees.

## Rules for the orchestrating agent

1. **Spawn all crews before waiting.** Then issue one blocking call such as
   `wait A B C`. Do not start one crew and wait before starting the others.
2. **Handle `blocked`.** Relay the exact question to the user. Use `send NAME ANSWER`
   to give the answer to the crew. Then wait again.
3. **Handle `done`.** Act on the final answer. Review, integrate, or report it as the
   task requires. Then wait again for any crews that still run.
4. **A task is just text.** Plain instructions, a skill invocation like
   `/deliver-ticket ABC-123`, or both. It lands in the crew's input box verbatim, so
   skills load in the crew's context, not the orchestrator's.
5. **`wait` is the Phase 1 listener.** It blocks in one foreground shell process.
   There is no task timeout or background watcher. Do not poll `list`, `read`, or crew
   screens for notifications.
6. **A read is a screen snapshot, not a transcript or notification.** Read generously
   (default 200 lines) and grep for what you expect rather than trusting the tail.
7. **Prefer `close` over `remove`** when the work might continue - closing costs
   nothing (the worktree keeps the files, `open` resumes the conversation), removing
   deletes the worktree.
8. **Do not invent discard authority.** If normal `remove` refuses, report why. Do not
   retry with `-f` unless the human explicitly authorized discarding local work.

## Events and state

Every crew appends `blocked` and `done` events to one shared append-only log. CrewBoss
reads them in strict FIFO insertion order and acts. FIFO means the oldest inserted event
first. Events for crews outside the current `wait` stay pending.

The first output line is the crew name and event kind. The exact payload follows. It can
use more than one line. A simple blocked event looks like this:

```text
ABC-123 blocked
Which database should I use?
```

A simple done event looks like this:

```text
ABC-123 done
The pull request is ready.
```

Delivery is at least once after a crash. An event can appear again, but an appended
event is not lost.

`list` prints `NAME ENDPOINT TASK BRANCH SUMMARY`. Endpoint values are `open`, `closed`,
and `unknown`. Task values are `running`, `blocked`, `done`, and `unknown`. `SUMMARY`
uses the stored initial task. `crew.json` stores the exact initial task and latest prompt.
`events.jsonl` is the append-only event source. `event-state.json` stores the read cursor
and pending checkpoint.

## Typical flow

```bash
"$CREWBOSS" spawn "ABC-123 make the footer sticky"
"$CREWBOSS" spawn "ABC-124 fix the login redirect"
"$CREWBOSS" spawn "ABC-125 add an export button"
"$CREWBOSS" wait ABC-123 ABC-124 ABC-125
# If the result is blocked, relay the exact question, then:
"$CREWBOSS" send ABC-124 "Yes, guests should see the login page."
"$CREWBOSS" wait ABC-123 ABC-124 ABC-125
# done for now, keep the conversation resumable:
"$CREWBOSS" close ABC-123
```
