# shellcheck shell=bash
# agent: start, prompt, and read. All timeouts are internal - the interface never asks for one.
CB_START_TIMEOUT_MS=120000   # startup readiness budget passed to herdr agent start

# Per-agent extra args. resume must restore the previous conversation in the same worktree.
cb_agent_args() {
  case "$1:$2" in
    claude:fresh)  echo "--dangerously-skip-permissions" ;;
    claude:resume) echo "--continue --dangerously-skip-permissions" ;;
    codex:resume)  echo "resume --last" ;;   # unverified, needs a machine with codex installed
    *)             echo "" ;;
  esac
}

# A just-created pane reports agent_pane_busy until its shell finishes starting, so retry.
cb_agent_start() {
  local name=$1 kind=$2 pane=$3 mode=${4:-fresh} extra out target tries=0
  target=$(cb_agent_target "$name") || return 1
  extra=$(cb_agent_args "$kind" "$mode")
  while :; do
    # shellcheck disable=SC2086
    out=$(herdr agent start "$target" --kind "$kind" --pane "$pane" --timeout "$CB_START_TIMEOUT_MS" \
      ${extra:+-- $extra} 2>&1) && return 0
    if printf '%s' "$out" | grep -q agent_pane_busy && [ $((tries += 1)) -lt 15 ]; then
      sleep 1; continue
    fi
    printf '%s\n' "$out" >&2
    return 1
  done
}

# A freshly started agent can silently swallow the first prompt, so confirm the text
# actually echoed in the pane and resend if it did not.
_cb_agent_shell_quote() {
  printf '%q' "$1"
}

cb_agent_prompt() {
  local name=$1 task=$2 crew_id=$3 run_id=$4 tool_path=$5 state_dir=$6
  local target tries=0 marker prompt q_name q_crew_id q_run_id q_tool q_state
  target=$(cb_agent_target "$name") || return 1
  marker="CrewBoss run id: $run_id"
  q_name=$(_cb_agent_shell_quote "$name") || return 1
  q_crew_id=$(_cb_agent_shell_quote "$crew_id") || return 1
  q_run_id=$(_cb_agent_shell_quote "$run_id") || return 1
  q_tool=$(_cb_agent_shell_quote "$tool_path") || return 1
  q_state=$(_cb_agent_shell_quote "$state_dir") || return 1
  prompt="$task

$marker

Use CrewBoss events to report this run. When you need an answer, emit the exact question before waiting:
CB_STATE_DIR=$q_state $q_tool emit $q_name $q_crew_id $q_run_id blocked \"the exact question\"

When the work is complete, emit the final answer before ending:
CB_STATE_DIR=$q_state $q_tool emit $q_name $q_crew_id $q_run_id done \"the final answer\""

  while :; do
    herdr agent prompt "$target" "$prompt" >/dev/null || return 1
    sleep 2
    if herdr agent read "$target" --source recent-unwrapped --lines 120 2>/dev/null \
        | grep -Fq -- "$marker"; then
      return 0
    fi
    if [ $((tries += 1)) -ge 5 ]; then
      echo "crewboss: prompt never appeared in $name's pane" >&2
      return 1
    fi
    sleep 2
  done
}

# A read is a screen snapshot, not a transcript - read generously.
cb_agent_read() {
  local target
  target=$(cb_agent_target "$1") || return 1
  herdr agent read "$target" --source recent-unwrapped --lines "${2:-200}"
}

cb_agent_state() {
  local target
  target=$(cb_agent_target "$1") || return 1
  herdr agent explain "$target" 2>/dev/null | sed -n 's/^state: //p'
}
