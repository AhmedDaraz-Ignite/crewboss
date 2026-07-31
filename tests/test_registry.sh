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

wait_for_file() {
  local path=$1 i
  for i in $(seq 1 300); do
    [ -f "$path" ] && return 0
    sleep 0.01
  done
  return 1
}

wait_for_dir() {
  local path=$1 i
  for i in $(seq 1 300); do
    [ -d "$path" ] && return 0
    sleep 0.01
  done
  return 1
}

wait_for_claim() {
  local claims=$1 prefix=$2 i claim
  FOUND_CLAIM=
  for i in $(seq 1 300); do
    for claim in "$claims"/"$prefix"*; do
      if [ -e "$claim" ]; then
        FOUND_CLAIM=$claim
        return 0
      fi
    done
    sleep 0.01
  done
  return 1
}

stop_workers() {
  local pid
  for pid in "$@"; do
    kill "$pid" 2>/dev/null || true
  done
  for pid in "$@"; do
    wait "$pid" 2>/dev/null || true
  done
}

test_concurrent_puts_keep_every_field() {
  setup_registry
  cb_reg_init || return 1

  local i field pid real_jq status=0
  local -a pids=()
  real_jq=$(command -v jq) || return 1
  for i in $(seq 1 32); do
    field=$(jq -n --arg k "k$i" --arg v "$i" '{($k): $v}')
    CB_STATE_DIR="$CB_STATE_DIR" CB_TEST_CRITICAL="$TEST_TMP/critical" \
      CB_TEST_OVERLAP="$TEST_TMP/overlap" REAL_JQ="$real_jq" \
      bash -c '
        jq() {
          local owns_marker=0 status
          if mkdir "$CB_TEST_CRITICAL" 2>/dev/null; then
            owns_marker=1
          else
            : > "$CB_TEST_OVERLAP"
          fi
          sleep 0.02
          "$REAL_JQ" "$@"
          status=$?
          [ "$owns_marker" -eq 0 ] || rmdir "$CB_TEST_CRITICAL"
          return "$status"
        }
        source "$1"
        cb_reg_put "$2" "$3"
      ' bash \
      "$PROJECT_ROOT/scripts/lib/registry.sh" crew "$field" &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || status=1
  done
  [ "$status" -eq 0 ] || return 1
  [ ! -e "$TEST_TMP/overlap" ] || return 1

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
  jq -e '.crew.task_status == "done" and .crew.blocked == false and
    .crew.message == "The pull request is ready." and .crew.last_event_seq == 7' "$CB_REG" >/dev/null || return 1
  cb_reg_apply_event "$event" || return 1
  after=$(jq -c '.crew' "$CB_REG")

  assert_eq "$before" "$after"
}

test_background_owner_uses_worker_pid() {
  setup_registry
  mkdir -p "$CB_STATE_DIR"

  (trap - EXIT; cb_lock_acquire "$CB_REG_LOCK" || exit 1
    printf '%s\n' "$CB_LOCK_OWNER_ANCHOR" > "$TEST_TMP/anchor"
    wait_for_file "$TEST_TMP/release" || exit 1
    cb_lock_release "$CB_REG_LOCK") &
  local worker=$!
  if ! wait_for_file "$TEST_TMP/anchor"; then
    stop_workers "$worker"
    return 1
  fi

  local anchor owner
  IFS= read -r anchor < "$TEST_TMP/anchor" || {
    stop_workers "$worker"
    return 1
  }
  IFS= read -r owner < "$anchor" || {
    stop_workers "$worker"
    return 1
  }
  if [ "$owner" != "$worker" ] || [ "$owner" = "$$" ]; then
    stop_workers "$worker"
    return 1
  fi

  : > "$TEST_TMP/release"
  wait "$worker" || return 1
  [ ! -e "$anchor" ]
}

start_equal_claimant() {
  local label=$1
  (trap - EXIT
    mv() {
      local source=$1 destination=$2
      case ${source##*/} in
        C.*)
          printf '%s\n' "$destination" > "$TEST_TMP/$label-planned"
          : > "$TEST_TMP/$label-ready"
          wait_for_file "$TEST_TMP/equal-go" || return 1
          ;;
      esac
      command mv "$@"
    }
    cb_lock_acquire "$CB_REG_LOCK" || exit 1
    : > "$TEST_TMP/$label-acquired"
    wait_for_file "$TEST_TMP/$label-release" || exit 1
    cb_lock_release "$CB_REG_LOCK") &
  STARTED_PID=$!
}

test_equal_tickets_enter_in_tuple_order() {
  setup_registry
  mkdir -p "$CB_STATE_DIR"

  local a b planned_a planned_b first second status=0
  start_equal_claimant a
  a=$STARTED_PID
  start_equal_claimant b
  b=$STARTED_PID

  if ! wait_for_file "$TEST_TMP/a-ready" || ! wait_for_file "$TEST_TMP/b-ready"; then
    stop_workers "$a" "$b"
    return 1
  fi
  IFS= read -r planned_a < "$TEST_TMP/a-planned" || status=1
  IFS= read -r planned_b < "$TEST_TMP/b-planned" || status=1
  case ${planned_a##*/} in T.1.*) ;; *) status=1 ;; esac
  case ${planned_b##*/} in T.1.*) ;; *) status=1 ;; esac
  if [ "$status" -ne 0 ]; then
    stop_workers "$a" "$b"
    return 1
  fi

  if [ "$a" -lt "$b" ]; then
    first=a
    second=b
  else
    first=b
    second=a
  fi
  : > "$TEST_TMP/equal-go"
  if ! wait_for_file "$TEST_TMP/$first-acquired" ||
    ! wait_for_dir "$planned_a" || ! wait_for_dir "$planned_b"; then
    stop_workers "$a" "$b"
    return 1
  fi
  sleep 0.05
  if [ -f "$TEST_TMP/$second-acquired" ]; then
    stop_workers "$a" "$b"
    return 1
  fi

  : > "$TEST_TMP/$first-release"
  if ! wait_for_file "$TEST_TMP/$second-acquired"; then
    stop_workers "$a" "$b"
    return 1
  fi
  : > "$TEST_TMP/$second-release"
  wait "$a" || status=1
  wait "$b" || status=1
  return "$status"
}

test_dead_chooser_does_not_block_a_successor() {
  setup_registry
  mkdir -p "$CB_STATE_DIR"

  (trap - EXIT
    mkdir() {
      command mkdir "$@" || return 1
      case ${1##*/} in
        C.*)
          : > "$TEST_TMP/chooser-ready"
          wait_for_file "$TEST_TMP/never" || return 1
          ;;
      esac
    }
    cb_lock_acquire "$CB_REG_LOCK") &
  local dead=$!
  if ! wait_for_file "$TEST_TMP/chooser-ready"; then
    stop_workers "$dead"
    return 1
  fi
  kill -9 "$dead" 2>/dev/null || return 1
  wait "$dead" 2>/dev/null || true

  local claims="$CB_REG_LOCK.claims" dead_claim
  wait_for_claim "$claims" C. || return 1
  dead_claim=$FOUND_CLAIM
  cb_lock_acquire "$CB_REG_LOCK" || return 1
  [ -d "$dead_claim" ] || return 1
  cb_lock_release "$CB_REG_LOCK" || return 1
  [ -d "$dead_claim" ]
}

test_dead_ticket_holder_does_not_block_a_successor() {
  setup_registry
  mkdir -p "$CB_STATE_DIR"

  mv() {
    command mv "$@" || return 1
    case ${1##*/} in
      C.*)
        : > "$TEST_TMP/ticket-ready"
        wait_for_file "$TEST_TMP/never" || return 1
        ;;
    esac
  }
  (trap - EXIT; cb_lock_acquire "$CB_REG_LOCK") &
  local dead=$!
  unset -f mv
  if ! wait_for_file "$TEST_TMP/ticket-ready"; then
    stop_workers "$dead"
    return 1
  fi
  kill -9 "$dead" 2>/dev/null || return 1
  wait "$dead" 2>/dev/null || true

  local claims="$CB_REG_LOCK.claims" dead_claim
  wait_for_claim "$claims" T. || return 1
  dead_claim=$FOUND_CLAIM
  cb_lock_acquire "$CB_REG_LOCK" || return 1
  [ -d "$dead_claim" ] || return 1
  cb_lock_release "$CB_REG_LOCK" || return 1
  [ -d "$dead_claim" ]
}

test_later_claimant_cannot_overtake_a_live_ticket() {
  setup_registry
  mkdir -p "$CB_STATE_DIR"

  (trap - EXIT; cb_lock_acquire "$CB_REG_LOCK" || exit 1
    printf '%s\n' "$CB_LOCK_OWNER_TICKET" > "$TEST_TMP/first-ticket"
    : > "$TEST_TMP/first-acquired"
    wait_for_file "$TEST_TMP/first-release" || exit 1
    cb_lock_release "$CB_REG_LOCK") &
  local first=$!
  if ! wait_for_file "$TEST_TMP/first-acquired"; then
    stop_workers "$first"
    return 1
  fi

  (trap - EXIT; cb_lock_acquire "$CB_REG_LOCK" || exit 1
    : > "$TEST_TMP/second-acquired"
    wait_for_file "$TEST_TMP/second-release" || exit 1
    cb_lock_release "$CB_REG_LOCK") &
  local second=$!
  local claims="$CB_REG_LOCK.claims" second_ticket
  if ! wait_for_claim "$claims" "T.2.$second."; then
    stop_workers "$first" "$second"
    return 1
  fi
  second_ticket=$FOUND_CLAIM
  sleep 0.05
  if [ -f "$TEST_TMP/second-acquired" ]; then
    stop_workers "$first" "$second"
    return 1
  fi

  : > "$TEST_TMP/first-release"
  if ! wait_for_file "$TEST_TMP/second-acquired"; then
    stop_workers "$first" "$second"
    return 1
  fi
  [ -d "$second_ticket" ] || {
    : > "$TEST_TMP/second-release"
    stop_workers "$first" "$second"
    return 1
  }
  : > "$TEST_TMP/second-release"
  wait "$first" || return 1
  wait "$second"
}

test_release_failure_keeps_local_ownership() {
  setup_registry
  mkdir -p "$CB_STATE_DIR"
  cb_lock_acquire "$CB_REG_LOCK" || return 1

  local anchor=$CB_LOCK_OWNER_ANCHOR ticket=$CB_LOCK_OWNER_TICKET status
  : > "$ticket/block-release"
  cb_lock_release "$CB_REG_LOCK" >/dev/null 2>&1
  status=$?

  assert_eq 1 "$status" || return 1
  assert_eq "$anchor" "$CB_LOCK_OWNER_ANCHOR" || return 1
  assert_eq "$ticket" "$CB_LOCK_OWNER_TICKET" || return 1
  [ -f "$anchor" ] || return 1
  [ -d "$ticket" ] || return 1

  rm -f "$ticket/block-release"
  cb_lock_release "$CB_REG_LOCK"
}

test_registry_mutation_returns_release_failure() {
  setup_registry
  cb_reg_init || return 1

  mv() {
    command mv "$@" || return 1
    if [ "$2" = "$CB_REG" ]; then
      : > "$CB_LOCK_OWNER_TICKET/block-release"
    fi
  }

  cb_reg_put crew '{"field":"value"}' >/dev/null 2>&1
  local status=$?
  unset -f mv

  assert_eq 1 "$status" || return 1
  jq -e '.crew.field == "value"' "$CB_REG" >/dev/null || return 1
  [ -n "$CB_LOCK_OWNER_TICKET" ] || return 1
  rm -f "$CB_LOCK_OWNER_TICKET/block-release"
  cb_lock_release "$CB_REG_LOCK"
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
run_test "a same-shell background owner uses its worker pid" test_background_owner_uses_worker_pid
run_test "forced equal tickets enter in tuple order" test_equal_tickets_enter_in_tuple_order
run_test "a process killed while choosing does not block a successor" test_dead_chooser_does_not_block_a_successor
run_test "a process killed with a ticket does not block a successor" test_dead_ticket_holder_does_not_block_a_successor
run_test "a later claimant cannot overtake a live ticket" test_later_claimant_cannot_overtake_a_live_ticket
run_test "a release failure keeps local ownership state" test_release_failure_keeps_local_ownership
run_test "registry mutations return release failures" test_registry_mutation_returns_release_failure
finish_tests
