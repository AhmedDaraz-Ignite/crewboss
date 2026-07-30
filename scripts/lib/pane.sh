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
  herdr pane close "$1" >/dev/null
}
