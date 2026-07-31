# shellcheck shell=bash
# pane: where the crew session lives in herdr. The pane id path differs per command shape:
# tab create and worktree open return .result.root_pane, pane split returns .result.pane.

cb_pane_create() {
  local placement=$1 cwd=$2 label=$3
  case $placement in
    tab)
      [ -n "${HERDR_WORKSPACE_ID:-}" ] || { echo "crewboss: run inside herdr (HERDR_WORKSPACE_ID unset)" >&2; return 1; }
      herdr tab create --workspace "$HERDR_WORKSPACE_ID" --cwd "$cwd" --label "$label" --no-focus \
        | jq -er '.result.root_pane.pane_id' ;;
    space)
      herdr worktree open --path "$cwd" --label "$label" --no-focus \
        | jq -er '.result.root_pane.pane_id' ;;
    split)
      [ -n "${HERDR_PANE_ID:-}" ] || { echo "crewboss: run inside herdr (HERDR_PANE_ID unset)" >&2; return 1; }
      herdr pane split --pane "$HERDR_PANE_ID" --direction right --cwd "$cwd" --no-focus \
        | jq -er '.result.pane.pane_id' ;;
    *)
      echo "crewboss: placement must be tab, space, or split" >&2; return 2 ;;
  esac
}

cb_pane_status() {
  local pane=$1 name=$2 response status live code target
  target=$(cb_agent_target "$name") || {
    printf 'unknown\n'
    return 0
  }
  response=$(herdr agent get "$target" 2>&1)
  status=$?

  if [ "$status" -ne 0 ]; then
    code=$(printf '%s' "$response" | jq -ers '
      select(length == 1) | .[0].error.code |
      select(type == "string" and length > 0)
    ') || code=
    if [ "$code" = agent_not_found ]; then
      printf 'closed\n'
    else
      printf 'unknown\n'
    fi
    return 0
  fi

  live=$(printf '%s' "$response" | jq -ers '
    select(length == 1) | .[0].result.agent.pane_id |
    select(type == "string" and length > 0)
  ') || live=
  if [ -n "$live" ] && [ "$live" = "$pane" ]; then
    printf 'open\n'
  else
    printf 'unknown\n'
  fi
}

cb_pane_close() {
  local pane=$1 name=$2 response status live code target
  target=$(cb_agent_target "$name") || return 1
  response=$(herdr agent get "$target" 2>&1)
  status=$?

  if [ "$status" -ne 0 ]; then
    code=$(printf '%s' "$response" | jq -ers '
      select(length == 1) | .[0].error.code |
      select(type == "string" and length > 0)
    ') || code=
    if [ "$code" = agent_not_found ]; then
      return 0
    fi
    printf '%s\n' "$response" >&2
    return 1
  fi

  live=$(printf '%s' "$response" | jq -ers '
    select(length == 1) | .[0].result.agent.pane_id |
    select(type == "string" and length > 0)
  ') || {
    echo "crewboss: could not verify the pane for '$name'" >&2
    return 1
  }
  [ "$live" = "$pane" ] || {
    echo "crewboss: '$name' now lives in $live, not $pane - refusing to close" >&2
    return 1
  }
  herdr pane close "$pane" >/dev/null
}
