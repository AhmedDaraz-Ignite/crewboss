#!/bin/bash
set -u

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd "$TEST_ROOT/.." && pwd)
# shellcheck source=tests/test_helper.sh
source "$TEST_ROOT/test_helper.sh"

setup_registry() {
  TEST_TMP=$(mktemp -d)
  export CB_STATE_DIR="$TEST_TMP/state"
  trap 'rm -rf "$TEST_TMP"' EXIT
  # shellcheck source=scripts/lib/registry.sh
  source "$PROJECT_ROOT/scripts/lib/registry.sh"
}

test_concurrent_puts_keep_every_field() {
  setup_registry

  local i field pid
  local -a pids=()
  for i in $(seq 1 32); do
    field=$(jq -n --arg k "k$i" --arg v "$i" '{($k): $v}')
    CB_STATE_DIR="$CB_STATE_DIR" bash -c 'source "$1"; cb_reg_put "$2" "$3"' bash \
      "$PROJECT_ROOT/scripts/lib/registry.sh" crew "$field" &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || return 1
  done

  jq -e '(.crew | keys | map(select(startswith("k"))) | length) == 32' "$CB_REG" >/dev/null
}

test_current_blocked_event_updates_task_state() {
  setup_registry
  cb_reg_put crew '{"crew_id":"crew-current","run_id":"run-current","task_status":"running","blocked":false,"message":"","last_event_seq":0}' || return 1

  local event
  event=$(jq -n '{version: 1, seq: 7, event_id: "event-7", crew: "crew", crew_id: "crew-current", run_id: "run-current", kind: "blocked", payload: "Which database should I use?", time: "2026-07-31T12:00:00Z"}')
  cb_reg_apply_event "$event" || return 1

  jq -e '.crew == {
    "crew_id":"crew-current",
    "run_id":"run-current",
    "task_status":"blocked",
    "blocked":true,
    "message":"Which database should I use?",
    "last_event_seq":7
  }' "$CB_REG" >/dev/null
}

test_replaying_an_event_keeps_the_same_state() {
  setup_registry
  cb_reg_put crew '{"crew_id":"crew-current","run_id":"run-current","task_status":"running","blocked":false,"message":"","last_event_seq":0}' || return 1

  local event before after
  event=$(jq -n '{version: 1, seq: 7, event_id: "event-7", crew: "crew", crew_id: "crew-current", run_id: "run-current", kind: "done", payload: "The pull request is ready.", time: "2026-07-31T12:00:00Z"}')
  cb_reg_apply_event "$event" || return 1
  before=$(jq -c '.crew' "$CB_REG")
  cb_reg_apply_event "$event" || return 1
  after=$(jq -c '.crew' "$CB_REG")

  assert_eq "$before" "$after"
}

test_old_crew_identity_returns_stale_without_changing_the_record() {
  setup_registry
  cb_reg_put crew '{"crew_id":"crew-current","run_id":"run-current","task_status":"running","blocked":false,"message":"","last_event_seq":0}' || return 1

  local event before status after
  event=$(jq -n '{version: 1, seq: 7, event_id: "event-7", crew: "crew", crew_id: "crew-old", run_id: "run-current", kind: "done", payload: "Old result", time: "2026-07-31T12:00:00Z"}')
  before=$(jq -c '.crew' "$CB_REG")
  cb_reg_apply_event "$event" >/dev/null 2>&1
  status=$?
  after=$(jq -c '.crew' "$CB_REG")

  assert_eq 2 "$status" || return 1
  assert_eq "$before" "$after"
}

test_old_run_identity_returns_stale_without_changing_the_record() {
  setup_registry
  cb_reg_put crew '{"crew_id":"crew-current","run_id":"run-current","task_status":"running","blocked":false,"message":"","last_event_seq":0}' || return 1

  local event before status after
  event=$(jq -n '{version: 1, seq: 7, event_id: "event-7", crew: "crew", crew_id: "crew-current", run_id: "run-old", kind: "done", payload: "Old result", time: "2026-07-31T12:00:00Z"}')
  before=$(jq -c '.crew' "$CB_REG")
  cb_reg_apply_event "$event" >/dev/null 2>&1
  status=$?
  after=$(jq -c '.crew' "$CB_REG")

  assert_eq 2 "$status" || return 1
  assert_eq "$before" "$after"
}

test_replace_and_endpoint_state_write_atomically() {
  setup_registry
  cb_reg_put crew '{"old":"value"}' || return 1
  cb_reg_replace crew '{"crew_id":"crew-current","run_id":"run-current"}' || return 1
  cb_reg_set_endpoint crew unknown || return 1

  jq -e '.crew == {"crew_id":"crew-current","run_id":"run-current","endpoint_state":"unknown"}' "$CB_REG" >/dev/null
}

test_new_ids_keep_the_requested_prefix_and_are_unique() {
  setup_registry

  local first second
  first=$(cb_id_new crew)
  second=$(cb_id_new crew)

  [[ $first == crew-* ]] || return 1
  [[ $second == crew-* ]] || return 1
  [ "$first" != "$second" ]
}

run_test "concurrent registry writes keep every field" test_concurrent_puts_keep_every_field
run_test "a current blocked event updates task state" test_current_blocked_event_updates_task_state
run_test "replaying an event keeps the same task state" test_replaying_an_event_keeps_the_same_state
run_test "an old crew identity is stale without changing state" test_old_crew_identity_returns_stale_without_changing_the_record
run_test "an old run identity is stale without changing state" test_old_run_identity_returns_stale_without_changing_the_record
run_test "replace and endpoint state keep only current record fields" test_replace_and_endpoint_state_write_atomically
run_test "new registry identities use unique requested prefixes" test_new_ids_keep_the_requested_prefix_and_are_unique
finish_tests
