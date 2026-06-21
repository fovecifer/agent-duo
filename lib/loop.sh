#!/usr/bin/env bash
# lib/loop.sh — loop runtime helpers shared by loopd and supervisor hooks.
# Source-only library; compatible with macOS bash 3.2.

ad_loop_duo_dir() { # <root>
  printf '%s/.agent-duo' "$1"
}

ad_loop_events_dir() { # <root>
  printf '%s/events' "$(ad_loop_duo_dir "$1")"
}

ad_loop_state_dir() { # <root>
  printf '%s/state' "$(ad_loop_duo_dir "$1")"
}

ad_loop_queue_file() { # <root>
  printf '%s/queue.jsonl' "$(ad_loop_events_dir "$1")"
}

ad_loop_cursor_file() { # <root>
  printf '%s/cursor' "$(ad_loop_events_dir "$1")"
}

ad_loop_cursor_lock() { # <root>
  printf '%s/cursor.lock' "$(ad_loop_events_dir "$1")"
}

ad_loop_delivered_file() { # <root>
  printf '%s/delivered' "$(ad_loop_events_dir "$1")"
}

ad_loop_ensure_dirs() { # <root>
  local root="$1"
  mkdir -p "$(ad_loop_events_dir "$root")" "$(ad_loop_state_dir "$root")"
  [[ -e "$(ad_loop_queue_file "$root")" ]] || : > "$(ad_loop_queue_file "$root")"
}

ad_loop_now_epoch() {
  date +%s
}

ad_loop_iso_ts() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

ad_loop_is_nonnegative_int() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

ad_loop_read_cursor() { # <root>
  local cursor_file value
  cursor_file="$(ad_loop_cursor_file "$1")"
  value="0"
  if [[ -f "$cursor_file" ]]; then
    value="$(sed -n '1p' "$cursor_file" 2>/dev/null || true)"
  fi
  if ! ad_loop_is_nonnegative_int "$value"; then
    value="0"
  fi
  printf '%s' "$value"
}

ad_loop_migrate_cursor_to_delivered() { # <root>
  local root="$1" cursor delivered i
  delivered="$(ad_loop_delivered_file "$root")"
  [[ -f "$delivered" ]] && return 0
  cursor="$(ad_loop_read_cursor "$root")"
  ad_loop_is_nonnegative_int "$cursor" || cursor="0"
  (( cursor > 0 )) || return 0
  i=1
  while (( i <= cursor )); do
    printf '%s\n' "$i"
    i=$(( i + 1 ))
  done > "$delivered"
}

ad_loop_write_cursor() { # <root> <line_number>
  local root="$1" value="$2" cursor_file tmp
  ad_loop_ensure_dirs "$root"
  cursor_file="$(ad_loop_cursor_file "$root")"
  tmp="${cursor_file}.$$"
  printf '%s\n' "$value" > "$tmp"
  mv -f "$tmp" "$cursor_file"
}

ad_loop_line_count() { # <file>
  local file="$1"
  if [[ -f "$file" ]]; then
    wc -l < "$file" | tr -d ' '
  else
    printf '0'
  fi
}

ad_loop_pending_count() { # <root>
  local root="$1" queue cursor lines
  ad_loop_migrate_cursor_to_delivered "$root"
  queue="$(ad_loop_queue_file "$root")"
  cursor="$(ad_loop_read_cursor "$root")"
  lines="$(ad_loop_line_count "$queue")"
  if (( lines > cursor )); then
    printf '%s' "$(( lines - cursor ))"
  else
    printf '0'
  fi
}

ad_loop_event_priority() { # <event_json>
  local type
  type="$(jq -r '.type // "unknown"' <<EOF
$1
EOF
)"
  case "$type" in
    blocked|request|loop_stop) printf '10' ;;
    result)              printf '20' ;;
    stuck|dead)          printf '30' ;;
    budget_low)          printf '40' ;;
    silent)              printf '50' ;;
    plan)                printf '60' ;;
    checkpoint)          printf '90' ;;
    tick)                printf '95' ;;
    *)                   printf '80' ;;
  esac
}

ad_loop_line_delivered() { # <root> <line_number>
  local delivered
  delivered="$(ad_loop_delivered_file "$1")"
  [[ -f "$delivered" ]] || return 1
  grep -qx "$2" "$delivered"
}

ad_loop_mark_delivered() { # <root> <line_number>
  local root="$1" line="$2" delivered count
  delivered="$(ad_loop_delivered_file "$root")"
  if ! ad_loop_line_delivered "$root" "$line"; then
    printf '%s\n' "$line" >> "$delivered"
  fi
  count="$(wc -l < "$delivered" | tr -d ' ')"
  ad_loop_write_cursor "$root" "$count"
}

ad_loop_with_cursor_lock() { # <root> <function> [args...]
  local root="$1" lock lock_dir fn
  shift
  fn="$1"
  shift
  ad_loop_ensure_dirs "$root"
  lock="$(ad_loop_cursor_lock "$root")"
  : > "$lock"
  if command -v flock >/dev/null 2>&1; then
    (
      exec 9>"$lock"
      flock 9
      "$fn" "$@"
    )
  else
    lock_dir="${lock}.d"
    while ! mkdir "$lock_dir" 2>/dev/null; do
      sleep 0.1
    done
    (
      trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT
      "$fn" "$@"
    )
  fi
}

ad_loop_event_text() { # <event_json>
  jq -r '
    "«AGENTDUO event» id=\(.id) agent=\(.agent) type=\(.type) round=\(.round) ref=\(.ref)\nsummary: \(.summary)"
  ' <<EOF
$1
EOF
}

ad_loop_print_block_decision() { # <event_text>
  jq -cn --arg reason "$1" '{decision:"block",reason:$reason}'
}

ad_loop_inject_event_text() { # <event_text>
  local peer_bin text
  text="$1"
  peer_bin="${AGENT_DUO_PEER_BIN:-peer}"
  "$peer_bin" tell supervisor "$text" >/dev/null 2>&1
}

ad_loop_deliver_next_event_locked() { # <root> <mode:inject|block|print>
  local root="$1" mode="$2" queue lines candidate next event text priority
  ad_loop_migrate_cursor_to_delivered "$root"
  queue="$(ad_loop_queue_file "$root")"
  lines="$(ad_loop_line_count "$queue")"
  if (( lines == 0 )); then
    return 1
  fi

  candidate="$(
    awk '{ print NR "\t" $0 }' "$queue" | while IFS=$'\t' read -r next event; do
      [[ -n "$next" && -n "$event" ]] || continue
      if ad_loop_line_delivered "$root" "$next"; then
        continue
      fi
      priority="$(ad_loop_event_priority "$event")" || continue
      printf '%s\t%s\t%s\n' "$priority" "$next" "$event"
    done | sort -n -k1,1 -k2,2 | sed -n '1p'
  )"
  if [[ -z "$candidate" ]]; then
    return 1
  fi
  priority="${candidate%%$'\t'*}"
  candidate="${candidate#*$'\t'}"
  next="${candidate%%$'\t'*}"
  event="${candidate#*$'\t'}"
  text="$(ad_loop_event_text "$event")" || return 1

  case "$mode" in
    inject)
      ad_loop_inject_event_text "$text" || return 1
      ;;
    block)
      ad_loop_print_block_decision "$text"
      ;;
    print)
      printf '%s\n' "$text"
      ;;
    *)
      return 2
      ;;
  esac

  ad_loop_mark_delivered "$root" "$next"
  return 0
}

ad_loop_mark_supervisor_turn() { # <root> <busy|idle>
  local root="$1" state="$2"
  ad_loop_ensure_dirs "$root"
  printf '%s\n' "$state" > "$(ad_loop_state_dir "$root")/supervisor.turn"
}

ad_loop_daemon_heartbeat_file() { # <root>
  printf '%s/daemon.heartbeat' "$(ad_loop_state_dir "$1")"
}

ad_loop_daemon_expected_file() { # <root>
  printf '%s/daemon.expected' "$(ad_loop_state_dir "$1")"
}

ad_loop_daemon_offline_marker() { # <root>
  printf '%s/daemon.offline.notified' "$(ad_loop_state_dir "$1")"
}

ad_loop_daemon_heartbeat_stale() { # <root> <now>
  local root="$1" now="$2" ttl heartbeat_file heartbeat
  ttl="${LOOPD_HEARTBEAT_TTL:-10}"
  ad_loop_is_nonnegative_int "$ttl" || ttl="10"
  heartbeat_file="$(ad_loop_daemon_heartbeat_file "$root")"
  if [[ ! -f "$heartbeat_file" ]]; then
    [[ -f "$(ad_loop_daemon_expected_file "$root")" ]]
    return $?
  fi
  heartbeat="$(sed -n '1p' "$heartbeat_file" 2>/dev/null || true)"
  ad_loop_is_nonnegative_int "$heartbeat" || return 0
  (( now - heartbeat > ttl ))
}

ad_loop_maybe_block_daemon_offline() { # <root>
  local root="$1" now marker message
  now="$(ad_loop_now_epoch)"
  marker="$(ad_loop_daemon_offline_marker "$root")"
  if ad_loop_daemon_heartbeat_stale "$root" "$now"; then
    [[ -f "$marker" ]] && return 1
    printf '%s\n' "$now" > "$marker"
    message="运行时监控离线，失去 worker 存活/卡死检测，建议重启 loopd。"
    ad_loop_print_block_decision "$message"
    return 0
  fi
  rm -f "$marker"
  return 1
}

ad_loop_stop_drain() { # <root>
  local root="$1"
  ad_loop_mark_supervisor_turn "$root" idle
  if ad_loop_maybe_block_daemon_offline "$root"; then
    return 0
  fi
  if ad_loop_with_cursor_lock "$root" ad_loop_deliver_next_event_locked "$root" block; then
    return 0
  fi
}

ad_loop_user_prompt_submit() { # <root>
  ad_loop_mark_supervisor_turn "$1" busy
}

ad_loop_tmux_panes() { # <session>
  tmux list-panes -s -t "$1" \
    -F '#{pane_id}	#{@agent_id}	#{@agent_role}	#{@agent_provider}' 2>/dev/null || true
}

ad_loop_pane_for_id() { # <session> <agent_id>
  ad_loop_tmux_panes "$1" | awk -F'\t' -v w="$2" '$2 == w { print $1; found=1 } END { exit found ? 0 : 1 }'
}

ad_loop_role_for_id() { # <session> <agent_id>
  ad_loop_tmux_panes "$1" | awk -F'\t' -v w="$2" '$2 == w { print $3; found=1 } END { exit found ? 0 : 1 }'
}

ad_loop_is_worker_role() { # <role>
  case "$1" in
    ""|supervisor|daemon|loopd) return 1 ;;
    *) return 0 ;;
  esac
}

ad_loop_active_workers() { # <session>
  local session="$1"
  ad_loop_tmux_panes "$session" | while IFS=$'\t' read -r pane id role provider; do
    [[ -n "$pane" && -n "$id" ]] || continue
    if ad_loop_is_worker_role "$role"; then
      printf '%s\n' "$id"
    fi
  done
}

ad_loop_state_agents() { # <root>
  local state d base
  state="$(ad_loop_state_dir "$1")"
  for d in "$state"/*; do
    [[ -d "$d" ]] || continue
    [[ -f "$d/report.json" ]] || continue
    base="${d##*/}"
    case "$base" in
      supervisor|daemon|loopd) continue ;;
    esac
    printf '%s\n' "$base"
  done
}

ad_loop_contract_agents() { # <root>
  local state d base
  state="$(ad_loop_state_dir "$1")"
  for d in "$state"/*; do
    [[ -d "$d" && -f "$d/loop.json" ]] || continue
    base="${d##*/}"
    case "$base" in
      supervisor|daemon|loopd) continue ;;
    esac
    printf '%s\n' "$base"
  done
}

ad_loop_report_path() { # <root> <agent_id>
  printf '%s/%s/report.json' "$(ad_loop_state_dir "$1")" "$2"
}

ad_loop_contract_path() { # <root> <agent_id>
  printf '%s/%s/loop.json' "$(ad_loop_state_dir "$1")" "$2"
}

ad_loop_report_round() { # <report_path>
  local round
  round="$(jq -r '.round // 0' "$1" 2>/dev/null || true)"
  if ! ad_loop_is_nonnegative_int "$round"; then
    round="0"
  fi
  printf '%s' "$round"
}

ad_loop_report_status() { # <report_path>
  jq -r '.status // "unknown"' "$1" 2>/dev/null || printf 'unknown'
}

ad_loop_report_ref() { # <root> <agent_id> <round>
  local root="$1" agent="$2" round="$3" report target
  report="$(ad_loop_report_path "$root" "$agent")"
  if [[ -L "$report" ]]; then
    target="$(readlink "$report")"
    if [[ -n "$target" ]]; then
      printf '.agent-duo/state/%s/%s' "$agent" "$target"
      return 0
    fi
  fi
  if [[ "$round" != "0" ]]; then
    printf '.agent-duo/state/%s/r%s.json' "$agent" "$round"
  else
    printf '.agent-duo/state/%s/report.json' "$agent"
  fi
}

ad_loop_mtime() { # <path>
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || printf '0'
}

ad_loop_event_seen() { # <root> <agent> <type> <round> <ref>
  local queue
  queue="$(ad_loop_queue_file "$1")"
  [[ -f "$queue" ]] || return 1
  jq -e --arg agent "$2" --arg type "$3" --arg ref "$5" --argjson round "$4" '
    select(.agent == $agent and .type == $type and .round == $round and .ref == $ref)
  ' "$queue" >/dev/null 2>&1
}

ad_loop_event_id_seen() { # <root> <event_id>
  local queue id
  queue="$(ad_loop_queue_file "$1")"
  id="$2"
  [[ -f "$queue" ]] || return 1
  grep -F "\"id\":\"${id}\"" "$queue" >/dev/null 2>&1
}

ad_loop_append_event() { # <root> <agent> <type> <round> <summary> <ref>
  local root="$1" agent="$2" type="$3" round="$4" summary="$5" ref="$6" queue id ts json
  ad_loop_ensure_dirs "$root"
  queue="$(ad_loop_queue_file "$root")"
  id="$(printf 'e%s-%s-%s-%s-%s' "$(date -u '+%Y%m%dT%H%M%SZ')" "$type" "$agent" "$round" "$RANDOM")"
  ts="$(ad_loop_iso_ts)"
  json="$(jq -cn \
    --arg id "$id" --arg ts "$ts" --arg agent "$agent" --arg type "$type" \
    --arg summary "$summary" --arg ref "$ref" --argjson round "$round" \
    '{id:$id,ts:$ts,agent:$agent,type:$type,round:$round,summary:$summary,ref:$ref}')"
  printf '%s\n' "$json" >> "$queue"
}

ad_loop_append_event_with_id() { # <root> <id> <agent> <type> <round> <summary> <ref>
  local root="$1" id="$2" agent="$3" type="$4" round="$5" summary="$6" ref="$7" queue ts json
  ad_loop_ensure_dirs "$root"
  queue="$(ad_loop_queue_file "$root")"
  ts="$(ad_loop_iso_ts)"
  json="$(jq -cn \
    --arg id "$id" --arg ts "$ts" --arg agent "$agent" --arg type "$type" \
    --arg summary "$summary" --arg ref "$ref" --argjson round "$round" \
    '{id:$id,ts:$ts,agent:$agent,type:$type,round:$round,summary:$summary,ref:$ref}')"
  printf '%s\n' "$json" >> "$queue"
}

ad_loop_append_event_once() { # <root> <agent> <type> <round> <summary> <ref>
  if ad_loop_event_seen "$1" "$2" "$3" "$4" "$6"; then
    return 0
  fi
  ad_loop_append_event "$@"
}

ad_loop_stop_contract() { # <root> <agent> <reason> <current_round> <rounds_used> <max_rounds>
  local root="$1" agent="$2" reason="$3" current_round="$4" rounds_used="$5" max_rounds="$6"
  local contract tmp ts event_id summary ref
  contract="$(ad_loop_contract_path "$root" "$agent")"
  tmp="${contract}.$$"
  ts="$(ad_loop_iso_ts)"
  event_id="loopstop-${agent}-${current_round}"
  ref=".agent-duo/state/${agent}/loop.json"
  case "$reason" in
    max_rounds) summary="loop stopped: max_rounds (${rounds_used}/${max_rounds})" ;;
    done)       summary="loop stopped: done" ;;
    failed)     summary="loop stopped: failed" ;;
    *)          summary="loop stopped: ${reason}" ;;
  esac
  if ! jq -c --arg reason "$reason" --arg ts "$ts" --argjson round "$current_round" '
    .status = "stopped"
    | .stop.reason = $reason
    | .stop.stopped_at_round = $round
    | .stop.stopped_at = $ts
    | .updated_at = $ts
  ' "$contract" > "$tmp"; then
    rm -f "$tmp"
    echo "警告: 无法更新 ${contract},已跳过 loop stop。" >&2
    return 1
  fi
  if ! ad_loop_event_id_seen "$root" "$event_id"; then
    if ! ad_loop_append_event_with_id "$root" "$event_id" "$agent" loop_stop "$current_round" "$summary" "$ref"; then
      rm -f "$tmp"
      return 1
    fi
  fi
  mv "$tmp" "$contract"
}

ad_loop_eval_contracts() { # <root> <session>
  local root="$1" session="${2:-}" agent contract parsed status max_rounds frozen_round on_terminal
  local report current_round report_status rounds_used reason
  : "${session:-}"
  ad_loop_contract_agents "$root" | while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    contract="$(ad_loop_contract_path "$root" "$agent")"
    if ! parsed="$(jq -c '.' "$contract" 2>/dev/null)"; then
      echo "警告: ${contract} 解析失败,已跳过 loop 评估。" >&2
      continue
    fi
    status="$(jq -r '.status // "active"' <<EOF
$parsed
EOF
)"
    [[ "$status" == "active" ]] || continue
    max_rounds="$(jq -r '.max_rounds // empty' <<EOF
$parsed
EOF
)"
    frozen_round="$(jq -r '.frozen_at_round // empty' <<EOF
$parsed
EOF
)"
    on_terminal="$(jq -r '.stop.on_terminal // true' <<EOF
$parsed
EOF
)"
    if ! ad_loop_is_nonnegative_int "$max_rounds" || [[ "$max_rounds" == "0" ]] \
       || ! ad_loop_is_nonnegative_int "$frozen_round" || [[ "$frozen_round" == "0" ]]; then
      echo "警告: ${contract} 缺少有效 max_rounds/frozen_at_round,已跳过 loop 评估。" >&2
      continue
    fi
    report="$(ad_loop_report_path "$root" "$agent")"
    current_round="$(ad_loop_report_round "$report")"
    report_status="$(ad_loop_report_status "$report")"
    rounds_used="$(( current_round - frozen_round + 1 ))"
    reason=""
    if [[ "$on_terminal" == "true" && "$report_status" == "done" ]]; then
      reason="done"
    elif [[ "$on_terminal" == "true" && "$report_status" == "failed" ]]; then
      reason="failed"
    elif (( rounds_used > 0 && rounds_used >= max_rounds )); then
      reason="max_rounds"
    fi
    [[ -n "$reason" ]] || continue
    ad_loop_stop_contract "$root" "$agent" "$reason" "$current_round" "$rounds_used" "$max_rounds" || true
  done
}

ad_loop_pane_quiet() { # <pane> [sample_seconds]
  local pane="$1" sample="${2:-0.5}" first second
  first="$(tmux capture-pane -p -J -t "$pane" -S -80 2>/dev/null || true)"
  sleep "$sample"
  second="$(tmux capture-pane -p -J -t "$pane" -S -80 2>/dev/null || true)"
  [[ -n "$first$second" && "$first" == "$second" ]]
}

ad_loop_supervisor_guard_ok() { # <session>
  local session="$1" pane in_mode sample
  pane="$(ad_loop_pane_for_id "$session" supervisor 2>/dev/null || true)"
  [[ -n "$pane" ]] || return 1
  in_mode="$(tmux display-message -p -t "$pane" '#{pane_in_mode}' 2>/dev/null || true)"
  [[ "$in_mode" == "1" ]] && return 1
  sample="${LOOPD_DRAFT_SAMPLE:-${LOOPD_QUIET_SAMPLE:-0.5}}"
  ad_loop_pane_quiet "$pane" "$sample"
}

ad_loop_check_liveness() { # <root> <session> <now> <silent_t>
  local root="$1" session="$2" now="$3" silent_t="$4" agent report round ref pane last quiet_sample
  quiet_sample="${LOOPD_QUIET_SAMPLE:-0.5}"
  ad_loop_state_agents "$root" | while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    report="$(ad_loop_report_path "$root" "$agent")"
    round="$(ad_loop_report_round "$report")"
    ref="$(ad_loop_report_ref "$root" "$agent" "$round")"
    pane="$(ad_loop_pane_for_id "$session" "$agent" 2>/dev/null || true)"
    if [[ -z "$pane" ]]; then
      ad_loop_append_event_once "$root" "$agent" dead "$round" "pane missing" "$ref"
      continue
    fi
    last="$(ad_loop_mtime "$report")"
    if ad_loop_is_nonnegative_int "$last" && (( now - last > silent_t )); then
      if ad_loop_pane_quiet "$pane" "$quiet_sample"; then
        ad_loop_append_event_once "$root" "$agent" silent "$round" "no report for $(( now - last ))s; pane quiet" "$ref"
      fi
    fi
  done
}

ad_loop_last_tick_epoch() { # <root>
  local queue
  queue="$(ad_loop_queue_file "$1")"
  [[ -f "$queue" ]] || { printf '0'; return 0; }
  jq -sr '[.[] | select(.type == "tick") | (.ts | fromdateiso8601? // 0)] | max // 0' "$queue" 2>/dev/null || printf '0'
}

ad_loop_maybe_tick() { # <root> <session> <now> <tick_t>
  local root="$1" session="$2" now="$3" tick_t="$4" active last agent report mtime newest
  active="$(ad_loop_active_workers "$session" | sed -n '1p')"
  [[ -n "$active" ]] || return 0
  last="$(ad_loop_last_tick_epoch "$root")"
  if ! ad_loop_is_nonnegative_int "$last"; then
    last="0"
  fi
  if [[ "$last" == "0" ]]; then
    newest="$(ad_loop_active_workers "$session" | while IFS= read -r agent; do
      [[ -n "$agent" ]] || continue
      report="$(ad_loop_report_path "$root" "$agent")"
      [[ -f "$report" ]] || continue
      mtime="$(ad_loop_mtime "$report")"
      if ad_loop_is_nonnegative_int "$mtime"; then
        printf '%s\n' "$mtime"
      fi
    done | sort -n | tail -1)"
    if ad_loop_is_nonnegative_int "$newest" && [[ "$newest" != "0" ]]; then
      last="$newest"
    else
      last="$now"
    fi
  fi
  if (( now - last > tick_t )); then
    ad_loop_append_event "$root" "-" tick 0 "loop tick" ""
  fi
}

ad_loop_idle_arrival() { # <root> <session>
  local root="$1" session="$2" turn pending
  turn="$(sed -n '1p' "$(ad_loop_state_dir "$root")/supervisor.turn" 2>/dev/null || true)"
  [[ "$turn" == "idle" ]] || return 0
  pending="$(ad_loop_pending_count "$root")"
  [[ "$pending" != "0" ]] || return 0
  ad_loop_supervisor_guard_ok "$session" || return 0
  ad_loop_with_cursor_lock "$root" ad_loop_deliver_next_event_locked "$root" inject || true
}

ad_loop_dashboard_loop_info() { # <root> <agent>
  local root="$1" agent="$2" contract parsed max_rounds frozen_round status reason current_round rounds_used
  contract="$(ad_loop_contract_path "$root" "$agent")"
  [[ -f "$contract" ]] || return 0
  if ! parsed="$(jq -c '.' "$contract" 2>/dev/null)"; then
    printf 'loop=invalid'
    return 0
  fi
  max_rounds="$(jq -r '.max_rounds // 0' <<EOF
$parsed
EOF
)"
  frozen_round="$(jq -r '.frozen_at_round // 1' <<EOF
$parsed
EOF
)"
  status="$(jq -r '.status // "active"' <<EOF
$parsed
EOF
)"
  reason="$(jq -r '.stop.reason // ""' <<EOF
$parsed
EOF
)"
  if ! ad_loop_is_nonnegative_int "$max_rounds"; then max_rounds="0"; fi
  if ! ad_loop_is_nonnegative_int "$frozen_round" || [[ "$frozen_round" == "0" ]]; then frozen_round="1"; fi
  current_round="$(ad_loop_report_round "$(ad_loop_report_path "$root" "$agent")")"
  rounds_used="$(( current_round - frozen_round + 1 ))"
  if [[ "$status" == "stopped" && -n "$reason" ]]; then
    printf 'loop=%s/%s stopped:%s' "$rounds_used" "$max_rounds" "$reason"
  else
    printf 'loop=%s/%s %s' "$rounds_used" "$max_rounds" "$status"
  fi
}

ad_loop_render_dashboard() { # <root> <session>
  local root="$1" session="$2" now turn pending workers agent pane report status round loop_info
  now="$(ad_loop_now_epoch)"
  turn="$(sed -n '1p' "$(ad_loop_state_dir "$root")/supervisor.turn" 2>/dev/null || true)"
  [[ -n "$turn" ]] || turn="unknown"
  pending="$(ad_loop_pending_count "$root")"
  workers="$( { ad_loop_state_agents "$root"; ad_loop_contract_agents "$root"; ad_loop_active_workers "$session"; } | grep -v '^$' | sort -u || true )"

  printf 'agent-duo loopd\n'
  printf 'heartbeat: %s\n' "$now"
  printf 'supervisor: %s\n' "$turn"
  printf 'pending: %s\n' "$pending"
  printf 'workers:\n'
  if [[ -z "$workers" ]]; then
    printf '  (none)\n'
    return 0
  fi
  printf '%s\n' "$workers" | while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    pane="$(ad_loop_pane_for_id "$session" "$agent" 2>/dev/null || true)"
    report="$(ad_loop_report_path "$root" "$agent")"
    if [[ -f "$report" ]]; then
      status="$(ad_loop_report_status "$report")"
      round="$(ad_loop_report_round "$report")"
    else
      status="no-report"
      round="0"
    fi
    [[ -n "$pane" ]] || pane="-"
    loop_info="$(ad_loop_dashboard_loop_info "$root" "$agent")"
    printf '  %s pane=%s round=%s status=%s' "$agent" "$pane" "$round" "$status"
    if [[ -n "$loop_info" ]]; then
      printf '   %s' "$loop_info"
    fi
    printf '\n'
  done
}

ad_loop_once() { # <root> <session>
  local root="$1" session="$2" now silent_t tick_t heartbeat
  ad_loop_ensure_dirs "$root"
  now="$(ad_loop_now_epoch)"
  heartbeat="$(ad_loop_daemon_heartbeat_file "$root")"
  printf '%s\n' "$now" > "$(ad_loop_daemon_expected_file "$root")"
  printf '%s\n' "$now" > "$heartbeat"
  silent_t="${LOOPD_SILENT_T:-180}"
  tick_t="${LOOPD_TICK_T:-1800}"
  ad_loop_check_liveness "$root" "$session" "$now" "$silent_t"
  ad_loop_maybe_tick "$root" "$session" "$now" "$tick_t"
  ad_loop_eval_contracts "$root" "$session"
  ad_loop_idle_arrival "$root" "$session"
  ad_loop_render_dashboard "$root" "$session"
}
