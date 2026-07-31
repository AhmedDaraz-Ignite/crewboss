#!/bin/bash
set -u

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$TEST_ROOT/test_helper.sh"
source "$TEST_ROOT/../scripts/lib/tree.sh"

test_rejects_primary_checkout() {
  cb_tree_path() { printf '/repo'; }
  cb_tree_primary_path() { printf '/repo'; }
  wt() { printf 'wt must not run\n' >&2; return 99; }

  local output status
  output=$(cb_tree_create feature 2>&1)
  status=$?

  assert_eq 1 "$status"
  assert_contains "$output" "checked out in the primary repo"
}

test_reuses_linked_worktree() {
  cb_tree_path() { printf '/repo.feature'; }
  cb_tree_primary_path() { printf '/repo'; }
  wt() { printf 'wt must not run\n' >&2; return 99; }

  assert_eq /repo.feature "$(cb_tree_create feature)"
}

test_creates_missing_worktree() {
  local calls
  calls=$(mktemp)
  trap 'rm -f "$calls"' RETURN
  cb_tree_path() {
    if [ -s "$calls" ]; then printf '/repo.feature'; else return 1; fi
  }
  cb_tree_primary_path() { printf '/repo'; }
  cb_base_ref() { printf origin/main; }
  wt() { printf '%s\n' "$*" >> "$calls"; }

  assert_eq /repo.feature "$(cb_tree_create feature)"
  assert_contains "$(cat "$calls")" "switch --create feature --base origin/main --no-cd"
}

run_test "rejects an existing branch in the primary checkout" test_rejects_primary_checkout
run_test "reuses an existing linked worktree" test_reuses_linked_worktree
run_test "creates a missing worktree" test_creates_missing_worktree
finish_tests
