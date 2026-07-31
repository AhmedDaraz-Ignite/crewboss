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

cb_pane_close() {
  local pane=$1 name=$2 response status live
  response=$(herdr agent get "$name" 2>&1)
  status=$?

  if [ "$status" -ne 0 ]; then
    if printf '%s' "$response" |
        jq -e '.error.code == "agent_not_found"' >/dev/null 2>&1; then
      return 0
    fi
    printf '%s\n' "$response" >&2
    return 1
  fi

  live=$(printf '%s' "$response" | jq -er '.result.agent.pane_id') || {
    echo "crewboss: could not verify the pane for '$name'" >&2
    return 1
  }
  [ "$live" = "$pane" ] || {
    echo "crewboss: '$name' now lives in $live, not $pane - refusing to close" >&2
    return 1
  }
  herdr pane close "$pane" >/dev/null
}
