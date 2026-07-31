# shellcheck shell=bash
# registry: one JSON file mapping crew name to branch, path, pane, agent kind, placement,
# pending sentinel token, and open/closed status. This is what makes close and reopen possible.
CB_STATE_DIR=${CB_STATE_DIR:-"$HOME/.local/state/crewboss"}
CB_REG="$CB_STATE_DIR/crew.json"

cb_reg_init() {
  mkdir -p "$CB_STATE_DIR"
  [ -f "$CB_REG" ] || echo '{}' > "$CB_REG"
}

cb_reg_put() {
  cb_reg_init
  local tmp
  tmp=$(mktemp) || return 1
  jq --arg n "$1" --argjson v "$2" '.[$n] = ((.[$n] // {}) + $v)' "$CB_REG" > "$tmp" && mv "$tmp" "$CB_REG"
}

cb_reg_get() {
  cb_reg_init
  jq -er --arg n "$1" '.[$n] // empty' "$CB_REG"
}

cb_reg_field() {
  cb_reg_get "$1" | jq -r --arg f "$2" '.[$f] // empty'
}

cb_reg_del() {
  cb_reg_init
  local tmp
  tmp=$(mktemp) || return 1
  jq --arg n "$1" 'del(.[$n])' "$CB_REG" > "$tmp" && mv "$tmp" "$CB_REG"
}

cb_reg_names() {
  cb_reg_init
  jq -r 'keys[]' "$CB_REG"
}
