#!/bin/bash
set -u

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/test_helper.sh
source "$TEST_ROOT/test_helper.sh"
# shellcheck source=scripts/lib/tree.sh
source "$TEST_ROOT/../scripts/lib/tree.sh"

test_rejects_primary_checkout() {
  # These fakes are invoked indirectly by cb_tree_create from the sourced library.
  # shellcheck disable=SC2329
  cb_tree_path() { printf '/repo'; }
  # shellcheck disable=SC2329
  cb_tree_primary_path() { printf '/repo'; }
  # shellcheck disable=SC2329
  wt() { printf 'wt must not run\n' >&2; return 99; }

  local output status
  output=$(cb_tree_create feature 2>&1)
  status=$?

  assert_eq 1 "$status"
  assert_contains "$output" "checked out in the primary repo"
}

test_reuses_linked_worktree() {
  # These fakes are invoked indirectly by cb_tree_create from the sourced library.
  # shellcheck disable=SC2329
  cb_tree_path() { printf '/repo.feature'; }
  # shellcheck disable=SC2329
  cb_tree_primary_path() { printf '/repo'; }
  # shellcheck disable=SC2329
  wt() { printf 'wt must not run\n' >&2; return 99; }

  assert_eq /repo.feature "$(cb_tree_create feature)"
}

test_creates_missing_worktree() {
  local calls
  calls=$(mktemp)
  trap 'rm -f "$calls"' RETURN
  # These fakes are invoked indirectly by cb_tree_create from the sourced library.
  # shellcheck disable=SC2329
  cb_tree_path() {
    if [ -s "$calls" ]; then printf '/repo.feature'; else return 1; fi
  }
  # shellcheck disable=SC2329
  cb_tree_primary_path() { printf '/repo'; }
  # shellcheck disable=SC2329
  cb_base_ref() { printf origin/main; }
  # shellcheck disable=SC2329
  wt() { printf '%s\n' "$*" >> "$calls"; }

  assert_eq /repo.feature "$(cb_tree_create feature)"
  assert_contains "$(cat "$calls")" "switch --create feature --base origin/main --no-cd"
}

run_test "rejects an existing branch in the primary checkout" test_rejects_primary_checkout
run_test "reuses an existing linked worktree" test_reuses_linked_worktree
run_test "creates a missing worktree" test_creates_missing_worktree
finish_tests
