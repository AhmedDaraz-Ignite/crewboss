# shellcheck shell=bash
# agent: start, prompt, wait, read. All timeouts are internal - the interface never asks for one.
CB_START_TIMEOUT_MS=120000   # startup readiness budget passed to herdr agent start
CB_TASK_TIMEOUT_MS=1800000   # how long `crewboss wait` blocks for one task (30 min)

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
  local name=$1 kind=$2 pane=$3 mode=${4:-fresh} extra out tries=0
  extra=$(cb_agent_args "$kind" "$mode")
  while :; do
    # shellcheck disable=SC2086
    out=$(herdr agent start "$name" --kind "$kind" --pane "$pane" --timeout "$CB_START_TIMEOUT_MS" \
      ${extra:+-- $extra} 2>&1) && return 0
    if printf '%s' "$out" | grep -q agent_pane_busy && [ $((tries += 1)) -lt 15 ]; then
      sleep 1; continue
    fi
    printf '%s\n' "$out" >&2
    return 1
  done
}

# Sends the task plus a completion sentinel. The token word and digits are split in the prompt
# text so the echoed instruction cannot match the joined regex that wait looks for.
# A freshly started agent can silently swallow the first prompt, so confirm the text
# actually echoed in the pane and resend if it did not.
cb_agent_prompt() {
  local name=$1 task=$2 tok=TASKDONE num=$RANDOM tries=0
  while :; do
    herdr agent prompt "$name" "$task

When you are completely finished, print on its own final line the word $tok followed immediately by the digits $num, with no space between them." >/dev/null || return 1
    sleep 2
    if herdr agent read "$name" --source recent-unwrapped --lines 120 2>/dev/null \
        | grep -q "digits $num"; then
      printf '%s%s' "$tok" "$num"
      return 0
    fi
    if [ $((tries += 1)) -ge 5 ]; then
      echo "crewboss: prompt never appeared in $name's pane" >&2
      return 1
    fi
    sleep 2
  done
}

cb_agent_wait() {
  herdr pane wait-output "$1" --regex "$2" --source recent --timeout "$CB_TASK_TIMEOUT_MS" >/dev/null
}

# A read is a screen snapshot, not a transcript - read generously.
cb_agent_read() {
  herdr agent read "$1" --source recent-unwrapped --lines "${2:-200}"
}

cb_agent_state() {
  herdr agent explain "$1" 2>/dev/null | sed -n 's/^state: //p'
}
