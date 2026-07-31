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
  cb_reg_put alpha '{"crew_id":"crew-current","run_id":"run-current"}'
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

run_test "concurrent emit is one physical FIFO and keeps the source inode" \
  test_concurrent_emit_is_one_physical_fifo_and_keeps_the_inode
run_test "emit rejects unknown stale and invalid producers before append" \
  test_emit_rejects_invalid_producers_before_append
run_test "emit refuses to append after a malformed last event" \
  test_emit_refuses_to_append_after_a_malformed_last_record
finish_tests
