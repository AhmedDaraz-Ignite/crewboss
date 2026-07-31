#!/bin/bash
set -u

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd "$TEST_ROOT/.." && pwd)
CREWBOSS="$PROJECT_ROOT/scripts/crewboss"
# shellcheck source=tests/test_helper.sh
source "$TEST_ROOT/test_helper.sh"

setup_events() {
  TEST_TMP=$(mktemp -d)
  export CB_STATE_DIR="$TEST_TMP/state"
  trap 'rm -rf "$TEST_TMP"' EXIT
  # shellcheck source=scripts/lib/registry.sh
  source "$PROJECT_ROOT/scripts/lib/registry.sh"
  # shellcheck source=scripts/lib/events.sh
  source "$PROJECT_ROOT/scripts/lib/events.sh"
  cb_reg_put alpha '{"crew_id":"crew-current","run_id":"run-current"}'
}

write_event_tail_fixture() {
  local raw_seq=$1 event_id=$2
  cb_event_init || return 1
  printf '{"version":1,"seq":%s,"event_id":"%s","crew":"alpha","crew_id":"crew-current","run_id":"run-current","kind":"done","payload":"fixture","time":"2026-07-31T12:00:00Z"}\n' \
    "$raw_seq" "$event_id" > "$CB_EVENT_SOURCE"
}

event_source_inode() {
  ls -di "$CB_EVENT_SOURCE" | awk '{print $1}'
}

run_emit_with_owner_snapshot() {
  local status_file="$TEST_TMP/emit.status" owner_file="$TEST_TMP/emit.owner"
  CB_STATE_DIR="$CB_STATE_DIR" bash -c '
    source "$1"
    source "$2"
    status_file=$3
    owner_file=$4
    record_exit() {
      local status=$?
      printf "%s\n" "$status" > "$status_file"
      printf "%s\n" "${CB_LOCK_OWNER_LOCK:-}" > "$owner_file"
    }
    trap record_exit EXIT
    cb_event_emit alpha crew-current run-current done after-fixture
    exit $?
  ' bash "$PROJECT_ROOT/scripts/lib/registry.sh" \
    "$PROJECT_ROOT/scripts/lib/events.sh" "$status_file" "$owner_file" \
    >/dev/null 2>&1

  EMIT_STATUS=
  EMIT_OWNER=
  IFS= read -r EMIT_STATUS < "$status_file" || return 1
  IFS= read -r EMIT_OWNER < "$owner_file" || return 1
}

assert_tail_rejected_and_unlocked() {
  setup_events || return 1
  write_event_tail_fixture "$1" "$2" || return 1

  local before after
  before=$(cat "$CB_EVENT_SOURCE") || return 1
  run_emit_with_owner_snapshot || true
  after=$(cat "$CB_EVENT_SOURCE") || return 1

  assert_eq 1 "$EMIT_STATUS" || return 1
  assert_eq '' "$EMIT_OWNER" || return 1
  assert_eq "$before" "$after" || return 1
  cb_lock_acquire "$CB_EVENT_LOCK" || return 1
  cb_lock_release "$CB_EVENT_LOCK"
}

wait_for_producers() {
  local step marker pending=1 status=0 producer_status pid producer
  step=0
  while [ "$step" -lt 6000 ]; do
    step=$((step + 1))
    pending=0
    for producer in $(seq 1 16); do
      marker="$TEST_TMP/producer-$producer.status"
      if [ ! -f "$marker" ]; then
        pending=1
        break
      fi
    done
    [ "$pending" -eq 0 ] && break
    sleep 0.01
  done

  if [ "$pending" -ne 0 ]; then
    status=1
    for pid in "${PRODUCER_PIDS[@]}"; do
      kill -9 "$pid" 2>/dev/null || true
    done
  fi
  for pid in "${PRODUCER_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || status=1
  done
  for producer in $(seq 1 16); do
    marker="$TEST_TMP/producer-$producer.status"
    producer_status=
    IFS= read -r producer_status < "$marker" || producer_status=1
    [ "$producer_status" = 0 ] || status=1
  done
  return "$status"
}

test_concurrent_emit_is_one_physical_fifo_and_keeps_the_inode() {
  setup_events || return 1

  local producer item kind payload marker status fd_count
  PRODUCER_PIDS=()
  for producer in $(seq 1 16); do
    marker="$TEST_TMP/producer-$producer.status"
    (
      status=0
      for item in $(seq 1 8); do
        if [ $((item % 2)) -eq 0 ]; then kind="done"; else kind="blocked"; fi
        payload="producer-$producer-$item"
        CB_STATE_DIR="$CB_STATE_DIR" "$CREWBOSS" emit \
          alpha crew-current run-current "$kind" "$payload" >/dev/null 2>&1 || {
          status=$?
          break
        }
      done
      printf '%s\n' "$status" > "$marker"
      exit "$status"
    ) &
    PRODUCER_PIDS+=("$!")
  done
  wait_for_producers || return 1

  jq -s -e '
    length == 128 and
    ([.[].seq] == [range(1;129)]) and
    ([.[].event_id] == [range(1;129) | "event-\(.)"]) and
    ([.[].event_id] | unique | length) == 128 and
    all(.[ ];
      type == "object" and
      keys == ["crew","crew_id","event_id","kind","payload","run_id","seq","time","version"] and
      .version == 1 and
      .crew == "alpha" and
      .crew_id == "crew-current" and
      .run_id == "run-current" and
      (.kind == "blocked" or .kind == "done") and
      (.payload | type == "string" and length > 0) and
      (.time | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    ) and
    ([.[].payload] | sort) ==
      ([range(1;17) as $producer | range(1;9) as $item |
        "producer-\($producer)-\($item)"] | sort) and
    ([range(1;17) as $producer |
      ([.[] | select(.payload | startswith("producer-\($producer)-")) |
        .payload | split("-")[2] | tonumber] == [range(1;9)])] | all)
  ' "$CB_STATE_DIR/events.jsonl" >/dev/null || return 1

  exec 9< "$CB_STATE_DIR/events.jsonl"
  CB_STATE_DIR="$CB_STATE_DIR" "$CREWBOSS" emit \
    alpha crew-current run-current "done" appended-after-open >/dev/null 2>&1 || return 1
  fd_count=$(jq -s 'length' /dev/fd/9) || return 1
  exec 9<&-
  assert_eq 129 "$fd_count"
}

test_emit_rejects_invalid_producers_before_append() {
  setup_events || return 1

  CB_STATE_DIR="$CB_STATE_DIR" "$CREWBOSS" emit \
    alpha crew-current run-current "done" accepted >/dev/null 2>&1 || return 1

  ! CB_STATE_DIR="$CB_STATE_DIR" "$CREWBOSS" emit \
    missing crew-current run-current "done" payload >/dev/null 2>&1 || return 1
  ! CB_STATE_DIR="$CB_STATE_DIR" "$CREWBOSS" emit \
    alpha crew-stale run-current "done" payload >/dev/null 2>&1 || return 1
  ! CB_STATE_DIR="$CB_STATE_DIR" "$CREWBOSS" emit \
    alpha crew-current run-stale "done" payload >/dev/null 2>&1 || return 1
  ! CB_STATE_DIR="$CB_STATE_DIR" "$CREWBOSS" emit \
    alpha crew-current run-current running payload >/dev/null 2>&1 || return 1
  ! CB_STATE_DIR="$CB_STATE_DIR" "$CREWBOSS" emit \
    alpha crew-current run-current "done" '' >/dev/null 2>&1 || return 1

  jq -s -e 'length == 1 and .[0].payload == "accepted"' \
    "$CB_STATE_DIR/events.jsonl" >/dev/null
}

test_emit_refuses_to_append_after_a_malformed_last_record() {
  setup_events || return 1
  CB_STATE_DIR="$CB_STATE_DIR" "$CREWBOSS" emit \
    alpha crew-current run-current "done" first >/dev/null 2>&1 || return 1
  printf '{malformed}\n' >> "$CB_STATE_DIR/events.jsonl"

  ! CB_STATE_DIR="$CB_STATE_DIR" "$CREWBOSS" emit \
    alpha crew-current run-current "done" second >/dev/null 2>&1 || return 1
  assert_eq 2 "$(wc -l < "$CB_STATE_DIR/events.jsonl" | tr -d ' ')"
}

test_emit_refuses_an_unterminated_tail_without_changing_source() {
  setup_events || return 1
  cb_event_init || return 1
  printf '%s' \
    '{"version":1,"seq":1,"event_id":"event-1","crew":"alpha","crew_id":"crew-current","run_id":"run-current","kind":"done","payload":"unterminated","time":"2026-07-31T12:00:00Z"}' \
    > "$CB_EVENT_SOURCE" || return 1
  cp "$CB_EVENT_SOURCE" "$TEST_TMP/events.before" || return 1
  local before_inode after_inode
  before_inode=$(event_source_inode) || return 1

  ! CB_STATE_DIR="$CB_STATE_DIR" "$CREWBOSS" emit \
    alpha crew-current run-current done refused >/dev/null 2>&1 || return 1

  after_inode=$(event_source_inode) || return 1
  assert_eq "$before_inode" "$after_inode" || return 1
  cmp -s "$TEST_TMP/events.before" "$CB_EVENT_SOURCE"
}

test_emit_appends_after_a_complete_tail_without_replacing_source() {
  setup_events || return 1
  write_event_tail_fixture 1 event-1 || return 1
  local before_inode after_inode
  before_inode=$(event_source_inode) || return 1

  CB_STATE_DIR="$CB_STATE_DIR" "$CREWBOSS" emit \
    alpha crew-current run-current done accepted >/dev/null 2>&1 || return 1

  after_inode=$(event_source_inode) || return 1
  assert_eq "$before_inode" "$after_inode" || return 1
  jq -s -e 'length == 2 and .[0].payload == "fixture" and
    .[1].seq == 2 and .[1].payload == "accepted"' \
    "$CB_EVENT_SOURCE" >/dev/null
}

test_noncanonical_sequence_tokens_are_rejected_and_unlock() {
  (assert_tail_rejected_and_unlocked 1.5 event-1.5) || return 1
  (assert_tail_rejected_and_unlocked 1e3 event-1E+3) || return 1
  (assert_tail_rejected_and_unlocked 1e100 event-1E+100) || return 1
  (assert_tail_rejected_and_unlocked 0 event-0) || return 1
  (assert_tail_rejected_and_unlocked -1 event--1) || return 1
  (assert_tail_rejected_and_unlocked 01 event-1)
}

test_maximum_and_larger_sequences_are_rejected_and_unlock() {
  (assert_tail_rejected_and_unlocked 2147483647 event-2147483647) || return 1
  (assert_tail_rejected_and_unlocked 2147483648 event-2147483648)
}

test_sequence_immediately_below_maximum_appends_the_maximum_once() {
  setup_events || return 1
  write_event_tail_fixture 2147483646 event-2147483646 || return 1

  CB_STATE_DIR="$CB_STATE_DIR" "$CREWBOSS" emit \
    alpha crew-current run-current "done" reaches-maximum >/dev/null 2>&1 || return 1
  jq -s -e '
    length == 2 and
    .[1].seq == 2147483647 and
    .[1].event_id == "event-2147483647" and
    .[1].payload == "reaches-maximum"
  ' "$CB_EVENT_SOURCE" >/dev/null || return 1

  local before after
  before=$(cat "$CB_EVENT_SOURCE") || return 1
  ! CB_STATE_DIR="$CB_STATE_DIR" "$CREWBOSS" emit \
    alpha crew-current run-current "done" over-maximum >/dev/null 2>&1 || return 1
  after=$(cat "$CB_EVENT_SOURCE") || return 1
  assert_eq "$before" "$after" || return 1
  cb_lock_acquire "$CB_EVENT_LOCK" || return 1
  cb_lock_release "$CB_EVENT_LOCK"
}

run_test "concurrent emit is one physical FIFO and keeps the source inode" \
  test_concurrent_emit_is_one_physical_fifo_and_keeps_the_inode
run_test "emit rejects unknown stale and invalid producers before append" \
  test_emit_rejects_invalid_producers_before_append
run_test "emit refuses to append after a malformed last event" \
  test_emit_refuses_to_append_after_a_malformed_last_record
run_test "emit refuses an unterminated tail without changing bytes or inode" \
  test_emit_refuses_an_unterminated_tail_without_changing_source
run_test "emit appends after a complete tail without replacing the source" \
  test_emit_appends_after_a_complete_tail_without_replacing_source
run_test "noncanonical sequence tokens are rejected without keeping the lock" \
  test_noncanonical_sequence_tokens_are_rejected_and_unlock
run_test "maximum and larger sequences are rejected without keeping the lock" \
  test_maximum_and_larger_sequences_are_rejected_and_unlock
run_test "the sequence below maximum appends maximum exactly once" \
  test_sequence_immediately_below_maximum_appends_the_maximum_once
finish_tests
