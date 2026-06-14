#!/usr/bin/env bash
# test/start.test.sh — start.sh 注入接线的集成测试(用 stub 替换 tmux/claude/codex)
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
source "$DIR/assert.sh"

# 为每个场景搭建:stub bin + 干净项目目录 + send-keys 日志
setup() {
  SCENARIO_TMP="$(mktemp -d)"
  STUB_BIN="$SCENARIO_TMP/bin"; mkdir -p "$STUB_BIN"
  PROJECT="$SCENARIO_TMP/project"; mkdir -p "$PROJECT"
  SENDLOG="$SCENARIO_TMP/sendkeys.log"; : > "$SENDLOG"

  # tmux stub:has-session 返回 1(无会话),send-keys 记录参数,其它成功。
  cat > "$STUB_BIN/tmux" <<STUB
#!/usr/bin/env bash
case "\$1" in
  has-session) exit 1 ;;
  send-keys)   printf '%s\n' "\$*" >> "$SENDLOG"; exit 0 ;;
  *)           exit 0 ;;
esac
STUB
  chmod +x "$STUB_BIN/tmux"
  # claude/codex stub:存在即可,绝不应被真正执行(start.sh 只 send-keys 字符串)
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/claude"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/codex"
  chmod +x "$STUB_BIN/claude" "$STUB_BIN/codex"
}
teardown() { rm -rf "$SCENARIO_TMP"; }

run_start() { # 在 stub PATH + 指定 stdin/env 下运行 start.sh
  PATH="$STUB_BIN:$PATH" AGENT_SESSION=adktest "$@" bash "$ROOT/start.sh" "$PROJECT" \
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

# 说明:prompt 分支(无块 + 无 AUTO + 有 TTY)需要伪终端才能驱动,本无依赖测试框架无法模拟;
# 其决策路径(adk_plan→prompt、adk_answer_yes)已由 test/inject.test.sh 的单元测试覆盖。

exit "$ADK_FAIL"
