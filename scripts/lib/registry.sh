# shellcheck shell=bash
# registry: one JSON file mapping crew name to branch, path, pane, agent kind, placement,
# pending sentinel token, and open/closed status. This is what makes close and reopen possible.
CB_STATE_DIR=${CB_STATE_DIR:-"$HOME/.local/state/crewboss"}
CB_REG="$CB_STATE_DIR/crew.json"
CB_REG_LOCK="$CB_STATE_DIR/crew.lock"

cb_lock_acquire() {
  local lock=$1 owner current_owner pid=${BASHPID:-$$}
  while :; do
    if mkdir "$lock" 2>/dev/null; then
      if printf '%s\n' "$pid" > "$lock/pid" 2>/dev/null && chmod 700 "$lock"; then
        return 0
      fi
      return 1
    fi

    owner=
    if [ -f "$lock/pid" ]; then
      IFS= read -r owner 2>/dev/null < "$lock/pid" || owner=
      if [[ $owner =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
        current_owner=
        IFS= read -r current_owner 2>/dev/null < "$lock/pid" || current_owner=
        if [ "$current_owner" = "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
          rm -rf "$lock"
        fi
      fi
    fi
    sleep 0.01
  done
}

cb_lock_release() {
  rm -rf "$1"
}

cb_reg_init() {
  mkdir -p "$CB_STATE_DIR" || return 1
  cb_lock_acquire "$CB_REG_LOCK" || return 1

  local tmp status=0
  if [ ! -f "$CB_REG" ]; then
    tmp=$(mktemp "$CB_STATE_DIR/.crew.json.XXXXXX") || status=1
    if [ "$status" -eq 0 ]; then
      printf '{}\n' > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$CB_REG" || status=1
    fi
    [ -z "${tmp:-}" ] || [ ! -f "$tmp" ] || rm -f "$tmp"
  fi

  cb_lock_release "$CB_REG_LOCK"
  return "$status"
}

cb_id_new() {
  printf '%s-%s-%s-%s\n' "$1" "${BASHPID:-$$}" "$RANDOM" "$RANDOM"
}

cb_reg_put() {
  cb_reg_init || return 1
  cb_lock_acquire "$CB_REG_LOCK" || return 1

  local tmp status=0
  tmp=$(mktemp "$CB_STATE_DIR/.crew.json.XXXXXX") || status=1
  if [ "$status" -eq 0 ]; then
    jq --arg n "$1" --argjson v "$2" '.[$n] = ((.[$n] // {}) + $v)' \
      "$CB_REG" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$CB_REG" || status=1
  fi
  [ -z "${tmp:-}" ] || [ ! -f "$tmp" ] || rm -f "$tmp"
  cb_lock_release "$CB_REG_LOCK"
  return "$status"
}

cb_reg_replace() {
  cb_reg_init || return 1
  cb_lock_acquire "$CB_REG_LOCK" || return 1

  local tmp status=0
  tmp=$(mktemp "$CB_STATE_DIR/.crew.json.XXXXXX") || status=1
  if [ "$status" -eq 0 ]; then
    jq --arg n "$1" --argjson v "$2" '.[$n] = $v' "$CB_REG" > "$tmp" &&
      chmod 600 "$tmp" && mv "$tmp" "$CB_REG" || status=1
  fi
  [ -z "${tmp:-}" ] || [ ! -f "$tmp" ] || rm -f "$tmp"
  cb_lock_release "$CB_REG_LOCK"
  return "$status"
}

cb_reg_get() {
  cb_reg_init || return 1
  jq -er --arg n "$1" '.[$n] // empty' "$CB_REG"
}

cb_reg_field() {
  cb_reg_get "$1" | jq -r --arg f "$2" '.[$f] // empty'
}

cb_reg_del() {
  cb_reg_init || return 1
  cb_lock_acquire "$CB_REG_LOCK" || return 1

  local tmp status=0
  tmp=$(mktemp "$CB_STATE_DIR/.crew.json.XXXXXX") || status=1
  if [ "$status" -eq 0 ]; then
    jq --arg n "$1" 'del(.[$n])' "$CB_REG" > "$tmp" && chmod 600 "$tmp" &&
      mv "$tmp" "$CB_REG" || status=1
  fi
  [ -z "${tmp:-}" ] || [ ! -f "$tmp" ] || rm -f "$tmp"
  cb_lock_release "$CB_REG_LOCK"
  return "$status"
}

cb_reg_names() {
  cb_reg_init || return 1
  jq -r 'keys[]' "$CB_REG"
}

cb_reg_identity_matches() {
  cb_reg_init || return 1
  jq -e 'type == "object"' "$CB_REG" >/dev/null || return 1
  jq -e --arg n "$1" 'has($n)' "$CB_REG" >/dev/null || return 2
  jq -e --arg n "$1" --arg crew_id "$2" --arg run_id "$3" \
    '.[$n].crew_id == $crew_id and .[$n].run_id == $run_id' "$CB_REG" >/dev/null || return 2
}

cb_reg_apply_event() {
  local event crew crew_id run_id current tmp status=0
  event=$(jq -ce 'select(
    type == "object" and
    (.crew | type == "string" and length > 0) and
    (.crew_id | type == "string" and length > 0) and
    (.run_id | type == "string" and length > 0) and
    (.seq | type == "number" and floor == .) and
    (.kind == "blocked" or .kind == "done") and
    (.payload | type == "string")
  )' <<< "$1") || return 1

  crew=$(jq -r '.crew' <<< "$event")
  crew_id=$(jq -r '.crew_id' <<< "$event")
  run_id=$(jq -r '.run_id' <<< "$event")

  cb_reg_init || return 1
  cb_lock_acquire "$CB_REG_LOCK" || return 1
  jq -e 'type == "object"' "$CB_REG" >/dev/null || status=1
  if [ "$status" -eq 0 ]; then
    current=$(jq -cer --arg n "$crew" '.[$n] // empty' "$CB_REG") || status=2
  fi
  if [ "$status" -eq 0 ]; then
    jq -e --arg crew_id "$crew_id" --arg run_id "$run_id" \
      '.crew_id == $crew_id and .run_id == $run_id' <<< "$current" >/dev/null || status=2
  fi
  if [ "$status" -eq 0 ]; then
    tmp=$(mktemp "$CB_STATE_DIR/.crew.json.XXXXXX") || status=1
  fi
  if [ "$status" -eq 0 ]; then
    jq --arg n "$crew" --argjson event "$event" '
      .[$n] as $record |
      if (($record.last_event_seq? | type) == "number" and $record.last_event_seq >= $event.seq) then .
      else .[$n] = ($record + {
        task_status: $event.kind,
        blocked: ($event.kind == "blocked"),
        message: $event.payload,
        last_event_seq: $event.seq
      }) end
    ' "$CB_REG" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$CB_REG" || status=1
  fi
  [ -z "${tmp:-}" ] || [ ! -f "$tmp" ] || rm -f "$tmp"
  cb_lock_release "$CB_REG_LOCK"
  return "$status"
}

cb_reg_set_endpoint() {
  case $2 in
    open|closed|unknown) ;;
    *) return 1 ;;
  esac
  cb_reg_put "$1" "$(jq -n --arg state "$2" '{endpoint_state: $state}')"
}
