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

exit "$ADK_FAIL"
