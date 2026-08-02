# Phase 1 Shared Event Log Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace screen-sentinel supervision with one shared append-only FIFO event log that reports the first blocked or done crew, survives restart, stores task text, and reconciles stale endpoints.

**Architecture:** Crews call an internal `emit` command that appends one locked JSON line to `events.jsonl`. `wait NAME...` consumes every log line in global sequence order, writes its cursor and pending events together to `event-state.json`, updates current crew state, and returns the oldest current event for the selected names. `crew_id` and `run_id` reject old events.

**Tech Stack:** Bash 3.2-compatible shell, `jq`, portable `mkdir` locks, Herdr 0.7.5 CLI, existing shell test harness.

## Global Constraints

- Keep every public command keyed by crew name. Do not expose pane IDs, paths, or timeouts.
- Use one shared append-only file at `$CB_STATE_DIR/events.jsonl`.
- FIFO order is the sequence assigned while holding the append lock, not wall-clock time.
- New prompts notify CrewBoss only with `blocked` and `done` events.
- Keep the observed Herdr start retry and prompt-delivery retry.
- A crash may repeat an event, but must never lose an appended event.
- Use Bash 3.2-compatible syntax. Do not require GNU `flock`, GNU `timeout`, or another service.
- Keep `README.md`, `SKILL.md`, command help, and `AGENTS.md` in sync.
- Use short sentences and define new terms because the main reader is not a native English speaker.

## File Structure

- Create `scripts/lib/events.sh`: event append, FIFO consumption, checkpoint, pending selection, and event lock.
- Modify `scripts/lib/registry.sh`: portable lock, atomic writes, IDs, stored task fields, identity checks, and event-derived task state.
- Modify `scripts/lib/agent.sh`: event instructions and `run_id` prompt confirmation.
- Modify `scripts/lib/pane.sh`: exact endpoint probe with `open`, `closed`, and `unknown` results.
- Modify `scripts/crewboss`: persist-before-prompt flow, `emit`, multi-name `wait`, list reconciliation, and state-preserving close/open.
- Create `tests/test_events.sh`: concurrent real appends and append-only checks.
- Create `tests/test_wait.sh`: FIFO routing, restart, stale identities, and endpoint reconciliation.
- Modify `tests/test_agent.sh`: verify the event prompt and keep delivery retry coverage.
- Modify `README.md`, `SKILL.md`, and `AGENTS.md`: shipped interface and architecture.

---

### Task 1: Locked and atomic crew registry

**Files:**
- Create: `tests/test_registry.sh`
- Modify: `scripts/lib/registry.sh`

**Interfaces:**
- Consumes: `jq`, `mkdir`, `mv`, `kill -0`, and `$CB_STATE_DIR`.
- Produces: `cb_lock_acquire PATH`, `cb_lock_release PATH`, `cb_id_new PREFIX`, `cb_reg_put NAME JSON`, `cb_reg_replace NAME JSON`, `cb_reg_identity_matches NAME CREW_ID RUN_ID`, `cb_reg_apply_event EVENT_JSON`, and `cb_reg_set_endpoint NAME STATE`.

- [ ] **Step 1: Write failing registry tests**

Add tests that run 32 concurrent `cb_reg_put` calls and assert all fields remain. Add a test that a matching event changes `task_status`, `blocked`, `message`, and `last_event_seq`. Add tests that old `crew_id` and old `run_id` return status 2 without changing the record.

```bash
for i in $(seq 1 32); do
  (cb_reg_put crew "$(jq -n --arg k "k$i" --arg v "$i" '{($k):$v}')") &
done
wait
jq -e '(.crew | keys | map(select(startswith("k"))) | length) == 32' "$CB_REG"
```

- [ ] **Step 2: Run the registry test and see RED**

Run: `bash tests/test_registry.sh`

Expected: FAIL because registry updates are unlocked and the new helpers do not exist.

- [ ] **Step 3: Add portable locks and atomic writes**

Implement an atomic `mkdir` lock. Store the owner PID inside it. A waiter may remove the lock only when the owner PID is no longer alive. Create temporary files inside `$CB_STATE_DIR`, set private permissions, then rename them over `crew.json`.

```bash
cb_reg_put() {
  cb_reg_init
  cb_lock_acquire "$CB_REG_LOCK" || return 1
  local tmp status=0
  tmp=$(mktemp "$CB_STATE_DIR/.crew.json.XXXXXX") || status=1
  if [ "$status" -eq 0 ]; then
    jq --arg n "$1" --argjson v "$2" '.[$n] = ((.[$n] // {}) + $v)' \
      "$CB_REG" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$CB_REG" || status=1
  fi
  [ -z "${tmp:-}" ] || [ ! -f "$tmp" ] || rm -f "$tmp"
  cb_lock_release "$CB_REG_LOCK"
  return "$status"
}
```

Add conditional event application. Return 0 for a current event, 2 for a stale identity, and 1 for an I/O or JSON error. Replaying the same sequence must be safe.

- [ ] **Step 4: Run registry tests and the full baseline**

Run: `bash tests/test_registry.sh && bash tests/run`

Expected: all registry tests pass and all 33 baseline behavior tests still pass.

- [ ] **Step 5: Commit the registry unit**

```bash
git add scripts/lib/registry.sh tests/test_registry.sh
git commit -m "feat: make crew state durable under concurrency"
```

### Task 2: Shared append-only event source

**Files:**
- Create: `scripts/lib/events.sh`
- Create: `tests/test_events.sh`
- Modify: `scripts/crewboss`

**Interfaces:**
- Consumes: registry identity helpers from Task 1.
- Produces: `cb_event_init`, `cb_event_emit CREW CREW_ID RUN_ID KIND PAYLOAD`, and internal `crewboss emit CREW CREW_ID RUN_ID blocked|done PAYLOAD`.

- [ ] **Step 1: Write the concurrent append test**

Create one current crew record. Start 16 processes. Each process runs the real `crewboss emit` command eight times. Assert 128 valid lines, literal sequences 1 through 128, unique event IDs, exact payloads, and local producer order. Open the file on a read descriptor before later appends and assert that descriptor sees later lines; this proves the source file was not replaced.

```bash
jq -s -e '
  length == 128 and
  ([.[].seq] == [range(1;129)]) and
  ([.[].event_id] | unique | length) == 128 and
  all(.[]; .kind == "blocked" or .kind == "done")
' "$CB_STATE_DIR/events.jsonl"
```

- [ ] **Step 2: Run the event test and see RED**

Run: `bash tests/test_events.sh`

Expected: FAIL because `emit` and `events.jsonl` do not exist.

- [ ] **Step 3: Implement the append boundary**

Use one compact JSON object per line. Under the event lock, read and validate the last complete line, assign `seq + 1`, build `event-$seq`, and append with one `printf` call. Never accept sequence, ID, or time from the crew.

```json
{"version":1,"seq":1,"event_id":"event-1","crew":"A","crew_id":"crew-1","run_id":"run-1","kind":"done","payload":"ready","time":"2026-07-31T12:00:00Z"}
```

Reject an unknown crew, stale identity, kind outside `blocked|done`, or an empty payload before append.

- [ ] **Step 4: Run and stress the event test**

Run: `bash tests/test_events.sh`

Then run:

```bash
i=0
while [ "$i" -lt 25 ]; do
  bash tests/test_events.sh >/dev/null || exit 1
  i=$((i + 1))
done
```

Expected: every run passes with consecutive physical FIFO order.

- [ ] **Step 5: Commit the append-only source**

```bash
git add scripts/lib/events.sh scripts/crewboss tests/test_events.sh
git commit -m "feat: append crew events to one FIFO log"
```

### Task 3: FIFO consumption and multi-crew wait

**Files:**
- Modify: `scripts/lib/events.sh`
- Create: `tests/test_wait.sh`
- Modify: `scripts/crewboss`

**Interfaces:**
- Consumes: `cb_reg_apply_event EVENT_JSON` from Task 1 and the JSONL source from Task 2.
- Produces: `cb_event_pump`, `cb_event_next NAME...`, `cb_event_ack EVENT_JSON`, `cb_event_drop_crew CREW_ID`, and `crewboss wait NAME...`.

- [ ] **Step 1: Write FIFO routing and restart tests**

Write matching raw events in this order: C blocked, B done, A blocked. Run three separate commands:

```bash
crewboss wait A B  # B done
crewboss wait C    # C blocked was kept
crewboss wait A B  # A blocked; B is not repeated
```

Also write old-crew, old-run, and current events for A. Assert `wait A` returns only the current event.

- [ ] **Step 2: Run wait tests and see RED**

Run: `bash tests/test_wait.sh`

Expected: FAIL because the current dispatcher passes only `$1` and waits on screen output.

- [ ] **Step 3: Implement one atomic checkpoint**

Create `$CB_STATE_DIR/event-state.json` with this shape:

```json
{"cursor":0,"pending":{}}
```

While holding the event lock, read lines after `cursor` in exact sequence. For a current event, apply registry state first. Then write the new cursor and pending entry together through a temporary file and rename. For a stale event, advance the cursor without adding pending state.

For one crew, a newer current event replaces its older pending event. This makes a later `done` replace an obsolete `blocked` question.

- [ ] **Step 4: Replace screen waiting with event listening**

Validate every requested crew. Repeatedly pump available events, select the lowest pending sequence for the requested names, and sleep inside the same shell process only when no event exists. Print before acknowledgement:

```text
B done
B finished
```

Do not hold the event lock while sleeping. If printing fails, keep the event pending.

- [ ] **Step 5: Run wait, event, and baseline tests**

Run: `bash tests/test_wait.sh && bash tests/test_events.sh && bash tests/run`

Expected: all tests pass. `wait A B` returns by event sequence, not argument order.

- [ ] **Step 6: Commit FIFO consumption**

```bash
git add scripts/lib/events.sh scripts/crewboss tests/test_wait.sh
git commit -m "feat: wait for the first crew event"
```

### Task 4: Persist task and run identity before prompts

**Files:**
- Modify: `scripts/lib/agent.sh`
- Modify: `scripts/crewboss`
- Modify: `tests/test_agent.sh`
- Modify: `tests/test_wait.sh`

**Interfaces:**
- Consumes: internal `crewboss emit` from Task 2.
- Produces: `cb_agent_prompt NAME TEXT CREW_ID RUN_ID TOOL_PATH STATE_DIR`; spawn records with `task`, `latest_prompt`, `crew_id`, `run_id`, `status`, and `task_status`.

- [ ] **Step 1: Write prompt and persist-before-send tests**

Assert the prompt contains the absolute emit command, exact state directory, current crew and run IDs, both kinds, and no `TASKDONE` completion token. Make the fake prompt call `emit` immediately and assert the registry identity already exists.

- [ ] **Step 2: Run agent tests and see RED**

Run: `bash tests/test_agent.sh && bash tests/test_wait.sh`

Expected: FAIL because the current prompt uses a screen sentinel and spawn saves after prompting.

- [ ] **Step 3: Add the event instructions**

Keep the start retry. Keep the prompt-delivery retry, but confirm the unique line `CrewBoss run id: RUN_ID` in the pane instead of sentinel digits. Tell the crew to emit the exact question before waiting and the final answer before ending.

- [ ] **Step 4: Change spawn and send ordering**

For spawn, mint `crew_id` and `run_id`, then save the exact task and current state before calling `cb_agent_prompt`. For send, mint a new `run_id`, save the latest prompt before sending, and clear an older block only after prompt delivery succeeds. A failed send restores the prior blocked state.

Do not clear event state in `close` or `open`. A successful remove deletes derived pending state for that `crew_id`, but leaves raw history unchanged.

- [ ] **Step 5: Run focused and full tests**

Run: `bash tests/test_agent.sh && bash tests/test_wait.sh && bash tests/run`

Expected: all tests pass and the two observed Herdr retry loops remain covered.

- [ ] **Step 6: Commit the producer protocol**

```bash
git add scripts/lib/agent.sh scripts/crewboss tests/test_agent.sh tests/test_wait.sh
git commit -m "feat: teach crews to report through events"
```

### Task 5: Reconcile stale open crews

**Files:**
- Modify: `scripts/lib/pane.sh`
- Modify: `scripts/crewboss`
- Modify: `tests/test_pane.sh`
- Modify: `tests/test_wait.sh`

**Interfaces:**
- Consumes: `herdr agent get TARGET` JSON.
- Produces: `cb_pane_status PANE NAME`, returning `open`, `closed`, or `unknown` without guessing.

- [ ] **Step 1: Write the reconciliation table test**

Test these results:

| Herdr response | Saved state |
| --- | --- |
| matching pane | `open` |
| exact `agent_not_found` | `closed` |
| `agent_not_found_stale` | `unknown` |
| daemon error | `unknown` |
| malformed success JSON | `unknown` |
| different pane | `unknown` |

Run `crewboss list` and assert it persists and prints each result. Assert it never calls pane close.

- [ ] **Step 2: Run reconciliation tests and see RED**

Run: `bash tests/test_pane.sh && bash tests/test_wait.sh`

Expected: FAIL because `list` does not save live endpoint truth.

- [ ] **Step 3: Implement the exact probe and list update**

Parse the structured error code with `jq`. Never grep error text. On success, compare the live pane ID with the registered pane. `list` first pumps available events, then prints `NAME`, `ENDPOINT`, `TASK`, `BRANCH`, and a one-line task summary.

Old records with missing Phase 1 fields print `unknown`. Exact missing records become `closed`, so `crewboss open NAME` can repair them.

- [ ] **Step 4: Run all behavior tests**

Run: `bash tests/run`

Expected: all old and new tests pass.

- [ ] **Step 5: Commit reconciliation**

```bash
git add scripts/lib/pane.sh scripts/crewboss tests/test_pane.sh tests/test_wait.sh
git commit -m "feat: reconcile missing crew endpoints"
```

### Task 6: Ship the event-driven contract

**Files:**
- Modify: `README.md`
- Modify: `SKILL.md`
- Modify: `AGENTS.md`
- Modify: `scripts/crewboss`
- Modify: `docs/superpowers/specs/2026-07-31-phase-1-event-log-design.md`

**Interfaces:**
- Consumes: final behavior from Tasks 1 through 5.
- Produces: matching user help, installed skill rules, contributor architecture, and design record.

- [ ] **Step 1: Update command help and README**

Explain `wait NAME...`, the two-line blocked/done output, stored tasks, and the one shared append-only FIFO log. State that `wait` is the Phase 1 listener and background supervision is later work.

- [ ] **Step 2: Update the installed skill**

Tell the orchestrating agent to spawn all crews, then issue one blocking `wait A B C`. On `blocked`, relay the exact question and use `send` for the answer. On `done`, act on the result. Remove the 30-minute timeout and screen-sentinel rules for new runs.

- [ ] **Step 3: Update contributor architecture**

Add `events.sh`. Replace the "completion protocol" section with the shared log rules. Keep warnings around both observed Herdr retries. Document the event and checkpoint files and the at-least-once crash rule.

- [ ] **Step 4: Check language and consistency**

Run:

```bash
rg -n 'wait <name>|TASKDONE|30 min|sentinel|events.jsonl|event-state.json' \
  README.md SKILL.md AGENTS.md scripts/crewboss \
  docs/superpowers/specs/2026-07-31-phase-1-event-log-design.md
```

Expected: no public rule still teaches sentinel waiting. Compatibility notes, if any, are clearly marked as old-record behavior.

- [ ] **Step 5: Commit documentation**

```bash
git add README.md SKILL.md AGENTS.md scripts/crewboss \
  docs/superpowers/specs/2026-07-31-phase-1-event-log-design.md
git commit -m "docs: explain event-driven crew supervision"
```

### Task 7: Final verification and runtime smoke test

**Files:**
- Modify only if verification finds a defect in an already listed file.

**Interfaces:**
- Consumes: the complete Phase 1 implementation.
- Produces: evidence that the branch is ready for review.

- [ ] **Step 1: Run static and behavior gates**

Run: `bash tests/run`

Expected: Bash syntax, help, ShellCheck, and every behavior test pass.

- [ ] **Step 2: Repeat the concurrency test**

Run the 25-iteration `tests/test_events.sh` loop from Task 2.

Expected: no lost, duplicate, malformed, or reordered records.

- [ ] **Step 3: Run a disposable two-crew Herdr smoke test**

Inside a disposable Herdr workspace and Git repository, spawn two short crews. Make one emit `blocked` and one emit `done`. Run one `crewboss wait NAME1 NAME2`, answer the blocked crew with `send`, wait again, inspect `list`, then remove both crews.

Expected: the earlier inserted event returns first, task text remains visible, and cleanup succeeds.

- [ ] **Step 4: Review the branch diff**

Run:

```bash
git diff --check main...HEAD
git status --short
git diff --stat main...HEAD
```

Expected: no whitespace errors, no unrelated files, and a clean worktree.

- [ ] **Step 5: Commit any verified correction**

If Step 1 through 4 required a correction, run its focused test, then the full gate, and commit only that correction with a precise message. If no correction was needed, do not create an empty commit.
