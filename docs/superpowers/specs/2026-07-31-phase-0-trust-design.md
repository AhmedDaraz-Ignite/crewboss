# Phase 0: trust crewboss

Date: 31 July 2026

## Goal

Close the four safety defects selected in the gap analysis, then add automated checks
that keep them closed.

The change covers:

- D1: never start a crew in the primary checkout
- D2: never close a pane unless it still belongs to that crew
- D3: never tear down committed work that is not known to a remote without explicit
  force
- D4: only the exact `-f` argument enables force
- Bash behavior tests
- ShellCheck and behavior tests in GitHub Actions
- matching help, `README.md`, and `SKILL.md` updates

D5, D6, multi-crew wait, stored task text, delivery, backend abstraction, and
secondmates stay out of this change.

## Constraints

The existing product boundaries remain:

- Every public command targets a crew name.
- worktrunk owns worktrees.
- herdr owns panes and agent processes.
- crewboss owns only its JSON registry.
- The completion sentinel and its startup and prompt retry loops do not change.
- No package manager or test framework is added.
- No commit or push is made on `main`.

## Evidence used

The gap analysis describes crewboss at commit `9e66047`. The current command code is
unchanged since that commit.

The installed runtime is:

- herdr 0.7.5
- worktrunk 0.33.0
- ShellCheck 0.11.0

Current herdr supports `herdr agent get <target>`. Its JSON response stores the live
pane at `.result.agent.pane_id`. A missing target returns
`.error.code == "agent_not_found"`.

Current worktrunk already preserves a branch with unmerged commits unless `-D` is
given. crewboss never gives `-D`. That protects the commits, but it does not protect
the crew as a unit: crewboss can still close the pane and delete the registry record
before the work is pushed. D3 therefore remains a useful crewboss-level guard.

`wt remove` runs in the background by default. Phase 0 will use `--foreground`, so
crewboss only deletes its registry record after worktrunk reports success.

## Chosen approach

Implement explicit safety checks in crewboss and keep worktrunk's own checks as a
second line of defense.

Two alternatives were rejected:

1. Trust worktrunk alone. This is smaller, but it allows crewboss to forget a crew
   whose worktree was removed while its branch was merely preserved.
2. Always pass `--no-delete-branch`. This keeps every branch, but changes the meaning
   of full teardown and leaves routine cleanup to the user.

## D1: primary checkout protection

`cb_tree_create` will distinguish three cases:

1. No worktree exists for the branch. Create one with `wt switch --create`, as today.
2. A distinct linked worktree exists. Reuse it, so a failed spawn remains retryable.
3. The branch is checked out in the primary checkout. Refuse before creating a pane
   or starting an agent.

The primary checkout path comes from the first `worktree` record in
`git worktree list --porcelain`. The existing branch path still comes from
`wt list --format=json`.

The refusal will name the branch and explain that it is checked out in the primary
repository.

## D2: pane identity protection

Pane closing will take both the stored pane ID and the crew name.

Before closing, it will call `herdr agent get <crew>`:

- If the live pane equals the stored pane, close it.
- If the live pane differs, refuse and show both IDs.
- If herdr returns `agent_not_found`, treat the pane as already gone and do not close
  the stored ID.
- If herdr returns another error or malformed JSON, refuse. Do not guess.

Both `close` and `remove` will check the result. A failed identity check stops the
command before registry or worktree mutation.

This protects against pane ID reuse without adding pane IDs to the public interface.

## D3: unpushed work protection

Before teardown, crewboss will inspect the branch in its registered worktree.

Without `-f`, removal is refused when either condition is true:

- the worktree has uncommitted or untracked changes
- the branch contains a commit after the configured base that is not reachable from
  any locally known remote ref

The remote proof is local and conservative. crewboss does not fetch during removal.
If local remote refs are stale, it may refuse safe cleanup. The user can fetch and
retry, or use explicit `-f`.

If the registered worktree, configured base, or Git state cannot be inspected,
normal removal fails closed before the pane is touched.

The commit check is based on:

```bash
git -C "$path" rev-list --max-count=1 "$(cb_base_ref)..$branch" --not --remotes
```

Any output means at least one branch commit is not known to a remote.

Removal has two safety checks:

1. Check before closing the pane. A refusal leaves the crew untouched.
2. Check again after closing the pane. This catches a last-moment write or commit.

If the second check fails, the worktree and registry record stay. The registry is
marked closed, so `crewboss open <name>` can resume the conversation.

After both checks pass, run worktrunk in the foreground. Delete the registry record
only after worktrunk succeeds.

`-f` skips the two local dirty and remote-proof refusals and is passed to worktrunk.
It is explicit discard authority for this command. crewboss still never passes
worktrunk's separate `-D` branch-deletion flag.

`-f` does not bypass pane identity validation.

## D4: exact force parsing

`remove` accepts only these forms:

```text
crewboss remove <name>
crewboss remove <name> -f
```

An unknown second argument or any third argument returns usage before any lookup or
mutation. The implementation will not use non-empty-string expansion to decide
whether force is active.

## Removal flow

The new order is:

1. Validate the exact command shape.
2. Resolve the crew record.
3. Run the first worktree safety check.
4. If the crew is open, verify pane identity and close the live pane.
5. Mark the registry record closed and clear its pending token.
6. Run the second worktree safety check.
7. Run `wt remove --foreground`, with `-f` only when explicitly requested.
8. Delete the registry record.

On any failure after step 4, the branch, worktree, and registry record remain. The
crew may be closed, but it is recoverable with `open`.

## Tests

Add a dependency-free Bash behavior suite. It will run the real
`scripts/crewboss` dispatcher with temporary registry and git repositories. Fake
`herdr` and `wt` executables on `PATH` will record calls and return controlled JSON.

The suite will prove:

### D1

- an existing primary checkout is rejected before pane creation
- an existing distinct worktree is reused
- a missing worktree is created as before

### D2

- a matching live pane is closed
- a different live pane is refused and nothing else is removed
- a missing live agent does not close a possibly reused pane
- a herdr operational error fails closed

### D3

- dirty work is refused before the pane closes
- a local-only branch commit is refused
- a branch head reachable from a remote is removable
- exact `-f` bypasses the local safety refusals
- a last-moment change caught by the second check keeps the closed crew recoverable
- a worktrunk failure keeps the registry record
- successful removal uses `--foreground` and then deletes the record

### D4

- no flag is accepted
- exact `-f` is accepted and forwarded once
- another second argument is rejected before mutation
- extra arguments are rejected before mutation

The suite will also run:

```bash
bash -n scripts/crewboss scripts/lib/*.sh
scripts/crewboss help
```

## ShellCheck

The raw repository command must pass:

```bash
shellcheck scripts/crewboss scripts/lib/*.sh
```

Each sourced library will declare Bash as its shell. The dispatcher will give
ShellCheck explicit source paths for its five dynamic `source` statements. This
avoids global warning suppression.

## Continuous integration

Add `.github/workflows/ci.yml` with:

- `push` and `pull_request` triggers
- read-only repository permissions
- an Ubuntu runner
- `actions/checkout@v6`
- ShellCheck installation
- one behavior-test step
- one syntax and ShellCheck step

The workflow must use the same commands documented for local contributors.

## Documentation

Update all shipped interfaces in the same implementation commit:

- `scripts/crewboss help`
- `README.md`
- `SKILL.md`

The docs will say:

- `remove` accepts only optional exact `-f`
- normal removal refuses dirty or locally unpushed work
- `-f` is explicit discard authority
- pane identity and primary-checkout protections are automatic
- how to run the behavior tests and ShellCheck locally

The text will stay short and use the existing plain-language style.

## Acceptance criteria

Phase 0 is complete when:

1. All D1 through D4 behavior tests pass.
2. `bash -n scripts/crewboss scripts/lib/*.sh` passes.
3. `shellcheck scripts/crewboss scripts/lib/*.sh` passes without exclusions.
4. `scripts/crewboss help` passes and describes exact `-f` behavior.
5. README and `SKILL.md` match the command behavior.
6. The GitHub Actions workflow runs the same tests and checks.
7. A manual smoke test in herdr confirms spawn, list, and safe teardown in a
   disposable git repository.

## Later phases

Phase 1 will build on this foundation with multi-crew waiting, stored task text,
blocked detection, and stale-state reconciliation. This design does not pre-choose
the persistence or watcher architecture for that work.
