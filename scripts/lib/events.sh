# shellcheck shell=bash
# events: one append-only JSON Lines source shared by every crew.
CB_EVENT_SOURCE="$CB_STATE_DIR/events.jsonl"
CB_EVENT_LOCK="$CB_STATE_DIR/events.lock"
CB_EVENT_STATE="$CB_STATE_DIR/event-state.json"
CB_EVENT_MAX_SEQ=2147483647
CB_EVENT_WAIT_SECS=${CB_EVENT_WAIT_SECS:-1}
CB_EVENT_LAST_SEQ=
CB_EVENT_PARSED_SEQ=
CB_EVENT_STATE_JSON=

_cb_event_parse_record() {
  local record=$1 raw max_length=${#CB_EVENT_MAX_SEQ}
  CB_EVENT_PARSED_SEQ=

  case $record in
    '{"version":1,"seq":'*,*) ;;
    *) return 1 ;;
  esac
  raw=${record#'{"version":1,"seq":'}
  raw=${raw%%,*}
  case $raw in
    ''|0|0*|*[!0-9]*) return 1 ;;
  esac
  if [ "${#raw}" -gt "$max_length" ] ||
    { [ "${#raw}" -eq "$max_length" ] && [ "$raw" -gt "$CB_EVENT_MAX_SEQ" ]; }; then
    return 1
  fi

  jq -e --arg seq "$raw" '
    type == "object" and
    keys == ["crew","crew_id","event_id","kind","payload","run_id","seq","time","version"] and
    .version == 1 and
    .seq == ($seq | tonumber) and
    .event_id == ("event-" + $seq) and
    (.crew | type == "string" and length > 0) and
    (.crew_id | type == "string" and length > 0) and
    (.run_id | type == "string" and length > 0) and
    (.kind == "blocked" or .kind == "done") and
    (.payload | type == "string" and length > 0) and
    (.time | type == "string" and length > 0)
  ' <<< "$record" >/dev/null || return 1

  CB_EVENT_PARSED_SEQ=$raw
}

_cb_event_parse_last_seq() {
  CB_EVENT_LAST_SEQ=
  _cb_event_parse_record "$1" || return 1
  [ "$CB_EVENT_PARSED_SEQ" != "$CB_EVENT_MAX_SEQ" ] || return 1
  CB_EVENT_LAST_SEQ=$CB_EVENT_PARSED_SEQ
}

_cb_event_state_valid() {
  jq -e -s --argjson max "$CB_EVENT_MAX_SEQ" '
    def event:
      type == "object" and
      keys == ["crew","crew_id","event_id","kind","payload","run_id","seq","time","version"] and
      .version == 1 and
      (.seq | type == "number" and floor == . and . > 0 and . <= $max) and
      .event_id == ("event-" + (.seq | tostring)) and
      (.crew | type == "string" and length > 0) and
      (.crew_id | type == "string" and length > 0) and
      (.run_id | type == "string" and length > 0) and
      (.kind == "blocked" or .kind == "done") and
      (.payload | type == "string" and length > 0) and
      (.time | type == "string" and length > 0);
    length == 1 and
    (.[0] |
      . as $state |
      type == "object" and
      keys == ["cursor","pending"] and
      (.cursor | type == "number" and floor == . and . >= 0 and . <= $max) and
      (.pending | type == "object") and
      all(.pending | to_entries[];
        .key == .value.crew_id and (.value | event) and
        .value.seq <= $state.cursor))
  ' >/dev/null
}

_cb_event_state_write_locked() {
  local state=$1 tmp status=0
  printf '%s\n' "$state" | _cb_event_state_valid || return 1

  tmp=$(mktemp "$CB_STATE_DIR/.event-state.json.XXXXXX") || return 1
  printf '%s\n' "$state" > "$tmp" && chmod 600 "$tmp" &&
    mv "$tmp" "$CB_EVENT_STATE" || status=1
  [ ! -f "$tmp" ] || rm -f "$tmp"
  return "$status"
}

_cb_event_state_load_locked() {
  CB_EVENT_STATE_JSON=
  if [ ! -e "$CB_EVENT_STATE" ]; then
    CB_EVENT_STATE_JSON='{"cursor":0,"pending":{}}'
    _cb_event_state_write_locked "$CB_EVENT_STATE_JSON" || return 1
  elif [ ! -f "$CB_EVENT_STATE" ]; then
    return 1
  else
    CB_EVENT_STATE_JSON=$(jq -c '.' "$CB_EVENT_STATE") || return 1
    printf '%s\n' "$CB_EVENT_STATE_JSON" | _cb_event_state_valid || return 1
  fi
}

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
      _cb_event_parse_last_seq "$last" || status=1
    fi
    if [ "$status" -eq 0 ]; then
      last_seq=$CB_EVENT_LAST_SEQ
    fi
    if [ "$status" -eq 0 ]; then
      seq=$((10#$last_seq + 1))
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

cb_event_pump() {
  local snapshot current cursor line_number expected record candidate candidate_found
  local apply_status next_state status

  cb_event_init || return 1
  while :; do
    status=0
    candidate=
    candidate_found=0
    line_number=0
    cb_lock_acquire "$CB_EVENT_LOCK" || return 1
    _cb_event_state_load_locked || status=1
    if [ "$status" -eq 0 ]; then
      snapshot=$CB_EVENT_STATE_JSON
      cursor=$(jq -r '.cursor' <<< "$snapshot") || status=1
    fi
    if [ "$status" -eq 0 ]; then
      while IFS= read -r record; do
        line_number=$((line_number + 1))
        [ "$line_number" -gt "$cursor" ] || continue
        candidate=$record
        candidate_found=1
        break
      done < "$CB_EVENT_SOURCE"
    fi
    if [ "$status" -eq 0 ] && [ "$candidate_found" -eq 0 ] &&
      [ "$line_number" -lt "$cursor" ]; then
      echo "crewboss: event checkpoint is past the complete event log" >&2
      status=1
    fi
    if [ "$status" -eq 0 ] && [ "$candidate_found" -eq 1 ]; then
      expected=$((cursor + 1))
      if ! _cb_event_parse_record "$candidate"; then
        echo "crewboss: malformed complete event at log line $line_number" >&2
        status=1
      elif [ "$CB_EVENT_PARSED_SEQ" -ne "$expected" ]; then
        echo "crewboss: event sequence gap at log line $line_number (expected $expected)" >&2
        status=1
      fi
    fi
    cb_lock_release "$CB_EVENT_LOCK" || status=1
    [ "$status" -eq 0 ] || return 1
    [ "$candidate_found" -eq 1 ] || return 0

    cb_reg_apply_event "$candidate"
    apply_status=$?
    case $apply_status in
      0|2) ;;
      *)
        echo "crewboss: could not apply event at log line $line_number" >&2
        return 1
        ;;
    esac

    status=0
    cb_lock_acquire "$CB_EVENT_LOCK" || return 1
    _cb_event_state_load_locked || status=1
    if [ "$status" -eq 0 ]; then
      current=$CB_EVENT_STATE_JSON
      if [ "$current" = "$snapshot" ]; then
        case $apply_status in
          0)
            next_state=$(jq -c --argjson event "$candidate" '
              .cursor = $event.seq | .pending[$event.crew_id] = $event
            ' <<< "$current") || status=1
            ;;
          2)
            next_state=$(jq -c --argjson event "$candidate" \
              '.cursor = $event.seq' <<< "$current") || status=1
            ;;
        esac
        if [ "$status" -eq 0 ]; then
          _cb_event_state_write_locked "$next_state" || status=1
        fi
      fi
    fi
    cb_lock_release "$CB_EVENT_LOCK" || status=1
    [ "$status" -eq 0 ] || return 1
  done
}

cb_event_next() {
  local name requested snapshot current state pending event crew crew_id run_id
  local match_status next_state status
  [ "$#" -gt 0 ] || return 1

  for name in "$@"; do
    cb_reg_get "$name" >/dev/null 2>&1 || return 1
  done
  requested=$(jq -cn --args '$ARGS.positional' -- "$@") || return 1

  while :; do
    cb_event_pump || return 1
    status=0
    cb_lock_acquire "$CB_EVENT_LOCK" || return 1
    _cb_event_state_load_locked || status=1
    if [ "$status" -eq 0 ]; then
      snapshot=$CB_EVENT_STATE_JSON
      pending=$(jq -c '.pending[]' <<< "$snapshot") || status=1
    fi
    cb_lock_release "$CB_EVENT_LOCK" || status=1
    [ "$status" -eq 0 ] || return 1

    state=$snapshot
    if [ -n "$pending" ]; then
      while IFS= read -r event; do
        crew=$(jq -r '.crew' <<< "$event") || return 1
        crew_id=$(jq -r '.crew_id' <<< "$event") || return 1
        run_id=$(jq -r '.run_id' <<< "$event") || return 1
        cb_reg_identity_matches "$crew" "$crew_id" "$run_id"
        match_status=$?
        case $match_status in
          0) ;;
          2)
            next_state=$(jq -c --arg crew_id "$crew_id" --argjson event "$event" '
              if .pending[$crew_id].seq == $event.seq and
                 .pending[$crew_id].event_id == $event.event_id
              then del(.pending[$crew_id]) else . end
            ' <<< "$state") || return 1
            state=$next_state
            ;;
          *) return 1 ;;
        esac
      done <<< "$pending"
    fi

    event=
    status=0
    cb_lock_acquire "$CB_EVENT_LOCK" || return 1
    _cb_event_state_load_locked || status=1
    if [ "$status" -eq 0 ]; then
      current=$CB_EVENT_STATE_JSON
      if [ "$current" != "$snapshot" ]; then
        status=2
      elif [ "$state" != "$snapshot" ]; then
        _cb_event_state_write_locked "$state" || status=1
      fi
    fi
    if [ "$status" -eq 0 ]; then
      event=$(jq -cer --argjson requested "$requested" '
        [.pending[] | select(.crew as $crew | $requested | index($crew))] |
        sort_by(.seq) | .[0] // empty
      ' <<< "$state") || event=
    fi
    cb_lock_release "$CB_EVENT_LOCK" || status=1
    case $status in
      0) ;;
      2) continue ;;
      *) return 1 ;;
    esac

    if [ -n "$event" ]; then
      crew=$(jq -r '.crew' <<< "$event") || return 1
      crew_id=$(jq -r '.crew_id' <<< "$event") || return 1
      run_id=$(jq -r '.run_id' <<< "$event") || return 1
      cb_reg_identity_matches "$crew" "$crew_id" "$run_id"
      match_status=$?
      case $match_status in
        0)
          printf '%s\n' "$event"
          return $?
          ;;
        2) continue ;;
        *) return 1 ;;
      esac
    fi
    sleep "$CB_EVENT_WAIT_SECS" || return 1
  done
}

cb_event_ack() {
  local event=$1 crew crew_id run_id state next_state match_status status=0
  _cb_event_parse_record "$event" || return 1
  crew=$(jq -r '.crew' <<< "$event") || return 1
  crew_id=$(jq -r '.crew_id' <<< "$event") || return 1
  run_id=$(jq -r '.run_id' <<< "$event") || return 1

  cb_reg_identity_matches "$crew" "$crew_id" "$run_id"
  match_status=$?
  case $match_status in
    0|2) ;;
    *) return 1 ;;
  esac

  cb_event_init || return 1
  cb_lock_acquire "$CB_EVENT_LOCK" || return 1
  _cb_event_state_load_locked || status=1
  if [ "$status" -eq 0 ]; then
    state=$CB_EVENT_STATE_JSON
    next_state=$(jq -c --arg crew_id "$crew_id" --argjson event "$event" '
      if .pending[$crew_id].seq == $event.seq and
         .pending[$crew_id].event_id == $event.event_id
      then del(.pending[$crew_id]) else . end
    ' <<< "$state") || status=1
  fi
  if [ "$status" -eq 0 ] && [ "$next_state" != "$state" ]; then
    _cb_event_state_write_locked "$next_state" || status=1
  fi
  cb_lock_release "$CB_EVENT_LOCK" || status=1
  return "$status"
}

cb_event_drop_crew() {
  local crew_id=$1 state next_state status=0
  [ -n "$crew_id" ] || return 1
  cb_event_init || return 1
  cb_lock_acquire "$CB_EVENT_LOCK" || return 1
  _cb_event_state_load_locked || status=1
  if [ "$status" -eq 0 ]; then
    state=$CB_EVENT_STATE_JSON
    next_state=$(jq -c --arg crew_id "$crew_id" 'del(.pending[$crew_id])' \
      <<< "$state") || status=1
  fi
  if [ "$status" -eq 0 ] && [ "$next_state" != "$state" ]; then
    _cb_event_state_write_locked "$next_state" || status=1
  fi
  cb_lock_release "$CB_EVENT_LOCK" || status=1
  return "$status"
}
