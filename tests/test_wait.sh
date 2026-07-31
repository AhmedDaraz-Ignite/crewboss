#!/bin/bash
set -u

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd "$TEST_ROOT/.." && pwd)
CREWBOSS="$PROJECT_ROOT/scripts/crewboss"
# shellcheck source=tests/test_helper.sh
source "$TEST_ROOT/test_helper.sh"

setup_wait() {
  TEST_TMP=$(mktemp -d)
  export CB_STATE_DIR="$TEST_TMP/state"
  trap 'rm -rf "$TEST_TMP"' EXIT
  # shellcheck source=scripts/lib/registry.sh
  source "$PROJECT_ROOT/scripts/lib/registry.sh"
  # shellcheck source=scripts/lib/events.sh
  source "$PROJECT_ROOT/scripts/lib/events.sh"

  cb_reg_put A '{"crew_id":"crew-a","run_id":"run-a","task_status":"running","last_event_seq":0}' || return 1
  cb_reg_put B '{"crew_id":"crew-b","run_id":"run-b","task_status":"running","last_event_seq":0}' || return 1
  cb_reg_put C '{"crew_id":"crew-c","run_id":"run-c","task_status":"running","last_event_seq":0}' || return 1
  cb_event_init
}

start_wait_recorded() {
  local label=$1 step
  shift
  WAIT_MARKER="$TEST_TMP/$label.status"
  WAIT_OUTPUT_FILE="$TEST_TMP/$label.out"
  WAIT_ERRORS_FILE="$TEST_TMP/$label.err"
  WAIT_PID_FILE="$TEST_TMP/$label.pid"

  (
    local child_pid child_status
    CB_STATE_DIR="$CB_STATE_DIR" CB_EVENT_WAIT_SECS=0.01 \
      "$CREWBOSS" wait "$@" > "$WAIT_OUTPUT_FILE" 2> "$WAIT_ERRORS_FILE" &
    child_pid=$!
    printf '%s\n' "$child_pid" > "$WAIT_PID_FILE"
    wait "$child_pid"
    child_status=$?
    printf '%s\n' "$child_status" > "$WAIT_MARKER"
  ) &
  WAIT_WRAPPER_PID=$!

  step=0
  while [ "$step" -lt 500 ]; do
    step=$((step + 1))
    [ -f "$WAIT_PID_FILE" ] && break
    sleep 0.01
  done
  [ -f "$WAIT_PID_FILE" ] || {
    kill -9 "$WAIT_WRAPPER_PID" 2>/dev/null || true
    wait "$WAIT_WRAPPER_PID" 2>/dev/null || true
    return 1
  }
  WAIT_CHILD_PID=
  IFS= read -r WAIT_CHILD_PID < "$WAIT_PID_FILE"
}

terminate_wait_recorded() {
  local step=0
  kill -TERM "$WAIT_CHILD_PID" 2>/dev/null || true
  while [ "$step" -lt 100 ]; do
    step=$((step + 1))
    [ -f "$WAIT_MARKER" ] && break
    sleep 0.01
  done
  if [ ! -f "$WAIT_MARKER" ]; then
    kill -9 "$WAIT_CHILD_PID" 2>/dev/null || true
  fi
  wait "$WAIT_WRAPPER_PID" 2>/dev/null || true
}

finish_wait_bounded() {
  local step=0
  while [ "$step" -lt 500 ]; do
    step=$((step + 1))
    [ -f "$WAIT_MARKER" ] && break
    sleep 0.01
  done
  if [ ! -f "$WAIT_MARKER" ]; then
    terminate_wait_recorded
    RUN_STATUS=124
  else
    wait "$WAIT_WRAPPER_PID" 2>/dev/null || true
    RUN_STATUS=
    IFS= read -r RUN_STATUS < "$WAIT_MARKER" || RUN_STATUS=1
  fi
  RUN_OUTPUT=$(cat "$WAIT_OUTPUT_FILE" 2>/dev/null || true)
  RUN_ERRORS=$(cat "$WAIT_ERRORS_FILE" 2>/dev/null || true)
}

run_wait_bounded() {
  start_wait_recorded "$@" || return 1
  finish_wait_bounded
}

write_event_source() {
  cb_event_init || return 1
  printf '%s\n' "$@" > "$CB_EVENT_SOURCE"
}

assert_corrupt_checkpoint_fails_unchanged() {
  local checkpoint=$1
  write_event_source \
    '{"version":1,"seq":1,"event_id":"event-1","crew":"A","crew_id":"crew-a","run_id":"run-a","kind":"done","payload":"must not apply","time":"2026-07-31T12:00:01Z"}' || return 1
  printf '%s\n' "$checkpoint" > "$CB_EVENT_STATE"
  cp "$CB_EVENT_SOURCE" "$TEST_TMP/events.before" || return 1
  cp "$CB_EVENT_STATE" "$TEST_TMP/event-state.before" || return 1
  cp "$CB_REG" "$TEST_TMP/crew.before" || return 1

  ! cb_event_pump >/dev/null 2>&1 || return 1
  cmp -s "$TEST_TMP/events.before" "$CB_EVENT_SOURCE" || return 1
  cmp -s "$TEST_TMP/event-state.before" "$CB_EVENT_STATE" || return 1
  cmp -s "$TEST_TMP/crew.before" "$CB_REG"
}

write_fake_wait_watchdog() {
  local path=$1
  cat > "$path" <<'WATCHDOG'
#!/bin/bash
set -u
output=$1
shift
marker="$output.timeout"
rm -f "$marker"
"$@" > "$output" &
wait_pid=$!
(
  ticks=0
  while kill -0 "$wait_pid" 2>/dev/null; do
    ticks=$((ticks + 1))
    if [ "$ticks" -ge 500 ]; then
      : > "$marker"
      kill -TERM "$wait_pid" 2>/dev/null || true
      /bin/sleep 0.1
      if kill -0 "$wait_pid" 2>/dev/null; then
        kill -KILL "$wait_pid" 2>/dev/null || true
      fi
      exit 0
    fi
    /bin/sleep 0.01
  done
) &
watchdog_pid=$!
wait "$wait_pid" 2>/dev/null
wait_status=$?
wait "$watchdog_pid" 2>/dev/null || true
if [ -e "$marker" ]; then
  printf 'fake Herdr wait timed out\n' >&2
  exit 124
fi
exit "$wait_status"
WATCHDOG
  chmod +x "$path"
}

test_spawn_persists_identity_before_prompt_and_keeps_an_immediate_event() {
  local fixture bin state tree output status
  fixture=$(mktemp -d)
  trap 'rm -rf "$fixture"' RETURN
  bin="$fixture/bin"
  state="$fixture/state"
  tree="$fixture/tree"
  mkdir -p "$bin" "$state"

  cat > "$bin/wt" <<'WT'
#!/bin/bash
case $1 in
  list)
    if [ -f "$TEST_TREE/.created" ]; then
      jq -cn --arg path "$TEST_TREE" '[{branch:"test-ABC-123-immediate-task",path:$path}]'
    else
      printf '[]\n'
    fi
    ;;
  switch)
    mkdir -p "$TEST_TREE"
    : > "$TEST_TREE/.created"
    ;;
  *) exit 2 ;;
esac
WT

  cat > "$bin/herdr" <<'HERDR'
#!/bin/bash
case "$1 $2" in
  "tab create")
    printf '{"result":{"root_pane":{"pane_id":"w1:p1"}}}\n'
    ;;
  "agent start") ;;
  "agent prompt")
    jq -e --arg name ABC-123 '
      .[$name].task == "ABC-123 immediate task" and
      .[$name].latest_prompt == "ABC-123 immediate task" and
      (.[$name].crew_id | type == "string" and startswith("crew-")) and
      (.[$name].run_id | type == "string" and startswith("run-")) and
      .[$name].status == "open" and .[$name].task_status == "running" and
      (.[$name] | has("token") | not)
    ' "$CB_STATE_DIR/crew.json" >/dev/null || exit 70
    crew_id=$(jq -r '.["ABC-123"].crew_id' "$CB_STATE_DIR/crew.json") || exit 71
    run_id=$(jq -r '.["ABC-123"].run_id' "$CB_STATE_DIR/crew.json") || exit 72
    printf '%s\n' "$4" > "$TEST_PROMPT"
    printf '%s\n' "$4" | grep -Fq "CrewBoss run id: $run_id" || exit 73
    "$CREWBOSS" emit ABC-123 "$crew_id" "$run_id" done "immediate result" || exit 74
    "$TEST_WAIT_BOUNDED" "$TEST_IMMEDIATE_OUTPUT" \
      "$CREWBOSS" wait ABC-123 || exit 75
    ;;
  "agent read")
    sed -n '/^CrewBoss run id: /p' "$TEST_PROMPT"
    ;;
  *) exit 2 ;;
esac
HERDR

  cat > "$bin/sleep" <<'SLEEP'
#!/bin/bash
exit 0
SLEEP
  chmod +x "$bin/herdr" "$bin/sleep" "$bin/wt"
  write_fake_wait_watchdog "$bin/wait-bounded"

  output=$(PATH="$bin:$PATH" CB_STATE_DIR="$state" CB_PREFIX=test \
    HERDR_WORKSPACE_ID=w1 TEST_TREE="$tree" TEST_PROMPT="$fixture/prompt" \
    TEST_IMMEDIATE_OUTPUT="$fixture/immediate.out" CREWBOSS="$CREWBOSS" \
    TEST_WAIT_BOUNDED="$bin/wait-bounded" \
    "$CREWBOSS" spawn "ABC-123 immediate task" 2>&1)
  status=$?

  assert_eq 0 "$status" || return 1
  assert_contains "$output" "spawned ABC-123" || return 1
  assert_eq $'ABC-123 done\nimmediate result' \
    "$(cat "$fixture/immediate.out")" || return 1
  jq -e '.["ABC-123"] as $crew |
    $crew.task == "ABC-123 immediate task" and
    $crew.latest_prompt == "ABC-123 immediate task" and
    $crew.task_status == "done" and $crew.blocked == false and
    $crew.message == "immediate result" and $crew.last_event_seq == 1
  ' "$state/crew.json" >/dev/null
}

test_relative_state_dir_is_absolute_in_the_delivered_event_command() {
  local fixture orchestrator orchestrator_physical bin tree output status
  fixture=$(mktemp -d)
  trap 'rm -rf "$fixture"' RETURN
  orchestrator="$fixture/orchestrator"
  bin="$fixture/bin"
  tree="$fixture/tree"
  mkdir -p "$orchestrator" "$bin"
  orchestrator_physical=$(cd "$orchestrator" && pwd -P) || return 1

  cat > "$bin/wt" <<'WT'
#!/bin/bash
case $1 in
  list)
    if [ -f "$TEST_TREE/.created" ]; then
      jq -cn --arg path "$TEST_TREE" '[{branch:"test-ABC-124-relative-state",path:$path}]'
    else
      printf '[]\n'
    fi
    ;;
  switch)
    mkdir -p "$TEST_TREE"
    : > "$TEST_TREE/.created"
    ;;
  *) exit 2 ;;
esac
WT

  cat > "$bin/herdr" <<'HERDR'
#!/bin/bash
case "$1 $2" in
  "tab create")
    printf '{"result":{"root_pane":{"pane_id":"w1:p1"}}}\n'
    ;;
  "agent start") ;;
  "agent prompt")
    printf '%s\n' "$4" > "$TEST_PROMPT"
    awk '
      $0 == "When the work is complete, emit the final answer before ending:" {
        copying = 1
        next
      }
      copying { print }
    ' "$TEST_PROMPT" > "$TEST_EMIT_SCRIPT" || exit 70
    [ -s "$TEST_EMIT_SCRIPT" ] || exit 71
    (
      cd "$TEST_TREE" || exit 1
      /bin/bash "$TEST_EMIT_SCRIPT"
    ) || exit 72
    ;;
  "agent read")
    sed -n '/^CrewBoss run id: /p' "$TEST_PROMPT"
    ;;
  *) exit 2 ;;
esac
HERDR

  cat > "$bin/sleep" <<'SLEEP'
#!/bin/bash
exit 0
SLEEP
  chmod +x "$bin/herdr" "$bin/sleep" "$bin/wt"

  output=$(cd "$orchestrator" && PATH="$bin:$PATH" CB_STATE_DIR=state \
    CB_PREFIX=test CB_BASE=origin/main HERDR_WORKSPACE_ID=w1 TEST_TREE="$tree" \
    TEST_PROMPT="$fixture/prompt" TEST_EMIT_SCRIPT="$fixture/emit.sh" \
    "$CREWBOSS" spawn "ABC-124 relative state" 2>&1)
  status=$?

  assert_eq 0 "$status" || return 1
  assert_contains "$output" "spawned ABC-124" || return 1
  assert_contains "$(cat "$fixture/prompt")" \
    "CB_STATE_DIR=$orchestrator_physical/state " || return 1
  jq -s -e 'length == 1 and .[0].crew == "ABC-124" and
    .[0].kind == "done" and .[0].payload == "the final answer"' \
    "$orchestrator/state/events.jsonl" >/dev/null || return 1
  [ ! -e "$tree/state" ]
}

setup_failed_spawn_cli() {
  SPAWN_FAIL_TMP=$(mktemp -d)
  SPAWN_FAIL_BIN="$SPAWN_FAIL_TMP/bin"
  SPAWN_FAIL_STATE="$SPAWN_FAIL_TMP/state"
  SPAWN_FAIL_TREE="$SPAWN_FAIL_TMP/tree"
  mkdir -p "$SPAWN_FAIL_BIN" "$SPAWN_FAIL_STATE"
  : > "$SPAWN_FAIL_TMP/herdr.log"

  cat > "$SPAWN_FAIL_BIN/wt" <<'WT'
#!/bin/bash
case $1 in
  list)
    if [ -f "$TEST_TREE/.created" ]; then
      jq -cn --arg path "$TEST_TREE" '[{branch:"test-ABC-125-failed-delivery",path:$path}]'
    else
      printf '[]\n'
    fi
    ;;
  switch)
    mkdir -p "$TEST_TREE"
    : > "$TEST_TREE/.created"
    ;;
  *) exit 2 ;;
esac
WT

  cat > "$SPAWN_FAIL_BIN/herdr" <<'HERDR'
#!/bin/bash
case "$1 $2" in
  "tab create")
    printf '{"result":{"root_pane":{"pane_id":"w1:p1"}}}\n'
    ;;
  "agent start") ;;
  "agent prompt")
    printf 'prompt\n' >> "$TEST_HERDR_LOG"
    printf '%s\n' "$4" > "$TEST_PROMPT"
    if [ "$TEST_FAILURE_MODE" = immediate ] && [ ! -e "$TEST_EVENT_SENT" ]; then
      crew_id=$(jq -r '.["ABC-125"].crew_id' "$CB_STATE_DIR/crew.json") || exit 70
      run_id=$(jq -r '.["ABC-125"].run_id' "$CB_STATE_DIR/crew.json") || exit 71
      "$CREWBOSS" emit ABC-125 "$crew_id" "$run_id" done \
        "event despite failed confirmation" || exit 72
      "$TEST_WAIT_BOUNDED" "$TEST_IMMEDIATE_OUTPUT" \
        "$CREWBOSS" wait ABC-125 || exit 73
      : > "$TEST_EVENT_SENT"
    fi
    ;;
  "agent read")
    printf 'prompt confirmation unavailable\n'
    ;;
  *) exit 2 ;;
esac
HERDR

  cat > "$SPAWN_FAIL_BIN/sleep" <<'SLEEP'
#!/bin/bash
exit 0
SLEEP
  chmod +x "$SPAWN_FAIL_BIN/herdr" "$SPAWN_FAIL_BIN/sleep" "$SPAWN_FAIL_BIN/wt"
  write_fake_wait_watchdog "$SPAWN_FAIL_BIN/wait-bounded"
}

run_failed_spawn_cli() {
  PATH="$SPAWN_FAIL_BIN:$PATH" CB_STATE_DIR="$SPAWN_FAIL_STATE" CB_PREFIX=test \
    CB_BASE=origin/main HERDR_WORKSPACE_ID=w1 TEST_TREE="$SPAWN_FAIL_TREE" \
    TEST_HERDR_LOG="$SPAWN_FAIL_TMP/herdr.log" TEST_PROMPT="$SPAWN_FAIL_TMP/prompt" \
    TEST_FAILURE_MODE="$TEST_FAILURE_MODE" TEST_EVENT_SENT="$SPAWN_FAIL_TMP/event-sent" \
    TEST_IMMEDIATE_OUTPUT="$SPAWN_FAIL_TMP/immediate.out" CREWBOSS="$CREWBOSS" \
    TEST_WAIT_BOUNDED="$SPAWN_FAIL_BIN/wait-bounded" \
    "$CREWBOSS" spawn "ABC-125 failed delivery"
}

test_failed_initial_prompt_marks_the_saved_crew_unknown() {
  setup_failed_spawn_cli
  trap 'rm -rf "$SPAWN_FAIL_TMP"' RETURN
  TEST_FAILURE_MODE=ordinary
  local output status

  output=$(run_failed_spawn_cli 2>&1)
  status=$?

  assert_eq 1 "$status" || return 1
  assert_contains "$output" "could not send the task" || return 1
  assert_eq 5 "$(grep -c '^prompt$' "$SPAWN_FAIL_TMP/herdr.log")" || return 1
  jq -e '.["ABC-125"] as $crew |
    $crew.status == "open" and $crew.task_status == "unknown" and
    $crew.blocked == false and $crew.message == "" and $crew.last_event_seq == 0 and
    ($crew.crew_id | startswith("crew-")) and ($crew.run_id | startswith("run-"))
  ' "$SPAWN_FAIL_STATE/crew.json" >/dev/null
}

test_failed_initial_prompt_preserves_an_applied_event() {
  setup_failed_spawn_cli
  trap 'rm -rf "$SPAWN_FAIL_TMP"' RETURN
  TEST_FAILURE_MODE=immediate
  local output status

  output=$(run_failed_spawn_cli 2>&1)
  status=$?

  assert_eq 1 "$status" || return 1
  assert_contains "$output" "could not send the task" || return 1
  assert_eq 5 "$(grep -c '^prompt$' "$SPAWN_FAIL_TMP/herdr.log")" || return 1
  assert_eq $'ABC-125 done\nevent despite failed confirmation' \
    "$(cat "$SPAWN_FAIL_TMP/immediate.out")" || return 1
  jq -e '.["ABC-125"] as $crew |
    $crew.task_status == "done" and $crew.blocked == false and
    $crew.message == "event despite failed confirmation" and
    $crew.last_event_seq == 1
  ' "$SPAWN_FAIL_STATE/crew.json" >/dev/null
}

setup_send_cli() {
  SEND_TMP=$(mktemp -d)
  SEND_BIN="$SEND_TMP/bin"
  SEND_STATE="$SEND_TMP/state"
  mkdir -p "$SEND_BIN" "$SEND_STATE"
  : > "$SEND_TMP/herdr.log"

  cat > "$SEND_BIN/herdr" <<'HERDR'
#!/bin/bash
case "$1 $2" in
  "agent prompt")
    printf 'prompt\n' >> "$TEST_HERDR_LOG"
    printf '%s\n' "$4" > "$TEST_PROMPT_FILE"
    jq -e --arg name "$TEST_CREW" --arg prompt "$TEST_NEW_PROMPT" \
      --arg old_run "$TEST_OLD_RUN" '
      .[$name].latest_prompt == $prompt and
      (.[$name].crew_id | type == "string" and startswith("crew-")) and
      (.[$name].run_id | type == "string" and startswith("run-") and . != $old_run)
    ' "$CB_STATE_DIR/crew.json" >/dev/null || exit 70
    if [ "$TEST_RECORD_MODE" = phase1 ]; then
      jq -e --arg name "$TEST_CREW" '
        .[$name].crew_id == "crew-a" and .[$name].task_status == "blocked" and
        .[$name].blocked == true and .[$name].message == "old question"
      ' "$CB_STATE_DIR/crew.json" >/dev/null || exit 71
    else
      jq -e --arg name "$TEST_CREW" '
        (.[$name] | has("task_status") | not) and (.[$name] | has("task") | not)
      ' "$CB_STATE_DIR/crew.json" >/dev/null || exit 72
    fi
    if [ "$TEST_PROMPT_MODE" = immediate ]; then
      crew_id=$(jq -r --arg name "$TEST_CREW" '.[$name].crew_id' "$CB_STATE_DIR/crew.json") || exit 73
      run_id=$(jq -r --arg name "$TEST_CREW" '.[$name].run_id' "$CB_STATE_DIR/crew.json") || exit 74
      "$CREWBOSS" emit "$TEST_CREW" "$crew_id" "$run_id" done "immediate follow-up" || exit 75
      "$TEST_WAIT_BOUNDED" "$TEST_IMMEDIATE_OUTPUT" \
        "$CREWBOSS" wait "$TEST_CREW" || exit 76
    fi
    ;;
  "agent read")
    if [ "$TEST_PROMPT_MODE" != fail ]; then
      sed -n '/^CrewBoss run id: /p' "$TEST_PROMPT_FILE"
    else
      printf 'prompt still not visible\n'
    fi
    ;;
  *) exit 2 ;;
esac
HERDR

  cat > "$SEND_BIN/sleep" <<'SLEEP'
#!/bin/bash
exit 0
SLEEP
  chmod +x "$SEND_BIN/herdr" "$SEND_BIN/sleep"
  write_fake_wait_watchdog "$SEND_BIN/wait-bounded"
}

write_phase1_send_record() {
  jq -n '{A:{branch:"feature",path:"/tmp/tree",pane:"w1:p1",agent:"claude",
    placement:"tab",token:"",status:"open",task:"initial task",
    latest_prompt:"initial task",crew_id:"crew-a",run_id:"run-old",
    task_status:"blocked",blocked:true,message:"old question",last_event_seq:0}}' \
    > "$SEND_STATE/crew.json"
}

write_legacy_send_record() {
  jq -n '{A:{branch:"feature",path:"/tmp/tree",pane:"w1:p1",agent:"claude",
    placement:"tab",token:"",status:"open"}}' > "$SEND_STATE/crew.json"
}

run_send_cli() {
  PATH="$SEND_BIN:$PATH" CB_STATE_DIR="$SEND_STATE" CREWBOSS="$CREWBOSS" \
    TEST_HERDR_LOG="$SEND_TMP/herdr.log" TEST_PROMPT_FILE="$SEND_TMP/prompt" \
    TEST_IMMEDIATE_OUTPUT="$SEND_TMP/immediate.out" TEST_CREW=A \
    TEST_NEW_PROMPT="follow-up answer" TEST_OLD_RUN="${TEST_OLD_RUN:-run-old}" \
    TEST_RECORD_MODE="$TEST_RECORD_MODE" TEST_PROMPT_MODE="$TEST_PROMPT_MODE" \
    TEST_WAIT_BOUNDED="$SEND_BIN/wait-bounded" \
    "$CREWBOSS" send A "follow-up answer"
}

test_send_persists_new_run_before_prompt_without_clobbering_an_immediate_event() {
  setup_send_cli
  trap 'rm -rf "$SEND_TMP"' RETURN
  write_phase1_send_record
  TEST_RECORD_MODE=phase1
  TEST_PROMPT_MODE=immediate

  local output status
  output=$(run_send_cli 2>&1)
  status=$?

  assert_eq 0 "$status" || return 1
  assert_contains "$output" "sent; crewboss wait A" || return 1
  assert_eq $'A done\nimmediate follow-up' "$(cat "$SEND_TMP/immediate.out")" || return 1
  jq -e '.A.crew_id == "crew-a" and .A.run_id != "run-old" and
    .A.task == "initial task" and .A.latest_prompt == "follow-up answer" and
    .A.task_status == "done" and .A.blocked == false and
    .A.message == "immediate follow-up" and .A.last_event_seq == 1
  ' "$SEND_STATE/crew.json" >/dev/null
}

test_failed_send_restores_the_complete_previous_record() {
  setup_send_cli
  trap 'rm -rf "$SEND_TMP"' RETURN
  write_phase1_send_record
  local before output status
  before=$(jq -c '.A' "$SEND_STATE/crew.json") || return 1
  TEST_RECORD_MODE=phase1
  TEST_PROMPT_MODE=fail

  output=$(run_send_cli 2>&1)
  status=$?

  [ "$status" -ne 0 ] || return 1
  assert_contains "$output" "could not send" || return 1
  assert_eq 5 "$(grep -c '^prompt$' "$SEND_TMP/herdr.log")" || return 1
  jq -e --argjson before "$before" '.A == $before' "$SEND_STATE/crew.json" >/dev/null
}

test_send_upgrades_a_legacy_record_without_losing_old_fields() {
  setup_send_cli
  trap 'rm -rf "$SEND_TMP"' RETURN
  write_legacy_send_record
  TEST_OLD_RUN=missing
  TEST_RECORD_MODE=legacy
  TEST_PROMPT_MODE=confirm

  run_send_cli >/dev/null 2>&1 || return 1

  jq -e '.A.branch == "feature" and .A.path == "/tmp/tree" and
    .A.pane == "w1:p1" and .A.agent == "claude" and .A.placement == "tab" and
    .A.status == "open" and (.A | has("task") | not) and
    (.A.crew_id | type == "string" and startswith("crew-")) and
    (.A.run_id | type == "string" and startswith("run-")) and
    .A.latest_prompt == "follow-up answer" and .A.task_status == "running" and
    .A.blocked == false and .A.message == "" and .A.last_event_seq == 0
  ' "$SEND_STATE/crew.json" >/dev/null
}

test_wait_routes_global_fifo_and_keeps_unselected_events_across_restarts() {
  setup_wait || return 1
  write_event_source \
    '{"version":1,"seq":1,"event_id":"event-1","crew":"C","crew_id":"crew-c","run_id":"run-c","kind":"blocked","payload":"C needs an answer","time":"2026-07-31T12:00:01Z"}' \
    '{"version":1,"seq":2,"event_id":"event-2","crew":"B","crew_id":"crew-b","run_id":"run-b","kind":"done","payload":"B finished","time":"2026-07-31T12:00:02Z"}' \
    '{"version":1,"seq":3,"event_id":"event-3","crew":"A","crew_id":"crew-a","run_id":"run-a","kind":"blocked","payload":"A needs an answer","time":"2026-07-31T12:00:03Z"}' || return 1

  run_wait_bounded first A B
  assert_eq 0 "$RUN_STATUS" || return 1
  assert_eq $'B done\nB finished' "$RUN_OUTPUT" || return 1
  jq -e '.cursor == 3 and
    (.pending | keys | sort) == ["crew-a","crew-c"]' \
    "$CB_STATE_DIR/event-state.json" >/dev/null || return 1

  run_wait_bounded second C
  assert_eq 0 "$RUN_STATUS" || return 1
  assert_eq $'C blocked\nC needs an answer' "$RUN_OUTPUT" || return 1

  run_wait_bounded third A B
  assert_eq 0 "$RUN_STATUS" || return 1
  assert_eq $'A blocked\nA needs an answer' "$RUN_OUTPUT" || return 1
  jq -e '.cursor == 3 and (.pending | length) == 0' \
    "$CB_STATE_DIR/event-state.json" >/dev/null
}

test_wait_skips_old_crew_and_run_events() {
  setup_wait || return 1
  write_event_source \
    '{"version":1,"seq":1,"event_id":"event-1","crew":"A","crew_id":"crew-old","run_id":"run-old","kind":"done","payload":"old crew result","time":"2026-07-31T12:00:01Z"}' \
    '{"version":1,"seq":2,"event_id":"event-2","crew":"A","crew_id":"crew-a","run_id":"run-old","kind":"blocked","payload":"old run question","time":"2026-07-31T12:00:02Z"}' \
    '{"version":1,"seq":3,"event_id":"event-3","crew":"A","crew_id":"crew-a","run_id":"run-a","kind":"done","payload":"current result","time":"2026-07-31T12:00:03Z"}' || return 1

  run_wait_bounded stale A
  assert_eq 0 "$RUN_STATUS" || return 1
  assert_eq $'A done\ncurrent result' "$RUN_OUTPUT" || return 1
  jq -e '.cursor == 3 and (.pending | length) == 0' \
    "$CB_STATE_DIR/event-state.json" >/dev/null || return 1
  jq -e '.A.last_event_seq == 3 and .A.message == "current result"' \
    "$CB_REG" >/dev/null
}

test_later_current_event_replaces_an_old_pending_event() {
  setup_wait || return 1
  write_event_source \
    '{"version":1,"seq":1,"event_id":"event-1","crew":"A","crew_id":"crew-a","run_id":"run-a","kind":"blocked","payload":"obsolete question","time":"2026-07-31T12:00:01Z"}' \
    '{"version":1,"seq":2,"event_id":"event-2","crew":"A","crew_id":"crew-a","run_id":"run-a","kind":"done","payload":"final result","time":"2026-07-31T12:00:02Z"}' || return 1

  run_wait_bounded replaced A
  assert_eq 0 "$RUN_STATUS" || return 1
  assert_eq $'A done\nfinal result' "$RUN_OUTPUT" || return 1
  jq -e '.cursor == 2 and (.pending | length) == 0' \
    "$CB_STATE_DIR/event-state.json" >/dev/null
}

test_wait_validates_every_requested_name_before_pumping() {
  setup_wait || return 1
  write_event_source \
    '{"version":1,"seq":1,"event_id":"event-1","crew":"A","crew_id":"crew-a","run_id":"run-a","kind":"done","payload":"ready","time":"2026-07-31T12:00:01Z"}' || return 1

  run_wait_bounded invalid A missing
  [ "$RUN_STATUS" -ne 0 ] || return 1
  assert_contains "$RUN_ERRORS" "no crew named 'missing'" || return 1
  [ ! -e "$CB_STATE_DIR/event-state.json" ]
}

test_complete_malformed_event_stops_without_advancing() {
  setup_wait || return 1
  write_event_source '{"broken":true}' || return 1

  ! cb_event_pump 2>/dev/null || return 1
  jq -e '.cursor == 0 and (.pending | length) == 0' \
    "$CB_STATE_DIR/event-state.json" >/dev/null || return 1
  assert_eq 0 "$(cb_reg_field A last_event_seq)"
}

test_complete_blank_line_stops_without_advancing() {
  setup_wait || return 1
  write_event_source '' || return 1

  ! cb_event_pump 2>/dev/null || return 1
  jq -e '.cursor == 0 and (.pending | length) == 0' \
    "$CB_STATE_DIR/event-state.json" >/dev/null || return 1
  assert_eq 0 "$(cb_reg_field A last_event_seq)"
}

test_sequence_gap_stops_without_advancing() {
  setup_wait || return 1
  write_event_source \
    '{"version":1,"seq":2,"event_id":"event-2","crew":"A","crew_id":"crew-a","run_id":"run-a","kind":"done","payload":"gap","time":"2026-07-31T12:00:02Z"}' || return 1

  ! cb_event_pump 2>/dev/null || return 1
  jq -e '.cursor == 0 and (.pending | length) == 0' \
    "$CB_STATE_DIR/event-state.json" >/dev/null || return 1
  assert_eq 0 "$(cb_reg_field A last_event_seq)"
}

test_checkpoint_rejects_multiple_json_documents_without_changes() {
  setup_wait || return 1
  assert_corrupt_checkpoint_fails_unchanged \
    $'{"cursor":0,"pending":{}}\n{"cursor":0,"pending":{}}'
}

test_checkpoint_rejects_pending_ahead_of_cursor_without_changes() {
  setup_wait || return 1
  assert_corrupt_checkpoint_fails_unchanged \
    '{"cursor":0,"pending":{"crew-a":{"version":1,"seq":1,"event_id":"event-1","crew":"A","crew_id":"crew-a","run_id":"run-a","kind":"done","payload":"must not apply","time":"2026-07-31T12:00:01Z"}}}'
}

test_incomplete_final_line_waits_for_its_newline() {
  setup_wait || return 1
  cb_event_init || return 1
  printf '%s' \
    '{"version":1,"seq":1,"event_id":"event-1","crew":"A","crew_id":"crew-a","run_id":"run-a","kind":"done","payload":"complete later","time":"2026-07-31T12:00:01Z"}' \
    > "$CB_EVENT_SOURCE"

  cb_event_pump || return 1
  jq -e '.cursor == 0 and (.pending | length) == 0' \
    "$CB_STATE_DIR/event-state.json" >/dev/null || return 1
  assert_eq 0 "$(cb_reg_field A last_event_seq)" || return 1

  printf '\n' >> "$CB_EVENT_SOURCE"
  cb_event_pump || return 1
  jq -e '.cursor == 1 and .pending["crew-a"].event_id == "event-1"' \
    "$CB_STATE_DIR/event-state.json" >/dev/null || return 1
  assert_eq 1 "$(cb_reg_field A last_event_seq)"
}

test_registry_failure_does_not_advance_the_cursor() {
  setup_wait || return 1
  write_event_source \
    '{"version":1,"seq":1,"event_id":"event-1","crew":"A","crew_id":"crew-a","run_id":"run-a","kind":"done","payload":"not applied","time":"2026-07-31T12:00:01Z"}' || return 1
  printf '%s\n' '{broken' > "$CB_REG"

  ! cb_event_pump 2>/dev/null || return 1
  jq -e '.cursor == 0 and (.pending | length) == 0' \
    "$CB_STATE_DIR/event-state.json" >/dev/null
}

test_ack_of_an_old_event_does_not_delete_its_replacement() {
  setup_wait || return 1
  write_event_source \
    '{"version":1,"seq":1,"event_id":"event-1","crew":"A","crew_id":"crew-a","run_id":"run-a","kind":"blocked","payload":"old","time":"2026-07-31T12:00:01Z"}' || return 1
  cb_event_pump || return 1
  local old_event new_event
  old_event=$(jq -c '.pending["crew-a"]' "$CB_STATE_DIR/event-state.json") || return 1

  printf '%s\n' \
    '{"version":1,"seq":2,"event_id":"event-2","crew":"A","crew_id":"crew-a","run_id":"run-a","kind":"done","payload":"new","time":"2026-07-31T12:00:02Z"}' \
    >> "$CB_EVENT_SOURCE"
  cb_event_pump || return 1
  new_event=$(jq -c '.pending["crew-a"]' "$CB_STATE_DIR/event-state.json") || return 1

  cb_event_ack "$old_event" || return 1
  assert_eq "$new_event" \
    "$(jq -c '.pending["crew-a"]' "$CB_STATE_DIR/event-state.json")" || return 1
  cb_event_ack "$new_event" || return 1
  jq -e '(.pending | length) == 0' "$CB_STATE_DIR/event-state.json" >/dev/null
}

test_drop_removes_only_derived_pending_state() {
  setup_wait || return 1
  write_event_source \
    '{"version":1,"seq":1,"event_id":"event-1","crew":"A","crew_id":"crew-a","run_id":"run-a","kind":"done","payload":"A result","time":"2026-07-31T12:00:01Z"}' \
    '{"version":1,"seq":2,"event_id":"event-2","crew":"B","crew_id":"crew-b","run_id":"run-b","kind":"done","payload":"B result","time":"2026-07-31T12:00:02Z"}' || return 1
  cb_event_pump || return 1
  local before
  before=$(cat "$CB_EVENT_SOURCE") || return 1

  cb_event_drop_crew crew-a || return 1
  assert_eq "$before" "$(cat "$CB_EVENT_SOURCE")" || return 1
  jq -e '.cursor == 2 and
    (.pending | keys) == ["crew-b"] and
    .pending["crew-b"].event_id == "event-2"' \
    "$CB_STATE_DIR/event-state.json" >/dev/null
}

test_output_failure_keeps_the_pending_event() {
  setup_wait || return 1
  write_event_source \
    '{"version":1,"seq":1,"event_id":"event-1","crew":"A","crew_id":"crew-a","run_id":"run-a","kind":"done","payload":"must survive","time":"2026-07-31T12:00:01Z"}' || return 1

  local status=0
  CB_STATE_DIR="$CB_STATE_DIR" CB_EVENT_WAIT_SECS=0.01 \
    "$CREWBOSS" wait A >&- 2> "$TEST_TMP/output-failure.err" || status=$?
  [ "$status" -ne 0 ] || return 1
  jq -e '.cursor == 1 and .pending["crew-a"].event_id == "event-1"' \
    "$CB_STATE_DIR/event-state.json" >/dev/null
}

test_wait_prunes_a_stale_pending_run_before_listening() {
  setup_wait || return 1
  write_event_source \
    '{"version":1,"seq":1,"event_id":"event-1","crew":"A","crew_id":"crew-a","run_id":"run-a","kind":"blocked","payload":"old question","time":"2026-07-31T12:00:01Z"}' || return 1
  cb_event_pump || return 1
  cb_reg_put A '{"run_id":"run-new","task_status":"running","last_event_seq":0}' || return 1

  start_wait_recorded prune A || return 1

  sleep 0.1
  if [ -f "$WAIT_MARKER" ]; then
    wait "$WAIT_WRAPPER_PID" 2>/dev/null || true
    return 1
  fi
  CB_STATE_DIR="$CB_STATE_DIR" "$CREWBOSS" emit \
    A crew-a run-new "done" "new result" >/dev/null 2>&1 || {
    terminate_wait_recorded
    return 1
  }
  finish_wait_bounded
  assert_eq 0 "$RUN_STATUS" || return 1
  assert_eq $'A done\nnew result' "$RUN_OUTPUT"
}

run_test "wait routes global FIFO and keeps other crews across restarts" \
  test_wait_routes_global_fifo_and_keeps_unselected_events_across_restarts
run_test "spawn persists identity before prompt and keeps an immediate event" \
  test_spawn_persists_identity_before_prompt_and_keeps_an_immediate_event
run_test "relative state is absolute in delivered event commands" \
  test_relative_state_dir_is_absolute_in_the_delivered_event_command
run_test "failed initial prompt marks the saved crew unknown" \
  test_failed_initial_prompt_marks_the_saved_crew_unknown
run_test "failed initial prompt preserves an applied event" \
  test_failed_initial_prompt_preserves_an_applied_event
run_test "send persists a new run and keeps an immediate event" \
  test_send_persists_new_run_before_prompt_without_clobbering_an_immediate_event
run_test "a failed send restores the complete previous record" \
  test_failed_send_restores_the_complete_previous_record
run_test "send upgrades a legacy record without losing old fields" \
  test_send_upgrades_a_legacy_record_without_losing_old_fields
run_test "wait skips old crew and old run events" \
  test_wait_skips_old_crew_and_run_events
run_test "a later current event replaces older pending state" \
  test_later_current_event_replaces_an_old_pending_event
run_test "wait validates every requested crew before pumping" \
  test_wait_validates_every_requested_name_before_pumping
run_test "a complete malformed event does not advance the cursor" \
  test_complete_malformed_event_stops_without_advancing
run_test "a complete blank line does not advance the cursor" \
  test_complete_blank_line_stops_without_advancing
run_test "a sequence gap does not advance the cursor" \
  test_sequence_gap_stops_without_advancing
run_test "a multi-document checkpoint changes no durable state" \
  test_checkpoint_rejects_multiple_json_documents_without_changes
run_test "a pending event ahead of the cursor changes no durable state" \
  test_checkpoint_rejects_pending_ahead_of_cursor_without_changes
run_test "an incomplete final line waits for a newline" \
  test_incomplete_final_line_waits_for_its_newline
run_test "a registry failure does not advance the cursor" \
  test_registry_failure_does_not_advance_the_cursor
run_test "ack cannot delete a newer replacement event" \
  test_ack_of_an_old_event_does_not_delete_its_replacement
run_test "drop removes only one crew's derived pending state" \
  test_drop_removes_only_derived_pending_state
run_test "output failure leaves the event pending" \
  test_output_failure_keeps_the_pending_event
run_test "wait prunes a stale pending run before listening" \
  test_wait_prunes_a_stale_pending_run_before_listening
finish_tests
