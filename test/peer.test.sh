#!/usr/bin/env bash
# test/peer.test.sh — bin/peer 的 tmux-stub 覆盖测试
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

setup() {
  SCENARIO_TMP="$(make_tmp)"
  STUB_BIN="$SCENARIO_TMP/bin"; mkdir -p "$STUB_BIN"
  TMUX_STUB_LOG="$SCENARIO_TMP/tmux.log"; : > "$TMUX_STUB_LOG"
  TMUX_STUB_BUFFER_DIR="$SCENARIO_TMP/buffers"; mkdir -p "$TMUX_STUB_BUFFER_DIR"
  TMUX_STUB_CAPTURE_COUNT="$SCENARIO_TMP/capture-count"; : > "$TMUX_STUB_CAPTURE_COUNT"
  OUT="$SCENARIO_TMP/out.txt"
  ERR="$SCENARIO_TMP/err.txt"

  cat > "$STUB_BIN/tmux" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

cmd="${1:-}"
shift || true
printf '%s %s\n' "$cmd" "$*" >> "$TMUX_STUB_LOG"

case "$cmd" in
  has-session)
    [[ "${TMUX_STUB_HAS_SESSION:-1}" == "1" ]]
    ;;
  display-message)
    [[ "${TMUX_STUB_HAS_SESSION:-1}" == "1" ]] || exit 1
    [[ "${TMUX_STUB_PANE_EXISTS:-1}" == "1" ]] || exit 1
    printf '%s\n' "${TMUX_STUB_PANE_SESSION:-${AGENT_SESSION:-agents}}"
    ;;
  list-windows)
    [[ "${TMUX_STUB_HAS_SESSION:-1}" == "1" ]] || exit 1
    if [[ "$*" == *'#{window_name}'* ]]; then
      printf 'claude\ncodex\n'
    else
      printf '窗口: claude  pane:%%1  尺寸:100x30\n'
      printf '窗口: codex  pane:%%2  尺寸:100x30\n'
    fi
    ;;
  capture-pane)
    count=0
    if [[ -s "$TMUX_STUB_CAPTURE_COUNT" ]]; then
      count="$(cat "$TMUX_STUB_CAPTURE_COUNT")"
    fi
    count=$(( count + 1 ))
    printf '%s\n' "$count" > "$TMUX_STUB_CAPTURE_COUNT"
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
      changing) printf 'screen-%s\n' "$count" ;;
      *)        printf 'screen-stable\n' ;;
    esac
    ;;
  load-buffer)
    buf=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -b) buf="$2"; shift 2 ;;
        -) shift ;;
        *) shift ;;
      esac
    done
    [[ -n "$buf" ]] || exit 1
    cat > "$TMUX_STUB_BUFFER_DIR/$buf"
    ;;
  paste-buffer|send-keys)
    ;;
  *)
    exit 1
    ;;
esac
STUB
  chmod +x "$STUB_BIN/tmux"

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

run_peer() {
  : > "$OUT"
  : > "$ERR"
  : > "$TMUX_STUB_LOG"
  PATH="$STUB_BIN:$PATH" \
    AGENT_NAME="${TEST_AGENT_NAME:-claude}" \
    AGENT_SESSION="${TEST_AGENT_SESSION:-agents}" \
    AGENT_CLAUDE_PANE="${TEST_CLAUDE_PANE-%1}" \
    AGENT_CODEX_PANE="${TEST_CODEX_PANE-%2}" \
    TMUX_STUB_LOG="$TMUX_STUB_LOG" \
    TMUX_STUB_BUFFER_DIR="$TMUX_STUB_BUFFER_DIR" \
    TMUX_STUB_CAPTURE_COUNT="$TMUX_STUB_CAPTURE_COUNT" \
    TMUX_STUB_CAPTURE_MODE="${TMUX_STUB_CAPTURE_MODE:-stable}" \
    PEER_FORCE="${TEST_PEER_FORCE:-0}" \
    TMUX_STUB_HAS_SESSION="${TMUX_STUB_HAS_SESSION:-1}" \
    TMUX_STUB_PANE_EXISTS="${TMUX_STUB_PANE_EXISTS:-1}" \
    TMUX_STUB_PANE_SESSION="${TMUX_STUB_PANE_SESSION:-${TEST_AGENT_SESSION:-agents}}" \
    "$ROOT/bin/peer" "$@" >"$OUT" 2>"$ERR"
}

run_peer_without_agent() {
  : > "$OUT"
  : > "$ERR"
  (
    unset AGENT_NAME AGENT_CLAUDE_PANE AGENT_CODEX_PANE
    PATH="$STUB_BIN:$PATH" \
      AGENT_SESSION="${TEST_AGENT_SESSION:-agents}" \
      TMUX_STUB_LOG="$TMUX_STUB_LOG" \
      TMUX_STUB_BUFFER_DIR="$TMUX_STUB_BUFFER_DIR" \
      TMUX_STUB_CAPTURE_COUNT="$TMUX_STUB_CAPTURE_COUNT" \
      "$ROOT/bin/peer" "$@" >"$OUT" 2>"$ERR"
  )
}

# status:命令分发与 pane ID 目标展示。
setup
assert_ok "status: succeeds" run_peer status
assert_contains "status: prints identity" "$(cat "$OUT")" '我是: claude'
assert_contains "status: prints pane target" "$(cat "$OUT")" '目标: %2'
assert_contains "status: lists windows" "$(cat "$TMUX_STUB_LOG")" 'list-windows -t agents'
teardown

# peek:使用 pane ID 捕获指定行数。
setup
assert_ok "peek: succeeds" run_peer peek 12
assert_contains "peek: output header" "$(cat "$OUT")" '===== [codex] 终端最近输出 ====='
assert_contains "peek: captures pane" "$(cat "$TMUX_STUB_LOG")" 'capture-pane -p -J -t %2 -S -12'
teardown

# peek:没有 pane ID 时回退到窗口名定位。
setup
TEST_CODEX_PANE="" assert_ok "peek: fallback target succeeds" run_peer peek 5
assert_contains "peek: fallback checks window name" "$(cat "$TMUX_STUB_LOG")" 'list-windows -t agents -F #{window_name}'
assert_contains "peek: fallback captures window" "$(cat "$TMUX_STUB_LOG")" 'capture-pane -p -J -t agents:codex -S -5'
teardown

# tell:单行参数走 tmux buffer + bracketed paste + Enter。
setup
assert_ok "tell: arg succeeds" run_peer tell "hello" "codex"
assert_eq "tell: arg buffer content" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-claude2codex")" "hello codex"
assert_contains "tell: load-buffer called" "$(cat "$TMUX_STUB_LOG")" 'load-buffer -b peer-claude2codex -'
assert_contains "tell: paste-buffer called" "$(cat "$TMUX_STUB_LOG")" 'paste-buffer -b peer-claude2codex -t %2 -d -p'
assert_contains "tell: enter sent" "$(cat "$TMUX_STUB_LOG")" 'send-keys -t %2 Enter'
teardown

# tell:普通 TUI 输入提示符和普通 no/yes 文本不应被误判为权限弹窗。
setup
TMUX_STUB_CAPTURE_MODE=normal_prompt assert_ok "tell: normal prompt screen succeeds" run_peer tell "ordinary"
assert_eq "tell: normal prompt buffer content" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-claude2codex")" "ordinary"
assert_contains "tell: normal prompt enter" "$(cat "$TMUX_STUB_LOG")" 'send-keys -t %2 Enter'
teardown

# tell:对方疑似权限弹窗时拒绝发送,不写 buffer、不粘贴、不回车。
setup
TMUX_STUB_CAPTURE_MODE=prompt assert_exit_code "tell: prompt screen exits 3" 3 run_peer tell "danger"
assert_contains "tell: prompt error" "$(cat "$ERR")" '疑似正在等待权限确认'
assert_ok "tell: prompt no buffer" test ! -e "$TMUX_STUB_BUFFER_DIR/peer-claude2codex"
assert_not_contains "tell: prompt no paste" "$(cat "$TMUX_STUB_LOG")" 'paste-buffer'
assert_not_contains "tell: prompt no enter" "$(cat "$TMUX_STUB_LOG")" 'send-keys -t %2 Enter'
teardown

# tell:--force 跳过弹窗检测并按原流程发送。
setup
TMUX_STUB_CAPTURE_MODE=prompt assert_ok "tell: force sends despite prompt" run_peer tell --force "forced"
assert_eq "tell: force buffer content" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-claude2codex")" "forced"
assert_contains "tell: force notice" "$(cat "$ERR")" '已跳过对方权限弹窗检测'
assert_contains "tell: force paste" "$(cat "$TMUX_STUB_LOG")" 'paste-buffer -b peer-claude2codex -t %2 -d -p'
assert_contains "tell: force enter" "$(cat "$TMUX_STUB_LOG")" 'send-keys -t %2 Enter'
teardown

# tell:stdin 多行保持原文进入 buffer。
setup
assert_ok "tell: stdin succeeds" run_peer tell <<< $'line 1\n`quoted`'
printf 'line 1\n`quoted`\n' > "$SCENARIO_TMP/expected-stdin-buffer"
assert_ok "tell: stdin buffer content" cmp -s "$SCENARIO_TMP/expected-stdin-buffer" "$TMUX_STUB_BUFFER_DIR/peer-claude2codex"
teardown

# esc:向目标 pane 发送 Escape。
setup
assert_ok "esc: succeeds" run_peer esc
assert_contains "esc: escape sent" "$(cat "$TMUX_STUB_LOG")" 'send-keys -t %2 Escape'
teardown

# esc:对方疑似权限弹窗时拒绝发送 Escape。
setup
TMUX_STUB_CAPTURE_MODE=prompt assert_exit_code "esc: prompt screen exits 3" 3 run_peer esc
assert_contains "esc: prompt error" "$(cat "$ERR")" '疑似正在等待权限确认'
assert_not_contains "esc: prompt no escape" "$(cat "$TMUX_STUB_LOG")" 'send-keys -t %2 Escape'
teardown

# esc:PEER_FORCE=1 跳过检测并发送 Escape。
setup
TMUX_STUB_CAPTURE_MODE=prompt TEST_PEER_FORCE=1 assert_ok "esc: force env sends despite prompt" run_peer esc
assert_contains "esc: force notice" "$(cat "$ERR")" '已跳过对方权限弹窗检测'
assert_contains "esc: force escape" "$(cat "$TMUX_STUB_LOG")" 'send-keys -t %2 Escape'
teardown

# wait:连续两次稳定采样才成功。
setup
assert_ok "wait: stable after repeated samples" run_peer wait 3 1 2
assert_eq "wait: sampled initial plus two stable checks" "$(cat "$TMUX_STUB_CAPTURE_COUNT")" "3"
assert_contains "wait: success message" "$(cat "$OUT")" '连续 2 次采样一致'
teardown

# wait:输出一直变化时超时。
setup
TMUX_STUB_CAPTURE_MODE=changing assert_not_ok "wait: times out on changing output" run_peer wait 1 1 2
assert_contains "wait: timeout message" "$(cat "$ERR")" '等待超时(1s)'
teardown

# 非法输入。
setup
assert_not_ok "invalid: missing AGENT_NAME" run_peer_without_agent status
assert_contains "invalid: missing AGENT_NAME error" "$(cat "$ERR")" '未设置 AGENT_NAME'
teardown

setup
TEST_AGENT_NAME=bad assert_not_ok "invalid: bad AGENT_NAME" run_peer status
assert_contains "invalid: bad AGENT_NAME error" "$(cat "$ERR")" 'AGENT_NAME 必须是 claude 或 codex'
teardown

setup
assert_not_ok "invalid: bad peek lines" run_peer peek nope
assert_contains "invalid: bad peek error" "$(cat "$ERR")" '行数必须是正整数'
teardown

setup
assert_not_ok "invalid: bad wait timeout" run_peer wait nope
assert_contains "invalid: bad wait error" "$(cat "$ERR")" '超时秒数必须是正整数'
teardown

# 缺失 session:peek/status 都报错。
setup
TMUX_STUB_HAS_SESSION=0 assert_not_ok "missing session: peek fails" run_peer peek
assert_contains "missing session: peek error" "$(cat "$ERR")" "tmux 会话 'agents' 不存在"
teardown

setup
TMUX_STUB_HAS_SESSION=0 assert_not_ok "missing session: status fails" run_peer status
assert_contains "missing session: status error" "$(cat "$ERR")" "tmux 会话 'agents' 不存在"
teardown

exit "$ADK_FAIL"
