# Phase 0 Trust Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent crewboss from using the primary checkout, closing an unrelated
pane, or tearing down locally unpushed work, then enforce those guarantees with
Bash tests and CI.

**Architecture:** Keep the current five-module Bash structure. Add narrow
fail-closed checks at the existing tree and pane boundaries, then make `remove`
coordinate them in a recoverable order. Test library boundaries with shell
function fakes and test the dispatcher with temporary Git repositories and fake
`herdr` and `wt` executables.

**Tech Stack:** Bash, Git, jq, herdr 0.7.5 JSON contracts, worktrunk 0.33.0 CLI,
ShellCheck, GitHub Actions.

## Global Constraints

- Every public command continues to target a crew name, never a pane ID, path, or
  timeout.
- worktrunk continues to own worktrees; herdr continues to own panes and agents.
- crewboss continues to own only its JSON registry.
- Do not change the completion sentinel or any startup or prompt retry loop.
- Add no package manager and no external test framework.
- Keep `README.md`, `SKILL.md`, and command help synchronized with behavior.
- Use short sentences and define jargon for non-native English readers.
- Never commit or push on `main`.
- Do not claim that Codex resume works; it remains unverified.

---

### Task 1: Test harness and primary-checkout protection

**Files:**

- Create: `tests/test_helper.sh`
- Create: `tests/run`
- Create: `tests/test_tree.sh`
- Modify: `scripts/lib/tree.sh:14-23`

**Interfaces:**

- Produces: `cb_tree_primary_path() -> absolute path on stdout`
- Preserves: `cb_tree_create(branch) -> reusable or newly created worktree path`
- Produces for later tests: `run_test`, `assert_eq`, `assert_contains`,
  `assert_not_contains`, and `finish_tests`

- [ ] **Step 1: Create the dependency-free test harness**

Create `tests/test_helper.sh` with this control flow:

```bash
#!/bin/bash
set -u

TEST_COUNT=0
TEST_FAILURES=0

assert_eq() {
  local expected=$1 actual=$2
  [ "$expected" = "$actual" ] || {
    printf 'expected: %s\nactual:   %s\n' "$expected" "$actual" >&2
    return 1
  }
}

assert_contains() {
  local haystack=$1 needle=$2
  case $haystack in
    *"$needle"*) ;;
    *) printf 'missing text: %s\n' "$needle" >&2; return 1 ;;
  esac
}

assert_not_contains() {
  local haystack=$1 needle=$2
  case $haystack in
    *"$needle"*) printf 'unexpected text: %s\n' "$needle" >&2; return 1 ;;
    *) ;;
  esac
}

run_test() {
  local name=$1
  shift
  TEST_COUNT=$((TEST_COUNT + 1))
  if ( "$@" ); then
    printf 'ok %d - %s\n' "$TEST_COUNT" "$name"
  else
    printf 'not ok %d - %s\n' "$TEST_COUNT" "$name"
    TEST_FAILURES=$((TEST_FAILURES + 1))
  fi
}

finish_tests() {
  [ "$TEST_FAILURES" -eq 0 ] || {
    printf '%d of %d tests failed\n' "$TEST_FAILURES" "$TEST_COUNT" >&2
    exit 1
  }
  printf '%d tests passed\n' "$TEST_COUNT"
}
```

Create `tests/run` so every behavior file runs in a fresh Bash process:

```bash
#!/bin/bash
set -u

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
status=0

for test_file in "$TEST_ROOT"/test_*.sh; do
  [ "$(basename "$test_file")" = test_helper.sh ] && continue
  bash "$test_file" || status=1
done

exit "$status"
```

- [ ] **Step 2: Write failing D1 tests**

In `tests/test_tree.sh`, source `test_helper.sh` and `scripts/lib/tree.sh`. Define
`cb_tree_path`, `cb_tree_primary_path`, and `wt` as shell functions inside each
test so no real worktree is changed.

Add these cases:

```bash
test_rejects_primary_checkout() {
  cb_tree_path() { printf '/repo'; }
  cb_tree_primary_path() { printf '/repo'; }
  wt() { printf 'wt must not run\n' >&2; return 99; }

  local output status
  output=$(cb_tree_create feature 2>&1)
  status=$?

  assert_eq 1 "$status"
  assert_contains "$output" "checked out in the primary repo"
}

test_reuses_linked_worktree() {
  cb_tree_path() { printf '/repo.feature'; }
  cb_tree_primary_path() { printf '/repo'; }
  wt() { printf 'wt must not run\n' >&2; return 99; }

  assert_eq /repo.feature "$(cb_tree_create feature)"
}

test_creates_missing_worktree() {
  local calls
  calls=$(mktemp)
  cb_tree_path() {
    if [ -s "$calls" ]; then printf '/repo.feature'; else return 1; fi
  }
  cb_tree_primary_path() { printf '/repo'; }
  cb_base_ref() { printf origin/main; }
  wt() { printf '%s\n' "$*" >> "$calls"; }

  assert_eq /repo.feature "$(cb_tree_create feature)"
  assert_contains "$(cat "$calls")" "switch --create feature --base origin/main --no-cd"
}
```

Run:

```bash
bash tests/test_tree.sh
```

Expected: the primary-checkout case fails because current `cb_tree_create` returns
the existing path without checking it.

- [ ] **Step 3: Implement D1**

Add this boundary to `scripts/lib/tree.sh`:

```bash
cb_tree_primary_path() {
  local worktrees
  worktrees=$(git worktree list --porcelain) || return 1
  printf '%s\n' "$worktrees" | sed -n 's/^worktree //p' | head -1
}

cb_tree_create() {
  local existing primary
  if existing=$(cb_tree_path "$1" 2>/dev/null); then
    primary=$(cb_tree_primary_path) || return 1
    [ -n "$primary" ] || {
      echo "crewboss: could not identify the primary repo" >&2
      return 1
    }
    [ "$existing" != "$primary" ] || {
      echo "crewboss: '$1' is checked out in the primary repo, pick another branch" >&2
      return 1
    }
    printf '%s' "$existing"
    return 0
  fi
  wt switch --create "$1" --base "$(cb_base_ref)" --no-cd >&2 || return 1
  cb_tree_path "$1"
}
```

- [ ] **Step 4: Run Task 1 checks**

Run:

```bash
bash tests/test_tree.sh
bash tests/run
bash -n scripts/crewboss scripts/lib/*.sh tests/run tests/test_*.sh
```

Expected: all tests and syntax checks pass.

- [ ] **Step 5: Commit Task 1**

```bash
git add scripts/lib/tree.sh tests/test_helper.sh tests/run tests/test_tree.sh
git commit -m "fix: keep crews out of the primary checkout"
```

---

### Task 2: Pane identity protection

**Files:**

- Create: `tests/test_pane.sh`
- Modify: `scripts/lib/pane.sh:23-25`
- Modify: `scripts/crewboss:118-123`

**Interfaces:**

- Changes: `cb_pane_close(stored_pane, crew_name) -> 0 only when close is safe`
- Consumes: herdr JSON at `.result.agent.pane_id` and
  `.error.code == "agent_not_found"`

- [ ] **Step 1: Write failing pane tests**

Create `tests/test_pane.sh`. Source the helper and `scripts/lib/pane.sh`. Use a
temporary log and this fake shape:

```bash
HERDR_LOG=$(mktemp)
HERDR_MODE=matching

herdr() {
  if [ "$1 $2" = "agent get" ]; then
    case $HERDR_MODE in
      matching)
        printf '{"result":{"agent":{"pane_id":"w1:p1"}}}\n' ;;
      mismatch)
        printf '{"result":{"agent":{"pane_id":"w1:p9"}}}\n' ;;
      missing)
        printf '{"error":{"code":"agent_not_found"}}\n'; return 1 ;;
      broken)
        printf '{"error":{"code":"daemon_unavailable"}}\n'; return 1 ;;
      malformed)
        printf 'not-json\n' ;;
    esac
    return
  fi
  if [ "$1 $2" = "pane close" ]; then
    printf '%s\n' "$*" >> "$HERDR_LOG"
    return
  fi
  return 2
}
```

Add assertions for:

- matching `w1:p1` closes exactly `pane close w1:p1`
- mismatch returns nonzero, names `w1:p9` and `w1:p1`, and logs no close
- missing agent returns zero and logs no close
- daemon error returns nonzero and logs no close
- malformed success JSON returns nonzero and logs no close

Run:

```bash
bash tests/test_pane.sh
```

Expected: FAIL because current `cb_pane_close` accepts one argument and closes it
without checking the crew.

- [ ] **Step 2: Implement fail-closed pane lookup**

Replace `cb_pane_close` with:

```bash
cb_pane_close() {
  local pane=$1 name=$2 response status live
  response=$(herdr agent get "$name" 2>&1)
  status=$?

  if [ "$status" -ne 0 ]; then
    if printf '%s' "$response" |
        jq -e '.error.code == "agent_not_found"' >/dev/null 2>&1; then
      return 0
    fi
    printf '%s\n' "$response" >&2
    return 1
  fi

  live=$(printf '%s' "$response" | jq -er '.result.agent.pane_id') || {
    echo "crewboss: could not verify the pane for '$name'" >&2
    return 1
  }
  [ "$live" = "$pane" ] || {
    echo "crewboss: '$name' now lives in $live, not $pane - refusing to close" >&2
    return 1
  }
  herdr pane close "$pane" >/dev/null
}
```

- [ ] **Step 3: Make `close` honor the result**

Change `do_close` to pass the crew name and stop before registry mutation:

```bash
cb_pane_close "$(cb_reg_field "$1" pane)" "$1" ||
  die "could not safely close '$1'"
cb_reg_put "$1" '{"status": "closed", "token": ""}' ||
  die "could not update the crew registry"
```

Do not change `remove` yet; Task 3 rewrites its full sequence.

- [ ] **Step 4: Run Task 2 checks**

Run:

```bash
bash tests/test_pane.sh
bash tests/run
bash -n scripts/crewboss scripts/lib/*.sh tests/run tests/test_*.sh
```

Expected: all tests and syntax checks pass.

- [ ] **Step 5: Commit Task 2**

```bash
git add scripts/lib/pane.sh scripts/crewboss tests/test_pane.sh
git commit -m "fix: verify crew identity before closing panes"
```

---

### Task 3: Fail-closed removal and exact force parsing

**Files:**

- Create: `tests/test_remove.sh`
- Modify: `scripts/lib/tree.sh:25-27`
- Modify: `scripts/crewboss:139-159`

**Interfaces:**

- Produces: `cb_tree_check_remove(branch, path, force) -> 0 when teardown may proceed`
- Changes: `cb_tree_remove(branch, force) -> foreground worktrunk result`
- Changes: `do_remove(name, optional_exact_-f)`

- [ ] **Step 1: Add real Git fixture helpers**

In `tests/test_remove.sh`, source `test_helper.sh`. Build each fixture under a
fresh `mktemp -d` directory:

```bash
make_git_fixture() {
  TEST_TMP=$(mktemp -d)
  TEST_REPO="$TEST_TMP/repo"
  TEST_REMOTE="$TEST_TMP/remote.git"
  TEST_BIN="$TEST_TMP/bin"
  TEST_LOG="$TEST_TMP/calls"
  TEST_STATE="$TEST_TMP/state"
  mkdir -p "$TEST_BIN" "$TEST_STATE"
  : > "$TEST_LOG"

  git init -q --bare "$TEST_REMOTE"
  git init -q -b main "$TEST_REPO"
  git -C "$TEST_REPO" config user.name Test
  git -C "$TEST_REPO" config user.email test@example.com
  printf 'base\n' > "$TEST_REPO/file"
  git -C "$TEST_REPO" add file
  git -C "$TEST_REPO" commit -q -m base
  git -C "$TEST_REPO" remote add origin "$TEST_REMOTE"
  git -C "$TEST_REPO" push -q -u origin main
  git -C "$TEST_REPO" switch -q -c feature
}
```

Add helpers that:

- commit `feature` text to `file`
- optionally push `feature` to `origin`
- write a registry entry named `crew` with branch `feature`, path `$TEST_REPO`,
  pane `w1:p1`, agent `claude`, placement `tab`, empty token, and status `open`
- write fake `herdr` and `wt` executables into `$TEST_BIN`
- run the real dispatcher with:

```bash
PATH="$TEST_BIN:$PATH" \
CB_STATE_DIR="$TEST_STATE" \
CB_BASE=origin/main \
"$PROJECT_ROOT/scripts/crewboss" remove "$@"
```

The fake herdr must log every argument. Its normal `agent get crew` response is:

```json
{"result":{"agent":{"pane_id":"w1:p1"}}}
```

The fake worktrunk must log every argument and exit with the numeric value in
`$WT_EXIT`, defaulting to zero.

- [ ] **Step 2: Write failing D3 and D4 tests**

Add these black-box cases:

1. Dirty file, no flag: status 1, output contains `uncommitted`, no herdr or wt call.
2. Local feature commit, no flag: status 1, output contains `not found on a remote`,
   no herdr or wt call.
3. Pushed feature commit: status 0, calls contain `agent get crew`,
   `pane close w1:p1`, and `remove --foreground feature`; registry no longer has
   `crew`.
4. Dirty local commit with `-f`: status 0 and worktrunk call ends in exact `-f`.
5. Argument `please`: usage error before registry lookup and no external call.
6. Arguments `-f extra`: usage error before registry lookup and no external call.
7. Pane mismatch: status 1, no worktrunk call, registry still says `open`.
8. Worktrunk exit 7: status 1, registry still exists and says `closed`.
9. Missing live agent: no pane close call, foreground removal succeeds.

Run:

```bash
bash tests/test_remove.sh
```

Expected: multiple failures because current removal has no Git preflight, treats
every second argument as force, closes by stale pane ID, and does not request
foreground worktrunk execution.

- [ ] **Step 3: Implement the tree preflight**

Add to `scripts/lib/tree.sh`:

```bash
cb_tree_check_remove() {
  local branch=$1 path=$2 force=${3:-} status base unpushed
  [ "$force" = -f ] && return 0

  [ -d "$path" ] || {
    echo "crewboss: registered worktree is missing: $path" >&2
    return 1
  }
  status=$(git -C "$path" status --porcelain) || {
    echo "crewboss: could not inspect worktree $path" >&2
    return 1
  }
  [ -z "$status" ] || {
    echo "crewboss: '$branch' has uncommitted work; commit it or add -f" >&2
    return 1
  }

  base=$(cb_base_ref) || {
    echo "crewboss: could not resolve the base branch" >&2
    return 1
  }
  unpushed=$(git -C "$path" rev-list --max-count=1 "$base..$branch" \
    --not --remotes) || {
    echo "crewboss: could not inspect commits for '$branch'" >&2
    return 1
  }
  [ -z "$unpushed" ] || {
    echo "crewboss: '$branch' has commits not found on a remote; push them or add -f" >&2
    return 1
  }
}

cb_tree_remove() {
  local branch=$1 force=${2:-}
  if [ "$force" = -f ]; then
    wt remove --foreground "$branch" -f
  else
    wt remove --foreground "$branch"
  fi
}
```

- [ ] **Step 4: Rewrite removal as a recoverable sequence**

Implement:

```bash
do_remove() {
  [ $# -ge 1 ] && [ $# -le 2 ] ||
    die "usage: crewboss remove <name> [-f]"
  local name=$1 force=${2:-} branch path
  [ -z "$force" ] || [ "$force" = -f ] ||
    die "usage: crewboss remove <name> [-f]"

  require_crew "$name"
  branch=$(cb_reg_field "$name" branch)
  path=$(cb_reg_field "$name" path)
  cb_tree_check_remove "$branch" "$path" "$force" ||
    die "refusing to remove '$name'"

  if [ "$(cb_reg_field "$name" status)" = open ]; then
    cb_pane_close "$(cb_reg_field "$name" pane)" "$name" ||
      die "could not safely close '$name'"
    cb_reg_put "$name" '{"status": "closed", "token": ""}' ||
      die "could not update the crew registry"
  fi

  cb_tree_check_remove "$branch" "$path" "$force" ||
    die "'$name' changed while closing; worktree kept (crewboss open $name)"
  cb_tree_remove "$branch" "$force" ||
    die "worktree removal failed; crew kept closed (crewboss open $name)"
  cb_reg_del "$name" || die "worktree removed but registry cleanup failed"
  echo "removed $name"
}
```

Make the dispatcher validate one or two arguments:

```bash
remove)
  [ $# -ge 1 ] && [ $# -le 2 ] ||
    die "usage: crewboss remove <name> [-f]"
  do_remove "$@"
  ;;
```

- [ ] **Step 5: Add the second-check race test**

Make fake herdr dirty the repository during `pane close`. Without `-f`, assert:

- the first check passes
- pane close occurs
- the second check refuses removal
- no worktrunk call occurs
- registry status is `closed`
- registry token is empty

Run:

```bash
bash tests/test_remove.sh
bash tests/run
```

Expected: all removal tests pass.

- [ ] **Step 6: Run Task 3 checks**

Run:

```bash
bash tests/run
bash -n scripts/crewboss scripts/lib/*.sh tests/run tests/test_*.sh
scripts/crewboss help
```

Expected: all tests and checks pass.

- [ ] **Step 7: Commit Task 3**

```bash
git add scripts/lib/tree.sh scripts/crewboss tests/test_remove.sh
git commit -m "fix: make crew removal fail closed"
```

---

### Task 4: ShellCheck and continuous integration

**Files:**

- Create: `.github/workflows/ci.yml`
- Modify: `scripts/crewboss:5-10`
- Modify: `scripts/lib/agent.sh:1`
- Modify: `scripts/lib/naming.sh:1`
- Modify: `scripts/lib/pane.sh:1`
- Modify: `scripts/lib/registry.sh:1`
- Modify: `scripts/lib/tree.sh:1`
- Modify: `tests/test_pane.sh:4-6`
- Modify: `tests/test_remove.sh:5`
- Modify: `tests/test_tree.sh:4-47`
- Modify: `tests/run`

**Interfaces:**

- Produces: one local command set that CI repeats exactly

- [ ] **Step 1: Capture the current raw ShellCheck failure**

Run:

```bash
shellcheck scripts/crewboss scripts/lib/*.sh
```

Expected: SC2148 for sourced libraries and SC1091 for dynamic source paths.

- [ ] **Step 2: Add narrow ShellCheck metadata**

Add this first line to every `scripts/lib/*.sh` file:

```bash
# shellcheck shell=bash
```

Add one exact source annotation before each dispatcher source:

```bash
# shellcheck source=scripts/lib/naming.sh
. "$CB_HOME/lib/naming.sh"
# shellcheck source=scripts/lib/tree.sh
. "$CB_HOME/lib/tree.sh"
# shellcheck source=scripts/lib/pane.sh
. "$CB_HOME/lib/pane.sh"
# shellcheck source=scripts/lib/agent.sh
. "$CB_HOME/lib/agent.sh"
# shellcheck source=scripts/lib/registry.sh
. "$CB_HOME/lib/registry.sh"
```

Add source annotations for dynamic test imports. For test doubles that ShellCheck cannot
trace through sourced production code, use a local `SC2329` disable immediately before
the fake function.

- [ ] **Step 3: Make the suite run syntax, help, and ShellCheck**

Define `PROJECT_ROOT` as the parent of `TEST_ROOT`. Replace the existing final
`exit "$status"` with:

```bash
[ "$status" -eq 0 ] || exit "$status"

bash -n "$PROJECT_ROOT/scripts/crewboss" "$PROJECT_ROOT"/scripts/lib/*.sh
"$PROJECT_ROOT/scripts/crewboss" help >/dev/null
shellcheck "$PROJECT_ROOT/scripts/crewboss" "$PROJECT_ROOT"/scripts/lib/*.sh
```

The final ShellCheck command becomes the script's exit status.

- [ ] **Step 4: Add GitHub Actions**

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
  pull_request:

permissions:
  contents: read

jobs:
  test:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v6
      - name: Install shell tools
        run: sudo apt-get update && sudo apt-get install --yes jq shellcheck
      - name: Run behavior and static checks
        run: bash tests/run
```

- [ ] **Step 5: Run Task 4 checks**

Run:

```bash
bash tests/run
shellcheck scripts/crewboss scripts/lib/*.sh tests/run tests/test_*.sh
git diff --check
```

Expected: every command passes without warning exclusions.

- [ ] **Step 6: Commit Task 4**

```bash
git add .github/workflows/ci.yml scripts tests/run
git commit -m "ci: test crewboss safety behavior"
```

---

### Task 5: Shipped documentation

**Files:**

- Modify: `scripts/crewboss:12-29`
- Modify: `README.md:13-24,100-127`
- Modify: `SKILL.md:29-65`
- Modify: `AGENTS.md:20-35`

**Interfaces:**

- Preserves: the `SKILL.md` frontmatter trigger contract
- Documents: exact `remove <name> [-f]` behavior and local check command

- [ ] **Step 1: Update command help**

Keep the command shape and add two short lines after the command list:

```text
remove refuses dirty or locally unpushed work. -f is explicit discard authority.
crewboss verifies the live pane before closing it and never spawns in the primary checkout.
```

- [ ] **Step 2: Update README**

Change the quick example comment for `remove -f` to say it discards local work.
Add a `Safe cleanup` section that explains:

```markdown
## Safe cleanup

`crewboss remove NAME` checks the worktree before it closes anything. It refuses
uncommitted files and commits that are not present on a known remote. Push or commit
the work and run the command again.

`-f` means that you accept discarding local work. It never lets crewboss close a pane
that belongs to another agent.

crewboss also refuses to start a crew when its branch is checked out in your primary
repo. A crew always runs in a separate worktree.
```

Add a `Checks` section with:

```bash
bash tests/run
```

- [ ] **Step 3: Update the shipped skill**

In the interface and orchestrator rules, state:

- normal removal checks dirty and locally unpushed work
- `-f` is explicit discard authority
- a refusal leaves the registry and worktree recoverable
- the orchestrator must report a refusal rather than retry with `-f` unless the human
  explicitly authorized discard

Keep the frontmatter description unchanged because command triggers did not change.

- [ ] **Step 4: Update contributor guidance**

Replace the no-test statement in `AGENTS.md` with the exact check:

```bash
bash tests/run
```

Keep the disposable Herdr smoke commands as the runtime verification section.

- [ ] **Step 5: Verify documentation and behavior agree**

Run:

```bash
rg -n "remove|primary checkout|unpushed|discard|tests/run" \
  scripts/crewboss README.md SKILL.md AGENTS.md
bash tests/run
git diff --check
```

Confirm that every document uses `remove <name> [-f]`, no document says force is
automatic, and the skill tells agents not to invent discard authority.

- [ ] **Step 6: Commit Task 5**

```bash
git add scripts/crewboss README.md SKILL.md AGENTS.md
git commit -m "docs: explain fail-closed crew cleanup"
```

---

### Task 6A: Herdr-compatible internal agent targets

The first disposable smoke test exposed an integration defect: public Jira crew
names such as `SMOKE-100` are valid crewboss names, but Herdr 0.7.5 accepts only
lowercase internal agent names. Keep the public name in the CLI, pane label, and
registry. Derive one deterministic Herdr target at every `herdr agent` boundary.

**Files:**

- Modify: `scripts/lib/naming.sh`
- Modify: `scripts/lib/agent.sh`
- Modify: `scripts/lib/pane.sh`
- Modify: `scripts/crewboss`
- Create: `tests/test_agent.sh`
- Modify: `tests/test_pane.sh`

**Interfaces:**

- Produces: `cb_agent_target(public_name) -> Herdr-compatible internal name`
- Preserves valid existing lowercase agent names unchanged
- Uses the same target for start, prompt, read, explain, get, and focus
- Keeps public crew names unchanged in the registry and command output

- [ ] **Step 1: Write failing adapter-boundary tests**

Cover `SMOKE-100` at every Herdr agent command. Assert that Herdr receives
`smoke-100`, while command output and registry lookup continue to use
`SMOKE-100`. Cover a valid existing lowercase name and an invalid long name so
the mapper is deterministic, starts with a lowercase letter, uses only Herdr's
allowed characters, and is no longer than 32 characters.

Run:

```bash
bash tests/test_agent.sh
bash tests/test_pane.sh
```

Expected: the new uppercase cases fail before the adapter is implemented.

- [ ] **Step 2: Implement one deterministic adapter**

Add `cb_agent_target` to `scripts/lib/naming.sh`. Lowercase a public name when
that produces a valid Herdr name. For names that still violate Herdr's
lowercase-letter start, allowed-character, or 32-character rules, derive a
stable `crew-<git-object-hash-prefix>` target. Do not store the internal target;
all call sites must derive it from the public name.

Use the adapter in:

- `cb_agent_start`
- both Herdr calls in `cb_agent_prompt`
- `cb_agent_read`
- `cb_agent_state`
- `cb_pane_close`
- `do_focus`

Do not change pane labels, registry keys, public output, or the existing startup
and prompt retry loops.

- [ ] **Step 3: Run Task 6A checks**

Run:

```bash
bash tests/test_agent.sh
bash tests/test_pane.sh
bash tests/run
bash -n scripts/crewboss scripts/lib/*.sh tests/run tests/test_*.sh
shellcheck scripts/crewboss scripts/lib/*.sh tests/run tests/test_*.sh
git diff --check
```

Expected: all commands exit zero.

- [ ] **Step 4: Commit Task 6A**

```bash
git add docs/superpowers/plans/2026-07-31-phase-0-trust.md \
  scripts/lib/naming.sh scripts/lib/agent.sh scripts/lib/pane.sh \
  scripts/crewboss tests/test_agent.sh tests/test_pane.sh
git commit -m "fix: map crew names to herdr targets"
```

---

### Task 6: Final verification and disposable Herdr smoke test

**Files:**

- Modify only if verification exposes a defect in a file already listed above.

**Interfaces:**

- Proves every acceptance criterion in the approved design.

- [ ] **Step 1: Run all automated checks from a clean shell**

Run:

```bash
bash tests/run
bash -n scripts/crewboss scripts/lib/*.sh tests/run tests/test_*.sh
shellcheck scripts/crewboss scripts/lib/*.sh tests/run tests/test_*.sh
scripts/crewboss help
git diff --check
```

Expected: all commands exit zero.

- [ ] **Step 2: Audit test coverage against D1 through D4**

Read `tests/test_tree.sh`, `tests/test_pane.sh`, and `tests/test_remove.sh`. Match
every design acceptance criterion to a named passing test. Add a missing behavior
test before claiming completion.

- [ ] **Step 3: Run a disposable live smoke test**

Create a temporary bare remote and working repository under `mktemp -d`. Make one
initial commit, push `main`, and run from the current Herdr pane:

```bash
CREWBOSS=$(pwd)/scripts/crewboss
SMOKE_ROOT=$(mktemp -d)
git init -q --bare "$SMOKE_ROOT/remote.git"
git init -q -b main "$SMOKE_ROOT/repo"
git -C "$SMOKE_ROOT/repo" config user.name Smoke
git -C "$SMOKE_ROOT/repo" config user.email smoke@example.com
printf 'smoke\n' > "$SMOKE_ROOT/repo/file"
git -C "$SMOKE_ROOT/repo" add file
git -C "$SMOKE_ROOT/repo" commit -q -m initial
git -C "$SMOKE_ROOT/repo" remote add origin "$SMOKE_ROOT/remote.git"
git -C "$SMOKE_ROOT/repo" push -q -u origin main
cd "$SMOKE_ROOT/repo"
"$CREWBOSS" spawn --branch smoke-phase-0 "SMOKE-100 verify phase zero"
"$CREWBOSS" list
```

Wait only until the agent has started and the task appears. Then test normal safe
teardown. If the crew created a local commit, push it or use explicit `-f` only for
this disposable repository:

```bash
"$CREWBOSS" remove SMOKE-100 -f
```

Confirm:

- the spawned path differs from the disposable primary checkout
- `list` shows the crew before removal
- pane identity is verified
- worktrunk finishes before the registry entry disappears
- `list` no longer shows the crew after removal

- [ ] **Step 4: Inspect repository state**

Run:

```bash
git status --short --branch
git log --oneline --decorate -8
```

Expected: only intentional changes are committed on `codex/phase-0-trust`; no
generated test or smoke files remain.

- [ ] **Step 5: Request final code review**

Use `superpowers:requesting-code-review` against `origin/main..HEAD`. Fix every
validated issue, rerun all checks, and only then use
`superpowers:verification-before-completion`.
