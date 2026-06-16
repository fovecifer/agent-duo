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

  TMUX_STUB_REGISTRY="$SCENARIO_TMP/registry.tsv"
  # 默认两人:supervisor(claude,%1) + worker(codex,%2)
  printf '%%1\tsupervisor\tsupervisor\tclaude\n%%2\tworker\tworker\tcodex\n' > "$TMUX_STUB_REGISTRY"

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
    if [[ "$*" == *'@agent_id'* ]]; then
      # 找 -t <pane> 的 pane,在 registry 里查它的 id(第 2 列)
      pane=""
      set -- $*
      while [[ $# -gt 0 ]]; do [[ "$1" == "-t" ]] && { pane="$2"; break; }; shift; done
      awk -F'\t' -v p="$pane" '$1==p{print $2}' "$TMUX_STUB_REGISTRY"
    else
      printf '%s\n' "${TMUX_STUB_PANE_SESSION:-${AGENT_SESSION:-agents}}"
    fi
    ;;
  list-panes)
    # peer 用固定 -F '#{pane_id}\t#{@agent_id}\t#{@agent_role}\t#{@agent_provider}'
    [[ "${TMUX_STUB_HAS_SESSION:-1}" == "1" ]] || exit 1
    cat "$TMUX_STUB_REGISTRY"
    ;;
  set-option)
    : # 仅记录(开头已 append 到 LOG)
    ;;
  new-window)
    printf '%s\n' "${TMUX_STUB_NEW_PANE:-%9}"
    ;;
  kill-window)
    : # 仅记录
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
    TMUX_PANE="${TEST_TMUX_PANE:-%1}" \
    TMUX_STUB_REGISTRY="$TMUX_STUB_REGISTRY" \
    TMUX_STUB_NEW_PANE="${TMUX_STUB_NEW_PANE:-%9}" \
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
    unset AGENT_NAME AGENT_CLAUDE_PANE AGENT_CODEX_PANE TMUX_PANE
    PATH="$STUB_BIN:$PATH" \
      AGENT_SESSION="${TEST_AGENT_SESSION:-agents}" \
      TMUX_STUB_REGISTRY="$TMUX_STUB_REGISTRY" \
      TMUX_STUB_LOG="$TMUX_STUB_LOG" \
      TMUX_STUB_BUFFER_DIR="$TMUX_STUB_BUFFER_DIR" \
      TMUX_STUB_CAPTURE_COUNT="$TMUX_STUB_CAPTURE_COUNT" \
      "$ROOT/bin/peer" "$@" >"$OUT" 2>"$ERR"
  )
}

# 身份:从 $TMUX_PANE 的 @agent_id 自识别(而非 AGENT_NAME)。
setup
TEST_TMUX_PANE="%1" assert_ok "identity: self from tmux pane" run_peer status
assert_contains "identity: prints self id" "$(cat "$OUT")" 'supervisor'
teardown

# status:命令分发与默认目标展示。
setup
assert_ok "status: succeeds" run_peer status
assert_contains "status: prints identity" "$(cat "$OUT")" '我是: supervisor'
teardown

# status:打印自身与目标。
setup
assert_contains "status: prints target pane" "$(run_peer status; cat "$OUT")" '%2'
teardown

# ls:列出 registry 内所有 agent;未注册 pane 显示 (unregistered)。
setup
assert_ok "ls: succeeds" run_peer ls
assert_contains "ls: shows supervisor" "$(cat "$OUT")" 'supervisor'
assert_contains "ls: shows worker"     "$(cat "$OUT")" 'worker'
assert_contains "ls: shows provider"   "$(cat "$OUT")" 'codex'
assert_contains "ls: marks self"       "$(cat "$OUT")" '*'   # 自己一行带标记
teardown

# ls:未注册 pane(无 @agent_id)显示占位。
setup
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%7\t\t\t\n' > "$TMUX_STUB_REGISTRY"
assert_ok "ls: unregistered succeeds" run_peer ls
assert_contains "ls: unregistered marked" "$(cat "$OUT")" '(unregistered)'
teardown

# 寻址:peek 无 id,正好两人 → 默认另一个(worker=%2)。
setup
assert_ok "addr: peek default other" run_peer peek 7
assert_contains "addr: peek default captures %2" "$(cat "$TMUX_STUB_LOG")" 'capture-pane -p -J -t %2 -S -7'
teardown

# 寻址:peek 显式 id → 路由到该 pane。
setup
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%2\tworker\tworker\tcodex\n%%3\treviewer\treviewer\tclaude\n' > "$TMUX_STUB_REGISTRY"
assert_ok "addr: peek explicit id" run_peer peek reviewer 9
assert_contains "addr: peek explicit captures %3" "$(cat "$TMUX_STUB_LOG")" 'capture-pane -p -J -t %3 -S -9'
teardown

# 寻址:≥3 人且省略 id → 报错要求指名。
setup
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%2\tworker\tworker\tcodex\n%%3\treviewer\treviewer\tclaude\n' > "$TMUX_STUB_REGISTRY"
assert_not_ok "addr: ambiguous rejected" run_peer peek
assert_contains "addr: ambiguous error" "$(cat "$ERR")" '请指定目标'
teardown

# 寻址:未知 id → 报错。
setup
assert_not_ok "addr: unknown id rejected" run_peer peek nobody
assert_contains "addr: unknown id error" "$(cat "$ERR")" "找不到 agent 'nobody'"
teardown

# tell:单行参数走 tmux buffer + bracketed paste + Enter。
setup
assert_ok "tell: arg succeeds" run_peer tell "hello codex"
assert_eq "tell: arg buffer content" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker")" "hello codex"
assert_contains "tell: load-buffer called" "$(cat "$TMUX_STUB_LOG")" 'load-buffer -b peer-supervisor2worker -'
assert_contains "tell: paste-buffer called" "$(cat "$TMUX_STUB_LOG")" 'paste-buffer -b peer-supervisor2worker -t %2 -d -p'
assert_contains "tell: enter sent" "$(cat "$TMUX_STUB_LOG")" 'send-keys -t %2 Enter'
teardown

# tell:显式 id 首参(已注册)→ 路由该 pane,其余为消息。
setup
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%2\tworker\tworker\tcodex\n%%3\treviewer\treviewer\tclaude\n' > "$TMUX_STUB_REGISTRY"
assert_ok "tell: explicit id routes" run_peer tell reviewer "please review"
assert_eq "tell: explicit id buffer" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-supervisor2reviewer")" "please review"
assert_contains "tell: explicit id paste" "$(cat "$TMUX_STUB_LOG")" 'paste-buffer -b peer-supervisor2reviewer -t %3 -d -p'
teardown

# tell:首参不是已注册 id → 整句当消息,两人默认发给另一个。
setup
assert_ok "tell: plain message default other" run_peer tell "hello there"
assert_eq "tell: plain buffer" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker")" "hello there"
teardown

# tell:stdin + 显式 id(stdin 形式下唯一位置参数即目标 id)。
setup
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%2\tworker\tworker\tcodex\n%%3\treviewer\treviewer\tclaude\n' > "$TMUX_STUB_REGISTRY"
run_peer tell reviewer <<< $'multi\nline'
printf 'multi\nline\n' > "$SCENARIO_TMP/expected"
assert_ok "tell: stdin with id buffer" cmp -s "$SCENARIO_TMP/expected" "$TMUX_STUB_BUFFER_DIR/peer-supervisor2reviewer"
teardown

# tell:普通 TUI 输入提示符和普通 no/yes 文本不应被误判为权限弹窗。
setup
TMUX_STUB_CAPTURE_MODE=normal_prompt assert_ok "tell: normal prompt screen succeeds" run_peer tell "ordinary"
assert_eq "tell: normal prompt buffer content" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker")" "ordinary"
assert_contains "tell: normal prompt enter" "$(cat "$TMUX_STUB_LOG")" 'send-keys -t %2 Enter'
teardown

# tell:对方疑似权限弹窗时拒绝发送,不写 buffer、不粘贴、不回车。
setup
TMUX_STUB_CAPTURE_MODE=prompt assert_exit_code "tell: prompt screen exits 3" 3 run_peer tell "danger"
assert_contains "tell: prompt error" "$(cat "$ERR")" '疑似正在等待权限确认'
assert_ok "tell: prompt no buffer" test ! -e "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker"
assert_not_contains "tell: prompt no paste" "$(cat "$TMUX_STUB_LOG")" 'paste-buffer'
assert_not_contains "tell: prompt no enter" "$(cat "$TMUX_STUB_LOG")" 'send-keys -t %2 Enter'
teardown

# tell:--force 跳过弹窗检测并按原流程发送。
setup
TMUX_STUB_CAPTURE_MODE=prompt assert_ok "tell: force sends despite prompt" run_peer tell --force "forced"
assert_eq "tell: force buffer content" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker")" "forced"
assert_contains "tell: force notice" "$(cat "$ERR")" '已跳过对方权限弹窗检测'
assert_contains "tell: force paste" "$(cat "$TMUX_STUB_LOG")" 'paste-buffer -b peer-supervisor2worker -t %2 -d -p'
assert_contains "tell: force enter" "$(cat "$TMUX_STUB_LOG")" 'send-keys -t %2 Enter'
teardown

# tell:stdin 多行保持原文进入 buffer。
setup
assert_ok "tell: stdin succeeds" run_peer tell <<< $'line 1\n`quoted`'
printf 'line 1\n`quoted`\n' > "$SCENARIO_TMP/expected-stdin-buffer"
assert_ok "tell: stdin buffer content" cmp -s "$SCENARIO_TMP/expected-stdin-buffer" "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker"
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

# esc:--force(作为参数)跳过弹窗检测并发送 Escape。
setup
TMUX_STUB_CAPTURE_MODE=prompt assert_ok "esc: force arg sends despite prompt" run_peer esc --force
assert_contains "esc: force arg notice" "$(cat "$ERR")" '已跳过对方权限弹窗检测'
assert_contains "esc: force arg escape" "$(cat "$TMUX_STUB_LOG")" 'send-keys -t %2 Escape'
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
assert_not_ok "invalid: missing identity" run_peer_without_agent status
assert_contains "invalid: missing identity error" "$(cat "$ERR")" '无法确定自身身份'
teardown

setup
assert_not_ok "invalid: bad peek lines" run_peer peek worker nope
assert_contains "invalid: bad peek error" "$(cat "$ERR")" '行数必须是正整数'
teardown

setup
assert_not_ok "invalid: bad wait timeout" run_peer wait worker nope
assert_contains "invalid: bad wait error" "$(cat "$ERR")" '超时秒数必须是正整数'
teardown

# add:新建 window、写三个 @agent_* 标签、send-keys 启动 provider、打印 id。
setup
TMUX_STUB_NEW_PANE="%5" assert_ok "add: succeeds" run_peer add --provider codex --role worker --id helper
assert_contains "add: new-window called" "$(cat "$TMUX_STUB_LOG")" 'new-window'
assert_contains "add: tags id"       "$(cat "$TMUX_STUB_LOG")" 'set-option -p -t %5 @agent_id helper'
assert_contains "add: tags role"     "$(cat "$TMUX_STUB_LOG")" 'set-option -p -t %5 @agent_role worker'
assert_contains "add: tags provider" "$(cat "$TMUX_STUB_LOG")" 'set-option -p -t %5 @agent_provider codex'
assert_contains "add: launches codex" "$(cat "$TMUX_STUB_LOG")" 'send-keys -t %5'
assert_contains "add: prints id" "$(cat "$OUT")" 'helper'
teardown

# add:省略 --id → 由 role 派生;已存在 worker → worker-2。
setup
TMUX_STUB_NEW_PANE="%5" assert_ok "add: derive id" run_peer add --provider codex --role worker
assert_contains "add: derived worker-2" "$(cat "$TMUX_STUB_LOG")" 'set-option -p -t %5 @agent_id worker-2'
teardown

# add:非法 provider 报错。
setup
assert_not_ok "add: bad provider" run_peer add --provider gpt --role worker
assert_contains "add: bad provider error" "$(cat "$ERR")" 'provider 必须是 claude 或 codex'
teardown

# rm:按 id 找到 pane 并 kill-window。
setup
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%2\tworker\tworker\tcodex\n' > "$TMUX_STUB_REGISTRY"
assert_ok "rm: succeeds" run_peer rm worker
assert_contains "rm: kills window" "$(cat "$TMUX_STUB_LOG")" 'kill-window -t %2'
teardown

# rm:未知 id 报错。
setup
assert_not_ok "rm: unknown id" run_peer rm ghost
assert_contains "rm: unknown error" "$(cat "$ERR")" "找不到 agent 'ghost'"
teardown

# rm:拒绝移除自己。
setup
assert_not_ok "rm: refuse self" run_peer rm supervisor
assert_contains "rm: refuse self error" "$(cat "$ERR")" '不能移除自己'
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
