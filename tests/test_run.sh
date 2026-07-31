#!/bin/bash
set -u

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd "$TEST_ROOT/.." && pwd)
# shellcheck source=tests/test_helper.sh
source "$TEST_ROOT/test_helper.sh"

make_runner_fixture() {
  RUNNER_FIXTURE=$(mktemp -d)
  mkdir -p "$RUNNER_FIXTURE/tests" "$RUNNER_FIXTURE/scripts/lib"
  cp "$PROJECT_ROOT/tests/run" "$RUNNER_FIXTURE/tests/run"
  printf '#!/bin/bash\nexit 0\n' > "$RUNNER_FIXTURE/tests/test_pass.sh"
  printf '#!/bin/bash\nexit 0\n' > "$RUNNER_FIXTURE/scripts/crewboss"
  printf '# shellcheck shell=bash\n' > "$RUNNER_FIXTURE/scripts/lib/test.sh"
  chmod +x "$RUNNER_FIXTURE/tests/run" "$RUNNER_FIXTURE/tests/test_pass.sh" "$RUNNER_FIXTURE/scripts/crewboss"
}

run_fixture() {
  PATH="$RUNNER_FIXTURE/bin:$PATH" /bin/bash "$RUNNER_FIXTURE/tests/run"
}

test_syntax_gate_failure_fails_runner() {
  make_runner_fixture
  mkdir "$RUNNER_FIXTURE/bin"
  printf '%s\n' '#!/bin/bash' "if [ \"\$1\" = \"-n\" ]; then exit 42; fi" "exec /bin/bash \"\$@\"" > "$RUNNER_FIXTURE/bin/bash"
  chmod +x "$RUNNER_FIXTURE/bin/bash"

  local status
  run_fixture >/dev/null 2>&1
  status=$?
  rm -rf "$RUNNER_FIXTURE"

  assert_eq 42 "$status"
}

test_help_gate_failure_fails_runner() {
  make_runner_fixture
  mkdir "$RUNNER_FIXTURE/bin"
  printf '#!/bin/bash\nexit 43\n' > "$RUNNER_FIXTURE/scripts/crewboss"
  chmod +x "$RUNNER_FIXTURE/scripts/crewboss"

  local status
  run_fixture >/dev/null 2>&1
  status=$?
  rm -rf "$RUNNER_FIXTURE"

  assert_eq 43 "$status"
}

run_test "fails when the syntax gate fails" test_syntax_gate_failure_fails_runner
run_test "fails when the help gate fails" test_help_gate_failure_fails_runner
finish_tests
