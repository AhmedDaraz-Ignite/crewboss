#!/bin/bash
set -u

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/test_helper.sh
source "$TEST_ROOT/test_helper.sh"
# shellcheck source=scripts/lib/naming.sh
source "$TEST_ROOT/../scripts/lib/naming.sh"
# shellcheck source=scripts/lib/pane.sh
source "$TEST_ROOT/../scripts/lib/pane.sh"

HERDR_LOG=$(mktemp)
HERDR_AGENT_LOG=$(mktemp)
HERDR_MODE=matching
trap 'rm -f "$HERDR_LOG" "$HERDR_AGENT_LOG"' EXIT

herdr() {
  if [ "$1 $2" = "agent get" ]; then
    printf '%s\n' "$*" >> "$HERDR_AGENT_LOG"
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
  if [ "$1 $2" = "tab create" ]; then
    printf '%s\n' "$*" >> "$HERDR_LOG"
    printf '{"result":{"root_pane":{"pane_id":"w1:p2"}}}\n'
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

test_public_name_maps_for_agent_identity_check() {
  HERDR_MODE=mismatch
  : > "$HERDR_LOG"
  : > "$HERDR_AGENT_LOG"

  local output status
  output=$(cb_pane_close w1:p1 SMOKE-100 2>&1)
  status=$?

  assert_eq 1 "$status" || return 1
  assert_eq "agent get smoke-100" "$(cat "$HERDR_AGENT_LOG")" || return 1
  assert_contains "$output" "'SMOKE-100'"
}

test_public_name_remains_the_pane_label() {
  : > "$HERDR_LOG"
  local HERDR_WORKSPACE_ID=w1 pane

  pane=$(cb_pane_create tab /tmp/tree SMOKE-100)

  assert_eq w1:p2 "$pane" || return 1
  assert_eq "tab create --workspace w1 --cwd /tmp/tree --label SMOKE-100 --no-focus" \
    "$(cat "$HERDR_LOG")"
}

run_test "closes a pane owned by the crew" test_matching_pane_closes
run_test "refuses to close a reassigned pane" test_mismatched_pane_refuses_close
run_test "leaves a pane alone when its agent is missing" test_missing_agent_keeps_pane
run_test "refuses to close when herdr is unavailable" test_daemon_error_refuses_close
run_test "refuses to close when herdr returns malformed JSON" test_malformed_json_refuses_close
run_test "maps the public crew name for agent identity checks" test_public_name_maps_for_agent_identity_check
run_test "keeps the public crew name as the pane label" test_public_name_remains_the_pane_label
finish_tests
