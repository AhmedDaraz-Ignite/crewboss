# shellcheck shell=bash
# registry: one JSON file mapping crew names to their worktree, agent, lifecycle, and task state.
# This is what makes close and reopen possible.
CB_STATE_DIR=${CB_STATE_DIR:-"$HOME/.local/state/crewboss"}
CB_REG="$CB_STATE_DIR/crew.json"
CB_REG_LOCK="$CB_STATE_DIR/crew.lock"
CB_LOCK_OWNER_LOCK=
CB_LOCK_OWNER_ANCHOR=
CB_LOCK_OWNER_TICKET=
CB_LOCK_OWNER_PID=
CB_REG_SEND_RECEIPT=

_cb_lock_parse_chooser() {
  local name=${1##*/} rest
  CB_LOCK_PARSE_PID=
  CB_LOCK_PARSE_TOKEN=

  case $name in
    C.*.*) ;;
    *) return 1 ;;
  esac
  rest=${name#C.}
  CB_LOCK_PARSE_PID=${rest%%.*}
  CB_LOCK_PARSE_TOKEN=${rest#*.}
  case $CB_LOCK_PARSE_PID in
    ''|0|0*|*[!0-9]*) return 1 ;;
  esac
  [ "${#CB_LOCK_PARSE_PID}" -le 18 ] || return 1
  case $CB_LOCK_PARSE_TOKEN in
    ''|*.*|*[!A-Za-z0-9]*) return 1 ;;
  esac
}

_cb_lock_parse_ticket() {
  local name=${1##*/} rest
  CB_LOCK_PARSE_TICKET=
  CB_LOCK_PARSE_PID=
  CB_LOCK_PARSE_TOKEN=

  case $name in
    T.*.*.*) ;;
    *) return 1 ;;
  esac
  rest=${name#T.}
  CB_LOCK_PARSE_TICKET=${rest%%.*}
  rest=${rest#*.}
  CB_LOCK_PARSE_PID=${rest%%.*}
  CB_LOCK_PARSE_TOKEN=${rest#*.}
  case $CB_LOCK_PARSE_TICKET in
    ''|0|0*|*[!0-9]*) return 1 ;;
  esac
  [ "${#CB_LOCK_PARSE_TICKET}" -le 18 ] || return 1
  case $CB_LOCK_PARSE_PID in
    ''|0|0*|*[!0-9]*) return 1 ;;
  esac
  [ "${#CB_LOCK_PARSE_PID}" -le 18 ] || return 1
  case $CB_LOCK_PARSE_TOKEN in
    ''|*.*|*[!A-Za-z0-9]*) return 1 ;;
  esac
}

cb_lock_acquire() {
  local lock=$1 claims old_umask anchor pid token chooser claim max_ticket=0 ticket
  local ticket_path blocked other_ticket other_pid other_token
  local LC_ALL=C
  [ -z "${CB_LOCK_OWNER_LOCK:-}" ] || return 1
  [ -z "${CB_LOCK_OWNER_ANCHOR:-}" ] || return 1
  [ -z "${CB_LOCK_OWNER_TICKET:-}" ] || return 1
  [ -z "${CB_LOCK_OWNER_PID:-}" ] || return 1

  old_umask=$(umask) || return 1
  umask 077
  claims="$lock.claims"
  if ! mkdir -p "$claims" 2>/dev/null || ! chmod 700 "$claims" 2>/dev/null; then
    umask "$old_umask"
    return 1
  fi

  anchor=$(mktemp "$claims/.id.XXXXXX") || {
    umask "$old_umask"
    return 1
  }
  if ! sh -c 'printf "%s\n" "$PPID" > "$1"' sh "$anchor" 2>/dev/null; then
    rm -f "$anchor"
    umask "$old_umask"
    return 1
  fi
  pid=
  IFS= read -r pid < "$anchor" || pid=
  case $pid in
    ''|0|0*|*[!0-9]*)
      rm -f "$anchor"
      umask "$old_umask"
      return 1
      ;;
  esac
  if [ "${#pid}" -gt 18 ]; then
    rm -f "$anchor"
    umask "$old_umask"
    return 1
  fi
  token=${anchor##*.}
  case $token in
    ''|*.*|*[!A-Za-z0-9]*)
      rm -f "$anchor"
      umask "$old_umask"
      return 1
      ;;
  esac

  chooser="$claims/C.$pid.$token"
  if ! mkdir "$chooser" 2>/dev/null; then
    rm -f "$anchor"
    umask "$old_umask"
    return 1
  fi

  for claim in "$claims"/T.*.*.*; do
    [ -d "$claim" ] || continue
    _cb_lock_parse_ticket "$claim" || continue
    kill -0 "$CB_LOCK_PARSE_PID" 2>/dev/null || continue
    if [ "$CB_LOCK_PARSE_TICKET" -gt "$max_ticket" ]; then
      max_ticket=$CB_LOCK_PARSE_TICKET
    fi
  done
  if [ "$max_ticket" -ge 999999999999999999 ]; then
    rmdir "$chooser" 2>/dev/null || true
    rm -f "$anchor"
    umask "$old_umask"
    return 1
  fi
  ticket=$((max_ticket + 1))
  ticket_path="$claims/T.$ticket.$pid.$token"
  if ! mv "$chooser" "$ticket_path" 2>/dev/null; then
    rmdir "$chooser" 2>/dev/null || true
    rm -f "$anchor"
    umask "$old_umask"
    return 1
  fi
  umask "$old_umask"

  while :; do
    blocked=0
    for claim in "$claims"/C.*.*; do
      [ -d "$claim" ] || continue
      _cb_lock_parse_chooser "$claim" || continue
      if kill -0 "$CB_LOCK_PARSE_PID" 2>/dev/null; then
        blocked=1
        break
      fi
    done
    if [ "$blocked" -ne 0 ]; then
      sleep 0.01
      continue
    fi

    for claim in "$claims"/T.*.*.*; do
      [ -d "$claim" ] || continue
      [ "$claim" = "$ticket_path" ] && continue
      _cb_lock_parse_ticket "$claim" || continue
      other_ticket=$CB_LOCK_PARSE_TICKET
      other_pid=$CB_LOCK_PARSE_PID
      other_token=$CB_LOCK_PARSE_TOKEN
      kill -0 "$other_pid" 2>/dev/null || continue
      if [ "$other_ticket" -lt "$ticket" ] ||
        { [ "$other_ticket" -eq "$ticket" ] && [ "$other_pid" -lt "$pid" ]; } ||
        { [ "$other_ticket" -eq "$ticket" ] && [ "$other_pid" -eq "$pid" ] &&
          [[ $other_token < $token ]]; }; then
        blocked=1
        break
      fi
    done
    [ "$blocked" -eq 0 ] && break
    sleep 0.01
  done

  CB_LOCK_OWNER_LOCK=$lock
  CB_LOCK_OWNER_ANCHOR=$anchor
  CB_LOCK_OWNER_TICKET=$ticket_path
  CB_LOCK_OWNER_PID=$pid
}

cb_lock_release() {
  local lock=$1 claims="$1.claims"
  local owner_lock=${CB_LOCK_OWNER_LOCK:-}
  local anchor=${CB_LOCK_OWNER_ANCHOR:-}
  local ticket=${CB_LOCK_OWNER_TICKET:-}
  local owner_pid=${CB_LOCK_OWNER_PID:-} anchor_pid token

  [ "$owner_lock" = "$lock" ] || return 1
  case $owner_pid in
    ''|0|0*|*[!0-9]*) return 1 ;;
  esac
  [ "${#owner_pid}" -le 18 ] || return 1
  case $anchor in
    "$claims"/.id.*) ;;
    *) return 1 ;;
  esac
  case $ticket in
    "$claims"/T.*.*.*) ;;
    *) return 1 ;;
  esac
  anchor_pid=
  IFS= read -r anchor_pid < "$anchor" || return 1
  [ "$anchor_pid" = "$owner_pid" ] || return 1
  _cb_lock_parse_ticket "$ticket" || return 1
  [ "$CB_LOCK_PARSE_PID" = "$owner_pid" ] || return 1
  token=${anchor##*.}
  [ "$CB_LOCK_PARSE_TOKEN" = "$token" ] || return 1
  sh -c '[ "$PPID" = "$1" ]' sh "$owner_pid" 2>/dev/null || return 1

  rmdir "$ticket" 2>/dev/null || return 1
  CB_LOCK_OWNER_LOCK=
  CB_LOCK_OWNER_ANCHOR=
  CB_LOCK_OWNER_TICKET=
  CB_LOCK_OWNER_PID=
  rm -f "$anchor" 2>/dev/null
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

  cb_lock_release "$CB_REG_LOCK" || status=1
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
  cb_lock_release "$CB_REG_LOCK" || status=1
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
  cb_lock_release "$CB_REG_LOCK" || status=1
  return "$status"
}

cb_reg_send_begin() {
  local name=$1 candidate_crew_id=$2 run_id=$3 prompt=$4
  local before prepared crew_id baseline receipt tmp status=0
  CB_REG_SEND_RECEIPT=
  [ -n "$name" ] && [ -n "$candidate_crew_id" ] && [ -n "$run_id" ] || return 1

  cb_reg_init || return 1
  cb_lock_acquire "$CB_REG_LOCK" || return 1
  jq -e 'type == "object"' "$CB_REG" >/dev/null || status=1
  if [ "$status" -eq 0 ]; then
    before=$(jq -cer --arg n "$name" '.[$n] // empty' "$CB_REG") || status=1
  fi
  if [ "$status" -eq 0 ]; then
    jq -e '.status == "open"' <<< "$before" >/dev/null || status=1
  fi
  if [ "$status" -eq 0 ]; then
    crew_id=$(jq -r --arg candidate "$candidate_crew_id" '
      if ((.crew_id? | type) == "string" and (.crew_id | length) > 0)
      then .crew_id else $candidate end
    ' <<< "$before") || status=1
  fi
  if [ "$status" -eq 0 ]; then
    baseline=$(jq -r '
      if ((.last_event_seq? | type) == "number" and
          (.last_event_seq | floor) == .last_event_seq and .last_event_seq >= 0)
      then .last_event_seq else 0 end
    ' <<< "$before") || status=1
  fi
  if [ "$status" -eq 0 ]; then
    prepared=$(jq -c --arg crew_id "$crew_id" --arg run_id "$run_id" \
      --arg prompt "$prompt" \
      '. + {crew_id: $crew_id, run_id: $run_id, latest_prompt: $prompt}' \
      <<< "$before") || status=1
  fi
  if [ "$status" -eq 0 ]; then
    receipt=$(jq -cn --argjson before "$before" --argjson prepared "$prepared" \
      --arg crew_id "$crew_id" --arg run_id "$run_id" --argjson baseline "$baseline" \
      '{before: $before, prepared: $prepared, crew_id: $crew_id, run_id: $run_id,
        baseline_last_event_seq: $baseline}') || status=1
  fi
  if [ "$status" -eq 0 ]; then
    tmp=$(mktemp "$CB_STATE_DIR/.crew.json.XXXXXX") || status=1
  fi
  if [ "$status" -eq 0 ]; then
    jq --arg n "$name" --argjson prepared "$prepared" '.[$n] = $prepared' \
      "$CB_REG" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$CB_REG" || status=1
  fi
  [ -z "${tmp:-}" ] || [ ! -f "$tmp" ] || rm -f "$tmp"
  cb_lock_release "$CB_REG_LOCK" || status=1
  if [ "$status" -eq 0 ]; then
    # shellcheck disable=SC2034 # consumed by the dispatcher after this file is sourced
    CB_REG_SEND_RECEIPT=$receipt
  fi
  return "$status"
}

cb_reg_send_finish() {
  local name=$1 receipt=$2 outcome=$3 before prepared crew_id run_id baseline
  local current current_seq replacement tmp status=0
  case $outcome in success|failure) ;; *) return 1 ;; esac
  receipt=$(jq -ce '
    select(type == "object" and
      keys == ["baseline_last_event_seq","before","crew_id","prepared","run_id"] and
      (.before | type == "object") and (.prepared | type == "object") and
      (.crew_id | type == "string" and length > 0) and
      (.run_id | type == "string" and length > 0) and
      (.baseline_last_event_seq | type == "number" and floor == . and . >= 0))
  ' <<< "$receipt") || return 1
  before=$(jq -c '.before' <<< "$receipt") || return 1
  prepared=$(jq -c '.prepared' <<< "$receipt") || return 1
  crew_id=$(jq -r '.crew_id' <<< "$receipt") || return 1
  run_id=$(jq -r '.run_id' <<< "$receipt") || return 1
  baseline=$(jq -r '.baseline_last_event_seq' <<< "$receipt") || return 1

  cb_reg_init || return 1
  cb_lock_acquire "$CB_REG_LOCK" || return 1
  jq -e 'type == "object"' "$CB_REG" >/dev/null || status=1
  if [ "$status" -eq 0 ]; then
    current=$(jq -cer --arg n "$name" '.[$n] // empty' "$CB_REG") || status=1
  fi
  if [ "$status" -eq 0 ]; then
    case $outcome in
      failure)
        if jq -e --argjson prepared "$prepared" '. == $prepared' \
          <<< "$current" >/dev/null; then
          replacement=$before
        else
          status=2
        fi
        ;;
      success)
        if ! jq -e --arg crew_id "$crew_id" --arg run_id "$run_id" \
          '.crew_id == $crew_id and .run_id == $run_id' \
          <<< "$current" >/dev/null; then
          status=2
        else
          current_seq=$(jq -r '
            if ((.last_event_seq? | type) == "number" and
                (.last_event_seq | floor) == .last_event_seq and .last_event_seq >= 0)
            then .last_event_seq else 0 end
          ' <<< "$current") || status=1
          if [ "$status" -eq 0 ] && [ "$current_seq" = "$baseline" ]; then
            replacement=$(jq -c --argjson baseline "$baseline" '
              . + {task_status: "running", blocked: false, message: "",
                   last_event_seq: $baseline}
            ' <<< "$current") || status=1
          else
            replacement=$current
          fi
        fi
        ;;
    esac
  fi
  if [ "$status" -eq 0 ] && [ "$replacement" != "$current" ]; then
    tmp=$(mktemp "$CB_STATE_DIR/.crew.json.XXXXXX") || status=1
  fi
  if [ "$status" -eq 0 ] && [ -n "${tmp:-}" ]; then
    jq --arg n "$name" --argjson replacement "$replacement" '.[$n] = $replacement' \
      "$CB_REG" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$CB_REG" || status=1
  fi
  [ -z "${tmp:-}" ] || [ ! -f "$tmp" ] || rm -f "$tmp"
  cb_lock_release "$CB_REG_LOCK" || status=1
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
  cb_lock_release "$CB_REG_LOCK" || status=1
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
  cb_lock_release "$CB_REG_LOCK" || status=1
  return "$status"
}

cb_reg_set_endpoint() {
  case $2 in
    open|closed|unknown) ;;
    *) return 1 ;;
  esac
  cb_reg_put "$1" "$(jq -n --arg state "$2" '{endpoint_state: $state}')"
}
