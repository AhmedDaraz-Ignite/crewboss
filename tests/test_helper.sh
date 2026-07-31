#!/bin/bash
set -u

TEST_COUNT=0
TEST_FAILURES=0

assert_eq() {
  local expected=$1 actual=$2
  [ "$expected" = "$actual" ] || {
    printf 'expected: %s\nactual:   %s\n' "$expected" "$actual" >&2
    return 1
  }
}

assert_contains() {
  local haystack=$1 needle=$2
  case $haystack in
    *"$needle"*) ;;
    *) printf 'missing text: %s\n' "$needle" >&2; return 1 ;;
  esac
}

assert_not_contains() {
  local haystack=$1 needle=$2
  case $haystack in
    *"$needle"*) printf 'unexpected text: %s\n' "$needle" >&2; return 1 ;;
    *) ;;
  esac
}

run_test() {
  local name=$1
  shift
  TEST_COUNT=$((TEST_COUNT + 1))
  if ( "$@" ); then
    printf 'ok %d - %s\n' "$TEST_COUNT" "$name"
  else
    printf 'not ok %d - %s\n' "$TEST_COUNT" "$name"
    TEST_FAILURES=$((TEST_FAILURES + 1))
  fi
}

finish_tests() {
  [ "$TEST_FAILURES" -eq 0 ] || {
    printf '%d of %d tests failed\n' "$TEST_FAILURES" "$TEST_COUNT" >&2
    exit 1
  }
  printf '%d tests passed\n' "$TEST_COUNT"
}
