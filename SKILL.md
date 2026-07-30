---
name: crewboss
description: Spawn isolated agent sessions (Claude, Codex, or any herdr-supported agent) in dedicated git worktrees and drive them from the current session - spawn a crew on a task, wait for completion without spending tokens, read its reply, jump to its pane, close and later resume it. Use when the user asks to spawn a crew, delegate a task to a parallel agent session, orchestrate work across worktrees, or says "crewboss".
---

# crewboss

crewboss turns the current session into an orchestrator (a "First Mate"): it spawns
crew sessions, each in its own git worktree with its own agent process, visible as a
pane in the herdr terminal multiplexer. The human can watch and click between crews;
the orchestrator prompts, waits, reads, and relays.

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

Every command takes a crew name - never a pane id, a path, or a timeout:

```bash
"$CREWBOSS" spawn <task...>    # start a crew on a task (--in tab|space|split, --agent KIND, --branch NAME)
"$CREWBOSS" list               # every crew: name, state, branch, pane
"$CREWBOSS" send  <name> <text...>
"$CREWBOSS" wait  <name>       # block until the crew reports done, then print its reply
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

## Rules for the orchestrating agent

1. **Waiting must cost zero tokens.** `wait` is one blocking shell call; issue it and
   let the process sleep. Never poll `list` in a model-driven loop - every check is a
   full model turn.
2. **A task is just text.** Plain instructions, a skill invocation like
   `/deliver-ticket ABC-123`, or both. It lands in the crew's input box verbatim, so
   skills load in the crew's context, not the orchestrator's.
3. **A read is a screen snapshot, not a transcript.** Read generously (default 200
   lines) and grep for what you expect rather than trusting the tail.
4. **Prefer `close` over `remove`** when the work might continue - closing costs
   nothing (the worktree keeps the files, `open` resumes the conversation), removing
   deletes the worktree.
5. **If `wait` times out**, the crew is still going or stuck: `read` it, and if it is
   blocked on a question, `focus` it and tell the human, or `send` the answer.

## Typical flow

```bash
"$CREWBOSS" spawn "ABC-123 make the footer sticky"
"$CREWBOSS" wait ABC-123        # zero-token block; prints the crew's reply
# follow-ups in the same conversation:
"$CREWBOSS" send ABC-123 "also fix the mobile layout"
"$CREWBOSS" wait ABC-123
# done for now, keep the conversation resumable:
"$CREWBOSS" close ABC-123
```
