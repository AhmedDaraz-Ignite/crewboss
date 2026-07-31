#!/bin/bash
set -u

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd "$TEST_ROOT/.." && pwd)
# shellcheck source=tests/test_helper.sh
source "$TEST_ROOT/test_helper.sh"

make_git_fixture() {
  TEST_TMP=$(mktemp -d)
  TEST_REPO="$TEST_TMP/repo"
  TEST_REMOTE="$TEST_TMP/remote.git"
  TEST_BIN="$TEST_TMP/bin"
  TEST_LOG="$TEST_TMP/calls"
  TEST_STATE="$TEST_TMP/state"
  mkdir -p "$TEST_BIN" "$TEST_STATE"
  : > "$TEST_LOG"
  trap 'rm -rf "$TEST_TMP"' EXIT

  git init -q --bare "$TEST_REMOTE"
  git init -q -b main "$TEST_REPO"
  git -C "$TEST_REPO" config user.name Test
  git -C "$TEST_REPO" config user.email test@example.com
  printf 'base\n' > "$TEST_REPO/file"
  git -C "$TEST_REPO" add file
  git -C "$TEST_REPO" commit -q -m base
  git -C "$TEST_REPO" remote add origin "$TEST_REMOTE"
  git -C "$TEST_REPO" push -q -u origin main
  git -C "$TEST_REPO" switch -q -c feature
}

commit_feature() {
  printf 'feature\n' > "$TEST_REPO/file"
  git -C "$TEST_REPO" add file
  git -C "$TEST_REPO" commit -q -m feature
}

push_feature() {
  git -C "$TEST_REPO" push -q -u origin feature
}

write_registry() {
  jq -n --arg path "$TEST_REPO" '{
    crew: {
      branch: "feature",
      path: $path,
      pane: "w1:p1",
      agent: "claude",
      placement: "tab",
      token: "",
      status: "open"
    }
  }' > "$TEST_STATE/crew.json"
}

write_phase1_registry() {
  jq -n --arg path "$TEST_REPO" '{
    crew: {
      branch: "feature",
      path: $path,
      pane: "w1:p1",
      agent: "claude",
      placement: "tab",
      token: "old-token",
      status: "open",
      task: "initial task",
      latest_prompt: "follow-up",
      crew_id: "crew-a",
      run_id: "run-a",
      task_status: "blocked",
      blocked: true,
      message: "question",
      last_event_seq: 1
    }
  }' > "$TEST_STATE/crew.json"
}

write_phase1_events() {
  cat > "$TEST_STATE/events.jsonl" <<'EVENTS'
{"version":1,"seq":1,"event_id":"event-1","crew":"crew","crew_id":"crew-a","run_id":"run-a","kind":"blocked","payload":"question","time":"2026-07-31T12:00:01Z"}
{"version":1,"seq":2,"event_id":"event-2","crew":"other","crew_id":"crew-b","run_id":"run-b","kind":"done","payload":"other result","time":"2026-07-31T12:00:02Z"}
EVENTS
  cat > "$TEST_STATE/event-state.json" <<'STATE'
{"cursor":2,"pending":{"crew-a":{"version":1,"seq":1,"event_id":"event-1","crew":"crew","crew_id":"crew-a","run_id":"run-a","kind":"blocked","payload":"question","time":"2026-07-31T12:00:01Z"},"crew-b":{"version":1,"seq":2,"event_id":"event-2","crew":"other","crew_id":"crew-b","run_id":"run-b","kind":"done","payload":"other result","time":"2026-07-31T12:00:02Z"}}}
STATE
}

write_fake_tools() {
  cat > "$TEST_BIN/herdr" <<'HERDR'
#!/bin/bash
printf 'herdr %s\n' "$*" >> "$TEST_LOG"

if [ "$1 $2" = "agent get" ]; then
  case ${HERDR_MODE:-matching} in
    matching)
      printf '{"result":{"agent":{"pane_id":"w1:p1"}}}\n'
      exit 0
      ;;
    mismatch)
      printf '{"result":{"agent":{"pane_id":"w1:p9"}}}\n'
      exit 0
      ;;
    missing)
      printf '{"error":{"code":"agent_not_found"}}\n'
      exit 1
      ;;
  esac
fi

if [ "$1 $2" = "pane close" ]; then
  if [ "${HERDR_DIRTY_ON_CLOSE:-0}" = 1 ]; then
    printf 'changed while closing\n' >> "$TEST_REPO/file"
  fi
  exit 0
fi

if [ "$1 $2" = "tab create" ]; then
  printf '{"result":{"root_pane":{"pane_id":"w2:p2"}}}\n'
  exit 0
fi

if [ "$1 $2" = "agent start" ]; then
  exit 0
fi

exit 2
HERDR

  cat > "$TEST_BIN/wt" <<'WT'
#!/bin/bash
printf 'wt %s\n' "$*" >> "$TEST_LOG"
exit "${WT_EXIT:-0}"
WT

  chmod +x "$TEST_BIN/herdr" "$TEST_BIN/wt"
}

setup_remove_fixture() {
  make_git_fixture
  write_registry
  write_fake_tools
}

run_remove() {
  run_crewboss remove "$@"
}

run_crewboss() {
  PATH="$TEST_BIN:$PATH" \
    CB_STATE_DIR="$TEST_STATE" \
    CB_BASE=origin/main \
    HERDR_WORKSPACE_ID=w1 \
    TEST_LOG="$TEST_LOG" \
    TEST_REPO="$TEST_REPO" \
    WT_EXIT="${WT_EXIT:-0}" \
    HERDR_MODE="${HERDR_MODE:-matching}" \
    HERDR_DIRTY_ON_CLOSE="${HERDR_DIRTY_ON_CLOSE:-0}" \
    "$PROJECT_ROOT/scripts/crewboss" "$@"
}

test_dirty_worktree_refuses_before_external_calls() {
  setup_remove_fixture
  printf 'dirty\n' >> "$TEST_REPO/file"

  local output status
  output=$(run_remove crew 2>&1)
  status=$?

  assert_eq 1 "$status" || return 1
  assert_contains "$output" uncommitted || return 1
  assert_eq '' "$(cat "$TEST_LOG")" || return 1
}

test_unpushed_commit_refuses_before_external_calls() {
  setup_remove_fixture
  commit_feature

  local output status
  output=$(run_remove crew 2>&1)
  status=$?

  assert_eq 1 "$status" || return 1
  assert_contains "$output" "not found on a remote" || return 1
  assert_eq '' "$(cat "$TEST_LOG")" || return 1
}

test_pushed_commit_removes_in_foreground() {
  setup_remove_fixture
  commit_feature
  push_feature

  local output status calls
  output=$(run_remove crew 2>&1)
  status=$?
  calls=$(cat "$TEST_LOG")

  assert_eq 0 "$status" || return 1
  assert_contains "$calls" "herdr agent get crew" || return 1
  assert_contains "$calls" "herdr pane close w1:p1" || return 1
  assert_contains "$calls" "wt remove --foreground feature" || return 1
  jq -e 'has("crew") | not' "$TEST_STATE/crew.json" >/dev/null || return 1
}

test_force_skips_git_guards_and_passes_exact_flag() {
  setup_remove_fixture
  commit_feature
  printf 'dirty\n' >> "$TEST_REPO/file"

  local output status
  output=$(run_remove crew -f 2>&1)
  status=$?

  assert_eq 0 "$status" || return 1
  assert_eq "wt remove --foreground feature -f" "$(tail -1 "$TEST_LOG")" || return 1
}

test_invalid_force_argument_fails_before_external_calls() {
  setup_remove_fixture

  local output status
  output=$(run_remove crew please 2>&1)
  status=$?

  assert_eq 1 "$status" || return 1
  assert_contains "$output" "usage: crewboss remove <name> [-f]" || return 1
  assert_eq '' "$(cat "$TEST_LOG")" || return 1
}

test_extra_argument_fails_before_external_calls() {
  setup_remove_fixture

  local output status
  output=$(run_remove crew -f extra 2>&1)
  status=$?

  assert_eq 1 "$status" || return 1
  assert_contains "$output" "usage: crewboss remove <name> [-f]" || return 1
  assert_eq '' "$(cat "$TEST_LOG")" || return 1
}

test_pane_mismatch_keeps_open_registry_and_worktree() {
  setup_remove_fixture
  commit_feature
  push_feature
  HERDR_MODE=mismatch

  local output status calls
  output=$(run_remove crew 2>&1)
  status=$?
  calls=$(cat "$TEST_LOG")

  assert_eq 1 "$status" || return 1
  assert_contains "$output" w1:p9 || return 1
  assert_contains "$calls" "herdr agent get crew" || return 1
  assert_not_contains "$calls" "wt " || return 1
  assert_eq open "$(jq -r '.crew.status' "$TEST_STATE/crew.json")" || return 1
}

test_worktrunk_failure_keeps_closed_registry() {
  setup_remove_fixture
  commit_feature
  push_feature
  WT_EXIT=7

  local output status
  output=$(run_remove crew 2>&1)
  status=$?

  assert_eq 1 "$status" || return 1
  jq -e 'has("crew")' "$TEST_STATE/crew.json" >/dev/null || return 1
  assert_eq closed "$(jq -r '.crew.status' "$TEST_STATE/crew.json")" || return 1
}

test_close_and_open_preserve_phase1_state_and_event_files() {
  setup_remove_fixture
  write_phase1_registry
  write_phase1_events
  local before output status
  before=$(jq -c '.crew | del(.status, .pane)' "$TEST_STATE/crew.json") || return 1
  cp "$TEST_STATE/events.jsonl" "$TEST_TMP/events.before" || return 1
  cp "$TEST_STATE/event-state.json" "$TEST_TMP/event-state.before" || return 1

  output=$(run_crewboss close crew 2>&1)
  status=$?
  assert_eq 0 "$status" || return 1
  assert_contains "$output" "closed crew" || return 1
  assert_eq closed "$(jq -r '.crew.status' "$TEST_STATE/crew.json")" || return 1

  output=$(run_crewboss open crew 2>&1)
  status=$?
  assert_eq 0 "$status" || return 1
  assert_contains "$output" "reopened crew" || return 1
  assert_eq open "$(jq -r '.crew.status' "$TEST_STATE/crew.json")" || return 1
  assert_eq w2:p2 "$(jq -r '.crew.pane' "$TEST_STATE/crew.json")" || return 1
  assert_eq "$before" \
    "$(jq -c '.crew | del(.status, .pane)' "$TEST_STATE/crew.json")" || return 1
  cmp -s "$TEST_TMP/events.before" "$TEST_STATE/events.jsonl" || return 1
  cmp -s "$TEST_TMP/event-state.before" "$TEST_STATE/event-state.json"
}

test_successful_remove_drops_only_its_pending_projection() {
  setup_remove_fixture
  write_phase1_registry
  write_phase1_events
  commit_feature
  push_feature
  cp "$TEST_STATE/events.jsonl" "$TEST_TMP/events.before" || return 1

  run_remove crew >/dev/null 2>&1 || return 1

  cmp -s "$TEST_TMP/events.before" "$TEST_STATE/events.jsonl" || return 1
  jq -e '.cursor == 2 and (.pending | keys) == ["crew-b"] and
    .pending["crew-b"].event_id == "event-2"' \
    "$TEST_STATE/event-state.json" >/dev/null || return 1
  jq -e 'has("crew") | not' "$TEST_STATE/crew.json" >/dev/null
}

test_failed_remove_keeps_pending_projection_and_raw_log() {
  setup_remove_fixture
  write_phase1_registry
  write_phase1_events
  commit_feature
  push_feature
  WT_EXIT=7
  cp "$TEST_STATE/events.jsonl" "$TEST_TMP/events.before" || return 1
  cp "$TEST_STATE/event-state.json" "$TEST_TMP/event-state.before" || return 1

  ! run_remove crew >/dev/null 2>&1 || return 1

  cmp -s "$TEST_TMP/events.before" "$TEST_STATE/events.jsonl" || return 1
  cmp -s "$TEST_TMP/event-state.before" "$TEST_STATE/event-state.json" || return 1
  jq -e '.crew.status == "closed" and .crew.crew_id == "crew-a"' \
    "$TEST_STATE/crew.json" >/dev/null
}

test_missing_agent_skips_pane_close_and_removes() {
  setup_remove_fixture
  commit_feature
  push_feature
  HERDR_MODE=missing

  local output status calls
  output=$(run_remove crew 2>&1)
  status=$?
  calls=$(cat "$TEST_LOG")

  assert_eq 0 "$status" || return 1
  assert_contains "$calls" "herdr agent get crew" || return 1
  assert_not_contains "$calls" "pane close" || return 1
  assert_contains "$calls" "wt remove --foreground feature" || return 1
}

test_change_during_close_keeps_closed_registry_and_worktree() {
  setup_remove_fixture
  HERDR_DIRTY_ON_CLOSE=1

  local output status calls
  output=$(run_remove crew 2>&1)
  status=$?
  calls=$(cat "$TEST_LOG")

  assert_eq 1 "$status" || return 1
  assert_contains "$calls" "herdr pane close w1:p1" || return 1
  assert_not_contains "$calls" "wt " || return 1
  assert_contains "$output" "changed while closing" || return 1
  assert_eq closed "$(jq -r '.crew.status' "$TEST_STATE/crew.json")" || return 1
  assert_eq '' "$(jq -r '.crew.token' "$TEST_STATE/crew.json")" || return 1
}

run_test "dirty worktree refuses removal before external calls" test_dirty_worktree_refuses_before_external_calls
run_test "unpushed commit refuses removal before external calls" test_unpushed_commit_refuses_before_external_calls
run_test "pushed commit closes and removes the crew in foreground" test_pushed_commit_removes_in_foreground
run_test "force skips Git guards and passes only exact -f" test_force_skips_git_guards_and_passes_exact_flag
run_test "invalid force argument fails before external calls" test_invalid_force_argument_fails_before_external_calls
run_test "extra removal argument fails before external calls" test_extra_argument_fails_before_external_calls
run_test "pane mismatch keeps the open registry and worktree" test_pane_mismatch_keeps_open_registry_and_worktree
run_test "worktrunk failure keeps a recoverable closed registry" test_worktrunk_failure_keeps_closed_registry
run_test "close and open preserve phase-one task and event state" \
  test_close_and_open_preserve_phase1_state_and_event_files
run_test "successful removal drops only its pending event projection" \
  test_successful_remove_drops_only_its_pending_projection
run_test "failed removal preserves its pending event projection and raw log" \
  test_failed_remove_keeps_pending_projection_and_raw_log
run_test "missing agent skips pane close and removes the worktree" test_missing_agent_skips_pane_close_and_removes
run_test "change during pane close keeps a recoverable closed crew" test_change_during_close_keeps_closed_registry_and_worktree
finish_tests
