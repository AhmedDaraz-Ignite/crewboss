# shellcheck shell=bash
# naming: task text in, crew name + branch out. Branch convention: {prefix}-{TICKET}-description
# where TICKET is any Jira-style key (ABC-123) found in the task text.
CB_PREFIX=${CB_PREFIX:-$(git config user.name 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//')}
CB_PREFIX=${CB_PREFIX:-crew}

cb_ticket() {
  printf '%s' "$1" | grep -oiE '[A-Za-z][A-Za-z0-9]+-[0-9]+' | head -1 | tr '[:lower:]' '[:upper:]'
}

cb_slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[a-z][a-z0-9]+-[0-9]+//g; s/[^a-z0-9]+/ /g' \
    | awk '{ for (i = 1; i <= NF && i <= 4; i++) printf "%s%s", (i > 1 ? "-" : ""), $i }'
}

cb_branch() {
  if [ -n "${2:-}" ]; then printf '%s' "$2"; return; fi
  local ticket slug
  ticket=$(cb_ticket "$1")
  slug=$(cb_slug "$1")
  if [ -n "$ticket" ] && [ -n "$slug" ]; then printf '%s-%s-%s' "$CB_PREFIX" "$ticket" "$slug"
  elif [ -n "$ticket" ]; then printf '%s-%s' "$CB_PREFIX" "$ticket"
  elif [ -n "$slug" ]; then printf '%s-%s' "$CB_PREFIX" "$slug"
  else return 1; fi
}

cb_name() {
  local ticket
  ticket=$(cb_ticket "$1")
  if [ -n "$ticket" ]; then printf '%s' "$ticket"; else cb_slug "$1"; fi
}

cb_agent_target() {
  local target hash
  target=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  if [[ $target =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; then
    printf '%s' "$target"
    return
  fi

  hash=$(printf '%s' "$1" | git --git-dir=/dev/null/crewboss hash-object --stdin) || return 1
  printf 'crew-%.27s' "$hash"
}
