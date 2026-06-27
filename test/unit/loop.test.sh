#!/usr/bin/env bash
# test/loop.test.sh — loop runtime / hook behavior with tmux and peer stubs.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
source "$DIR/../lib/harness.sh"
setup() { loop_setup; }

write_event() { # <id> <agent> <type> <round> <summary> <ref>
  jq -cn \
    --arg id "$1" --arg agent "$2" --arg type "$3" --arg summary "$5" --arg ref "$6" \
    --argjson round "$4" \
    '{id:$id,ts:"2026-06-17T00:00:00Z",agent:$agent,type:$type,round:$round,summary:$summary,ref:$ref}' \
    >> "$PROJECT/.agent-duo/events/queue.jsonl"
}

write_report() { # <agent> <round> <status>
  write_report_with_direction "$1" "$2" "$3" "" ""
}

write_report_with_direction() { # <agent> <round> <status> <delta> <drift>
  local agent="$1" round="$2" status="$3" delta="$4" drift="$5" state
  state="$PROJECT/.agent-duo/state/$agent"
  mkdir -p "$state"
  jq -cn \
    --argjson round "$round" --arg agent "$agent" --arg status "$status" --arg delta "$delta" --arg drift "$drift" \
    '{protocol:"1",round:$round,agent_id:$agent,role:"worker",type:"checkpoint",status:$status,delta:$delta,drift:(if $drift == "" then null else $drift end),next:"",needs:[]}' \
    > "$state/r${round}.json"
  rm -f "$state/report.json"
  ln -s "r${round}.json" "$state/report.json"
}

write_result_report_with_evidence() { # <agent> <round> <status>
  local agent="$1" round="$2" status="$3" state
  state="$PROJECT/.agent-duo/state/$agent"
  mkdir -p "$state"
  jq -cn \
    --argjson round "$round" --arg agent "$agent" --arg status "$status" \
    '{protocol:"1",round:$round,agent_id:$agent,role:"worker",type:"result",status:$status,delta:"done",drift:null,next:"",needs:[],evidence:[{cmd:"bash test/run.sh",result:"ALL TESTS PASSED",ref:".agent-duo/logs/test.log"}]}' \
    > "$state/r${round}.json"
  rm -f "$state/report.json"
  ln -s "r${round}.json" "$state/report.json"
}

write_loop_contract() { # <agent> <max_rounds> <frozen_at_round>
  local agent="$1" max_rounds="$2" frozen="$3" state
  state="$PROJECT/.agent-duo/state/$agent"
  mkdir -p "$state"
  jq -cn \
    --arg agent "$agent" --argjson max "$max_rounds" --argjson frozen "$frozen" \
    '{protocol:"1",agent_id:$agent,mission:"m",non_goals:[],success_signals:[],validation:[],max_rounds:$max,frozen_at_round:$frozen,status:"active",stop:{on_terminal:true,reason:null,stopped_at_round:null,stopped_at:null},created_at:"2026-06-21T00:00:00Z",updated_at:"2026-06-21T00:00:00Z"}' \
    > "$state/loop.json"
}

write_loop_contract_with_validation() { # <agent> <max_rounds> <frozen_at_round> <cmd> <satisfies_json> <success_json>
  local agent="$1" max_rounds="$2" frozen="$3" cmd="$4" satisfies="$5" success="$6" state
  state="$PROJECT/.agent-duo/state/$agent"
  mkdir -p "$state"
  jq -cn \
    --arg agent "$agent" --arg cmd "$cmd" --argjson max "$max_rounds" --argjson frozen "$frozen" \
    --argjson satisfies "$satisfies" --argjson success "$success" \
    '{protocol:"1",agent_id:$agent,mission:"m",non_goals:[],success_signals:$success,validation:[{id:"go-test",cmd:$cmd,timeout_seconds:5,satisfies:$satisfies}],max_rounds:$max,frozen_at_round:$frozen,status:"active",stop:{on_terminal:true,reason:null,stopped_at_round:null,stopped_at:null},created_at:"2026-06-21T00:00:00Z",updated_at:"2026-06-21T00:00:00Z"}' \
    > "$state/loop.json"
}

write_loop_contract_with_acceptance() { # <agent> <max_rounds> <frozen_at_round> <reviews_json>
  local agent="$1" max_rounds="$2" frozen="$3" reviews="$4" state
  state="$PROJECT/.agent-duo/state/$agent"
  mkdir -p "$state"
  jq -cn \
    --arg agent "$agent" --argjson max "$max_rounds" --argjson frozen "$frozen" --argjson reviews "$reviews" \
    '{protocol:"1",agent_id:$agent,mission:"m",non_goals:[],success_signals:[],validation:[],acceptance:{reviews:$reviews},max_rounds:$max,frozen_at_round:$frozen,status:"active",stop:{on_terminal:true,reason:null,stopped_at_round:null,stopped_at:null},created_at:"2026-06-21T00:00:00Z",updated_at:"2026-06-21T00:00:00Z"}' \
    > "$state/loop.json"
}

add_acceptance_to_contract() { # <agent> <reviews_json>
  local agent="$1" reviews="$2" state tmp
  state="$PROJECT/.agent-duo/state/$agent"
  tmp="$state/.loop.json.$$"
  jq --argjson reviews "$reviews" '.acceptance = {reviews:$reviews}' "$state/loop.json" > "$tmp"
  mv "$tmp" "$state/loop.json"
}

write_review_record() { # <agent> <role> <round> <verdict>
  local agent="$1" role="$2" round="$3" verdict="$4" dir
  dir="$PROJECT/.agent-duo/state/$agent/reviews"
  mkdir -p "$dir"
  jq -cn \
    --arg verdict "$verdict" --arg role "$role" --arg target "$agent" --argjson round "$round" \
    '{verdict:$verdict,by:"reviewer",role:$role,target:$target,target_round:$round,findings:[],ts:"2026-06-21T00:00:00Z"}' \
    > "$dir/${role}-r${round}.json"
}

write_validation_result() { # <agent> <round> <status> <satisfied_json> <missing_json> <failed_json>
  local agent="$1" round="$2" status="$3" satisfied="$4" missing="$5" failed="$6" state
  state="$PROJECT/.agent-duo/state/$agent"
  mkdir -p "$state"
  jq -cn \
    --arg agent "$agent" --arg status "$status" --argjson round "$round" \
    --argjson satisfied "$satisfied" --argjson missing "$missing" --argjson failed "$failed" \
    '{protocol:"1",agent_id:$agent,round:$round,status:$status,satisfied_signals:$satisfied,missing_signals:$missing,failed_validations:$failed,results:[],created_at:"2026-06-21T00:00:00Z"}' \
    > "$state/validation-r${round}.json"
}

write_running_marker() { # <agent> <round> <pid>
  local agent="$1" round="$2" pid="$3" dir
  dir="$PROJECT/.agent-duo/state/$agent/validation-r${round}.running"
  mkdir -p "$dir"
  jq -cn --argjson pid "$pid" '{pid:$pid,started_at:"2026-06-21T00:00:00Z"}' > "$dir/pid"
}

write_validation_runner_stub() {
  VERIFY_RUNNER_LOG="$SCENARIO_TMP/validation-runner.log"
  : > "$VERIFY_RUNNER_LOG"
  VERIFY_RUNNER="$SCENARIO_TMP/validation-runner"
  cat > "$VERIFY_RUNNER" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'root=%s session=%s args=%s\n' "${AGENT_DUO_ROOT:-}" "${AGENT_SESSION:-}" "$*" >> "$VERIFY_RUNNER_LOG"
exit 0
STUB
  chmod +x "$VERIFY_RUNNER"
}

wait_for_validation_runner_log() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [[ -s "$VERIFY_RUNNER_LOG" ]] && return 0
    /bin/sleep 0.1
  done
  return 1
}

# Provider hook environments can have a minimal PATH; hook entrypoints must not
# rely on /usr/bin/env finding bash.
assert_eq "hook user submit: absolute bash shebang" \
  "$(sed -n '1p' "$ROOT/scripts/supervisor-user-prompt-submit-hook")" "#!/bin/bash"
assert_eq "hook stop: absolute bash shebang" \
  "$(sed -n '1p' "$ROOT/scripts/supervisor-stop-drain-hook")" "#!/bin/bash"
assert_not_contains "hook supervisor entrypoints: no env bash" \
  "$(cat "$ROOT/scripts/supervisor-user-prompt-submit-hook" "$ROOT/scripts/supervisor-stop-drain-hook")" '/usr/bin/env bash'

# UserPromptSubmit marks the supervisor turn busy.
setup
assert_ok "hook user submit: marks busy" run_hook bash "$ROOT/scripts/supervisor-user-prompt-submit-hook"
assert_eq "hook user submit: turn state" "$(cat "$PROJECT/.agent-duo/state/supervisor.turn")" "busy"
teardown

# Stop hook marks idle and allows the turn when the queue is empty.
setup
assert_ok "hook stop: empty queue allows" run_hook bash "$ROOT/scripts/supervisor-stop-drain-hook"
assert_eq "hook stop: marks idle" "$(cat "$PROJECT/.agent-duo/state/supervisor.turn")" "idle"
assert_eq "hook stop: no block output" "$(cat "$OUT")" ""
teardown

# Stop hook surfaces a stale loopd heartbeat once, so liveness loss is not silent.
setup
printf '%s\n' "$(( $(date +%s) - 999 ))" > "$PROJECT/.agent-duo/state/daemon.heartbeat"
assert_ok "hook stop: stale daemon blocks" run_hook bash "$ROOT/scripts/supervisor-stop-drain-hook"
assert_contains "hook stop: stale daemon decision" "$(cat "$OUT")" '"decision":"block"'
assert_contains "hook stop: stale daemon message" "$(cat "$OUT")" '运行时监控离线'
assert_ok "hook stop: stale daemon dedupes" run_hook bash "$ROOT/scripts/supervisor-stop-drain-hook"
assert_eq "hook stop: stale daemon no repeat" "$(cat "$OUT")" ""
printf '%s\n' "$(date +%s)" > "$PROJECT/.agent-duo/state/daemon.heartbeat"
assert_ok "hook stop: fresh daemon clears marker" run_hook bash "$ROOT/scripts/supervisor-stop-drain-hook"
assert_ok "hook stop: offline marker cleared" test ! -f "$PROJECT/.agent-duo/state/daemon.offline.notified"
teardown

# Stop hook treats a missing heartbeat as offline only after loopd was expected.
setup
printf '%s\n' "$(date +%s)" > "$PROJECT/.agent-duo/state/daemon.expected"
assert_ok "hook stop: missing daemon heartbeat blocks" run_hook bash "$ROOT/scripts/supervisor-stop-drain-hook"
assert_contains "hook stop: missing daemon heartbeat decision" "$(cat "$OUT")" '"decision":"block"'
assert_contains "hook stop: missing daemon heartbeat message" "$(cat "$OUT")" '运行时监控离线'
teardown

# Daemon offline is a first-class warning and preempts queued runtime events once.
setup
printf '%s\n' "$(( $(date +%s) - 999 ))" > "$PROJECT/.agent-duo/state/daemon.heartbeat"
write_event e1 worker blocked 3 "needs approval" ".agent-duo/state/worker/r3.json"
assert_ok "hook stop: stale daemon preempts queue" run_hook bash "$ROOT/scripts/supervisor-stop-drain-hook"
assert_contains "hook stop: stale daemon preempt decision" "$(cat "$OUT")" '运行时监控离线'
assert_eq "hook stop: stale daemon leaves cursor" "$(cat "$PROJECT/.agent-duo/events/cursor" 2>/dev/null || true)" ""
assert_ok "hook stop: stale daemon then drains queue" run_hook bash "$ROOT/scripts/supervisor-stop-drain-hook"
assert_contains "hook stop: queue drains after offline notice" "$(cat "$OUT")" 'id=e1 agent=worker type=blocked round=3'
assert_eq "hook stop: queue cursor advances after notice" "$(cat "$PROJECT/.agent-duo/events/cursor")" "1"
teardown

# Stop hook drains exactly one pending event, emits a block decision, and advances cursor.
setup
write_event e1 worker blocked 3 "needs approval" ".agent-duo/state/worker/r3.json"
write_event e2 reviewer result 1 "review complete" ".agent-duo/state/reviewer/r1.json"
assert_ok "hook stop: first pending blocks" run_hook bash "$ROOT/scripts/supervisor-stop-drain-hook"
assert_contains "hook stop: block decision" "$(cat "$OUT")" '"decision":"block"'
assert_contains "hook stop: event text" "$(cat "$OUT")" 'id=e1 agent=worker type=blocked round=3'
assert_eq "hook stop: cursor advanced once" "$(cat "$PROJECT/.agent-duo/events/cursor")" "1"
assert_ok "hook stop: second pending blocks" run_hook bash "$ROOT/scripts/supervisor-stop-drain-hook"
assert_contains "hook stop: second event text" "$(cat "$OUT")" 'id=e2 agent=reviewer type=result round=1'
assert_eq "hook stop: cursor advanced twice" "$(cat "$PROJECT/.agent-duo/events/cursor")" "2"
teardown

# Stop hook chooses the highest-priority pending event, not just the first line.
setup
write_event e1 worker checkpoint 1 "progress" ".agent-duo/state/worker/r1.json"
write_event e2 worker blocked 2 "needs approval" ".agent-duo/state/worker/r2.json"
assert_ok "hook stop priority: first blocks on blocked event" run_hook bash "$ROOT/scripts/supervisor-stop-drain-hook"
assert_contains "hook stop priority: blocked first" "$(cat "$OUT")" 'id=e2 agent=worker type=blocked round=2'
assert_eq "hook stop priority: cursor count one" "$(cat "$PROJECT/.agent-duo/events/cursor")" "1"
assert_ok "hook stop priority: then checkpoint" run_hook bash "$ROOT/scripts/supervisor-stop-drain-hook"
assert_contains "hook stop priority: checkpoint second" "$(cat "$OUT")" 'id=e1 agent=worker type=checkpoint round=1'
assert_eq "hook stop priority: cursor count two" "$(cat "$PROJECT/.agent-duo/events/cursor")" "2"
teardown

# Stop hook hard gate allows only when verify pass + judge clear + evidence are all true.
setup
write_result_report_with_evidence builder 2 done
write_loop_contract_with_validation builder 5 1 "printf ok" '["tests pass"]' '["tests pass"]'
add_acceptance_to_contract builder '[{"role":"reviewer","veto_on":["request_changes","reject"]}]'
write_validation_result builder 2 pass '["tests pass"]' '[]' '[]'
write_review_record builder reviewer 2 approve
assert_ok "stop-hook gate: satisfied allows" run_stop_hook builder
assert_eq "stop-hook gate: satisfied no output" "$(cat "$OUT")" ""
teardown

# Stop hook hard gate blocks a false done while budget remains and injects a continue directive.
setup
write_result_report_with_evidence builder 2 done
write_loop_contract_with_validation builder 5 1 "false" '["tests pass"]' '["tests pass"]'
write_validation_result builder 2 fail '[]' '["tests pass"]' '["smoke"]'
assert_exit_code "stop-hook gate: verify fail blocks" 2 run_stop_hook builder
assert_contains "stop-hook gate: block decision" "$(cat "$OUT")" '"decision":"block"'
assert_contains "stop-hook gate: continue directive" "$(cat "$OUT")" '继续'
assert_ok "stop-hook gate: under budget opens no gate" test ! -d "$PROJECT/.agent-duo/gates"
teardown

# Stop hook hard gate opens a human gate instead of blocking forever once budget is exhausted.
setup
write_result_report_with_evidence builder 3 done
write_loop_contract_with_validation builder 3 1 "false" '["tests pass"]' '["tests pass"]'
write_validation_result builder 3 fail '[]' '["tests pass"]' '["smoke"]'
assert_ok "stop-hook gate: exhausted opens gate" run_stop_hook builder
assert_contains "stop-hook gate: exhausted output mentions gate" "$(cat "$OUT")" '"gate"'
gate_path="$(ls "$PROJECT/.agent-duo/gates"/*.json)"
gate_json="$(cat "$gate_path")"
assert_contains "stop-hook gate: packet pending" "$gate_json" '"status":"pending"'
assert_contains "stop-hook gate: packet target" "$gate_json" '"agent_id":"builder"'
assert_contains "stop-hook gate: packet title" "$gate_json" '预算耗尽未合门'
assert_contains "stop-hook gate: decision log opened" "$(cat "$PROJECT/.agent-duo/logs/decisions.jsonl")" '"status":"opened"'
teardown

# Stop hook anti-runaway: exhausted unfinished loops escalate once instead of blocking forever.
setup
write_report builder 3 in_progress
write_loop_contract_with_validation builder 3 1 "false" '["tests pass"]' '["tests pass"]'
write_validation_result builder 3 fail '[]' '["tests pass"]' '["smoke"]'
assert_ok "stop-hook runaway: exhausted unfinished opens gate" run_stop_hook builder
assert_contains "stop-hook runaway: output mentions gate" "$(cat "$OUT")" '"gate"'
assert_not_contains "stop-hook runaway: not a block decision" "$(cat "$OUT")" '"decision":"block"'
assert_eq "stop-hook runaway: one gate opened" "$(find "$PROJECT/.agent-duo/gates" -name '*.json' | wc -l | tr -d ' ')" "1"
assert_ok "stop-hook runaway: repeat still allows" run_stop_hook builder
assert_eq "stop-hook runaway: repeat does not duplicate gate" "$(find "$PROJECT/.agent-duo/gates" -name '*.json' | wc -l | tr -d ' ')" "1"
teardown

# loopd idle-arrival injects one pending event through peer tell and shares the same cursor.
setup
printf 'idle\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_event e1 worker blocked 3 "needs approval" ".agent-duo/state/worker/r3.json"
write_event e2 reviewer result 1 "review complete" ".agent-duo/state/reviewer/r1.json"
assert_ok "loopd: idle injects first event" run_loopd_once
assert_contains "loopd: peer tell supervisor" "$(cat "$PEER_STUB_LOG")" 'tell supervisor'
assert_contains "loopd: event text sent" "$(cat "$PEER_STUB_LOG")" 'id=e1 agent=worker type=blocked round=3'
assert_eq "loopd: cursor advanced once" "$(cat "$PROJECT/.agent-duo/events/cursor")" "1"
assert_ok "loopd: stop hook gets next event" run_hook bash "$ROOT/scripts/supervisor-stop-drain-hook"
assert_contains "loopd: no duplicate after cursor" "$(cat "$OUT")" 'id=e2 agent=reviewer type=result round=1'
assert_eq "loopd: cursor advanced twice" "$(cat "$PROJECT/.agent-duo/events/cursor")" "2"
teardown

# loopd writes heartbeat and renders a compact dashboard.
setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
mkdir -p "$PROJECT/.agent-duo/state/worker"
printf '{}\n' > "$PROJECT/.agent-duo/state/worker/report.json"
write_event e1 worker checkpoint 1 "progress" ".agent-duo/state/worker/r1.json"
assert_ok "loopd: dashboard once succeeds" run_loopd_once
assert_ok "loopd: heartbeat exists" test -s "$PROJECT/.agent-duo/state/daemon.heartbeat"
assert_contains "loopd: dashboard has pending" "$(cat "$OUT")" 'pending: 1'
assert_contains "loopd: dashboard has worker" "$(cat "$OUT")" 'worker'
teardown

# loopd stays healthy when there are no workers yet.
setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%2\tloopd\tdaemon\tbash\n' > "$TMUX_STUB_REGISTRY"
assert_ok "loopd: no workers succeeds" run_loopd_once
assert_contains "loopd: no workers dashboard" "$(cat "$OUT")" '(none)'
teardown

# loop evaluator: active + rounds_used<max 保持 active,无 loop_stop,看板显示 loop 预算。
setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_report worker 1 in_progress
write_loop_contract worker 3 1
assert_ok "loop eval: under budget stays active" run_loopd_once
assert_contains "loop eval: contract still active" "$(cat "$PROJECT/.agent-duo/state/worker/loop.json")" '"status":"active"'
assert_not_contains "loop eval: no loop_stop under budget" "$(cat "$PROJECT/.agent-duo/events/queue.jsonl")" '"type":"loop_stop"'
assert_contains "loop eval: dashboard loop active" "$(cat "$OUT")" 'loop=1/3 active'
teardown

# loop evaluator:只有 loop.json 还没有 report 时不触发 silent 噪声,但看板仍显示契约。
setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_loop_contract worker 3 1
assert_ok "loop eval: no-report contract stays quiet" run_loopd_once
assert_not_contains "loop eval: no-report no silent" "$(cat "$PROJECT/.agent-duo/events/queue.jsonl")" '"type":"silent"'
assert_contains "loop eval: no-report dashboard loop" "$(cat "$OUT")" 'loop=0/3 active'
teardown

# direction_drift:worker 自报 drift 时追加高优先方向事件,同轮幂等。
setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_report_with_direction worker 1 in_progress "progress" "碰 non_goal: 不改 auth"
write_loop_contract worker 3 1
assert_ok "direction drift: emits event" run_loopd_once
queue="$(cat "$PROJECT/.agent-duo/events/queue.jsonl")"
assert_contains "direction drift: event type" "$queue" '"type":"direction_drift"'
assert_contains "direction drift: deterministic id" "$queue" '"id":"drift-worker-1"'
assert_contains "direction drift: summary" "$queue" '"summary":"direction drift: 碰 non_goal: 不改 auth"'
assert_ok "direction drift: idempotent second run" run_loopd_once
drift_count="$(grep -c '"id":"drift-worker-1"' "$PROJECT/.agent-duo/events/queue.jsonl")"
assert_eq "direction drift: still once" "$drift_count" "1"
teardown

setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_report_with_direction worker 1 in_progress "progress" ""
write_loop_contract worker 3 1
assert_ok "direction drift: null drift no event" run_loopd_once
assert_not_contains "direction drift: null suppresses" "$(cat "$PROJECT/.agent-duo/events/queue.jsonl")" '"type":"direction_drift"'
teardown

setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
long_drift=$'line1\nline2\t'
long_drift="${long_drift}$(printf '%0205d' 0 | tr '0' x)"
write_report_with_direction worker 1 in_progress "progress" "$long_drift"
write_loop_contract worker 3 1
assert_ok "direction drift: long one-line succeeds" run_loopd_once
summary="$(jq -r 'select(.type == "direction_drift") | .summary' "$PROJECT/.agent-duo/events/queue.jsonl")"
assert_contains "direction drift: newline replaced" "$summary" 'line1 line2 '
assert_not_contains "direction drift: no newline in summary" "$summary" $'\n'
assert_not_contains "direction drift: no tab in summary" "$summary" $'\t'
assert_contains "direction drift: truncated with ellipsis" "$summary" '…'
summary_chars="$(printf '%s' "$summary" | wc -m | tr -d ' ')"
assert_ok "direction drift: summary capped" test "$summary_chars" -le 218
teardown

setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_report_with_direction worker 1 in_progress "progress" "drift while stopped"
mkdir -p "$PROJECT/.agent-duo/state/worker"
jq -cn '{protocol:"1",agent_id:"worker",mission:"m",non_goals:[],success_signals:[],validation:[],max_rounds:3,frozen_at_round:1,status:"stopped",stop:{on_terminal:true,reason:"max_rounds",stopped_at_round:1,stopped_at:"2026-06-21T00:00:00Z"}}' \
  > "$PROJECT/.agent-duo/state/worker/loop.json"
assert_ok "direction drift: stopped contract skipped" run_loopd_once
assert_not_contains "direction drift: stopped no event" "$(cat "$PROJECT/.agent-duo/events/queue.jsonl")" '"type":"direction_drift"'
teardown

# detail_trap:连续 N 轮 delta 为空时追加方向事件;缺轮/非空 delta/轮次不足都保守不报。
setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_report_with_direction worker 1 in_progress "" ""
write_report_with_direction worker 2 in_progress "" ""
write_report_with_direction worker 3 in_progress "" ""
write_loop_contract worker 5 1
assert_ok "detail trap: emits event" run_loopd_once
queue="$(cat "$PROJECT/.agent-duo/events/queue.jsonl")"
assert_contains "detail trap: event type" "$queue" '"type":"detail_trap"'
assert_contains "detail trap: deterministic id" "$queue" '"id":"detailtrap-worker-3"'
assert_contains "detail trap: summary" "$queue" '"summary":"detail trap: delta empty for 3 rounds (r1-r3)"'
assert_ok "detail trap: idempotent second run" run_loopd_once
trap_count="$(grep -c '"id":"detailtrap-worker-3"' "$PROJECT/.agent-duo/events/queue.jsonl")"
assert_eq "detail trap: still once" "$trap_count" "1"
write_report_with_direction worker 4 in_progress "" ""
assert_ok "detail trap: continuing emits next round" run_loopd_once
assert_contains "detail trap: next deterministic id" "$(cat "$PROJECT/.agent-duo/events/queue.jsonl")" '"id":"detailtrap-worker-4"'
trap_count="$(grep -c '"type":"detail_trap"' "$PROJECT/.agent-duo/events/queue.jsonl")"
assert_eq "detail trap: continuing count" "$trap_count" "2"
teardown

setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_report_with_direction worker 1 in_progress "" ""
write_report_with_direction worker 2 in_progress "made progress" ""
write_report_with_direction worker 3 in_progress "" ""
write_loop_contract worker 5 1
assert_ok "detail trap: nonempty delta suppresses" run_loopd_once
assert_not_contains "detail trap: no event with progress" "$(cat "$PROJECT/.agent-duo/events/queue.jsonl")" '"type":"detail_trap"'
teardown

setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_report_with_direction worker 1 in_progress "" ""
write_report_with_direction worker 2 in_progress "" ""
write_loop_contract worker 5 1
assert_ok "detail trap: insufficient rounds suppresses" run_loopd_once
assert_not_contains "detail trap: no event before N" "$(cat "$PROJECT/.agent-duo/events/queue.jsonl")" '"type":"detail_trap"'
teardown

setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_report_with_direction worker 1 in_progress "" ""
write_report_with_direction worker 3 in_progress "" ""
write_loop_contract worker 5 1
assert_ok "detail trap: missing report suppresses" run_loopd_once
assert_not_contains "detail trap: missing window no event" "$(cat "$PROJECT/.agent-duo/events/queue.jsonl")" '"type":"detail_trap"'
teardown

# 本轮会停止 loop 时跳过 direction 检测,只保留 loop_stop。
setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_report_with_direction worker 1 failed "failed" "drift on failed"
write_loop_contract worker 5 1
assert_ok "direction stop suppress: failed" run_loopd_once
queue="$(cat "$PROJECT/.agent-duo/events/queue.jsonl")"
assert_contains "direction stop suppress: failed loop stop" "$queue" '"type":"loop_stop"'
assert_not_contains "direction stop suppress: failed no drift" "$queue" '"type":"direction_drift"'
teardown

setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_report_with_direction worker 1 done "done" "drift on done"
write_loop_contract worker 5 1
assert_ok "direction stop suppress: done" run_loopd_once
queue="$(cat "$PROJECT/.agent-duo/events/queue.jsonl")"
assert_contains "direction stop suppress: done loop stop" "$queue" 'loop stopped: done'
assert_not_contains "direction stop suppress: done no drift" "$queue" '"type":"direction_drift"'
teardown

setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_report_with_direction worker 1 in_progress "" ""
write_report_with_direction worker 2 in_progress "" ""
write_report_with_direction worker 3 in_progress "" ""
write_loop_contract worker 3 1
assert_ok "direction stop suppress: max rounds" run_loopd_once
queue="$(cat "$PROJECT/.agent-duo/events/queue.jsonl")"
assert_contains "direction stop suppress: max loop stop" "$queue" 'loop stopped: max_rounds'
assert_not_contains "direction stop suppress: max no trap" "$queue" '"type":"detail_trap"'
teardown

# loop evaluator:max_rounds 是相对预算,到界后 stopped(max_rounds) 且只追加一条 loop_stop。
setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_report worker 1 in_progress
write_loop_contract worker 1 1
assert_ok "loop eval: max rounds stops" run_loopd_once
loop_json="$(cat "$PROJECT/.agent-duo/state/worker/loop.json")"
assert_contains "loop eval: stopped status" "$loop_json" '"status":"stopped"'
assert_contains "loop eval: stopped reason max" "$loop_json" '"reason":"max_rounds"'
loop_stop_count="$(grep -c '"type":"loop_stop"' "$PROJECT/.agent-duo/events/queue.jsonl")"
assert_eq "loop eval: one loop_stop" "$loop_stop_count" "1"
assert_contains "loop eval: deterministic id" "$(cat "$PROJECT/.agent-duo/events/queue.jsonl")" '"id":"loopstop-worker-1"'
teardown

# loop evaluator:历史 report 不按绝对 round 截停。
setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_report worker 12 in_progress
write_loop_contract worker 8 12
assert_ok "loop eval: relative budget not absolute" run_loopd_once
assert_contains "loop eval: historical stays active" "$(cat "$PROJECT/.agent-duo/state/worker/loop.json")" '"status":"active"'
assert_not_contains "loop eval: historical no stop" "$(cat "$PROJECT/.agent-duo/events/queue.jsonl")" '"type":"loop_stop"'
teardown

# loop evaluator:终态 done/failed 停止,且 done 在预算最后一轮优先于 max_rounds。
setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_report worker 1 done
write_loop_contract worker 1 1
assert_ok "loop eval: done priority stops" run_loopd_once
assert_contains "loop eval: done reason wins" "$(cat "$PROJECT/.agent-duo/state/worker/loop.json")" '"reason":"done"'
teardown

# loop evaluator:acceptance 非 veto 判决在场时 done 才能停。
setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_report worker 1 done
write_loop_contract_with_acceptance worker 3 1 '[{"role":"reviewer","veto_on":["request_changes","reject"]}]'
write_review_record worker reviewer 1 approve
assert_ok "loop eval acceptance: approve stops done" run_loopd_once
assert_contains "loop eval acceptance: done after approve" "$(cat "$PROJECT/.agent-duo/state/worker/loop.json")" '"reason":"done"'
assert_contains "loop eval acceptance: dashboard ok" "$(cat "$OUT")" 'judge=reviewer:ok'
teardown

setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_report worker 1 done
write_loop_contract_with_acceptance worker 3 1 '[{"role":"reviewer","veto_on":["request_changes","reject"]}]'
assert_ok "loop eval acceptance: missing keeps active" run_loopd_once
queue_json="$(cat "$PROJECT/.agent-duo/events/queue.jsonl")"
assert_contains "loop eval acceptance: missing active" "$(cat "$PROJECT/.agent-duo/state/worker/loop.json")" '"status":"active"'
assert_contains "loop eval acceptance: pending event" "$queue_json" '"id":"reviewreq-worker-1-pending"'
assert_contains "loop eval acceptance: pending summary" "$queue_json" '"summary":"judge pending: reviewer"'
assert_contains "loop eval acceptance: dashboard pending" "$(cat "$OUT")" 'judge=reviewer:pending'
teardown

setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_report worker 1 done
write_loop_contract_with_acceptance worker 3 1 '[{"role":"reviewer","veto_on":["request_changes","reject"]}]'
write_review_record worker reviewer 1 request_changes
assert_ok "loop eval acceptance: veto keeps active" run_loopd_once
queue_json="$(cat "$PROJECT/.agent-duo/events/queue.jsonl")"
assert_contains "loop eval acceptance: veto active" "$(cat "$PROJECT/.agent-duo/state/worker/loop.json")" '"status":"active"'
assert_contains "loop eval acceptance: veto event" "$queue_json" '"id":"reviewreq-worker-1-vetoed"'
assert_contains "loop eval acceptance: veto summary" "$queue_json" '"summary":"judge vetoed: reviewer(request_changes)"'
assert_contains "loop eval acceptance: dashboard veto" "$(cat "$OUT")" 'judge=reviewer:vetoed(request_changes)'
teardown

setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_report worker 1 done
write_loop_contract_with_acceptance worker 3 1 '[{"role":"reviewer","veto_on":["request_changes"]},{"role":"evaluator","veto_on":["fail"]}]'
assert_ok "loop eval acceptance: pending first" run_loopd_once
write_review_record worker reviewer 1 request_changes
assert_ok "loop eval acceptance: veto after pending" run_loopd_once
queue_json="$(cat "$PROJECT/.agent-duo/events/queue.jsonl")"
assert_contains "loop eval acceptance: pending id present" "$queue_json" '"id":"reviewreq-worker-1-pending"'
assert_contains "loop eval acceptance: veto id present" "$queue_json" '"id":"reviewreq-worker-1-vetoed"'
pending_count="$(grep -c '"id":"reviewreq-worker-1-pending"' "$PROJECT/.agent-duo/events/queue.jsonl")"
veto_count="$(grep -c '"id":"reviewreq-worker-1-vetoed"' "$PROJECT/.agent-duo/events/queue.jsonl")"
assert_eq "loop eval acceptance: pending idempotent" "$pending_count" "1"
assert_eq "loop eval acceptance: veto idempotent" "$veto_count" "1"
teardown

setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_report worker 1 done
write_loop_contract_with_acceptance worker 3 1 '[{"role":"reviewer","veto_on":["reject"]}]'
jq '.acceptance.reviews[0].veto_on = [null]' "$PROJECT/.agent-duo/state/worker/loop.json" > "$PROJECT/.agent-duo/state/worker/.loop.json"
mv "$PROJECT/.agent-duo/state/worker/.loop.json" "$PROJECT/.agent-duo/state/worker/loop.json"
assert_ok "loop eval acceptance: bad veto config keeps active" run_loopd_once
queue_json="$(cat "$PROJECT/.agent-duo/events/queue.jsonl")"
assert_eq "loop eval acceptance: config invalid active" "$(jq -r '.status' "$PROJECT/.agent-duo/state/worker/loop.json")" "active"
assert_contains "loop eval acceptance: config invalid event" "$queue_json" '"id":"reviewreq-worker-1-configinvalid"'
assert_contains "loop eval acceptance: config invalid dashboard" "$(cat "$OUT")" 'judge=config_invalid'
teardown

setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_report worker 1 done
write_loop_contract_with_acceptance worker 3 1 '[]'
assert_ok "loop eval acceptance: empty reviews no gate" run_loopd_once
assert_contains "loop eval acceptance: empty reviews done" "$(cat "$PROJECT/.agent-duo/state/worker/loop.json")" '"reason":"done"'
teardown

# loop evaluator:validation 异步启动后,done 等待 running 结果,不阻塞 tick、不立即停止。
setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_validation_runner_stub
write_report worker 1 done
write_loop_contract_with_validation worker 3 1 "printf ok" '["tests pass"]' '["tests pass"]'
AGENT_DUO_LOOPD_BIN="$VERIFY_RUNNER" assert_ok "loop eval validation async: spawn succeeds" run_loopd_once
assert_ok "loop eval validation async: runner log appears" wait_for_validation_runner_log
assert_ok "loop eval validation async: running dir exists" test -d "$PROJECT/.agent-duo/state/worker/validation-r1.running"
assert_ok "loop eval validation async: pid file exists" test -s "$PROJECT/.agent-duo/state/worker/validation-r1.running/pid"
assert_contains "loop eval validation async: runner got root" "$(cat "$VERIFY_RUNNER_LOG")" "root=$PROJECT"
assert_contains "loop eval validation async: runner got session" "$(cat "$VERIFY_RUNNER_LOG")" 'session=agents'
assert_contains "loop eval validation async: runner args" "$(cat "$VERIFY_RUNNER_LOG")" '--run-validation worker 1'
assert_contains "loop eval validation async: loop stays active" "$(cat "$PROJECT/.agent-duo/state/worker/loop.json")" '"status":"active"'
assert_not_contains "loop eval validation async: no loop stop while running" "$(cat "$PROJECT/.agent-duo/events/queue.jsonl")" '"type":"loop_stop"'
teardown

setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_validation_runner_stub
write_report worker 1 done
write_loop_contract_with_validation worker 3 1 "printf ok" '["tests pass"]' '["tests pass"]'
write_running_marker worker 1 "$$"
AGENT_DUO_LOOPD_BIN="$VERIFY_RUNNER" assert_ok "loop eval validation async: existing running stays running" run_loopd_once
assert_eq "loop eval validation async: no respawn for running" "$(cat "$VERIFY_RUNNER_LOG")" ""
assert_contains "loop eval validation async: running keeps loop active" "$(cat "$PROJECT/.agent-duo/state/worker/loop.json")" '"status":"active"'
teardown

setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_validation_runner_stub
write_report worker 1 in_progress
write_report worker 2 done
write_loop_contract_with_validation worker 5 1 "printf ok" '["tests pass"]' '["tests pass"]'
write_running_marker worker 1 "$$"
AGENT_DUO_LOOPD_BIN="$VERIFY_RUNNER" assert_ok "loop eval validation async: one runner per agent" run_loopd_once
assert_eq "loop eval validation async: no second runner" "$(cat "$VERIFY_RUNNER_LOG")" ""
assert_ok "loop eval validation async: no r2 running dir" test ! -d "$PROJECT/.agent-duo/state/worker/validation-r2.running"
assert_contains "loop eval validation async: r2 done waits" "$(cat "$PROJECT/.agent-duo/state/worker/loop.json")" '"status":"active"'
teardown

setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_report worker 1 done
write_loop_contract_with_validation worker 3 1 "printf ok" '["tests pass"]' '["tests pass"]'
write_validation_result worker 1 pass '["tests pass"]' '[]' '[]'
assert_ok "loop eval validation: pass stops done" run_loopd_once
assert_contains "loop eval validation: event pass" "$(cat "$PROJECT/.agent-duo/events/queue.jsonl")" '"type":"validation_pass"'
assert_contains "loop eval validation: done after pass" "$(cat "$PROJECT/.agent-duo/state/worker/loop.json")" '"reason":"done"'
assert_contains "loop eval validation: dashboard shows pass" "$(cat "$OUT")" 'verify=pass'
teardown

setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_report worker 1 done
write_loop_contract_with_validation worker 3 1 "false" '["tests pass"]' '["tests pass"]'
write_validation_result worker 1 fail '[]' '[]' '["go-test"]'
assert_ok "loop eval validation: fail keeps active" run_loopd_once
assert_contains "loop eval validation: event fail" "$(cat "$PROJECT/.agent-duo/events/queue.jsonl")" '"type":"validation_fail"'
assert_contains "loop eval validation: active after fail" "$(cat "$PROJECT/.agent-duo/state/worker/loop.json")" '"status":"active"'
assert_not_contains "loop eval validation: no loop stop on failed validation" "$(cat "$PROJECT/.agent-duo/events/queue.jsonl")" '"type":"loop_stop"'
teardown

setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_report worker 1 done
write_loop_contract_with_validation worker 3 1 "true" '["lint pass"]' '["tests pass"]'
write_validation_result worker 1 fail '["lint pass"]' '["tests pass"]' '[]'
assert_ok "loop eval validation: missing success signal keeps active" run_loopd_once
validation_json="$(cat "$PROJECT/.agent-duo/state/worker/validation-r1.json")"
assert_contains "loop eval validation: missing signal" "$validation_json" '"missing_signals":["tests pass"]'
assert_contains "loop eval validation: active on missing signal" "$(cat "$PROJECT/.agent-duo/state/worker/loop.json")" '"status":"active"'
teardown

setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_report worker 1 done
write_loop_contract_with_validation worker 3 1 "printf ok" '["tests pass"]' '["tests pass"]'
write_running_marker worker 1 0
assert_ok "loop eval validation: crashed runner fails" run_loopd_once
validation_json="$(cat "$PROJECT/.agent-duo/state/worker/validation-r1.json")"
assert_contains "loop eval validation: crashed status" "$validation_json" '"status":"fail"'
assert_contains "loop eval validation: crashed id" "$validation_json" '"failed_validations":["runner-crashed"]'
assert_ok "loop eval validation: crashed marker cleared" test ! -d "$PROJECT/.agent-duo/state/worker/validation-r1.running"
assert_contains "loop eval validation: crash fail event" "$(cat "$PROJECT/.agent-duo/events/queue.jsonl")" '"type":"validation_fail"'
teardown

setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_report worker 1 done
write_loop_contract_with_validation worker 3 1 "printf ok" '["tests pass"]' '["tests pass"]'
AGENT_DUO_LOOPD_BIN="$SCENARIO_TMP/missing-loopd" assert_ok "loop eval validation: sync fallback succeeds" run_loopd_once
validation_json="$(cat "$PROJECT/.agent-duo/state/worker/validation-r1.json")"
assert_contains "loop eval validation: fallback result pass" "$validation_json" '"status":"pass"'
assert_contains "loop eval validation: fallback warning" "$(cat "$ERR")" '回退为同步执行'
assert_contains "loop eval validation: fallback done" "$(cat "$PROJECT/.agent-duo/state/worker/loop.json")" '"reason":"done"'
teardown

setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_report worker 1 in_progress
write_loop_contract_with_validation worker 3 1 "printf run >> .agent-duo/logs/worker/validation-count.log" '["go-test"]' '[]'
AGENT_DUO_LOOPD_BIN="$SCENARIO_TMP/missing-loopd" assert_ok "loop eval validation: idempotent first" run_loopd_once
AGENT_DUO_LOOPD_BIN="$SCENARIO_TMP/missing-loopd" assert_ok "loop eval validation: idempotent second" run_loopd_once
validation_event_count="$(grep -c '"id":"validation-worker-1"' "$PROJECT/.agent-duo/events/queue.jsonl")"
assert_eq "loop eval validation: event still once" "$validation_event_count" "1"
assert_eq "loop eval validation: command ran once" "$(cat "$PROJECT/.agent-duo/logs/worker/validation-count.log")" "run"
teardown

setup
MARK="$PROJECT/child-survived"
export MARK
source "$ROOT/lib/loop.sh"
ad_loop_run_validation_command "$PROJECT" '(/bin/sleep 2; printf child > "$MARK") & wait' 1 "$PROJECT/pgroup.log" 2>"$PROJECT/pgroup.err"
assert_eq "validation pgroup kill: timeout exit" "$VALIDATION_EXIT_CODE" "124"
/bin/sleep 3
assert_ok "validation pgroup kill: child did not survive" test ! -e "$MARK"
teardown

setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_report worker 1 failed
write_loop_contract worker 8 1
assert_ok "loop eval: failed stops" run_loopd_once
assert_contains "loop eval: failed reason" "$(cat "$PROJECT/.agent-duo/state/worker/loop.json")" '"reason":"failed"'
teardown

# loop evaluator:status stopped 后不重评,正常连跑两次不会重复 loop_stop。
setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_report worker 1 in_progress
write_loop_contract worker 1 1
assert_ok "loop eval: idempotent first run" run_loopd_once
assert_ok "loop eval: idempotent second run" run_loopd_once
loop_stop_count="$(grep -c '"type":"loop_stop"' "$PROJECT/.agent-duo/events/queue.jsonl")"
assert_eq "loop eval: loop_stop still once" "$loop_stop_count" "1"
teardown

# loop evaluator:崩溃重试场景,queue 已有确定性 id 但 loop.json 仍 active 时,不重复 append,只补 mv。
setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_report worker 1 in_progress
write_loop_contract worker 1 1
write_event loopstop-worker-1 worker loop_stop 1 "loop stopped: max_rounds (1/1)" ".agent-duo/state/worker/loop.json"
assert_ok "loop eval: crash retry completes stop" run_loopd_once
loop_stop_count="$(grep -c '"type":"loop_stop"' "$PROJECT/.agent-duo/events/queue.jsonl")"
assert_eq "loop eval: crash retry no duplicate" "$loop_stop_count" "1"
assert_contains "loop eval: crash retry stopped" "$(cat "$PROJECT/.agent-duo/state/worker/loop.json")" '"status":"stopped"'
teardown

# loop evaluator:event append 失败时丢弃 tmp,loop.json 保持 active,不留半 stopped。
setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_report worker 1 in_progress
write_loop_contract worker 1 1
rm -f "$PROJECT/.agent-duo/events/queue.jsonl"
mkdir -p "$PROJECT/.agent-duo/events/queue.jsonl"
assert_ok "loop eval: append failure daemon survives" run_loopd_once
assert_contains "loop eval: append failure remains active" "$(cat "$PROJECT/.agent-duo/state/worker/loop.json")" '"status":"active"'
teardown

# loop evaluator:放在 idle_arrival 前,本 tick 产生的 loop_stop 会当 tick 注入 supervisor。
setup
printf 'idle\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
write_report worker 1 in_progress
write_loop_contract worker 1 1
assert_ok "loop eval: loop_stop injected same tick" run_loopd_once
assert_contains "loop eval: peer got loop_stop" "$(cat "$PEER_STUB_LOG")" 'type=loop_stop'
assert_contains "loop eval: dashboard stopped" "$(cat "$OUT")" 'loop=1/1 stopped:max_rounds'
teardown

# loopd appends dead once when a state-backed worker pane disappears.
setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
mkdir -p "$PROJECT/.agent-duo/state/worker"
printf '{}\n' > "$PROJECT/.agent-duo/state/worker/report.json"
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%2\tloopd\tdaemon\tbash\n' > "$TMUX_STUB_REGISTRY"
assert_ok "loopd: dead event emitted" run_loopd_once
dead_count="$(grep -c '"type":"dead"' "$PROJECT/.agent-duo/events/queue.jsonl")"
assert_eq "loopd: dead once" "$dead_count" "1"
assert_ok "loopd: dead event deduped" run_loopd_once
dead_count="$(grep -c '"type":"dead"' "$PROJECT/.agent-duo/events/queue.jsonl")"
assert_eq "loopd: dead still once" "$dead_count" "1"
teardown

# loopd appends silent once when a live worker has an old report and quiet pane.
setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
mkdir -p "$PROJECT/.agent-duo/state/worker"
printf '{}\n' > "$PROJECT/.agent-duo/state/worker/report.json"
touch -t 202001010000 "$PROJECT/.agent-duo/state/worker/report.json"
LOOPD_SILENT_T=1 assert_ok "loopd: silent event emitted" run_loopd_once
silent_count="$(grep -c '"type":"silent"' "$PROJECT/.agent-duo/events/queue.jsonl")"
assert_eq "loopd: silent once" "$silent_count" "1"
LOOPD_SILENT_T=1 assert_ok "loopd: silent event deduped" run_loopd_once
silent_count="$(grep -c '"type":"silent"' "$PROJECT/.agent-duo/events/queue.jsonl")"
assert_eq "loopd: silent still once" "$silent_count" "1"
teardown

# loopd appends a time tick only when at least one worker pane is active.
setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
mkdir -p "$PROJECT/.agent-duo/state/worker"
printf '{}\n' > "$PROJECT/.agent-duo/state/worker/report.json"
touch -t 202001010000 "$PROJECT/.agent-duo/state/worker/report.json"
LOOPD_TICK_T=1 assert_ok "loopd: tick emitted with active worker" run_loopd_once
assert_contains "loopd: tick event" "$(cat "$PROJECT/.agent-duo/events/queue.jsonl")" '"type":"tick"'
teardown

# Existing tick detection must aggregate JSONL as one stream, not one max per line.
setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"
mkdir -p "$PROJECT/.agent-duo/state/worker"
printf '{}\n' > "$PROJECT/.agent-duo/state/worker/report.json"
touch -t 202001010000 "$PROJECT/.agent-duo/state/worker/report.json"
write_event e1 worker blocked 1 "blocked" ".agent-duo/state/worker/r1.json"
jq -cn '{id:"tick-future",ts:"2999-01-01T00:00:00Z",agent:"-",type:"tick",round:0,summary:"loop tick",ref:""}' \
  >> "$PROJECT/.agent-duo/events/queue.jsonl"
write_event e2 worker checkpoint 2 "progress" ".agent-duo/state/worker/r2.json"
LOOPD_TICK_T=1 assert_ok "loopd: existing tick suppresses duplicate" run_loopd_once
tick_count="$(grep -c '"type":"tick"' "$PROJECT/.agent-duo/events/queue.jsonl" || true)"
assert_eq "loopd: tick still once" "$tick_count" "1"
teardown

exit "$ADK_FAIL"
