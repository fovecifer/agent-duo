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
  PROJECT="$SCENARIO_TMP/project"; mkdir -p "$PROJECT"
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
    elif [[ "$*" == *'@agent_role'* ]]; then
      pane=""
      set -- $*
      while [[ $# -gt 0 ]]; do [[ "$1" == "-t" ]] && { pane="$2"; break; }; shift; done
      awk -F'\t' -v p="$pane" '$1==p{print $3}' "$TMUX_STUB_REGISTRY"
    elif [[ "$*" == *'@agentduo_codec_tag'* ]]; then
      printf '%s\n' "${TMUX_STUB_CODEC_TAG:-}"
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
      sentinel)
        printf 'prior output\n'
        printf '%s\n' "$TMUX_STUB_SENTINEL"
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

mark_broker_ready() { # <agent_id>
  mkdir -p "$PROJECT/.agent-duo/state/$1"
  printf '{"agent":"%s","status":"ready","updated_epoch":%s,"nonce":"n1"}\n' "$1" "$(date +%s)" \
    > "$PROJECT/.agent-duo/state/$1/broker.json"
}

# 运行时和安装路径不应再依赖额外 Python 运行时。
PY_RUNTIME="python""3"
assert_not_contains "dependency: no Python runtime in peer/install docs" \
  "$(cat "$ROOT/bin/peer" "$ROOT/install.sh" "$ROOT/README.md" "$ROOT/README.zh-CN.md")" "$PY_RUNTIME"

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
AGENT_DUO_NO_BROKER_GATE=1 assert_ok "tell: arg succeeds" run_peer tell "hello codex"
assert_eq "tell: arg buffer content" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker")" "hello codex"
assert_contains "tell: load-buffer called" "$(cat "$TMUX_STUB_LOG")" 'load-buffer -b peer-supervisor2worker -'
assert_contains "tell: paste-buffer called" "$(cat "$TMUX_STUB_LOG")" 'paste-buffer -b peer-supervisor2worker -t %2 -d -p'
assert_contains "tell: enter sent" "$(cat "$TMUX_STUB_LOG")" 'send-keys -t %2 Enter'
teardown

# tell:显式 id 首参(已注册)→ 路由该 pane,其余为消息。
setup
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%2\tworker\tworker\tcodex\n%%3\treviewer\treviewer\tclaude\n' > "$TMUX_STUB_REGISTRY"
AGENT_DUO_NO_BROKER_GATE=1 assert_ok "tell: explicit id routes" run_peer tell reviewer "please review"
assert_eq "tell: explicit id buffer" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-supervisor2reviewer")" "please review"
assert_contains "tell: explicit id paste" "$(cat "$TMUX_STUB_LOG")" 'paste-buffer -b peer-supervisor2reviewer -t %3 -d -p'
teardown

# tell:首参不是已注册 id → 整句当消息,两人默认发给另一个。
setup
AGENT_DUO_NO_BROKER_GATE=1 assert_ok "tell: plain message default other" run_peer tell "hello there"
assert_eq "tell: plain buffer" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker")" "hello there"
teardown

# tell:stdin + 显式 id(stdin 形式下唯一位置参数即目标 id)。
setup
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%2\tworker\tworker\tcodex\n%%3\treviewer\treviewer\tclaude\n' > "$TMUX_STUB_REGISTRY"
AGENT_DUO_NO_BROKER_GATE=1 run_peer tell reviewer <<< $'multi\nline'
printf 'multi\nline\n' > "$SCENARIO_TMP/expected"
assert_ok "tell: stdin with id buffer" cmp -s "$SCENARIO_TMP/expected" "$TMUX_STUB_BUFFER_DIR/peer-supervisor2reviewer"
teardown

# tell:普通 TUI 输入提示符和普通 no/yes 文本不应被误判为权限弹窗。
setup
AGENT_DUO_NO_BROKER_GATE=1 TMUX_STUB_CAPTURE_MODE=normal_prompt assert_ok "tell: normal prompt screen succeeds" run_peer tell "ordinary"
assert_eq "tell: normal prompt buffer content" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker")" "ordinary"
assert_contains "tell: normal prompt enter" "$(cat "$TMUX_STUB_LOG")" 'send-keys -t %2 Enter'
teardown

# tell:对方疑似权限弹窗时拒绝发送,不写 buffer、不粘贴、不回车。
setup
AGENT_DUO_NO_BROKER_GATE=1 TMUX_STUB_CAPTURE_MODE=prompt assert_exit_code "tell: prompt screen exits 3" 3 run_peer tell "danger"
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
AGENT_DUO_NO_BROKER_GATE=1 assert_ok "tell: stdin succeeds" run_peer tell <<< $'line 1\n`quoted`'
printf 'line 1\n`quoted`\n' > "$SCENARIO_TMP/expected-stdin-buffer"
assert_ok "tell: stdin buffer content" cmp -s "$SCENARIO_TMP/expected-stdin-buffer" "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker"
teardown

# gate resolve:把 human gate 决策格式化为下行 decision verb。
setup
assert_ok "gate resolve: sends decision" run_peer gate resolve --choice staging-db --note "use staging"
printf '«AGENTDUO verb=decision choice=staging-db»\nuse staging' > "$SCENARIO_TMP/expected-gate-buffer"
assert_ok "gate resolve: buffer content" cmp -s "$SCENARIO_TMP/expected-gate-buffer" "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker-gate"
assert_contains "gate resolve: paste" "$(cat "$TMUX_STUB_LOG")" 'paste-buffer -b peer-supervisor2worker-gate -t %2 -d -p'
assert_contains "gate resolve: enter" "$(cat "$TMUX_STUB_LOG")" 'send-keys -t %2 Enter'
teardown

# gate resolve:存在唯一 pending gate 时,省略 id 会解析该 gate、更新 packet 与 decisions log,再发给原 worker。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "gate resolve pending setup report" \
  run_peer report --type request --status blocked --round 1 \
    --needs decision --needs-detail "用哪个库?" --needs-option new-vm --needs-option existing-dev-vm
gate_path="$(ls "$PROJECT/.agent-duo/gates"/*.json)"
assert_ok "gate resolve: resolves pending gate" run_peer gate resolve --choice existing-dev-vm --note "use dev"
gate_json="$(cat "$gate_path")"
assert_contains "gate resolve: packet resolved" "$gate_json" '"status":"resolved"'
assert_contains "gate resolve: choice recorded" "$gate_json" '"choice":"existing-dev-vm"'
assert_contains "gate resolve: note recorded" "$gate_json" '"note":"use dev"'
assert_contains "gate resolve: log resolved" "$(cat "$PROJECT/.agent-duo/logs/decisions.jsonl")" '"status":"resolved"'
printf '«AGENTDUO verb=decision choice=existing-dev-vm»\nuse dev' > "$SCENARIO_TMP/expected-resolved-gate-buffer"
assert_ok "gate resolve: pending buffer content" cmp -s "$SCENARIO_TMP/expected-resolved-gate-buffer" "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker-gate"
teardown

# gate resolve <target-id>:target 恰有唯一 pending gate 时,也要 resolve 记录,不能只裸发 decision。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "gate resolve target setup report" \
  run_peer report --type request --status blocked --round 1 \
    --needs decision --needs-detail "部署到哪里?" --needs-option staging --needs-option prod
gate_path="$(ls "$PROJECT/.agent-duo/gates"/*.json)"
assert_ok "gate resolve: target id resolves pending gate" run_peer gate resolve worker --choice staging --note "staging only"
gate_json="$(cat "$gate_path")"
assert_contains "gate resolve: target packet resolved" "$gate_json" '"status":"resolved"'
assert_contains "gate resolve: target choice recorded" "$gate_json" '"choice":"staging"'
assert_contains "gate resolve: target log resolved" "$(cat "$PROJECT/.agent-duo/logs/decisions.jsonl")" '"status":"resolved"'
printf '«AGENTDUO verb=decision choice=staging»\nstaging only' > "$SCENARIO_TMP/expected-target-gate-buffer"
assert_ok "gate resolve: target buffer content" cmp -s "$SCENARIO_TMP/expected-target-gate-buffer" "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker-gate"
teardown

# gate resolve:多个 pending gate 时省略 id 会 fail-closed,避免把人的选择发错 gate。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "gate resolve multi setup r1" \
  run_peer report --type request --status blocked --round 1 --needs decision --needs-detail "部署到哪里?"
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "gate resolve multi setup r2" \
  run_peer report --type request --status blocked --round 2 --needs decision --needs-detail "买哪种机器?"
assert_not_ok "gate resolve: ambiguous pending rejected" run_peer gate resolve --choice staging
assert_contains "gate resolve: ambiguous pending error" "$(cat "$ERR")" '多个 pending gate'
assert_not_contains "gate resolve: ambiguous no paste" "$(cat "$TMUX_STUB_LOG")" 'paste-buffer'
teardown

# gate open:Supervisor 可手动创建 Decision Packet,落 gates/ 与 decisions.jsonl。
setup
assert_ok "gate open: succeeds" run_peer gate open worker --title "选择部署目标" --detail "需要公网回调地址" --option new-vm --option existing-dev-vm
gate_path="$(ls "$PROJECT/.agent-duo/gates"/*.json)"
gate_json="$(cat "$gate_path")"
assert_contains "gate open: status pending" "$gate_json" '"status":"pending"'
assert_contains "gate open: target worker" "$gate_json" '"agent_id":"worker"'
assert_contains "gate open: title" "$gate_json" '"title":"选择部署目标"'
assert_contains "gate open: detail" "$gate_json" '"detail":"需要公网回调地址"'
assert_contains "gate open: options" "$gate_json" '"options":["new-vm","existing-dev-vm"]'
assert_contains "gate open: decisions log opened" "$(cat "$PROJECT/.agent-duo/logs/decisions.jsonl")" '"status":"opened"'
teardown

# gate resolve:choice 是结构化字段，含空白的解释放到 --note。
setup
assert_not_ok "gate resolve: rejects spaced choice" run_peer gate resolve --choice "staging db"
assert_contains "gate resolve: rejects spaced choice error" "$(cat "$ERR")" '--choice 只能包含'
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

# task:init 创建 task.json 步骤账本,默认所有步骤 pending。
setup
assert_ok "task init: succeeds" run_peer task init worker --task "add tenant_id" --round 1 \
  --step s1:"schema 加 tenant_id" --step s2:"写迁移" --step s3:"更新文档"
task_json="$(cat "$PROJECT/.agent-duo/state/worker/task.json")"
assert_contains "task init: task title" "$task_json" '"task":"add tenant_id"'
assert_contains "task init: frozen round" "$task_json" '"frozen_at_round":1'
assert_contains "task init: step s1" "$task_json" '"id":"s1"'
assert_contains "task init: pending status" "$task_json" '"status":"pending"'
assert_ok "task list: succeeds" run_peer task worker
assert_contains "task list: shows task" "$(cat "$OUT")" 'add tenant_id'
assert_ok "task next: succeeds" run_peer task next worker
assert_contains "task next: first pending" "$(cat "$OUT")" $'s1\tpending'
teardown

# task:report --step 会驱动 step 状态,并保留 done evidence 供幂等 resume 使用。
setup
assert_ok "task update setup: init succeeds" run_peer task init worker --task "add tenant_id" --round 1 \
  --step s1:"schema 加 tenant_id" --step s2:"写迁移"
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "task update: s1 in progress report" \
  run_peer report --type checkpoint --status in_progress --round 1 --step s1 --delta "started schema"
assert_contains "task update: s1 in progress" "$(cat "$PROJECT/.agent-duo/state/worker/task.json")" '"status":"in_progress"'
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "task update: s1 done report" \
  run_peer report --type checkpoint --status done --round 2 --step s1 \
    --evidence-cmd "go test ./..." --evidence-result "ok" --evidence-ref ".agent-duo/logs/worker/r2.log"
task_json="$(cat "$PROJECT/.agent-duo/state/worker/task.json")"
assert_contains "task update: s1 done" "$task_json" '"status":"done"'
assert_contains "task update: evidence kept" "$task_json" '"cmd":"go test ./..."'
assert_ok "task update: next skips done" run_peer task next worker
assert_contains "task update: next is s2" "$(cat "$OUT")" $'s2\tpending'
teardown

# task:blocked report 把当前 step 持久化为 blocked,解阻后 next 从该 step 继续。
setup
assert_ok "task blocked setup: init succeeds" run_peer task init worker --task "deploy demo" --round 1 \
  --step s1:"构建" --step s2:"部署"
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "task blocked: report succeeds" \
  run_peer report --type request --status blocked --round 1 --step s2 --needs decision --needs-detail "部署到哪里?"
assert_contains "task blocked: s2 blocked" "$(cat "$PROJECT/.agent-duo/state/worker/task.json")" '"status":"blocked"'
assert_ok "task blocked: next succeeds" run_peer task next worker
assert_contains "task blocked: next is blocked s2" "$(cat "$OUT")" $'s2\tblocked'
teardown

# task:有账本时,未知 step_ref fail-closed,避免 report 与 task.json 分裂。
setup
assert_ok "task unknown setup: init succeeds" run_peer task init worker --task "add tenant_id" --round 1 --step s1:"schema"
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_not_ok "task unknown: report rejected" \
  run_peer report --type checkpoint --status in_progress --round 1 --step s9 --delta "bad step"
assert_contains "task unknown: error" "$(cat "$ERR")" 'task.json 中不存在 step'
assert_ok "task unknown: no report written" test ! -e "$PROJECT/.agent-duo/state/worker/r1.json"
teardown

# task:ledger 未全 done/kept 时,result(done) 降级为 partial,不能静默完成整任务。
setup
assert_ok "task result setup: init succeeds" run_peer task init worker --task "add tenant_id" --round 1 \
  --step s1:"schema" --step s2:"docs"
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "task result: partial downgrade succeeds" \
  run_peer report --type result --status done --round 1 --step s1 \
    --evidence-cmd "go test ./..." --evidence-result "ok" --evidence-ref ".agent-duo/logs/worker/r1.log"
assert_contains "task result: report downgraded partial" "$(cat "$PROJECT/.agent-duo/state/worker/r1.json")" '"status":"partial"'
assert_contains "task result: sentinel partial" "$(cat "$OUT")" 'status=partial'
assert_contains "task result: s1 still done" "$(cat "$PROJECT/.agent-duo/state/worker/task.json")" '"status":"done"'
teardown

# loop:init 创建 loop.json,默认 frozen_at_round 取当前最新 report 轮次。
setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
jq -cn '{protocol:"1",round:12,agent_id:"worker",role:"worker",type:"checkpoint",status:"in_progress",delta:"",next:"",needs:[]}' \
  > "$PROJECT/.agent-duo/state/worker/r12.json"
ln -s "r12.json" "$PROJECT/.agent-duo/state/worker/report.json"
assert_ok "loop init: succeeds" run_peer loop init worker --mission "finish login copy" --max-rounds 8 \
  --non-goal "no auth refactor" --success "tests pass"
loop_json="$(cat "$PROJECT/.agent-duo/state/worker/loop.json")"
assert_contains "loop init: mission" "$loop_json" '"mission":"finish login copy"'
assert_contains "loop init: max rounds" "$loop_json" '"max_rounds":8'
assert_contains "loop init: frozen from report" "$loop_json" '"frozen_at_round":12'
assert_contains "loop init: non goal" "$loop_json" '"non_goals":["no auth refactor"]'
assert_contains "loop init: success" "$loop_json" '"success_signals":["tests pass"]'
assert_ok "loop print: succeeds" run_peer loop worker
assert_contains "loop print: rounds used" "$(cat "$OUT")" $'ROUNDS_USED\t1'
assert_contains "loop print: remaining" "$(cat "$OUT")" $'REMAINING\t7'
teardown

# loop:init 无 report 时 frozen_at_round 默认 1,且已存在/非法输入 fail-closed。
setup
assert_ok "loop init default no report: succeeds" run_peer loop init worker --mission "do work" --max-rounds 3
assert_contains "loop init default no report: frozen one" "$(cat "$PROJECT/.agent-duo/state/worker/loop.json")" '"frozen_at_round":1'
assert_not_ok "loop init: existing rejected" run_peer loop init worker --mission "again" --max-rounds 3
assert_contains "loop init: existing error" "$(cat "$ERR")" 'loop.json 已存在'
teardown

setup
assert_not_ok "loop init: missing mission rejected" run_peer loop init worker --max-rounds 3
assert_contains "loop init: missing mission error" "$(cat "$ERR")" '--mission'
assert_not_ok "loop init: bad max rejected" run_peer loop init worker --mission "do work" --max-rounds nope
assert_contains "loop init: bad max error" "$(cat "$ERR")" '--max-rounds'
teardown

# ask:stopped loop 发送前 fail-closed,不写 buffer。
setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
jq -cn '{protocol:"1",agent_id:"worker",mission:"m",non_goals:[],success_signals:[],max_rounds:1,frozen_at_round:1,status:"stopped",stop:{on_terminal:true,reason:"max_rounds",stopped_at_round:1,stopped_at:"2026-06-21T00:00:00Z"}}' \
  > "$PROJECT/.agent-duo/state/worker/loop.json"
assert_not_ok "ask: stopped loop rejected" run_peer ask worker "continue"
assert_contains "ask: stopped loop error" "$(cat "$ERR")" 'loop 已到界'
assert_ok "ask: stopped no buffer" test ! -e "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker-ask"
teardown

# ask:active 但 rounds_used>=max 时同样拒发,挡住 loopd 尚未 tick 的竞态。
setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
jq -cn '{protocol:"1",round:1,agent_id:"worker",role:"worker",type:"checkpoint",status:"in_progress",delta:"",next:"",needs:[]}' \
  > "$PROJECT/.agent-duo/state/worker/r1.json"
ln -s "r1.json" "$PROJECT/.agent-duo/state/worker/report.json"
jq -cn '{protocol:"1",agent_id:"worker",mission:"m",non_goals:[],success_signals:[],max_rounds:1,frozen_at_round:1,status:"active",stop:{on_terminal:true,reason:null,stopped_at_round:null,stopped_at:null}}' \
  > "$PROJECT/.agent-duo/state/worker/loop.json"
assert_not_ok "ask: max rounds rejected" run_peer ask worker "continue"
assert_contains "ask: max rounds error" "$(cat "$ERR")" 'reason=max_rounds'
assert_ok "ask: max rounds no buffer" test ! -e "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker-ask"
teardown

# ask:相对预算不因历史 round 误拒;发送后轮询新 report 并打印派生 summary/ref。
setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
mark_broker_ready worker
jq -cn '{protocol:"1",round:12,agent_id:"worker",role:"worker",type:"checkpoint",status:"in_progress",delta:"baseline",next:"",needs:[]}' \
  > "$PROJECT/.agent-duo/state/worker/r12.json"
ln -s "r12.json" "$PROJECT/.agent-duo/state/worker/report.json"
jq -cn '{protocol:"1",agent_id:"worker",mission:"m",non_goals:[],success_signals:[],max_rounds:8,frozen_at_round:12,status:"active",stop:{on_terminal:true,reason:null,stopped_at_round:null,stopped_at:null}}' \
  > "$PROJECT/.agent-duo/state/worker/loop.json"
TMUX_STUB_ON_SEND_REPORT_ROOT="$PROJECT" TMUX_STUB_ON_SEND_REPORT_AGENT=worker TMUX_STUB_ON_SEND_REPORT_ROUND=13 \
  TMUX_STUB_ON_SEND_REPORT_DELTA="answered ask" assert_ok "ask: historical budget sends and reads report" \
  run_peer ask worker "what changed?" --timeout 2 --interval 1
assert_eq "ask: buffer content" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker-ask")" "what changed?"
assert_contains "ask: summary printed" "$(cat "$OUT")" $'SUMMARY\tanswered ask'
assert_contains "ask: ref printed" "$(cat "$OUT")" $'REF\t.agent-duo/state/worker/r13.json'
teardown

# ask:broker 门仍独立生效;loop active 但 broker 非 ready 时拒发。
setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
jq -cn '{protocol:"1",agent_id:"worker",mission:"m",non_goals:[],success_signals:[],max_rounds:8,frozen_at_round:1,status:"active",stop:{on_terminal:true,reason:null,stopped_at_round:null,stopped_at:null}}' \
  > "$PROJECT/.agent-duo/state/worker/loop.json"
assert_not_ok "ask: broker gate still rejects" run_peer ask worker "work"
assert_contains "ask: broker gate error" "$(cat "$ERR")" 'Approval Broker'
assert_ok "ask: broker no buffer" test ! -e "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker-ask"
teardown

# ask:--force 同时越过 loop 边界与 broker 门。
setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
jq -cn '{protocol:"1",agent_id:"worker",mission:"m",non_goals:[],success_signals:[],max_rounds:1,frozen_at_round:1,status:"stopped",stop:{on_terminal:true,reason:"max_rounds",stopped_at_round:1,stopped_at:"2026-06-21T00:00:00Z"}}' \
  > "$PROJECT/.agent-duo/state/worker/loop.json"
TMUX_STUB_ON_SEND_REPORT_ROOT="$PROJECT" TMUX_STUB_ON_SEND_REPORT_AGENT=worker TMUX_STUB_ON_SEND_REPORT_ROUND=1 \
  assert_ok "ask: force sends" run_peer ask --force worker "override" --timeout 2 --interval 1
assert_eq "ask: force buffer content" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker-ask")" "override"
assert_contains "ask: force report printed" "$(cat "$OUT")" $'ROUND\t1'
teardown

# ask:无新 report 时非零退出并打印末屏兜底。
setup
mark_broker_ready worker
assert_not_ok "ask: timeout without new report" run_peer ask worker "status?" --timeout 1 --interval 1
assert_contains "ask: timeout error" "$(cat "$ERR")" '等待'
assert_contains "ask: timeout peek fallback" "$(cat "$ERR")" '目标末屏'
teardown

# report:写 rN.json、更新 latest 指针、追加极小 event、打印 sentinel。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "report: succeeds" \
  run_peer report --type checkpoint --status in_progress --round 7 --step s1 --delta "tests added" --next "implement codec"
STATE="$PROJECT/.agent-duo/state/worker"
QUEUE="$PROJECT/.agent-duo/events/queue.jsonl"
assert_ok "report: rN exists" test -f "$STATE/r7.json"
assert_eq "report: latest symlink" "$(readlink "$STATE/report.json")" "r7.json"
assert_ok "report: queue exists" test -f "$QUEUE"
report_json="$(cat "$STATE/r7.json")"
event_json="$(cat "$QUEUE")"
sentinel="$(cat "$OUT")"
assert_contains "report: protocol" "$report_json" '"protocol":"1"'
assert_contains "report: agent id" "$report_json" '"agent_id":"worker"'
assert_contains "report: role" "$report_json" '"role":"worker"'
assert_contains "report: type" "$report_json" '"type":"checkpoint"'
assert_contains "report: status" "$report_json" '"status":"in_progress"'
assert_contains "report: step" "$report_json" '"step_ref":"s1"'
assert_contains "report: sentinel delimiter" "$sentinel" '«AGENTDUO:7f3a»'
assert_contains "report: sentinel agent" "$sentinel" 'agent_id=worker'
assert_contains "report: sentinel round" "$sentinel" 'round=7'
assert_contains "report: sentinel file" "$sentinel" 'file=.agent-duo/state/worker/r7.json'
assert_contains "report: event agent" "$event_json" '"agent":"worker"'
assert_contains "report: event type" "$event_json" '"type":"checkpoint"'
assert_contains "report: event ref" "$event_json" '"ref":".agent-duo/state/worker/r7.json"'
teardown

# report:纯 Bash codec 仍要正确 JSON 转义常见特殊字符。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "report: json escaping succeeds" \
  run_peer report --type checkpoint --status in_progress --round 2 \
    --delta $'quote " backslash \\ tab\t' \
    --next $'line 1\nline 2'
escaped_report="$(cat "$PROJECT/.agent-duo/state/worker/r2.json")"
assert_contains "report: escapes quote" "$escaped_report" 'quote \"'
assert_contains "report: escapes backslash" "$escaped_report" 'backslash \\'
assert_contains "report: escapes tab" "$escaped_report" 'tab\t'
assert_contains "report: escapes newline" "$escaped_report" 'line 1\nline 2'
teardown

# report:其余 < 0x20 控制字符转为 \u00XX，且多字节 UTF-8 原样保留(否则下游 jq 会崩)。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "report: control char escaping succeeds" \
  run_peer report --type checkpoint --status in_progress --round 3 \
    --delta $'esc\x1bvt\x0b中文'
ctrl_report="$(cat "$PROJECT/.agent-duo/state/worker/r3.json")"
assert_contains "report: escapes ESC control char" "$ctrl_report" 'esc\u001bvt'
assert_contains "report: escapes vtab control char" "$ctrl_report" 'vt\u000b中文'
assert_contains "report: preserves UTF-8" "$ctrl_report" '中文'
teardown

# report:done/partial 没有 evidence 时按契约降级为 unknown。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "report: done without evidence succeeds" \
  run_peer report --type result --status done --round 1 --delta "claimed done"
assert_contains "report: done without evidence downgraded" "$(cat "$PROJECT/.agent-duo/state/worker/r1.json")" '"status":"unknown"'
assert_contains "report: downgraded sentinel status" "$(cat "$OUT")" 'status=unknown'
teardown

# report:runtime event 追加失败时不得先打印 sentinel，避免屏幕/队列分裂。
setup
mkdir -p "$PROJECT/.agent-duo/events/queue.jsonl"
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_not_ok "report: queue append failure fails" \
  run_peer report --type checkpoint --status in_progress --round 4 --delta "cannot enqueue"
assert_eq "report: queue append failure no sentinel" "$(cat "$OUT")" ""
assert_contains "report: queue append failure error" "$(cat "$ERR")" 'Is a directory'
assert_ok "report: queue append failure removes rN" test ! -e "$PROJECT/.agent-duo/state/worker/r4.json"
assert_ok "report: queue append failure leaves no latest" test ! -L "$PROJECT/.agent-duo/state/worker/report.json"
teardown

# report:decision gate 的 event 入队失败时,不要留下孤儿 gate 或 opened 审计行。
setup
mkdir -p "$PROJECT/.agent-duo/events/queue.jsonl"
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_not_ok "report: decision queue append failure fails" \
  run_peer report --type request --status blocked --round 4 --needs decision --needs-detail "部署到哪里?" --needs-option staging
assert_eq "report: decision queue append failure no sentinel" "$(cat "$OUT")" ""
assert_ok "report: decision queue append failure removes rN" test ! -e "$PROJECT/.agent-duo/state/worker/r4.json"
assert_ok "report: decision queue append failure removes gate" sh -c '! ls "$1"/*.json >/dev/null 2>&1' sh "$PROJECT/.agent-duo/gates"
assert_ok "report: decision queue append failure no opened log" sh -c '! test -e "$1/.agent-duo/logs/decisions.jsonl" || ! grep -q "\"status\":\"opened\"" "$1/.agent-duo/logs/decisions.jsonl"' sh "$PROJECT"
teardown

# report:无 --needs 时 needs[] 保持为空数组(无阻塞诉求)。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "report: no needs succeeds" \
  run_peer report --type checkpoint --status in_progress --round 1 --delta "still working"
assert_contains "report: empty needs" "$(cat "$PROJECT/.agent-duo/state/worker/r1.json")" '"needs":[]'
teardown

# report:--needs <kind> 把阻塞诉求结构化写入 needs[],供 supervisor 路由(approval|decision|info|scope|discovery)。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "report: needs approval succeeds" \
  run_peer report --type request --status blocked --round 1 --needs approval --needs-detail "迁移需要写权限"
needs_report="$(cat "$PROJECT/.agent-duo/state/worker/r1.json")"
assert_contains "report: needs kind approval" "$needs_report" '"kind":"approval"'
assert_contains "report: needs detail" "$needs_report" '"detail":"迁移需要写权限"'
assert_contains "report: needs empty options" "$needs_report" '"options":[]'
assert_not_contains "report: needs not empty array" "$needs_report" '"needs":[]'
teardown

# report:--needs decision 可带多个 --needs-option 候选,按 contract §2.2 给人类决策门。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "report: needs decision succeeds" \
  run_peer report --type request --status blocked --round 1 \
    --needs decision --needs-detail "用哪个库?" --needs-option new-vm --needs-option existing-dev-vm
decision_report="$(cat "$PROJECT/.agent-duo/state/worker/r1.json")"
assert_contains "report: needs kind decision" "$decision_report" '"kind":"decision"'
assert_contains "report: needs option a" "$decision_report" '"options":["new-vm","existing-dev-vm"]'
teardown

# report:--needs decision 会创建 Human Decision Gate,并让 runtime event 指向 gate packet。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "report: needs decision opens gate" \
  run_peer report --type request --status blocked --round 1 \
    --needs decision --needs-detail "用哪个库?" --needs-option new-vm --needs-option existing-dev-vm
gate_path="$(ls "$PROJECT/.agent-duo/gates"/*.json)"
gate_id="${gate_path##*/}"; gate_id="${gate_id%.json}"
gate_json="$(cat "$gate_path")"
assert_contains "report: gate status pending" "$gate_json" '"status":"pending"'
assert_contains "report: gate agent" "$gate_json" '"agent_id":"worker"'
assert_contains "report: gate detail" "$gate_json" '"detail":"用哪个库?"'
assert_contains "report: gate options" "$gate_json" '"options":["new-vm","existing-dev-vm"]'
assert_contains "report: gate report ref" "$gate_json" '"report_ref":".agent-duo/state/worker/r1.json"'
assert_contains "report: event ref points gate" "$(cat "$PROJECT/.agent-duo/events/queue.jsonl")" "\"ref\":\".agent-duo/gates/$gate_id.json\""
assert_contains "report: decisions log opened" "$(cat "$PROJECT/.agent-duo/logs/decisions.jsonl")" '"status":"opened"'
teardown

# gate:默认列出 pending Human Decision Gate。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "gate list setup report" \
  run_peer report --type request --status blocked --round 1 --needs decision --needs-detail "部署到哪里?" --needs-option staging
assert_ok "gate list: succeeds" run_peer gate
assert_contains "gate list: has header" "$(cat "$OUT")" 'ID'
assert_contains "gate list: shows pending" "$(cat "$OUT")" 'pending'
assert_contains "gate list: shows title" "$(cat "$OUT")" '部署到哪里?'
assert_contains "gate list: shows options" "$(cat "$OUT")" 'staging'
teardown

# report:--needs-detail 仍按 codec 转义,避免下游 jq 崩。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "report: needs detail escaping succeeds" \
  run_peer report --type request --status blocked --round 1 --needs info --needs-detail $'quote " tab\t'
assert_contains "report: needs detail escaped quote" "$(cat "$PROJECT/.agent-duo/state/worker/r1.json")" 'quote \"'
teardown

# report:--needs kind 非法枚举时 fail-closed,不写 report。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_not_ok "report: invalid needs kind fails" \
  run_peer report --type request --status blocked --round 1 --needs bogus
assert_contains "report: invalid needs kind error" "$(cat "$ERR")" 'approval'
assert_ok "report: invalid needs kind writes no rN" test ! -e "$PROJECT/.agent-duo/state/worker/r1.json"
teardown

# report:给了 --needs-detail 却忘了 --needs <kind> → fail-closed,别把阻塞诉求悄悄丢成空 needs[]。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_not_ok "report: detail without kind fails" \
  run_peer report --type request --status blocked --round 1 --needs-detail "迁移需要写权限"
assert_contains "report: detail without kind error" "$(cat "$ERR")" '--needs'
assert_ok "report: detail without kind writes no rN" test ! -e "$PROJECT/.agent-duo/state/worker/r1.json"
teardown

# report:给了 --needs-option 却忘了 --needs <kind> → 同样 fail-closed。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_not_ok "report: option without kind fails" \
  run_peer report --type request --status blocked --round 1 --needs-option new-vm
assert_ok "report: option without kind writes no rN" test ! -e "$PROJECT/.agent-duo/state/worker/r1.json"
teardown

# report:blocked + needs 但无 --delta/--next 时,event summary 用 needs detail,别退化成 request/blocked。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "report: needs summary succeeds" \
  run_peer report --type request --status blocked --round 1 --needs approval --needs-detail "迁移需要写权限"
needs_event="$(cat "$PROJECT/.agent-duo/events/queue.jsonl")"
assert_contains "report: event summary uses needs detail" "$needs_event" '"summary":"迁移需要写权限"'
teardown

# report:有 needs kind 但无 detail/delta/next 时,summary 退化为 needs:<kind> 而非 request/blocked。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "report: needs kind summary succeeds" \
  run_peer report --type request --status blocked --round 1 --needs discovery
assert_contains "report: event summary uses needs kind" "$(cat "$PROJECT/.agent-duo/events/queue.jsonl")" '"summary":"needs:discovery"'
teardown

# wait --round:等待指定 round 的 sentinel,不再靠屏幕稳定猜测回合边界。
setup
TMUX_STUB_SENTINEL='«AGENTDUO:7f3a» agent_id=worker round=7 type=checkpoint status=in_progress file=.agent-duo/state/worker/r7.json sha=abc ts=2026-06-17T00:00:00Z'
TMUX_STUB_CAPTURE_MODE=sentinel assert_ok "wait round: sentinel found" run_peer wait worker --round 7
assert_contains "wait round: success message" "$(cat "$OUT")" '已看到 round=7 的 sentinel'
teardown

# wait --round:指定回合一直没出现时超时。
setup
TMUX_STUB_SENTINEL='«AGENTDUO:7f3a» agent_id=worker round=6 type=checkpoint status=in_progress file=.agent-duo/state/worker/r6.json sha=abc ts=2026-06-17T00:00:00Z'
TMUX_STUB_CAPTURE_MODE=sentinel assert_not_ok "wait round: timeout" run_peer wait worker --round 7 --timeout 1 --interval 1
assert_contains "wait round: timeout message" "$(cat "$ERR")" '等待 round=7 的 sentinel 超时(1s)'
teardown

# wait --round:同 round 但 agent_id 不同不能误判成功。
setup
TMUX_STUB_SENTINEL='«AGENTDUO:7f3a» agent_id=reviewer round=7 type=checkpoint status=in_progress file=.agent-duo/state/reviewer/r7.json sha=abc ts=2026-06-17T00:00:00Z'
TMUX_STUB_CAPTURE_MODE=sentinel assert_not_ok "wait round: wrong agent ignored" run_peer wait worker --round 7 --timeout 1 --interval 1
assert_contains "wait round: wrong agent timeout" "$(cat "$ERR")" '等待 round=7 的 sentinel 超时(1s)'
teardown

# wait --round:字段必须精确匹配,不能把 round=70/worker2 当成目标。
setup
TMUX_STUB_SENTINEL='«AGENTDUO:7f3a» agent_id=worker round=70 type=checkpoint status=in_progress file=.agent-duo/state/worker/r70.json sha=abc ts=2026-06-17T00:00:00Z'
TMUX_STUB_CAPTURE_MODE=sentinel assert_not_ok "wait round: round boundary ignored" run_peer wait worker --round 7 --timeout 1 --interval 1
assert_contains "wait round: round boundary timeout" "$(cat "$ERR")" '等待 round=7 的 sentinel 超时(1s)'
teardown

setup
TMUX_STUB_SENTINEL='«AGENTDUO:7f3a» agent_id=worker2 round=7 type=checkpoint status=in_progress file=.agent-duo/state/worker2/r7.json sha=abc ts=2026-06-17T00:00:00Z'
TMUX_STUB_CAPTURE_MODE=sentinel assert_not_ok "wait round: agent boundary ignored" run_peer wait worker --round 7 --timeout 1 --interval 1
assert_contains "wait round: agent boundary timeout" "$(cat "$ERR")" '等待 round=7 的 sentinel 超时(1s)'
teardown

setup
TMUX_STUB_CODEC_TAG=expected
TMUX_STUB_SENTINEL='«AGENTDUO:other» agent_id=worker round=7 type=checkpoint status=in_progress file=.agent-duo/state/worker/r7.json sha=abc ts=2026-06-17T00:00:00Z'
TMUX_STUB_CAPTURE_MODE=sentinel assert_not_ok "wait round: tag mismatch ignored" run_peer wait worker --round 7 --timeout 1 --interval 1
assert_contains "wait round: tag mismatch timeout" "$(cat "$ERR")" '等待 round=7 的 sentinel 超时(1s)'
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

# add:工作型角色(任何 provider)都要提示先 broker-check——硬门对 Claude reviewer 同样 fail-closed。
setup
TMUX_STUB_NEW_PANE="%5" assert_ok "add: claude reviewer succeeds" run_peer add --provider claude --role reviewer
assert_contains "add: claude reviewer broker-check hint" "$(cat "$OUT")" 'peer broker-check reviewer'
teardown

# add:豁免名单角色(supervisor/daemon/loopd)不受硬门保护,不应误导用户去 broker-check。
setup
TMUX_STUB_NEW_PANE="%5" assert_ok "add: claude supervisor succeeds" run_peer add --provider claude --role supervisor --id sup2
assert_not_contains "add: exempt role no broker-check hint" "$(cat "$OUT")" 'broker-check'
teardown

# add:Codex 工作型角色既给 broker-check 提示,也给 /hooks 信任提示。
setup
TMUX_STUB_NEW_PANE="%5" assert_ok "add: codex worker succeeds" run_peer add --provider codex --role worker --id helper2
add_out="$(cat "$OUT")"
assert_contains "add: codex worker broker-check hint" "$add_out" 'peer broker-check helper2'
assert_contains "add: codex worker hooks hint" "$add_out" '/hooks'
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

# broker-status:无 marker 时报 unverified。
setup
assert_ok "broker-status: succeeds" run_peer broker-status worker
assert_contains "broker-status: unverified default" "$(cat "$OUT")" '"status":"unverified"'
teardown

# broker-status:已有 ready marker 时如实回报。
setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
printf '{"agent":"worker","status":"ready","updated_epoch":%s,"nonce":"n1"}\n' "$(date +%s)" > "$PROJECT/.agent-duo/state/worker/broker.json"
assert_ok "broker-status: reads marker" run_peer broker-status worker
assert_contains "broker-status: ready reported" "$(cat "$OUT")" '"status":"ready"'
assert_not_contains "broker-status: no hint when ready" "$(cat "$ERR")" 'broker-check'
teardown

# broker-status:ready 但过期(老 epoch)→ 报 stale,并给出 broker-check 提示。
setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
printf '{"agent":"worker","status":"ready","updated_epoch":1000000000,"nonce":"n1"}\n' > "$PROJECT/.agent-duo/state/worker/broker.json"
assert_ok "broker-status: stale surfaced" run_peer broker-status worker
assert_contains "broker-status: stale status" "$(cat "$OUT")" '"status":"stale"'
assert_contains "broker-status: stale hint to broker-check" "$(cat "$ERR")" 'broker-check'
teardown

# broker-check:投递自检探针(带 sentinel+nonce),未匹配时标记 fail-open 并非零退出。
setup
AGENT_DUO_BROKER_CHECK_TIMEOUT=2 assert_exit_code "broker-check: fail-open when hook never fires" 1 \
  run_peer broker-check worker --nonce fixednonce
assert_contains "broker-check: probe carries sentinel+nonce" \
  "$(cat "$TMUX_STUB_BUFFER_DIR/peer-brokercheck-worker")" 'AGENT_DUO_BROKER_SELFCHECK_fixednonce'
assert_contains "broker-check: warns fail-open" "$(cat "$ERR")" 'FAIL-OPEN'
assert_contains "broker-check: marker set fail-open" \
  "$(cat "$PROJECT/.agent-duo/state/worker/broker.json")" '"status":"fail-open"'
teardown

# broker-check:marker 已是 ready+匹配 nonce → 报 READY 并零退出。
setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
printf '{"agent":"worker","status":"ready","nonce":"fixednonce"}\n' > "$PROJECT/.agent-duo/state/worker/broker.json"
AGENT_DUO_BROKER_CHECK_TIMEOUT=3 assert_ok "broker-check: ready when marker matches nonce" \
  run_peer broker-check worker --nonce fixednonce
assert_contains "broker-check: reports READY" "$(cat "$OUT")" 'READY'
teardown

# broker-check:旧 marker 的 nonce 不匹配本次探针 → 不算通过(fail-open)。
setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
printf '{"agent":"worker","status":"ready","nonce":"stale"}\n' > "$PROJECT/.agent-duo/state/worker/broker.json"
AGENT_DUO_BROKER_CHECK_TIMEOUT=2 assert_exit_code "broker-check: stale nonce is not a pass" 1 \
  run_peer broker-check worker --nonce freshnonce
teardown

# broker-check:未知 id 报错。
setup
assert_not_ok "broker-check: unknown id" run_peer broker-check ghost
assert_contains "broker-check: unknown error" "$(cat "$ERR")" "找不到 agent 'ghost'"
teardown

# ② Broker dispatch hard gate: tell to a worker refuses unless broker is fresh ready.

# worker + no marker (unverified) → refuse, nonzero, no buffer written.
setup
assert_exit_code "gate: unverified worker refused" 1 run_peer tell worker "do work"
assert_contains "gate: unverified error mentions fresh ready" "$(cat "$ERR")" 'fresh ready'
assert_contains "gate: unverified error suggests broker-check" "$(cat "$ERR")" 'broker-check'
assert_ok "gate: unverified no buffer written" test ! -e "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker"
teardown

# worker + stale marker (old epoch) → refuse.
setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
printf '{"agent":"worker","status":"ready","updated_epoch":1000000000,"nonce":"old"}\n' > "$PROJECT/.agent-duo/state/worker/broker.json"
assert_exit_code "gate: stale worker refused" 1 run_peer tell worker "do work"
assert_ok "gate: stale no buffer written" test ! -e "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker"
teardown

# worker + fresh ready marker → allowed (sends).
setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
printf '{"agent":"worker","status":"ready","updated_epoch":%s,"nonce":"n1"}\n' "$(date +%s)" > "$PROJECT/.agent-duo/state/worker/broker.json"
assert_ok "gate: fresh ready worker allowed" run_peer tell worker "do work"
assert_eq "gate: fresh ready buffer written" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker")" "do work"
teardown

# worker + unverified + --force → allowed (bypass).
setup
assert_ok "gate: --force bypasses gate" run_peer tell --force worker "do work"
assert_eq "gate: --force buffer written" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker")" "do work"
teardown

# worker + unverified + AGENT_DUO_NO_BROKER_GATE=1 → allowed (bypass).
setup
AGENT_DUO_NO_BROKER_GATE=1 assert_ok "gate: env disable bypasses gate" run_peer tell worker "do work"
assert_eq "gate: env disable buffer written" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker")" "do work"
teardown

# F2: reviewer is a worker-like role → gated. unverified reviewer + no marker → refused.
setup
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%2\tworker\tworker\tcodex\n%%3\treviewer\treviewer\tclaude\n' > "$TMUX_STUB_REGISTRY"
assert_exit_code "gate: unverified reviewer refused" 1 run_peer tell reviewer "please review"
assert_ok "gate: reviewer no buffer written" test ! -e "$TMUX_STUB_BUFFER_DIR/peer-supervisor2reviewer"
teardown

# F2: non-worker roles (daemon/loopd) are NOT gated → send even with no marker.
setup
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%2\tworker\tworker\tcodex\n%%4\tloopd\tdaemon\tclaude\n' > "$TMUX_STUB_REGISTRY"
assert_ok "gate: daemon/loopd target not gated" run_peer tell loopd "tick"
assert_eq "gate: loopd buffer written" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-supervisor2loopd")" "tick"
teardown

exit "$ADK_FAIL"
