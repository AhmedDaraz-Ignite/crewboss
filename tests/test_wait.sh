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
