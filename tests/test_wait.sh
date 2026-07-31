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

run_wait_bounded() {
  local label=$1 marker output errors status pid step
  shift
  marker="$TEST_TMP/$label.status"
  output="$TEST_TMP/$label.out"
  errors="$TEST_TMP/$label.err"

  (
    CB_STATE_DIR="$CB_STATE_DIR" CB_EVENT_WAIT_SECS=0.01 \
      "$CREWBOSS" wait "$@" > "$output" 2> "$errors"
    status=$?
    printf '%s\n' "$status" > "$marker"
  ) &
  pid=$!

  for step in $(seq 1 500); do
    [ -f "$marker" ] && break
    sleep 0.01
  done
  if [ ! -f "$marker" ]; then
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    RUN_STATUS=124
  else
    wait "$pid" 2>/dev/null || true
    RUN_STATUS=
    IFS= read -r RUN_STATUS < "$marker" || RUN_STATUS=1
  fi
  RUN_OUTPUT=$(cat "$output" 2>/dev/null || true)
  RUN_ERRORS=$(cat "$errors" 2>/dev/null || true)
}

write_event_source() {
  cb_event_init || return 1
  printf '%s\n' "$@" > "$CB_EVENT_SOURCE"
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

  local marker="$TEST_TMP/prune.status" output="$TEST_TMP/prune.out" errors="$TEST_TMP/prune.err"
  local pid step status
  (
    CB_STATE_DIR="$CB_STATE_DIR" CB_EVENT_WAIT_SECS=0.01 \
      "$CREWBOSS" wait A > "$output" 2> "$errors"
    status=$?
    printf '%s\n' "$status" > "$marker"
  ) &
  pid=$!

  sleep 0.1
  if [ -f "$marker" ]; then
    wait "$pid" 2>/dev/null || true
    return 1
  fi
  CB_STATE_DIR="$CB_STATE_DIR" "$CREWBOSS" emit \
    A crew-a run-new "done" "new result" >/dev/null 2>&1 || {
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 1
  }
  step=0
  while [ "$step" -lt 500 ]; do
    step=$((step + 1))
    [ -f "$marker" ] && break
    sleep 0.01
  done
  if [ ! -f "$marker" ]; then
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 1
  fi
  wait "$pid" 2>/dev/null || true
  status=
  IFS= read -r status < "$marker" || return 1
  assert_eq 0 "$status" || return 1
  assert_eq $'A done\nnew result' "$(cat "$output")"
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
