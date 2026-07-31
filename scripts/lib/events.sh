# shellcheck shell=bash
# events: one append-only JSON Lines source shared by every crew.
CB_EVENT_SOURCE="$CB_STATE_DIR/events.jsonl"
CB_EVENT_LOCK="$CB_STATE_DIR/events.lock"

cb_event_init() {
  mkdir -p "$CB_STATE_DIR" || return 1
  cb_lock_acquire "$CB_EVENT_LOCK" || return 1

  local old_umask status=0
  if [ ! -e "$CB_EVENT_SOURCE" ]; then
    old_umask=$(umask) || status=1
    if [ "$status" -eq 0 ]; then
      umask 077
      : >> "$CB_EVENT_SOURCE" || status=1
      umask "$old_umask"
    fi
  elif [ ! -f "$CB_EVENT_SOURCE" ]; then
    status=1
  fi

  cb_lock_release "$CB_EVENT_LOCK" || status=1
  return "$status"
}

cb_event_emit() {
  local crew=$1 crew_id=$2 run_id=$3 kind=$4 payload=$5
  local last last_seq seq event event_time status=0

  [ -n "$crew" ] && [ -n "$crew_id" ] && [ -n "$run_id" ] || return 1
  case $kind in
    blocked|done) ;;
    *) return 1 ;;
  esac
  [ -n "$payload" ] || return 1
  cb_reg_identity_matches "$crew" "$crew_id" "$run_id" || return 1

  cb_event_init || return 1
  cb_lock_acquire "$CB_EVENT_LOCK" || return 1

  if [ -s "$CB_EVENT_SOURCE" ]; then
    last=$(tail -n 1 "$CB_EVENT_SOURCE") || status=1
    if [ "$status" -eq 0 ]; then
      jq -e '
        type == "object" and
        keys == ["crew","crew_id","event_id","kind","payload","run_id","seq","time","version"] and
        .version == 1 and
        (.seq | type == "number") and
        (.seq | floor == . and . > 0) and
        .event_id == ("event-" + (.seq | tostring)) and
        (.crew | type == "string" and length > 0) and
        (.crew_id | type == "string" and length > 0) and
        (.run_id | type == "string" and length > 0) and
        (.kind == "blocked" or .kind == "done") and
        (.payload | type == "string" and length > 0) and
        (.time | type == "string" and length > 0)
      ' <<< "$last" >/dev/null || status=1
    fi
    if [ "$status" -eq 0 ]; then
      last_seq=$(jq -r '.seq' <<< "$last") || status=1
    fi
    if [ "$status" -eq 0 ]; then
      seq=$((last_seq + 1))
    fi
  else
    seq=1
  fi

  if [ "$status" -eq 0 ]; then
    event_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || status=1
  fi
  if [ "$status" -eq 0 ]; then
    event=$(jq -cn --argjson seq "$seq" --arg crew "$crew" \
      --arg crew_id "$crew_id" --arg run_id "$run_id" --arg kind "$kind" \
      --arg payload "$payload" --arg time "$event_time" '
        {version: 1, seq: $seq, event_id: ("event-" + ($seq | tostring)),
         crew: $crew, crew_id: $crew_id, run_id: $run_id, kind: $kind,
         payload: $payload, time: $time}
      ') || status=1
  fi
  if [ "$status" -eq 0 ]; then
    printf '%s\n' "$event" >> "$CB_EVENT_SOURCE" || status=1
  fi

  cb_lock_release "$CB_EVENT_LOCK" || status=1
  return "$status"
}
