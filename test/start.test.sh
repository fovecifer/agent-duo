#!/usr/bin/env bash
# test/start.test.sh — start.sh 注入接线的集成测试(用 stub 替换 tmux/claude/codex)
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

# 为每个场景搭建:stub bin + 干净项目目录 + send-keys 日志
setup() {
  SCENARIO_TMP="$(make_tmp)"
  STUB_BIN="$SCENARIO_TMP/bin"; mkdir -p "$STUB_BIN"
  PROJECT="$SCENARIO_TMP/project"; mkdir -p "$PROJECT"
  SENDLOG="$SCENARIO_TMP/sendkeys.log"; : > "$SENDLOG"

  # tmux stub:记录所有调用;has-session 返回 1(无会话),new-* 返回 pane ID。
  cat > "$STUB_BIN/tmux" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SENDLOG"
case "\$1" in
  has-session) exit 1 ;;
  new-session) printf '%%1\n'; exit 0 ;;
  new-window)  printf '%%2\n'; exit 0 ;;
  *)           exit 0 ;;
esac
STUB
  chmod +x "$STUB_BIN/tmux"
  # claude/codex stub:存在即可,绝不应被真正执行(start.sh 只 send-keys 字符串)
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/claude"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/codex"
  chmod +x "$STUB_BIN/claude" "$STUB_BIN/codex"
}
teardown() {
  if [[ -n "${SCENARIO_TMP:-}" && -d "$SCENARIO_TMP" && "$SCENARIO_TMP" != "/" ]]; then
    rm -rf "$SCENARIO_TMP"
  fi
  unset TEST_PATH
}

run_start() { # 在 stub PATH + 指定 stdin/env 下运行 start.sh
  PATH="${TEST_PATH:-$STUB_BIN:$PATH}" AGENT_SESSION=adktest "$@" bash "$ROOT/start.sh" "$PROJECT" \
    >"$SCENARIO_TMP/out.txt" 2>&1
}

# 静态护栏:start.sh 里不得出现 "$变量" 紧贴非 ASCII 字节的写法。
# 某些 locale 下 bash 会把多字节字符首字节并入变量名(如 $AGENTS_MD。→ 查找 AGENTS_MD<字节>),
# 在 set -u 下报 unbound variable。必须写成 ${AGENTS_MD}。这条覆盖了无法用普通测试驱动的交互分支。
if perl -ne 'exit 1 if /\$[A-Za-z_][A-Za-z0-9_]*[\x80-\xff]/' "$ROOT/start.sh"; then
  printf 'ok   start.sh: no bare $var adjacent to non-ASCII\n'
else
  printf 'FAIL start.sh: a bare $var is glued to a non-ASCII char (use ${var}) — line:\n'
  perl -ne 'print "  $.: $_" if /\$[A-Za-z_][A-Za-z0-9_]*[\x80-\xff]/' "$ROOT/start.sh"
  ADK_FAIL=1
fi

# 场景 A:AUTO_INJECT=1 → 无询问,写块,claude 带 --append-system-prompt
setup
AGENT_DUO_AUTO_INJECT=1 run_start </dev/null
assert_ok        "A: AGENTS.md created" test -f "$PROJECT/AGENTS.md"
assert_contains  "A: block written"     "$(cat "$PROJECT/AGENTS.md")" '<!-- agent-duo:start -->'
assert_contains  "A: claude got flag"   "$(cat "$SENDLOG")" '--append-system-prompt'
assert_ok        "A: supervisor settings created" test -f "$PROJECT/.agent-duo/state/supervisor/session-settings.json"
assert_contains  "A: supervisor settings has Stop hook" "$(cat "$PROJECT/.agent-duo/state/supervisor/session-settings.json")" 'supervisor-stop-drain-hook'
assert_contains  "A: claude loads settings" "$(cat "$SENDLOG")" '--settings'
teardown

# 场景 B:已有块 → 友好提示,不重复块,claude 仍带参数
setup
printf '%s\n%s\n%s\n' '<!-- agent-duo:start -->' 'x' '<!-- agent-duo:end -->' > "$PROJECT/AGENTS.md"
run_start </dev/null
cnt="$(grep -cF '<!-- agent-duo:start -->' "$PROJECT/AGENTS.md")"
assert_eq        "B: no duplicate block" "$cnt" "1"
assert_contains  "B: friendly notice"    "$(cat "$SCENARIO_TMP/out.txt")" '已就绪'
assert_contains  "B: claude got flag"    "$(cat "$SENDLOG")" '--append-system-prompt'
teardown

# 场景 C:非交互(无 TTY)、无 AUTO → 跳过注入,裸 claude,打印手动说明
setup
run_start </dev/null
assert_ok        "C: no AGENTS.md written" test ! -f "$PROJECT/AGENTS.md"
assert_not_contains "C: claude is plain" "$(cat "$SENDLOG")" '--append-system-prompt'
assert_contains  "C: prints manual hint" "$(cat "$SCENARIO_TMP/out.txt")" 'AGENT_DUO_AUTO_INJECT'
teardown

# 场景 D:-y 标志(等价于 AGENT_DUO_AUTO_INJECT),验证 start.sh 的 flag 解析循环。
# 注意:run_start 把额外参数当作环境变量前缀,故这里直接调用 start.sh 并把 -y 作为参数传入。
setup
PATH="$STUB_BIN:$PATH" AGENT_SESSION=adktest bash "$ROOT/start.sh" "$PROJECT" -y \
  </dev/null >"$SCENARIO_TMP/out.txt" 2>&1
assert_ok        "D: AGENTS.md created (-y)" test -f "$PROJECT/AGENTS.md"
assert_contains  "D: block written (-y)"    "$(cat "$PROJECT/AGENTS.md")" '<!-- agent-duo:start -->'
assert_contains  "D: claude got flag (-y)"  "$(cat "$SENDLOG")" '--append-system-prompt'
teardown

# 场景 E:缺少 claude/codex 预检失败,且不创建 tmux pane。
setup
rm -f "$STUB_BIN/codex"
TEST_PATH="$STUB_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
if run_start </dev/null; then
  printf 'FAIL E: missing codex should fail\n'
  ADK_FAIL=1
else
  printf 'ok   E: missing codex fails before launch\n'
fi
assert_not_contains "E: no panes launched" "$(cat "$SENDLOG")" 'send-keys'
assert_contains  "E: error mentions codex" "$(cat "$SCENARIO_TMP/out.txt")" '找不到 codex'
teardown

# 场景 E2:--with provider 非法 → 预检失败,不能留下半启动 tmux session。
setup
if PATH="$STUB_BIN:$PATH" AGENT_DUO_AUTO_INJECT=1 \
  bash "$ROOT/start.sh" "$PROJECT" --with bad:worker \
  </dev/null >"$SCENARIO_TMP/out.txt" 2>&1; then
  printf 'FAIL E2: invalid --with provider should fail\n'
  ADK_FAIL=1
else
  printf 'ok   E2: invalid --with provider fails before launch\n'
fi
assert_not_contains "E2: no session launched" "$(cat "$SENDLOG")" 'new-session'
assert_contains "E2: error mentions provider" "$(cat "$SCENARIO_TMP/out.txt")" 'provider 必须是 claude 或 codex'
teardown

# 场景 F:默认 → supervisor + loopd 窗口,都打 @agent_* 标签。
# 注意:不设 AGENT_SESSION,以验证默认会话名 "agents"。
setup
PATH="$STUB_BIN:$PATH" AGENT_DUO_AUTO_INJECT=1 \
  bash "$ROOT/start.sh" "$PROJECT" \
  </dev/null >"$SCENARIO_TMP/out.txt" 2>&1
assert_contains     "F: single supervisor window"   "$(cat "$SENDLOG")" 'new-session -d -s agents -n supervisor'
assert_contains     "F: tags supervisor id"          "$(cat "$SENDLOG")" 'set-option -p -t %1 @agent_id supervisor'
assert_contains     "F: tags supervisor provider"    "$(cat "$SENDLOG")" 'set-option -p -t %1 @agent_provider claude'
assert_contains     "F: launches claude"             "$(cat "$SENDLOG")" 'send-keys -t %1'
assert_contains     "F: creates loopd window"         "$(cat "$SENDLOG")" 'new-window -t agents -n loopd'
assert_contains     "F: tags loopd id"                "$(cat "$SENDLOG")" '@agent_id loopd'
assert_contains     "F: tags loopd role"              "$(cat "$SENDLOG")" '@agent_role daemon'
assert_contains     "F: launches loopd"               "$(cat "$SENDLOG")" 'peer loopd'
teardown

# 场景 G:--supervisor codex → supervisor provider 为 codex,且仍启动 loopd。
# 注意:不设 AGENT_SESSION,以验证默认会话名 "agents"。
setup
PATH="$STUB_BIN:$PATH" AGENT_DUO_AUTO_INJECT=1 \
  bash "$ROOT/start.sh" "$PROJECT" --supervisor codex \
  </dev/null >"$SCENARIO_TMP/out.txt" 2>&1
assert_contains     "G: tags supervisor provider codex" "$(cat "$SENDLOG")" 'set-option -p -t %1 @agent_provider codex'
assert_contains     "G: launches codex"                 "$(cat "$SENDLOG")" 'send-keys -t %1 export AGENT_SESSION=agents'
assert_contains     "G: codex supervisor gets settings env" "$(cat "$SENDLOG")" 'AGENT_DUO_SUPERVISOR_SETTINGS='
assert_contains     "G: codex supervisor has user hook config" "$(cat "$SENDLOG")" 'hooks.UserPromptSubmit'
assert_contains     "G: codex supervisor has stop hook config" "$(cat "$SENDLOG")" 'hooks.Stop'
assert_contains     "G: creates loopd window"            "$(cat "$SENDLOG")" 'new-window -t agents -n loopd'
assert_contains     "G: launches loopd"                  "$(cat "$SENDLOG")" 'peer loopd'
teardown

# 场景 H:--with codex:worker → loopd 之外额外创建一个 worker 窗口,打 @agent_* 标签,启动 codex。
setup
PATH="$STUB_BIN:$PATH" AGENT_SESSION=adktest AGENT_DUO_AUTO_INJECT=1 \
  bash "$ROOT/start.sh" "$PROJECT" --with codex:worker \
  </dev/null >"$SCENARIO_TMP/out.txt" 2>&1
assert_contains  "H: supervisor still claude" "$(cat "$SENDLOG")" 'set-option -p -t %1 @agent_provider claude'
assert_contains  "H: creates loopd window"    "$(cat "$SENDLOG")" 'new-window -t adktest -n loopd'
assert_contains  "H: launches loopd"          "$(cat "$SENDLOG")" 'peer loopd'
assert_contains  "H: creates worker window"   "$(cat "$SENDLOG")" 'new-window -t adktest -n worker'
assert_contains  "H: tags worker id"          "$(cat "$SENDLOG")" '@agent_id worker'
assert_contains  "H: tags worker provider"    "$(cat "$SENDLOG")" '@agent_provider codex'
assert_contains  "H: launches worker"         "$(cat "$SENDLOG")" 'send-keys -t %2'
assert_ok        "H: worker settings created" test -f "$PROJECT/.agent-duo/state/worker/session-settings.json"
assert_contains  "H: worker exports approval settings" "$(cat "$SENDLOG")" 'AGENT_DUO_APPROVAL_SETTINGS='
assert_contains  "H: worker exports approval hook" "$(cat "$SENDLOG")" 'AGENT_DUO_APPROVAL_HOOK='
assert_contains  "H: codex worker has pretool hook config" "$(cat "$SENDLOG")" 'hooks.PreToolUse'
teardown

# 场景 I:--with claude:reviewer → worker settings 进入 Claude 启动参数。
setup
PATH="$STUB_BIN:$PATH" AGENT_SESSION=adktest AGENT_DUO_AUTO_INJECT=1 \
  bash "$ROOT/start.sh" "$PROJECT" --with claude:reviewer \
  </dev/null >"$SCENARIO_TMP/out.txt" 2>&1
assert_ok        "I: reviewer settings created" test -f "$PROJECT/.agent-duo/state/reviewer/session-settings.json"
assert_contains  "I: reviewer loads settings" "$(cat "$SENDLOG")" '--settings'
assert_contains  "I: reviewer settings path" "$(cat "$SENDLOG")" '.agent-duo/state/reviewer/session-settings.json'
teardown

# 说明:prompt 分支(无块 + 无 AUTO + 有 TTY)需要伪终端才能驱动,本无依赖测试框架无法模拟;
# 其决策路径(adk_plan→prompt、adk_answer_yes)已由 test/inject.test.sh 的单元测试覆盖。

exit "$ADK_FAIL"
