#!/usr/bin/env bash
# test/loop.test.sh — loop runtime / hook behavior with tmux and peer stubs.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
source "$DIR/assert.sh"

make_tmp() {
  local tmp
  tmp="$(mktemp -d)" || { echo "FAIL mktemp -d failed" >&2; exit 1; }
  if [[ -z "$tmp" || ! -d "$tmp" ]]; then
    echo "FAIL mktemp -d returned an invalid path" >&2
    exit 1
  fi
  printf '%s\n' "$tmp"
}

setup() {
  SCENARIO_TMP="$(make_tmp)"
  PROJECT="$SCENARIO_TMP/project"; mkdir -p "$PROJECT/.agent-duo/events" "$PROJECT/.agent-duo/state"
  STUB_BIN="$SCENARIO_TMP/bin"; mkdir -p "$STUB_BIN"
  TMUX_STUB_LOG="$SCENARIO_TMP/tmux.log"; : > "$TMUX_STUB_LOG"
  PEER_STUB_LOG="$SCENARIO_TMP/peer.log"; : > "$PEER_STUB_LOG"
  OUT="$SCENARIO_TMP/out.txt"
  ERR="$SCENARIO_TMP/err.txt"
  TMUX_STUB_REGISTRY="$SCENARIO_TMP/registry.tsv"
  printf '%%1\tsupervisor\tsupervisor\tclaude\n%%2\tloopd\tdaemon\tbash\n%%3\tworker\tworker\tcodex\n' > "$TMUX_STUB_REGISTRY"

  cat > "$STUB_BIN/tmux" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
shift || true
printf '%s %s\n' "$cmd" "$*" >> "$TMUX_STUB_LOG"
case "$cmd" in
  has-session)
    exit 0
    ;;
  list-panes)
    cat "$TMUX_STUB_REGISTRY"
    ;;
  capture-pane)
    count_file="${TMUX_STUB_CAPTURE_COUNT:-}"
    if [[ -n "$count_file" ]]; then
      count=0
      [[ -s "$count_file" ]] && count="$(cat "$count_file")"
      count=$(( count + 1 ))
      printf '%s\n' "$count" > "$count_file"
    fi
    case "${TMUX_STUB_CAPTURE_MODE:-stable}" in
      changing)
        printf 'changing-%s\n' "$(cat "$count_file")"
        ;;
      *)
        printf 'stable-screen\n'
        ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac
STUB
  chmod +x "$STUB_BIN/tmux"

  cat > "$STUB_BIN/peer" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PEER_STUB_LOG"
exit 0
STUB
  chmod +x "$STUB_BIN/peer"

  cat > "$STUB_BIN/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$STUB_BIN/sleep"
}

teardown() {
  if [[ -n "${SCENARIO_TMP:-}" && -d "$SCENARIO_TMP" && "$SCENARIO_TMP" != "/" ]]; then
    rm -rf "$SCENARIO_TMP"
  fi
}

write_event() { # <id> <agent> <type> <round> <summary> <ref>
  jq -cn \
    --arg id "$1" --arg agent "$2" --arg type "$3" --arg summary "$5" --arg ref "$6" \
    --argjson round "$4" \
    '{id:$id,ts:"2026-06-17T00:00:00Z",agent:$agent,type:$type,round:$round,summary:$summary,ref:$ref}' \
    >> "$PROJECT/.agent-duo/events/queue.jsonl"
}

run_hook() {
  : > "$OUT"; : > "$ERR"
  PATH="$STUB_BIN:$PATH" AGENT_DUO_ROOT="$PROJECT" "$@" >"$OUT" 2>"$ERR"
}

run_loopd_once() {
  : > "$OUT"; : > "$ERR"; : > "$PEER_STUB_LOG"; : > "$TMUX_STUB_LOG"
  TMUX_STUB_CAPTURE_COUNT="$SCENARIO_TMP/capture-count"; : > "$TMUX_STUB_CAPTURE_COUNT"
  PATH="$STUB_BIN:$PATH" \
    AGENT_DUO_ROOT="$PROJECT" \
    AGENT_SESSION=agents \
    LOOPD_ONCE=1 \
    LOOPD_QUIET_SAMPLE="${LOOPD_QUIET_SAMPLE:-0}" \
    LOOPD_SILENT_T="${LOOPD_SILENT_T:-999999}" \
    LOOPD_TICK_T="${LOOPD_TICK_T:-999999}" \
    TMUX_STUB_REGISTRY="$TMUX_STUB_REGISTRY" \
    TMUX_STUB_LOG="$TMUX_STUB_LOG" \
    TMUX_STUB_CAPTURE_MODE="${TMUX_STUB_CAPTURE_MODE:-stable}" \
    TMUX_STUB_CAPTURE_COUNT="$TMUX_STUB_CAPTURE_COUNT" \
    PEER_STUB_LOG="$PEER_STUB_LOG" \
    bash "$ROOT/scripts/loopd" --once >"$OUT" 2>"$ERR"
}

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
