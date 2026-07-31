# Phase 1 Shared Event Log Design

## Goal

CrewBoss must supervise several crews through events.

A crew must not notify CrewBoss by changing screen text.

Crews append events to one shared append-only log; CrewBoss reads them in strict FIFO insertion order and acts.
FIFO means the oldest inserted event first.

## Simple flow

```text
crew A ----\
crew B -----+--> append one event --> events.jsonl --> CrewBoss reads next event --> CrewBoss acts
crew C ----/
```

The log file is the durable queue. There is no separate queue service and no separate named pipe. If CrewBoss stops, unread events stay in the file.

In Phase 1, `crewboss wait NAME...` is the listener. An always-running background listener remains Phase 3 work.

## Event file

All crews append to:

```text
$CB_STATE_DIR/events.jsonl
```

The file is append-only. Phase 1 never truncates or replaces it.

Each line is one compact JSON event:

```json
{"version":1,"seq":12,"event_id":"event-12","crew":"ABC-123","crew_id":"crew-...","run_id":"run-...","kind":"blocked","payload":"Which database should I use?","time":"2026-07-31T12:00:00Z"}
```

The fields mean:

- `seq`: the global FIFO position.
- `event_id`: the stable event name.
- `crew`: the public crew name.
- `crew_id`: one crew lifetime. It changes after remove and spawn.
- `run_id`: one prompt. It changes after `send`.
- `kind`: `blocked` or `done`.
- `payload`: the exact question or final answer.
- `time`: useful history. It does not decide FIFO order.

CrewBoss assigns `seq`, `event_id`, and `time`. The crew cannot choose them.

A portable bakery lock protects sequence assignment and append. Each process creates a chooser claim, then a numbered ticket claim, under the lock's claims directory. Live claims wait by ticket order. `mkdir` creates the claims, but this is not a simple `mkdir` mutex. The next sequence comes from the last complete log line. Therefore physical line order and sequence order are the same. Concurrent crews cannot merge or overwrite lines.

## Crew protocol

CrewBoss saves the crew record before it sends a prompt. The record includes:

- the exact initial task;
- the latest prompt;
- `crew_id`;
- `run_id`;
- endpoint state: `open`, `closed`, or `unknown`;
- task state: `running`, `blocked`, `done`, or `unknown`.

The prompt gives the crew an exact internal command:

```bash
crewboss emit CREW CREW_ID RUN_ID blocked "the exact question"
crewboss emit CREW CREW_ID RUN_ID done "the final answer"
```

The real prompt also sets the exact `CB_STATE_DIR` and uses the absolute CrewBoss path.

When the crew needs an answer, it appends `blocked` and waits. When it finishes, it appends `done`. The event append is the notification. Screen text is not a notification.

The existing retry that starts a new Herdr agent remains. The existing retry that confirms prompt delivery also remains. It confirms the unique `run_id` marker.

## FIFO reading

CrewBoss stores its read position and pending events in:

```text
$CB_STATE_DIR/event-state.json
```

This is a small checkpoint file. It is not the event source. It contains:

```json
{"cursor":12,"pending":{"crew-id":{"...":"event"}}}
```

The cursor and pending map are written together by replacing one temporary file. This closes the crash gap between "I read the event" and "I saved the event for its crew."

`crewboss wait A B` works like this:

1. Read event lines after the cursor.
2. Process every line in global sequence order.
3. Save an event for an unselected crew as pending.
4. Update the crew's current task state.
5. Return the oldest current event for A or B.
6. Remove that pending event only after its output is printed.

For example:

```text
1  C blocked
2  B done
3  A blocked
```

`crewboss wait A B` first saves C's event. It then returns B's event. A later `crewboss wait C` returns C's older event. Nothing is skipped or lost.

If one run writes `blocked` and then `done` before CrewBoss reads the log, `done` replaces the old blocked marker for that run. CrewBoss does not ask a question that is no longer blocking the crew.

## Crash and restart rule

The delivery rule is **at least once**:

- An event can be printed twice after a crash.
- An event must never be lost after it was appended.

CrewBoss updates durable crew state before advancing the event cursor. Applying the same event again is safe because the crew record stores its last applied sequence.

A complete malformed log line stops consumption with a clear error. CrewBoss does not skip it. An incomplete final line is left unread until it becomes complete.

## Old and stale events

An event is current only when all three values match the registry:

- crew name;
- `crew_id`;
- `run_id`.

An old event still remains in the append-only history. CrewBoss advances past it, but does not change current state or wake a new crew.

This protects a new `ABC-123` crew from events written by an older removed `ABC-123` crew. It also protects a new prompt from a late event from the previous prompt.

## Stale endpoint reconciliation

`crewboss list` asks Herdr whether each open crew still exists.

- Exact `agent_not_found`: save the crew as `closed`. The user can run `crewboss open NAME`.
- Backend error, unexpected error, or malformed response: save `unknown`. CrewBoss does not guess.
- Matching live pane: save `open`.
- Different live pane: save `unknown`. CrewBoss does not adopt it silently.

Closing and reopening a crew keeps its task, identities, task state, and pending event.

## Commands and output

The public wait command becomes:

```text
crewboss wait <name>...
```

It returns the oldest current event for the selected crews.

The first output line is the crew name and event kind. The exact payload follows and can use more than one line. A simple blocked event looks like this:

```text
ABC-123 blocked
Which database should I use?
```

A simple done event looks like this:

```text
ABC-123 done
The pull request is ready.
```

`emit` is an internal command used by crews. It still validates all names, identities, kinds, and payloads before appending.

`list` prints these exact headers:

```text
NAME ENDPOINT TASK BRANCH SUMMARY
```

`ENDPOINT` is `open`, `closed`, or `unknown`. `TASK` is `running`, `blocked`, `done`, or `unknown`. `SUMMARY` uses the stored initial task. The exact initial task and latest prompt remain in `crew.json`.

## Compatibility

Old registry records remain readable. Missing Phase 1 fields are shown as `unknown`.

An already-running old crew does not know the event command. The user must send it a new prompt after installing Phase 1, or finish it before upgrading. New prompts use only the event protocol.

## Files

- `scripts/lib/events.sh`: append, FIFO checkpoint, pending events, and event locks.
- `scripts/lib/registry.sh`: locked crew records, stored tasks, identities, and event-derived task state.
- `scripts/lib/agent.sh`: prompt delivery and the crew event instructions.
- `scripts/lib/pane.sh`: exact endpoint reconciliation.
- `scripts/crewboss`: command flow and `wait NAME...`.
- `tests/test_events.sh`: concurrent append and log validation.
- `tests/test_wait.sh`: FIFO selection, restart, stale identity, and reconciliation.
- `README.md`, `SKILL.md`, `AGENTS.md`: the shipped event-driven contract.

## Phase boundary

Phase 1 acts on two crew events:

- `blocked`: save and return the question.
- `done`: save and return the result.

Delivery, pull-request landing, background watching, notifications, and log compaction remain later phases.
