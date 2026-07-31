#!/bin/bash
set -u

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd "$TEST_ROOT/.." && pwd)
# shellcheck source=tests/test_helper.sh
source "$TEST_ROOT/test_helper.sh"
# shellcheck source=scripts/lib/naming.sh
source "$PROJECT_ROOT/scripts/lib/naming.sh"
# shellcheck source=scripts/lib/agent.sh
source "$PROJECT_ROOT/scripts/lib/agent.sh"

HERDR_LOG=$(mktemp)
PROMPT_DIGITS=$(mktemp)
HERDR_ENFORCE=
trap 'rm -f "$HERDR_LOG" "$PROMPT_DIGITS"' EXIT

sleep() {
  :
}

herdr() {
  if [ "$1" != agent ]; then
    return 2
  fi

  printf '%s %s\n' "$2" "$3" >> "$HERDR_LOG"
  if [ "$HERDR_ENFORCE" = "$2" ] && [ "$3" != smoke-100 ]; then
    return 64
  fi

  case $2 in
    start|prompt)
      if [ "$2" = prompt ]; then
        printf '%s' "$4" | sed -n 's/.*digits \([0-9][0-9]*\),.*/\1/p' > "$PROMPT_DIGITS"
      fi
      ;;
    read)
      if [ -s "$PROMPT_DIGITS" ]; then
        printf 'digits %s\n' "$(cat "$PROMPT_DIGITS")"
      else
        printf 'visible pane output\n'
      fi
      ;;
    explain)
      printf 'state: active\n'
      ;;
    *)
      return 2
      ;;
  esac
}

reset_agent_fake() {
  HERDR_ENFORCE=$1
  : > "$HERDR_LOG"
  : > "$PROMPT_DIGITS"
}

test_uppercase_public_name_maps_to_lowercase_target() {
  assert_eq smoke-100 "$(cb_agent_target SMOKE-100)"
}

test_valid_lowercase_target_is_unchanged() {
  assert_eq crew-a_1 "$(cb_agent_target crew-a_1)"
}

test_numeric_leading_name_uses_stable_bounded_hash_target() {
  local first second
  first=$(cb_agent_target 123)
  second=$(cb_agent_target 123)

  assert_eq "$first" "$second" || return 1
  [[ $first =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || return 1
  [ "${#first}" -le 32 ]
}

test_long_name_uses_stable_bounded_hash_target() {
  local name=this-name-is-far-too-long-for-herdr-agent-targets first second
  first=$(cb_agent_target "$name")
  second=$(cb_agent_target "$name")

  assert_eq "$first" "$second" || return 1
  [[ $first =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || return 1
  [ "${#first}" -le 32 ]
}

test_hash_target_is_stable_across_repository_object_formats() {
  local fixture sha1_target sha256_target
  fixture=$(mktemp -d)
  git init --quiet --object-format=sha1 "$fixture/sha1" || {
    rm -rf "$fixture"
    return 1
  }
  git init --quiet --object-format=sha256 "$fixture/sha256" || {
    rm -rf "$fixture"
    return 1
  }

  sha1_target=$(cd "$fixture/sha1" && cb_agent_target 123)
  sha256_target=$(cd "$fixture/sha256" && cb_agent_target 123)
  rm -rf "$fixture"

  assert_eq "$sha1_target" "$sha256_target" || return 1
  [[ $sha1_target =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || return 1
  [ "${#sha1_target}" -le 32 ]
}

test_start_uses_internal_target() {
  reset_agent_fake start

  cb_agent_start SMOKE-100 claude w1:p1 fresh

  assert_contains "$(cat "$HERDR_LOG")" "start smoke-100"
}

test_prompt_send_uses_internal_target() {
  reset_agent_fake prompt

  cb_agent_prompt SMOKE-100 "do the task" >/dev/null

  assert_contains "$(cat "$HERDR_LOG")" "prompt smoke-100"
}

test_prompt_confirmation_read_uses_internal_target() {
  reset_agent_fake read

  cb_agent_prompt SMOKE-100 "do the task" >/dev/null

  assert_contains "$(cat "$HERDR_LOG")" "read smoke-100"
}

test_general_read_uses_internal_target() {
  reset_agent_fake read

  local output
  output=$(cb_agent_read SMOKE-100 20)

  assert_eq "visible pane output" "$output" || return 1
  assert_eq "read smoke-100" "$(cat "$HERDR_LOG")"
}

test_state_uses_internal_target() {
  reset_agent_fake explain

  local state
  state=$(cb_agent_state SMOKE-100)

  assert_eq active "$state" || return 1
  assert_eq "explain smoke-100" "$(cat "$HERDR_LOG")"
}

test_focus_uses_internal_target_and_public_registry_key() {
  local fixture bin state log output status
  fixture=$(mktemp -d)
  bin="$fixture/bin"
  state="$fixture/state"
  log="$fixture/herdr.log"
  mkdir -p "$bin" "$state"
  : > "$log"
  jq -n '{
    "SMOKE-100": {
      branch: "feature",
      path: "/tmp/tree",
      pane: "w1:p1",
      agent: "claude",
      placement: "tab",
      token: "",
      status: "open"
    }
  }' > "$state/crew.json"

  cat > "$bin/herdr" <<'HERDR'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_LOG"
[ "$1 $2 $3" = "agent focus smoke-100" ]
HERDR
  chmod +x "$bin/herdr"

  output=$(PATH="$bin:$PATH" CB_STATE_DIR="$state" TEST_LOG="$log" \
    "$PROJECT_ROOT/scripts/crewboss" focus SMOKE-100 2>&1)
  status=$?

  assert_eq 0 "$status" || { rm -rf "$fixture"; return 1; }
  assert_eq '' "$output" || { rm -rf "$fixture"; return 1; }
  assert_eq "agent focus smoke-100" "$(cat "$log")" || {
    rm -rf "$fixture"
    return 1
  }
  jq -e 'has("SMOKE-100") and (has("smoke-100") | not)' \
    "$state/crew.json" >/dev/null || {
      rm -rf "$fixture"
      return 1
    }
  rm -rf "$fixture"
}

run_test "maps an uppercase public name to a lowercase Herdr target" test_uppercase_public_name_maps_to_lowercase_target
run_test "keeps an already-valid lowercase Herdr target" test_valid_lowercase_target_is_unchanged
run_test "uses a stable bounded hash target for a numeric-leading name" test_numeric_leading_name_uses_stable_bounded_hash_target
run_test "uses a stable bounded hash target for a long name" test_long_name_uses_stable_bounded_hash_target
run_test "keeps hash targets stable across repository object formats" test_hash_target_is_stable_across_repository_object_formats
run_test "starts an agent with the internal target" test_start_uses_internal_target
run_test "prompts an agent with the internal target" test_prompt_send_uses_internal_target
run_test "confirms a prompt with the internal target" test_prompt_confirmation_read_uses_internal_target
run_test "reads an agent with the internal target" test_general_read_uses_internal_target
run_test "explains an agent with the internal target" test_state_uses_internal_target
run_test "focuses the internal target through the public registry key" test_focus_uses_internal_target_and_public_registry_key
finish_tests
