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
PROMPT_TEXT=$(mktemp)
PROMPT_ATTEMPTS=$(mktemp)
HERDR_ENFORCE=
HERDR_START_BUSY_COUNT=0
PROMPT_VISIBLE_AFTER=1
PROMPT_READ_MODE=marker
trap 'rm -f "$HERDR_LOG" "$PROMPT_TEXT" "$PROMPT_ATTEMPTS"' EXIT

sleep() {
  :
}

herdr() {
  local attempts=0
  if [ "$1" != agent ]; then
    return 2
  fi

  printf '%s %s\n' "$2" "$3" >> "$HERDR_LOG"
  if [ "$HERDR_ENFORCE" = "$2" ] && [ "$3" != smoke-100 ]; then
    return 64
  fi

  case $2 in
    start|prompt)
      if [ "$2" = start ]; then
        attempts=$(grep -c '^start ' "$HERDR_LOG")
        if [ "$attempts" -le "$HERDR_START_BUSY_COUNT" ]; then
          printf 'agent_pane_busy\n' >&2
          return 1
        fi
      else
        printf '%s\n' "$4" > "$PROMPT_TEXT"
        IFS= read -r attempts < "$PROMPT_ATTEMPTS" || attempts=0
        printf '%s\n' $((attempts + 1)) > "$PROMPT_ATTEMPTS"
      fi
      ;;
    read)
      IFS= read -r attempts < "$PROMPT_ATTEMPTS" || attempts=0
      if [ "$attempts" -ge "$PROMPT_VISIBLE_AFTER" ]; then
        case $PROMPT_READ_MODE in
          marker) sed -n '/^CrewBoss run id: /p' "$PROMPT_TEXT" ;;
          tail) tail -n 1 "$PROMPT_TEXT" ;;
          *) return 2 ;;
        esac
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
  HERDR_START_BUSY_COUNT=0
  PROMPT_VISIBLE_AFTER=1
  PROMPT_READ_MODE=marker
  : > "$HERDR_LOG"
  : > "$PROMPT_TEXT"
  printf '0\n' > "$PROMPT_ATTEMPTS"
}

extract_prompt_example() {
  local prompt=$1 kind=$2 line prefix opener collecting=0 saw_emit=0 output=''
  case $kind in
    blocked) prefix=CREWBOSS_BLOCKED_PAYLOAD_ ;;
    done) prefix=CREWBOSS_DONE_PAYLOAD_ ;;
    *) return 1 ;;
  esac
  opener="CREWBOSS_EVENT_PAYLOAD=\"\$(cat <<'$prefix"
  while IFS= read -r line; do
    if [ "$collecting" -eq 0 ]; then
      case $line in
        "$opener"*) collecting=1 ;;
        *) continue ;;
      esac
    fi
    output="$output${output:+$'\n'}$line"
    case $line in
      *" $kind \"\$CREWBOSS_EVENT_PAYLOAD\"") saw_emit=1 ;;
    esac
    if [ "$saw_emit" -eq 1 ] && [ "$line" = 'unset CREWBOSS_EVENT_PAYLOAD' ]; then
      printf '%s' "$output"
      return 0
    fi
  done <<< "$prompt"
  return 1
}

replace_prompt_payload() {
  local example=$1 placeholder=$2 payload=$3 line found=0
  while IFS= read -r line; do
    if [ "$line" = "$placeholder" ]; then
      printf '%s\n' "$payload"
      found=1
    else
      printf '%s\n' "$line"
    fi
  done <<< "$example"
  [ "$found" -eq 1 ]
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

test_start_retries_busy_pane_through_the_fifteenth_attempt() {
  reset_agent_fake start
  HERDR_START_BUSY_COUNT=14

  cb_agent_start SMOKE-100 claude w1:p1 fresh || return 1

  assert_eq 15 "$(grep -c '^start ' "$HERDR_LOG")"
}

test_prompt_send_uses_internal_target() {
  reset_agent_fake prompt

  cb_agent_prompt SMOKE-100 "do the task" crew-123 run-456 \
    /tmp/crewboss /tmp/state >/dev/null || return 1

  assert_contains "$(cat "$HERDR_LOG")" "prompt smoke-100"
}

test_prompt_confirmation_read_uses_internal_target() {
  reset_agent_fake read

  cb_agent_prompt SMOKE-100 "do the task" crew-123 run-456 \
    /tmp/crewboss /tmp/state >/dev/null || return 1

  assert_contains "$(cat "$HERDR_LOG")" "read smoke-100"
}

test_prompt_teaches_the_shell_safe_event_protocol() {
  reset_agent_fake prompt
  local output prompt

  output=$(cb_agent_prompt SMOKE-100 "do the exact task" crew-123 run-456 \
    "/tmp/CrewBoss tool's/bin/crewboss" "/tmp/state dir's") || return 1
  prompt=$(cat "$PROMPT_TEXT")

  assert_eq '' "$output" || return 1
  assert_contains "$prompt" "do the exact task" || return 1
  assert_contains "$prompt" "CrewBoss run id: run-456" || return 1
  assert_eq 1 "$(grep -Fc 'CrewBoss run id: run-456' <<< "$prompt")" || return 1
  assert_eq "CrewBoss run id: run-456" "$(tail -n 1 <<< "$prompt")" || return 1
  assert_contains "$prompt" \
    "CREWBOSS_EVENT_PAYLOAD=\"\$(cat <<'CREWBOSS_BLOCKED_PAYLOAD_" || return 1
  assert_contains "$prompt" \
    "CREWBOSS_EVENT_PAYLOAD=\"\$(cat <<'CREWBOSS_DONE_PAYLOAD_" || return 1
  assert_contains "$prompt" "printf '%s' 'CREWBOSS_PAYLOAD_SUFFIX_" || return 1
  assert_contains "$prompt" \
    "CREWBOSS_EVENT_PAYLOAD=\${CREWBOSS_EVENT_PAYLOAD%CREWBOSS_PAYLOAD_SUFFIX_" || return 1
  assert_contains "$prompt" \
    "CREWBOSS_EVENT_PAYLOAD=\${CREWBOSS_EVENT_PAYLOAD%\$'\\n'}" || return 1
  assert_contains "$prompt" \
    "CB_STATE_DIR=/tmp/state\\ dir\\'s /tmp/CrewBoss\\ tool\\'s/bin/crewboss emit SMOKE-100 crew-123 run-456 blocked \"\$CREWBOSS_EVENT_PAYLOAD\"" || return 1
  assert_contains "$prompt" \
    "CB_STATE_DIR=/tmp/state\\ dir\\'s /tmp/CrewBoss\\ tool\\'s/bin/crewboss emit SMOKE-100 crew-123 run-456 done \"\$CREWBOSS_EVENT_PAYLOAD\"" || return 1
  assert_contains "$prompt" "Put the exact message between the opening and closing delimiter" || return 1
  assert_contains "$prompt" "the exact question" || return 1
  assert_contains "$prompt" "the final answer" || return 1
  assert_contains "$prompt" "emit the exact question before waiting" || return 1
  assert_contains "$prompt" "emit the final answer before ending" || return 1
  assert_not_contains "$prompt" TASKDONE
}

test_prompt_event_examples_execute_with_hostile_values() {
  reset_agent_fake prompt
  HERDR_ENFORCE=
  local fixture tool_dir tool state log name crew_id run_id prompt blocked_example done_example
  local blocked_payload done_payload blocked_command done_command
  fixture=$(mktemp -d)
  trap 'rm -rf "$fixture"' RETURN
  tool_dir="$fixture/CrewBoss tool's \$(touch $fixture/tool-injected)"
  tool="$tool_dir/crewboss"
  state="$fixture/state dir's \$(touch $fixture/state-injected)"
  log="$fixture/events.jsonl"
  name="Crew name's \$(touch $fixture/name-injected)"
  crew_id="crew id's \$(touch $fixture/crew-injected)"
  run_id="run id's \$(touch $fixture/run-injected)"
  mkdir -p "$tool_dir" "$state"
  cat > "$tool" <<'TOOL'
#!/bin/bash
jq -cn --arg state "$CB_STATE_DIR" --args \
  '{state: $state, args: $ARGS.positional}' -- "$@" >> "$EVENT_LOG"
TOOL
  chmod +x "$tool"

  cb_agent_prompt "$name" "do the exact task" "$crew_id" "$run_id" \
    "$tool" "$state" >/dev/null || return 1
  prompt=$(cat "$PROMPT_TEXT")
  blocked_example=$(extract_prompt_example "$prompt" blocked) || return 1
  done_example=$(extract_prompt_example "$prompt" "done") || return 1
  blocked_payload="question with 'single' and \"double\"; \$(touch $fixture/payload-dollar) \`touch $fixture/payload-backtick\` and \\\\slashes"
  done_payload="answer; touch $fixture/payload-semicolon
second line with \$(touch $fixture/payload-second) and \\backslash"
  blocked_command=$(replace_prompt_payload "$blocked_example" \
    "the exact question" "$blocked_payload") || return 1
  done_command=$(replace_prompt_payload "$done_example" \
    "the final answer" "$done_payload") || return 1

  EVENT_LOG="$log" /bin/bash -c "$blocked_command" || return 1
  EVENT_LOG="$log" /bin/bash -c "$done_command" || return 1

  jq -s -e --arg state "$state" --arg name "$name" --arg crew_id "$crew_id" \
    --arg run_id "$run_id" --arg blocked "$blocked_payload" \
    --arg completed "$done_payload" '
      length == 2 and
      .[0] == {state: $state,
        args: ["emit", $name, $crew_id, $run_id, "blocked", $blocked]} and
      .[1] == {state: $state,
        args: ["emit", $name, $crew_id, $run_id, "done", $completed]}
    ' "$log" >/dev/null || return 1
  [ ! -e "$fixture/tool-injected" ] || return 1
  [ ! -e "$fixture/state-injected" ] || return 1
  [ ! -e "$fixture/name-injected" ] || return 1
  [ ! -e "$fixture/crew-injected" ] || return 1
  [ ! -e "$fixture/run-injected" ] || return 1
  [ ! -e "$fixture/payload-dollar" ] || return 1
  [ ! -e "$fixture/payload-backtick" ] || return 1
  [ ! -e "$fixture/payload-semicolon" ] || return 1
  [ ! -e "$fixture/payload-second" ]
}

test_prompt_event_examples_preserve_trailing_newlines() {
  reset_agent_fake prompt
  local fixture tool log prompt example command zero one multiple
  fixture=$(mktemp -d)
  trap 'rm -rf "$fixture"' RETURN
  tool="$fixture/crewboss"
  log="$fixture/events.jsonl"
  cat > "$tool" <<'TOOL'
#!/bin/bash
jq -cn --args '{args: $ARGS.positional}' -- "$@" >> "$EVENT_LOG"
TOOL
  chmod +x "$tool"

  cb_agent_prompt SMOKE-100 "do the exact task" crew-123 run-456 \
    "$tool" "$fixture/state" >/dev/null || return 1
  prompt=$(cat "$PROMPT_TEXT")
  example=$(extract_prompt_example "$prompt" blocked) || return 1
  zero='zero trailing newlines'
  one=$'one trailing newline\n'
  multiple=$'three trailing newlines\n\n\n'

  command=$(replace_prompt_payload "$example" "the exact question" "$zero") || return 1
  EVENT_LOG="$log" /bin/bash -c "$command" || return 1
  command=$(replace_prompt_payload "$example" "the exact question" "$one") || return 1
  EVENT_LOG="$log" /bin/bash -c "$command" || return 1
  command=$(replace_prompt_payload "$example" "the exact question" "$multiple") || return 1
  EVENT_LOG="$log" /bin/bash -c "$command" || return 1

  jq -s -e --arg zero "$zero" --arg one "$one" --arg multiple "$multiple" '
    length == 3 and
    .[0].args == ["emit","SMOKE-100","crew-123","run-456","blocked",$zero] and
    .[1].args == ["emit","SMOKE-100","crew-123","run-456","blocked",$one] and
    .[2].args == ["emit","SMOKE-100","crew-123","run-456","blocked",$multiple]
  ' "$log" >/dev/null
}

test_prompt_delivery_retries_until_the_fifth_attempt() {
  reset_agent_fake prompt
  PROMPT_VISIBLE_AFTER=5

  cb_agent_prompt SMOKE-100 "do the task" crew-123 run-456 \
    /tmp/crewboss /tmp/state >/dev/null || return 1

  assert_eq 5 "$(cat "$PROMPT_ATTEMPTS")"
}

test_prompt_delivery_is_confirmed_from_the_prompt_tail() {
  reset_agent_fake prompt
  PROMPT_READ_MODE='tail'

  cb_agent_prompt SMOKE-100 "do the task" crew-123 run-456 \
    /tmp/crewboss /tmp/state >/dev/null || return 1

  assert_eq 1 "$(cat "$PROMPT_ATTEMPTS")"
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
  trap 'rm -rf "$fixture"' RETURN
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

  assert_eq 0 "$status" || return 1
  assert_eq '' "$output" || return 1
  assert_eq "agent focus smoke-100" "$(cat "$log")" || return 1
  jq -e 'has("SMOKE-100") and (has("smoke-100") | not)' \
    "$state/crew.json" >/dev/null
}

run_test "maps an uppercase public name to a lowercase Herdr target" test_uppercase_public_name_maps_to_lowercase_target
run_test "keeps an already-valid lowercase Herdr target" test_valid_lowercase_target_is_unchanged
run_test "uses a stable bounded hash target for a numeric-leading name" test_numeric_leading_name_uses_stable_bounded_hash_target
run_test "uses a stable bounded hash target for a long name" test_long_name_uses_stable_bounded_hash_target
run_test "keeps hash targets stable across repository object formats" test_hash_target_is_stable_across_repository_object_formats
run_test "starts an agent with the internal target" test_start_uses_internal_target
run_test "retries a busy pane through the fifteenth start attempt" test_start_retries_busy_pane_through_the_fifteenth_attempt
run_test "prompts an agent with the internal target" test_prompt_send_uses_internal_target
run_test "confirms a prompt with the internal target" test_prompt_confirmation_read_uses_internal_target
run_test "teaches crews the shell-safe event protocol" test_prompt_teaches_the_shell_safe_event_protocol
run_test "keeps hostile values inert in executable event examples" test_prompt_event_examples_execute_with_hostile_values
run_test "preserves zero one and multiple trailing payload newlines" \
  test_prompt_event_examples_preserve_trailing_newlines
run_test "retries prompt delivery through the fifth attempt" test_prompt_delivery_retries_until_the_fifth_attempt
run_test "confirms delivered prompts from the pane tail on the first attempt" \
  test_prompt_delivery_is_confirmed_from_the_prompt_tail
run_test "reads an agent with the internal target" test_general_read_uses_internal_target
run_test "explains an agent with the internal target" test_state_uses_internal_target
run_test "focuses the internal target through the public registry key" test_focus_uses_internal_target_and_public_registry_key
finish_tests
