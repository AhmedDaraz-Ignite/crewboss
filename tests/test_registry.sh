#!/bin/bash
set -u

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd "$TEST_ROOT/.." && pwd)
# shellcheck source=tests/test_helper.sh
source "$TEST_ROOT/test_helper.sh"

setup_registry() {
  TEST_TMP=$(mktemp -d)
  export CB_STATE_DIR="$TEST_TMP/state"
  WORKER_PIDS=()
  WORKER_MARKERS=()
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
    kill -9 "$pid" 2>/dev/null || true
  done
  for pid in "$@"; do
    wait "$pid" 2>/dev/null || true
  done
  WORKER_PIDS=()
  WORKER_MARKERS=()
}

track_worker() {
  WORKER_PIDS+=("$1")
  WORKER_MARKERS+=("$2")
}

finish_worker() {
  local marker=$1 status=$2
  printf '%s\n' "$status" > "$marker" || status=1
  exit "$status"
}

wait_for_workers_bounded() {
  local steps=${TEST_WORKER_WAIT_STEPS:-300} step index pending=1 status=0 worker_status
  for step in $(seq 1 "$steps"); do
    pending=0
    for ((index = 0; index < ${#WORKER_MARKERS[@]}; index++)); do
      if [ ! -f "${WORKER_MARKERS[$index]}" ]; then
        pending=1
        break
      fi
    done
    [ "$pending" -eq 0 ] && break
    sleep 0.01
  done

  if [ "$pending" -ne 0 ]; then
    status=1
    for pid in "${WORKER_PIDS[@]}"; do
      kill -9 "$pid" 2>/dev/null || true
    done
  fi

  for ((index = 0; index < ${#WORKER_PIDS[@]}; index++)); do
    worker_status=
    if [ -f "${WORKER_MARKERS[$index]}" ]; then
      IFS= read -r worker_status < "${WORKER_MARKERS[$index]}" || worker_status=1
    else
      worker_status=1
    fi
    [ "$worker_status" = 0 ] || status=1
    wait "${WORKER_PIDS[$index]}" 2>/dev/null || status=1
  done
  WORKER_PIDS=()
  WORKER_MARKERS=()
  return "$status"
}

test_concurrent_puts_keep_every_field() {
  setup_registry
  cb_reg_init || return 1

  local i field marker real_jq
  real_jq=$(command -v jq) || return 1
  for i in $(seq 1 32); do
    field=$(jq -n --arg k "k$i" --arg v "$i" '{($k): $v}')
    marker="$TEST_TMP/writer-$i.done"
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
        status=0
        cb_reg_put "$2" "$3" || status=$?
        printf "%s\n" "$status" > "$4" || status=1
        exit "$status"
      ' bash \
      "$PROJECT_ROOT/scripts/lib/registry.sh" crew "$field" "$marker" &
    track_worker "$!" "$marker"
  done
  wait_for_workers_bounded || return 1
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

  local marker="$TEST_TMP/owner.done"
  (trap - EXIT
    local status=0
    cb_lock_acquire "$CB_REG_LOCK" || status=1
    if [ "$status" -eq 0 ]; then
      printf '%s\n' "$CB_LOCK_OWNER_ANCHOR" > "$TEST_TMP/anchor" || status=1
    fi
    if [ "$status" -eq 0 ]; then
      wait_for_file "$TEST_TMP/release" || status=1
    fi
    if [ "$status" -eq 0 ]; then
      cb_lock_release "$CB_REG_LOCK" || status=1
    fi
    finish_worker "$marker" "$status") &
  local worker=$!
  track_worker "$worker" "$marker"
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
  wait_for_workers_bounded || return 1
  [ ! -e "$anchor" ]
}

start_equal_claimant() {
  local label=$1 marker="$TEST_TMP/$1.done"
  (trap - EXIT
    local status=0
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
    cb_lock_acquire "$CB_REG_LOCK" || status=1
    if [ "$status" -eq 0 ]; then
      : > "$TEST_TMP/$label-acquired" || status=1
    fi
    if [ "$status" -eq 0 ]; then
      wait_for_file "$TEST_TMP/$label-release" || status=1
    fi
    if [ "$status" -eq 0 ]; then
      cb_lock_release "$CB_REG_LOCK" || status=1
    fi
    finish_worker "$marker" "$status") &
  STARTED_PID=$!
  track_worker "$STARTED_PID" "$marker"
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
  wait_for_workers_bounded
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

  local claims="$CB_REG_LOCK.claims" dead_claim marker="$TEST_TMP/successor.done"
  wait_for_claim "$claims" C. || return 1
  dead_claim=$FOUND_CLAIM
  (trap - EXIT
    local status=0
    cb_lock_acquire "$CB_REG_LOCK" || status=1
    if [ "$status" -eq 0 ]; then
      [ -d "$dead_claim" ] || status=1
    fi
    if [ "$status" -eq 0 ]; then
      cb_lock_release "$CB_REG_LOCK" || status=1
    fi
    finish_worker "$marker" "$status") &
  track_worker "$!" "$marker"
  wait_for_workers_bounded || return 1
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

  local claims="$CB_REG_LOCK.claims" dead_claim marker="$TEST_TMP/successor.done"
  wait_for_claim "$claims" T. || return 1
  dead_claim=$FOUND_CLAIM
  (trap - EXIT
    local status=0
    cb_lock_acquire "$CB_REG_LOCK" || status=1
    if [ "$status" -eq 0 ]; then
      [ -d "$dead_claim" ] || status=1
    fi
    if [ "$status" -eq 0 ]; then
      cb_lock_release "$CB_REG_LOCK" || status=1
    fi
    finish_worker "$marker" "$status") &
  track_worker "$!" "$marker"
  wait_for_workers_bounded || return 1
  [ -d "$dead_claim" ]
}

test_later_claimant_cannot_overtake_a_live_ticket() {
  setup_registry
  mkdir -p "$CB_STATE_DIR"

  local first_marker="$TEST_TMP/first.done" second_marker="$TEST_TMP/second.done"
  (trap - EXIT
    local status=0
    cb_lock_acquire "$CB_REG_LOCK" || status=1
    if [ "$status" -eq 0 ]; then
      printf '%s\n' "$CB_LOCK_OWNER_TICKET" > "$TEST_TMP/first-ticket" || status=1
      : > "$TEST_TMP/first-acquired" || status=1
    fi
    if [ "$status" -eq 0 ]; then
      wait_for_file "$TEST_TMP/first-release" || status=1
    fi
    if [ "$status" -eq 0 ]; then
      cb_lock_release "$CB_REG_LOCK" || status=1
    fi
    finish_worker "$first_marker" "$status") &
  local first=$!
  track_worker "$first" "$first_marker"
  if ! wait_for_file "$TEST_TMP/first-acquired"; then
    stop_workers "$first"
    return 1
  fi

  (trap - EXIT
    local status=0
    cb_lock_acquire "$CB_REG_LOCK" || status=1
    if [ "$status" -eq 0 ]; then
      : > "$TEST_TMP/second-acquired" || status=1
    fi
    if [ "$status" -eq 0 ]; then
      wait_for_file "$TEST_TMP/second-release" || status=1
    fi
    if [ "$status" -eq 0 ]; then
      cb_lock_release "$CB_REG_LOCK" || status=1
    fi
    finish_worker "$second_marker" "$status") &
  local second=$!
  track_worker "$second" "$second_marker"
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
  wait_for_workers_bounded
}

test_inherited_child_cannot_release_parent_ticket() {
  setup_registry
  mkdir -p "$CB_STATE_DIR"
  cb_lock_acquire "$CB_REG_LOCK" || return 1

  local ticket=$CB_LOCK_OWNER_TICKET attempt_marker="$TEST_TMP/attempt.done"
  local attempt_status waiter waiter_marker="$TEST_TMP/waiter.done"
  (trap - EXIT
    local status=0 release_status
    cb_lock_release "$CB_REG_LOCK" >/dev/null 2>&1
    release_status=$?
    printf '%s\n' "$release_status" > "$TEST_TMP/attempt-status" || status=1
    finish_worker "$attempt_marker" "$status") &
  track_worker "$!" "$attempt_marker"
  wait_for_workers_bounded || return 1

  IFS= read -r attempt_status < "$TEST_TMP/attempt-status" || return 1
  assert_eq 1 "$attempt_status" || return 1
  [ -d "$ticket" ] || return 1

  (trap - EXIT
    local status=0
    CB_LOCK_OWNER_LOCK=
    CB_LOCK_OWNER_ANCHOR=
    CB_LOCK_OWNER_TICKET=
    CB_LOCK_OWNER_PID=
    cb_lock_acquire "$CB_REG_LOCK" || status=1
    if [ "$status" -eq 0 ]; then
      : > "$TEST_TMP/waiter-acquired" || status=1
    fi
    if [ "$status" -eq 0 ]; then
      wait_for_file "$TEST_TMP/waiter-release" || status=1
    fi
    if [ "$status" -eq 0 ]; then
      cb_lock_release "$CB_REG_LOCK" || status=1
    fi
    finish_worker "$waiter_marker" "$status") &
  waiter=$!
  track_worker "$waiter" "$waiter_marker"
  if ! wait_for_claim "$CB_REG_LOCK.claims" "T.2.$waiter."; then
    stop_workers "$waiter"
    return 1
  fi
  sleep 0.05
  if [ -f "$TEST_TMP/waiter-acquired" ]; then
    stop_workers "$waiter"
    return 1
  fi

  cb_lock_release "$CB_REG_LOCK" || {
    stop_workers "$waiter"
    return 1
  }
  if ! wait_for_file "$TEST_TMP/waiter-acquired"; then
    stop_workers "$waiter"
    return 1
  fi
  : > "$TEST_TMP/waiter-release"
  wait_for_workers_bounded
}

test_bounded_worker_wait_kills_and_reaps_a_stuck_child() {
  setup_registry

  local marker="$TEST_TMP/stuck.done" worker status
  (trap - EXIT
    while :; do
      sleep 0.01
    done) &
  worker=$!
  track_worker "$worker" "$marker"
  TEST_WORKER_WAIT_STEPS=5
  wait_for_workers_bounded >/dev/null 2>&1
  status=$?
  unset TEST_WORKER_WAIT_STEPS

  assert_eq 1 "$status" || return 1
  ! kill -0 "$worker" 2>/dev/null
}

test_release_failure_keeps_local_ownership() {
  setup_registry
  mkdir -p "$CB_STATE_DIR"
  cb_lock_acquire "$CB_REG_LOCK" || return 1

  local anchor=$CB_LOCK_OWNER_ANCHOR ticket=$CB_LOCK_OWNER_TICKET
  local owner_pid=${CB_LOCK_OWNER_PID:-} status
  [ -n "$owner_pid" ] || return 1
  : > "$ticket/block-release"
  cb_lock_release "$CB_REG_LOCK" >/dev/null 2>&1
  status=$?

  assert_eq 1 "$status" || return 1
  assert_eq "$anchor" "$CB_LOCK_OWNER_ANCHOR" || return 1
  assert_eq "$ticket" "$CB_LOCK_OWNER_TICKET" || return 1
  assert_eq "$owner_pid" "$CB_LOCK_OWNER_PID" || return 1
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

test_endpoint_reconcile_closes_the_matching_open_lifecycle_atomically() {
  setup_registry
  cb_reg_put crew '{"pane":"w1:p1","status":"open","endpoint_state":"open","kept":"value"}' || return 1

  cb_reg_reconcile_endpoint crew w1:p1 closed || return 1

  jq -e '.crew == {pane:"w1:p1",status:"closed",endpoint_state:"closed",kept:"value"}' \
    "$CB_REG" >/dev/null
}

test_stale_endpoint_reconcile_cannot_overwrite_a_reopened_pane() {
  setup_registry
  cb_reg_put crew '{"pane":"w1:p1","status":"open","endpoint_state":"unknown","kept":"value"}' || return 1
  cb_reg_put crew '{"pane":"w1:p2","status":"open","endpoint_state":"open"}' || return 1
  local before status after
  before=$(jq -c '.crew' "$CB_REG") || return 1

  cb_reg_reconcile_endpoint crew w1:p1 closed >/dev/null 2>&1
  status=$?
  after=$(jq -c '.crew' "$CB_REG") || return 1

  assert_eq 2 "$status" || return 1
  assert_eq "$before" "$after"
}

test_stale_endpoint_reconcile_cannot_close_a_replacement_crew_lifetime() {
  setup_registry
  cb_reg_put crew '{"crew_id":"crew-old","pane":"w1:p1","status":"open","endpoint_state":"open"}' || return 1
  cb_reg_replace crew '{"crew_id":"crew-new","pane":"w1:p1","status":"open","endpoint_state":"open","kept":"replacement"}' || return 1
  local before status after
  before=$(jq -c '.crew' "$CB_REG") || return 1

  cb_reg_reconcile_endpoint crew w1:p1 closed crew-old >/dev/null 2>&1
  status=$?
  after=$(jq -c '.crew' "$CB_REG") || return 1

  assert_eq 2 "$status" || return 1
  assert_eq "$before" "$after"
}

test_endpoint_reconcile_requires_an_open_lifecycle() {
  setup_registry
  cb_reg_put crew '{"pane":"w1:p1","status":"closed","endpoint_state":"closed"}' || return 1
  local before status after
  before=$(jq -c '.crew' "$CB_REG") || return 1

  cb_reg_reconcile_endpoint crew w1:p1 unknown >/dev/null 2>&1
  status=$?
  after=$(jq -c '.crew' "$CB_REG") || return 1

  assert_eq 2 "$status" || return 1
  assert_eq "$before" "$after"
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

assert_send_receipt_rejected_unchanged() {
  local receipt=$1 status
  cp "$CB_REG" "$TEST_TMP/receipt.before" || return 1
  cb_reg_send_finish crew "$receipt" failure >/dev/null 2>&1
  status=$?
  assert_eq 1 "$status" || return 1
  cmp -s "$TEST_TMP/receipt.before" "$CB_REG"
}

test_send_receipt_binds_the_exact_prepared_transaction() {
  setup_registry
  cb_reg_put crew '{"status":"open","crew_id":"crew-current","run_id":"run-old",
    "latest_prompt":"old prompt","task_status":"blocked","blocked":true,
    "message":"old question","last_event_seq":7,"kept":"value"}' || return 1

  cb_reg_send_begin crew crew-candidate run-new "new prompt" || return 1
  local receipt=$CB_REG_SEND_RECEIPT

  jq -e --arg name crew '
    keys == ["baseline_last_event_seq","before","crew_id","name","prepared","run_id"] and
    .name == $name and .crew_id == "crew-current" and .run_id == "run-new" and
    .baseline_last_event_seq == 7 and (.prepared.latest_prompt | type) == "string" and
    .prepared == (.before + {
      crew_id: .crew_id, run_id: .run_id, latest_prompt: .prepared.latest_prompt
    })
  ' <<< "$receipt" >/dev/null
}

test_forged_send_receipts_change_nothing() {
  setup_registry
  cb_reg_put crew '{"status":"open","crew_id":"crew-current","run_id":"run-old",
    "latest_prompt":"old prompt","task_status":"blocked","blocked":true,
    "message":"old question","last_event_seq":7,"kept":"value"}' || return 1
  cb_reg_send_begin crew crew-candidate run-new "new prompt" || return 1
  local receipt=$CB_REG_SEND_RECEIPT forged
  local -a forged_receipts
  forged_receipts=()
  forged_receipts+=("$(jq -c '.name = "other"' <<< "$receipt")")
  forged_receipts+=("$(jq -c '.baseline_last_event_seq = 8' <<< "$receipt")")
  forged_receipts+=("$(jq -c '.prepared.crew_id = "crew-other"' <<< "$receipt")")
  forged_receipts+=("$(jq -c '.before = {status:"open",attacker:true}' <<< "$receipt")")
  forged_receipts+=("$receipt"$'\n'"$receipt")

  for forged in "${forged_receipts[@]}"; do
    assert_send_receipt_rejected_unchanged "$forged" || return 1
  done
}

run_test "concurrent registry writes keep every field" test_concurrent_puts_keep_every_field
run_test "a current blocked event updates task state" test_current_blocked_event_updates_task_state
run_test "replaying an event keeps the same task state" test_replaying_an_event_keeps_the_same_state
run_test "an old crew identity is stale without changing state" test_old_crew_identity_returns_stale_without_changing_the_record
run_test "an old run identity is stale without changing state" test_old_run_identity_returns_stale_without_changing_the_record
run_test "replace and endpoint state keep only current record fields" test_replace_and_endpoint_state_write_atomically
run_test "endpoint reconciliation atomically closes a matching open lifecycle" \
  test_endpoint_reconcile_closes_the_matching_open_lifecycle_atomically
run_test "a stale endpoint probe cannot overwrite a reopened pane" \
  test_stale_endpoint_reconcile_cannot_overwrite_a_reopened_pane
run_test "a stale endpoint probe cannot close a replacement crew lifetime" \
  test_stale_endpoint_reconcile_cannot_close_a_replacement_crew_lifetime
run_test "endpoint reconciliation requires an open lifecycle" \
  test_endpoint_reconcile_requires_an_open_lifecycle
run_test "new registry identities use unique requested prefixes" test_new_ids_keep_the_requested_prefix_and_are_unique
run_test "send receipts bind the exact prepared transaction" \
  test_send_receipt_binds_the_exact_prepared_transaction
run_test "forged send receipts change nothing" \
  test_forged_send_receipts_change_nothing
run_test "a same-shell background owner uses its worker pid" test_background_owner_uses_worker_pid
run_test "forced equal tickets enter in tuple order" test_equal_tickets_enter_in_tuple_order
run_test "a process killed while choosing does not block a successor" test_dead_chooser_does_not_block_a_successor
run_test "a process killed with a ticket does not block a successor" test_dead_ticket_holder_does_not_block_a_successor
run_test "a later claimant cannot overtake a live ticket" test_later_claimant_cannot_overtake_a_live_ticket
run_test "an inherited child cannot release its parent's ticket" test_inherited_child_cannot_release_parent_ticket
run_test "bounded worker waits kill and reap a stuck child" test_bounded_worker_wait_kills_and_reaps_a_stuck_child
run_test "a release failure keeps local ownership state" test_release_failure_keeps_local_ownership
run_test "registry mutations return release failures" test_registry_mutation_returns_release_failure
finish_tests
