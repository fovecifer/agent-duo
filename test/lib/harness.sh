#!/usr/bin/env bash

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HARNESS_DIR/../.." && pwd)"
source "$HARNESS_DIR/assert.sh"

make_tmp() {
  local tmp
  tmp="$(mktemp -d)" || { echo "FAIL mktemp -d failed" >&2; exit 1; }
  if [[ -z "$tmp" || ! -d "$tmp" ]]; then
    echo "FAIL mktemp -d returned an invalid path" >&2
    exit 1
  fi
  printf '%s\n' "$tmp"
}

assert_exit_code() {
  local name="$1" expected="$2"
  shift 2
  local rc=0
  if "$@"; then
    rc=0
  else
    rc="$?"
  fi
  if [[ "$rc" == "$expected" ]]; then
    printf 'ok   %s\n' "$name"
  else
    printf 'FAIL %s: exit [%s] want [%s]\n' "$name" "$rc" "$expected"
    ADK_FAIL=1
  fi
}

harness_tmp() {
  SCENARIO_TMP="$(make_tmp)"
  STUB_BIN="$SCENARIO_TMP/bin"; mkdir -p "$STUB_BIN"
  PROJECT="$SCENARIO_TMP/project"; mkdir -p "$PROJECT"
  OUT="$SCENARIO_TMP/out.txt"
  ERR="$SCENARIO_TMP/err.txt"
}

harness_install_tmux_stub() {
  cat > "$STUB_BIN/tmux" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

cmd="${1:-}"
shift || true
printf '%s %s\n' "$cmd" "$*" >> "$TMUX_STUB_LOG"

pane_from_args() {
  local pane=""
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "-t" ]]; then
      pane="${2:-}"
      break
    fi
    shift
  done
  printf '%s' "$pane"
}

registry_col() {
  local pane="$1" col="$2"
  awk -F'\t' -v p="$pane" -v c="$col" '$1 == p { print $c }' "$TMUX_STUB_REGISTRY"
}

case "$cmd" in
  has-session)
    [[ "${TMUX_STUB_HAS_SESSION:-1}" == "1" ]]
    ;;
  new-session)
    printf '%s\n' "${TMUX_STUB_NEW_SESSION_PANE:-%1}"
    ;;
  display-message)
    [[ "${TMUX_STUB_HAS_SESSION:-1}" == "1" ]] || exit 1
    [[ "${TMUX_STUB_PANE_EXISTS:-1}" == "1" ]] || exit 1
    pane="$(pane_from_args "$@")"
    if [[ "$*" == *'@agent_id'* ]]; then
      registry_col "$pane" 2
    elif [[ "$*" == *'@agent_role'* ]]; then
      registry_col "$pane" 3
    elif [[ "$*" == *'@agent_provider'* ]]; then
      registry_col "$pane" 4
    elif [[ "$*" == *'@agentduo_codec_tag'* ]]; then
      printf '%s\n' "${TMUX_STUB_CODEC_TAG:-}"
    elif [[ "$*" == *'#{pane_in_mode}'* ]]; then
      printf '0\n'
    else
      printf '%s\n' "${TMUX_STUB_PANE_SESSION:-${AGENT_SESSION:-agents}}"
    fi
    ;;
  list-panes)
    [[ "${TMUX_STUB_HAS_SESSION:-1}" == "1" ]] || exit 1
    cat "$TMUX_STUB_REGISTRY"
    ;;
  set-option)
    :
    ;;
  new-window)
    printf '%s\n' "${TMUX_STUB_NEW_PANE:-%9}"
    ;;
  kill-window)
    :
    ;;
  capture-pane)
    count_file="${TMUX_STUB_CAPTURE_COUNT:-}"
    count=0
    if [[ -n "$count_file" ]]; then
      [[ -s "$count_file" ]] && count="$(cat "$count_file")"
      count=$(( count + 1 ))
      printf '%s\n' "$count" > "$count_file"
    fi
    case "${TMUX_STUB_CAPTURE_MODE:-stable}" in
      prompt)
        printf 'Do you want to proceed?\n'
        printf '  1. Yes\n'
        printf '  2. No\n'
        printf '❯ Yes\n'
        ;;
      normal_prompt)
        printf 'Review complete: no issues found.\n'
        printf '❯ \n'
        ;;
      sentinel)
        printf 'prior output\n'
        printf '%s\n' "$TMUX_STUB_SENTINEL"
        ;;
      changing)
        printf '%s-%s\n' "${TMUX_STUB_CAPTURE_CHANGING_PREFIX:-screen}" "$count"
        ;;
      *)
        printf '%s\n' "${TMUX_STUB_CAPTURE_TEXT:-stable-screen}"
        ;;
    esac
    ;;
  load-buffer)
    buf=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -b) buf="${2:-}"; shift 2 ;;
        -) shift ;;
        *) shift ;;
      esac
    done
    [[ -n "$buf" ]] || exit 1
    cat > "$TMUX_STUB_BUFFER_DIR/$buf"
    ;;
  paste-buffer|send-keys)
    if [[ "$cmd" == "send-keys" && -n "${TMUX_STUB_ON_SEND_REPORT_AGENT:-}" ]]; then
      root="${TMUX_STUB_ON_SEND_REPORT_ROOT:-}"
      agent="${TMUX_STUB_ON_SEND_REPORT_AGENT}"
      round="${TMUX_STUB_ON_SEND_REPORT_ROUND:-1}"
      status="${TMUX_STUB_ON_SEND_REPORT_STATUS:-in_progress}"
      delta="${TMUX_STUB_ON_SEND_REPORT_DELTA:-ask answered}"
      next="${TMUX_STUB_ON_SEND_REPORT_NEXT:-continue}"
      if [[ -n "$root" ]]; then
        state="$root/.agent-duo/state/$agent"
        mkdir -p "$state"
        jq -cn \
          --argjson round "$round" --arg agent "$agent" --arg status "$status" \
          --arg delta "$delta" --arg next "$next" \
          '{protocol:"1",round:$round,agent_id:$agent,role:"worker",type:"checkpoint",status:$status,goal_ref:null,step_ref:null,delta:$delta,drift:null,evidence:[],needs:[],next:$next}' \
          > "$state/r${round}.json"
        rm -f "$state/report.json"
        ln -s "r${round}.json" "$state/report.json"
      fi
    fi
    ;;
  *)
    exit 1
    ;;
esac
STUB
  chmod +x "$STUB_BIN/tmux"
}

harness_install_sleep_stub() {
  cat > "$STUB_BIN/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$STUB_BIN/sleep"
}

harness_install_peer_stub() {
  cat > "$STUB_BIN/peer" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PEER_STUB_LOG"
exit 0
STUB
  chmod +x "$STUB_BIN/peer"
}

harness_install_provider_stubs() {
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/claude"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/codex"
  chmod +x "$STUB_BIN/claude" "$STUB_BIN/codex"
}

harness_install_validation_stub() {
  VERIFY_STUB="$SCENARIO_TMP/loopd-validation-stub"
  cat > "$VERIFY_STUB" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != "--run-validation" || -z "${2:-}" || -z "${3:-}" ]]; then
  exit 2
fi
agent="$2"
round="$3"
root="${AGENT_DUO_ROOT:?}"
out="$root/.agent-duo/state/$agent/validation-r${round}.json"
mkdir -p "$(dirname "$out")" "$root/.agent-duo/logs/$agent"
printf '%s\t%s\n' "$agent" "$round" >> "$VERIFY_STUB_LOG"

case ",${VERIFY_FAIL_AGENTS:-}," in
  *,"$agent",*)
    jq -cn --arg agent "$agent" --argjson round "$round" '
      {
        protocol:"1",
        agent_id:$agent,
        round:$round,
        status:"fail",
        satisfied_signals:[],
        missing_signals:["tests pass"],
        failed_validations:["validate"],
        results:[{
          id:"validate",
          cmd:"stub validation",
          status:"fail",
          exit_code:1,
          timed_out:false,
          duration_seconds:0,
          log_ref:null,
          satisfies:["tests pass"]
        }],
        created_at:"2026-06-22T00:00:00Z"
      }
    ' > "$out"
    ;;
  *)
    jq -cn --arg agent "$agent" --argjson round "$round" '
      {
        protocol:"1",
        agent_id:$agent,
        round:$round,
        status:"pass",
        satisfied_signals:["tests pass"],
        missing_signals:[],
        failed_validations:[],
        results:[{
          id:"validate",
          cmd:"stub validation",
          status:"pass",
          exit_code:0,
          timed_out:false,
          duration_seconds:0,
          log_ref:null,
          satisfies:["tests pass"]
        }],
        created_at:"2026-06-22T00:00:00Z"
      }
    ' > "$out"
    ;;
esac
STUB
  chmod +x "$VERIFY_STUB"
}

harness_write_registry() {
  : > "$TMUX_STUB_REGISTRY"
  if [[ "$#" -eq 0 ]]; then
    printf '%%1\tsupervisor\tsupervisor\tclaude\n%%2\tworker\tworker\tcodex\n' > "$TMUX_STUB_REGISTRY"
    return 0
  fi
  printf '%s\n' "$@" > "$TMUX_STUB_REGISTRY"
}

cli_setup() {
  harness_tmp
  TMUX_STUB_LOG="$SCENARIO_TMP/tmux.log"; : > "$TMUX_STUB_LOG"
  TMUX_STUB_BUFFER_DIR="$SCENARIO_TMP/buffers"; mkdir -p "$TMUX_STUB_BUFFER_DIR"
  TMUX_STUB_CAPTURE_COUNT="$SCENARIO_TMP/capture-count"; : > "$TMUX_STUB_CAPTURE_COUNT"
  TMUX_STUB_REGISTRY="$SCENARIO_TMP/registry.tsv"
  TMUX_STUB_CAPTURE_TEXT="screen-stable"
  TMUX_STUB_CAPTURE_CHANGING_PREFIX="screen"
  harness_write_registry
  harness_install_tmux_stub
  harness_install_sleep_stub
}

setup() { cli_setup; }

integration_setup() {
  harness_tmp
  mkdir -p "$PROJECT/.agent-duo/events" "$PROJECT/.agent-duo/state"
  TMUX_STUB_LOG="$SCENARIO_TMP/tmux.log"; : > "$TMUX_STUB_LOG"
  TMUX_STUB_BUFFER_DIR="$SCENARIO_TMP/buffers"; mkdir -p "$TMUX_STUB_BUFFER_DIR"
  TMUX_STUB_CAPTURE_COUNT="$SCENARIO_TMP/capture-count"; : > "$TMUX_STUB_CAPTURE_COUNT"
  TMUX_STUB_REGISTRY="$SCENARIO_TMP/registry.tsv"
  TMUX_STUB_CODEC_TAG="7f3a"
  TMUX_STUB_CAPTURE_TEXT="stable-screen"
  TMUX_STUB_CAPTURE_CHANGING_PREFIX="changing"
  VERIFY_STUB_LOG="$SCENARIO_TMP/validation.log"; : > "$VERIFY_STUB_LOG"
  QUEUE="$PROJECT/.agent-duo/events/queue.jsonl"
  harness_write_registry \
    $'%1\tsupervisor\tsupervisor\tclaude' \
    $'%2\tloopd\tdaemon\tbash' \
    $'%3\tworker\tworker\tcodex' \
    $'%4\thelper\tworker\tcodex' \
    $'%5\treviewer\treviewer\tclaude'
  harness_install_tmux_stub
  harness_install_sleep_stub
  harness_install_validation_stub
}

loop_setup() {
  harness_tmp
  mkdir -p "$PROJECT/.agent-duo/events" "$PROJECT/.agent-duo/state"
  TMUX_STUB_LOG="$SCENARIO_TMP/tmux.log"; : > "$TMUX_STUB_LOG"
  PEER_STUB_LOG="$SCENARIO_TMP/peer.log"; : > "$PEER_STUB_LOG"
  TMUX_STUB_BUFFER_DIR="$SCENARIO_TMP/buffers"; mkdir -p "$TMUX_STUB_BUFFER_DIR"
  TMUX_STUB_CAPTURE_COUNT="$SCENARIO_TMP/capture-count"; : > "$TMUX_STUB_CAPTURE_COUNT"
  TMUX_STUB_REGISTRY="$SCENARIO_TMP/registry.tsv"
  TMUX_STUB_CAPTURE_TEXT="stable-screen"
  TMUX_STUB_CAPTURE_CHANGING_PREFIX="changing"
  harness_write_registry \
    $'%1\tsupervisor\tsupervisor\tclaude' \
    $'%2\tloopd\tdaemon\tbash' \
    $'%3\tworker\tworker\tcodex'
  harness_install_tmux_stub
  harness_install_peer_stub
  harness_install_sleep_stub
}

start_setup() {
  harness_tmp
  SENDLOG="$SCENARIO_TMP/sendkeys.log"; : > "$SENDLOG"
  TMUX_STUB_LOG="$SENDLOG"
  TMUX_STUB_BUFFER_DIR="$SCENARIO_TMP/buffers"; mkdir -p "$TMUX_STUB_BUFFER_DIR"
  TMUX_STUB_CAPTURE_COUNT="$SCENARIO_TMP/capture-count"; : > "$TMUX_STUB_CAPTURE_COUNT"
  TMUX_STUB_REGISTRY="$SCENARIO_TMP/registry.tsv"
  TMUX_STUB_HAS_SESSION=0
  TMUX_STUB_NEW_SESSION_PANE="%1"
  TMUX_STUB_NEW_PANE="%2"
  harness_write_registry
  export TMUX_STUB_LOG TMUX_STUB_BUFFER_DIR TMUX_STUB_CAPTURE_COUNT TMUX_STUB_REGISTRY
  export TMUX_STUB_HAS_SESSION TMUX_STUB_NEW_SESSION_PANE TMUX_STUB_NEW_PANE
  harness_install_tmux_stub
  harness_install_provider_stubs
}

unit_setup() {
  harness_tmp
}

teardown() {
  if [[ -n "${SCENARIO_TMP:-}" && -d "$SCENARIO_TMP" && "$SCENARIO_TMP" != "/" ]]; then
    rm -rf "$SCENARIO_TMP"
  fi
  unset TEST_PATH
}

init_git_project() {
  git -C "$PROJECT" init -q
  printf 'hello\n' > "$PROJECT/README.md"
  git -C "$PROJECT" add README.md
  git -C "$PROJECT" -c user.name='Agent Duo Test' -c user.email='agent-duo@example.invalid' commit -m init -q
}

run_peer() {
  : > "$OUT"
  : > "$ERR"
  : > "$TMUX_STUB_LOG"
  PATH="$STUB_BIN:$PATH" \
    AGENT_NAME="${TEST_AGENT_NAME:-claude}" \
    AGENT_SESSION="${TEST_AGENT_SESSION:-agents}" \
    AGENT_CLAUDE_PANE="${TEST_CLAUDE_PANE-%1}" \
    AGENT_CODEX_PANE="${TEST_CODEX_PANE-%2}" \
    TMUX_PANE="${TEST_TMUX_PANE:-%1}" \
    TMUX_STUB_REGISTRY="$TMUX_STUB_REGISTRY" \
    TMUX_STUB_NEW_SESSION_PANE="${TMUX_STUB_NEW_SESSION_PANE:-%1}" \
    TMUX_STUB_NEW_PANE="${TMUX_STUB_NEW_PANE:-%9}" \
    TMUX_STUB_LOG="$TMUX_STUB_LOG" \
    TMUX_STUB_BUFFER_DIR="$TMUX_STUB_BUFFER_DIR" \
    TMUX_STUB_CAPTURE_COUNT="$TMUX_STUB_CAPTURE_COUNT" \
    TMUX_STUB_CAPTURE_TEXT="${TMUX_STUB_CAPTURE_TEXT:-stable-screen}" \
    TMUX_STUB_CAPTURE_CHANGING_PREFIX="${TMUX_STUB_CAPTURE_CHANGING_PREFIX:-screen}" \
    TMUX_STUB_CAPTURE_MODE="${TMUX_STUB_CAPTURE_MODE:-stable}" \
    TMUX_STUB_SENTINEL="${TMUX_STUB_SENTINEL:-}" \
    TMUX_STUB_CODEC_TAG="${TMUX_STUB_CODEC_TAG:-}" \
    TMUX_STUB_ON_SEND_REPORT_ROOT="${TMUX_STUB_ON_SEND_REPORT_ROOT:-}" \
    TMUX_STUB_ON_SEND_REPORT_AGENT="${TMUX_STUB_ON_SEND_REPORT_AGENT:-}" \
    TMUX_STUB_ON_SEND_REPORT_ROUND="${TMUX_STUB_ON_SEND_REPORT_ROUND:-}" \
    TMUX_STUB_ON_SEND_REPORT_STATUS="${TMUX_STUB_ON_SEND_REPORT_STATUS:-}" \
    TMUX_STUB_ON_SEND_REPORT_DELTA="${TMUX_STUB_ON_SEND_REPORT_DELTA:-}" \
    TMUX_STUB_ON_SEND_REPORT_NEXT="${TMUX_STUB_ON_SEND_REPORT_NEXT:-}" \
    PEER_FORCE="${TEST_PEER_FORCE:-0}" \
    AGENT_DUO_NO_BROKER_GATE="${AGENT_DUO_NO_BROKER_GATE:-0}" \
    AGENT_DUO_ROOT="${TEST_AGENT_DUO_ROOT:-$PROJECT}" \
    AGENT_DUO_WORKTREES_DIR="${TEST_AGENT_DUO_WORKTREES_DIR:-${AGENT_DUO_WORKTREES_DIR:-}}" \
    TMUX_STUB_HAS_SESSION="${TMUX_STUB_HAS_SESSION:-1}" \
    TMUX_STUB_PANE_EXISTS="${TMUX_STUB_PANE_EXISTS:-1}" \
    TMUX_STUB_PANE_SESSION="${TMUX_STUB_PANE_SESSION:-${TEST_AGENT_SESSION:-agents}}" \
    "$ROOT/bin/peer" "$@" >"$OUT" 2>"$ERR"
}

run_peer_without_agent() {
  : > "$OUT"
  : > "$ERR"
  (
    unset AGENT_NAME AGENT_CLAUDE_PANE AGENT_CODEX_PANE TMUX_PANE
    PATH="$STUB_BIN:$PATH" \
      AGENT_SESSION="${TEST_AGENT_SESSION:-agents}" \
      TMUX_STUB_REGISTRY="$TMUX_STUB_REGISTRY" \
      TMUX_STUB_LOG="$TMUX_STUB_LOG" \
      TMUX_STUB_BUFFER_DIR="$TMUX_STUB_BUFFER_DIR" \
      TMUX_STUB_CAPTURE_COUNT="$TMUX_STUB_CAPTURE_COUNT" \
      TMUX_STUB_CAPTURE_TEXT="${TMUX_STUB_CAPTURE_TEXT:-stable-screen}" \
      TMUX_STUB_HAS_SESSION="${TMUX_STUB_HAS_SESSION:-1}" \
      "$ROOT/bin/peer" "$@" >"$OUT" 2>"$ERR"
  )
}

run_peer_as() {
  local pane="$1"
  shift
  : > "$OUT"; : > "$ERR"; : > "$TMUX_STUB_LOG"
  PATH="$STUB_BIN:$PATH" \
    AGENT_SESSION=agents \
    AGENT_DUO_ROOT="$PROJECT" \
    AGENT_NAME=supervisor \
    TMUX_PANE="$pane" \
    TMUX_STUB_REGISTRY="$TMUX_STUB_REGISTRY" \
    TMUX_STUB_LOG="$TMUX_STUB_LOG" \
    TMUX_STUB_BUFFER_DIR="$TMUX_STUB_BUFFER_DIR" \
    TMUX_STUB_CAPTURE_COUNT="$TMUX_STUB_CAPTURE_COUNT" \
    TMUX_STUB_CAPTURE_TEXT="${TMUX_STUB_CAPTURE_TEXT:-stable-screen}" \
    TMUX_STUB_CODEC_TAG="${TMUX_STUB_CODEC_TAG:-7f3a}" \
    "$ROOT/bin/peer" "$@" >"$OUT" 2>"$ERR"
}

run_hook() {
  : > "$OUT"; : > "$ERR"
  PATH="$STUB_BIN:$PATH" AGENT_DUO_ROOT="$PROJECT" "$@" >"$OUT" 2>"$ERR"
}

run_loopd_once() {
  : > "$OUT"; : > "$ERR"; : > "$TMUX_STUB_LOG"
  [[ -n "${PEER_STUB_LOG:-}" ]] && : > "$PEER_STUB_LOG"
  TMUX_STUB_CAPTURE_COUNT="$SCENARIO_TMP/capture-count"; : > "$TMUX_STUB_CAPTURE_COUNT"
  PATH="$STUB_BIN:$PATH" \
    AGENT_DUO_ROOT="$PROJECT" \
    AGENT_SESSION=agents \
    AGENT_DUO_LOOPD_BIN="${AGENT_DUO_LOOPD_BIN:-${VERIFY_STUB:-}}" \
    VERIFY_STUB_LOG="${VERIFY_STUB_LOG:-}" \
    VERIFY_FAIL_AGENTS="${VERIFY_FAIL_AGENTS:-helper}" \
    VERIFY_RUNNER_LOG="${VERIFY_RUNNER_LOG:-}" \
    LOOPD_ONCE=1 \
    LOOPD_QUIET_SAMPLE="${LOOPD_QUIET_SAMPLE:-0}" \
    LOOPD_SILENT_T="${LOOPD_SILENT_T:-999999}" \
    LOOPD_TICK_T="${LOOPD_TICK_T:-999999}" \
    TMUX_STUB_REGISTRY="$TMUX_STUB_REGISTRY" \
    TMUX_STUB_LOG="$TMUX_STUB_LOG" \
    TMUX_STUB_BUFFER_DIR="$TMUX_STUB_BUFFER_DIR" \
    TMUX_STUB_CAPTURE_MODE="${TMUX_STUB_CAPTURE_MODE:-stable}" \
    TMUX_STUB_CAPTURE_TEXT="${TMUX_STUB_CAPTURE_TEXT:-stable-screen}" \
    TMUX_STUB_CAPTURE_CHANGING_PREFIX="${TMUX_STUB_CAPTURE_CHANGING_PREFIX:-changing}" \
    TMUX_STUB_CAPTURE_COUNT="$TMUX_STUB_CAPTURE_COUNT" \
    PEER_STUB_LOG="${PEER_STUB_LOG:-}" \
    bash "$ROOT/scripts/loopd" --once >"$OUT" 2>"$ERR"
}

mark_broker_ready() {
  mkdir -p "$PROJECT/.agent-duo/state/$1"
  printf '{"agent":"%s","status":"ready","updated_epoch":%s,"nonce":"n1"}\n' "$1" "$(date +%s)" \
    > "$PROJECT/.agent-duo/state/$1/broker.json"
}
