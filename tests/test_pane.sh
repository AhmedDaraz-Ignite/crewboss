#!/bin/bash
set -u

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$TEST_ROOT/test_helper.sh"
source "$TEST_ROOT/../scripts/lib/pane.sh"

HERDR_LOG=$(mktemp)
HERDR_MODE=matching
trap 'rm -f "$HERDR_LOG"' EXIT

herdr() {
  if [ "$1 $2" = "agent get" ]; then
    case $HERDR_MODE in
      matching)
        printf '{"result":{"agent":{"pane_id":"w1:p1"}}}\n' ;;
      mismatch)
        printf '{"result":{"agent":{"pane_id":"w1:p9"}}}\n' ;;
      missing)
        printf '{"error":{"code":"agent_not_found"}}\n'; return 1 ;;
      broken)
        printf '{"error":{"code":"daemon_unavailable"}}\n'; return 1 ;;
      malformed)
        printf 'not-json\n' ;;
    esac
    return
  fi
  if [ "$1 $2" = "pane close" ]; then
    printf '%s\n' "$*" >> "$HERDR_LOG"
    return
  fi
  return 2
}

test_matching_pane_closes() {
  HERDR_MODE=matching
  : > "$HERDR_LOG"

  cb_pane_close w1:p1 crew-a

  assert_eq 'pane close w1:p1' "$(cat "$HERDR_LOG")"
}

test_mismatched_pane_refuses_close() {
  HERDR_MODE=mismatch
  : > "$HERDR_LOG"

  local output status
  output=$(cb_pane_close w1:p1 crew-a 2>&1)
  status=$?

  assert_eq 1 "$status"
  assert_contains "$output" w1:p9
  assert_contains "$output" w1:p1
  assert_eq '' "$(cat "$HERDR_LOG")"
}

test_missing_agent_keeps_pane() {
  HERDR_MODE=missing
  : > "$HERDR_LOG"

  local status
  cb_pane_close w1:p1 crew-a
  status=$?

  assert_eq '' "$(cat "$HERDR_LOG")"
  assert_eq 0 "$status"
}

test_daemon_error_refuses_close() {
  HERDR_MODE=broken
  : > "$HERDR_LOG"

  local status
  cb_pane_close w1:p1 crew-a >/dev/null 2>&1
  status=$?

  assert_eq 1 "$status"
  assert_eq '' "$(cat "$HERDR_LOG")"
}

test_malformed_json_refuses_close() {
  HERDR_MODE=malformed
  : > "$HERDR_LOG"

  local status
  cb_pane_close w1:p1 crew-a >/dev/null 2>&1
  status=$?

  assert_eq 1 "$status"
  assert_eq '' "$(cat "$HERDR_LOG")"
}

run_test "closes a pane owned by the crew" test_matching_pane_closes
run_test "refuses to close a reassigned pane" test_mismatched_pane_refuses_close
run_test "leaves a pane alone when its agent is missing" test_missing_agent_keeps_pane
run_test "refuses to close when herdr is unavailable" test_daemon_error_refuses_close
run_test "refuses to close when herdr returns malformed JSON" test_malformed_json_refuses_close
finish_tests
