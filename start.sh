#!/usr/bin/env bash
# start.sh — 创建一个 tmux 会话,两个窗口分别运行 Claude Code 和 Codex,
#            并注入 peer 工具,使两者可以互相查看输出、互发指令。
#
# 用法:
#   ./start.sh [工作目录]     # 默认为当前目录
#
# 启动后在 iTerm2 里执行:
#   tmux -CC attach -t agents
# iTerm2 可把两个 tmux 窗口渲染成两个原生 tab。若被打开成两个 macOS 窗口,
# 到 iTerm2 Settings > General > tmux 将 "When attaching, restore windows as..."
# 设为 "Tabs in the attaching window"。

set -euo pipefail

SESSION="${AGENT_SESSION:-agents}"

# 解析 -y/--yes(其余参数原样保留);AGENT_DUO_AUTO_INJECT=1 等价于 -y。
AUTO=0
[[ "${AGENT_DUO_AUTO_INJECT:-0}" == "1" ]] && AUTO=1
_args=()
for _a in "$@"; do
  case "$_a" in
    -y|--yes) AUTO=1 ;;
    *) _args+=("$_a") ;;
  esac
done
set -- ${_args[@]+"${_args[@]}"}

WORKDIR="$(cd "${1:-$PWD}" && pwd)"
# 解引用软链接,保证从 ~/.local/bin 调用时也能定位到仓库里的 bin/
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do SOURCE="$(readlink "$SOURCE")"; done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
BIN_DIR="$SCRIPT_DIR/bin"
LIB_DIR="$SCRIPT_DIR/lib"
INSTR="$SCRIPT_DIR/docs/AGENT-INSTRUCTIONS.md"
# shellcheck source=lib/inject.sh
source "$LIB_DIR/inject.sh"

if ! command -v tmux >/dev/null; then
  echo "请先安装 tmux: brew install tmux" >&2
  exit 1
fi

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "会话 '$SESSION' 已存在。附加: tmux -CC attach -t $SESSION"
  exit 0
fi

# ---- 注入 peer 协作提示词(方案 B:Claude 走启动参数,Codex 写 AGENTS.md 块)----
AGENTS_MD="$WORKDIR/AGENTS.md"
has_block=0; adk_has_block "$AGENTS_MD" && has_block=1
is_tty=0; [[ -t 0 ]] && is_tty=1
do_inject=0
case "$(adk_plan "$has_block" "$AUTO" "$is_tty")" in
  reminder)
    do_inject=1
    echo "✓ peer 协作提示词已就绪(Codex 块在 $AGENTS_MD;Claude 走启动参数)。"
    ;;
  auto)
    if adk_inject_codex "$AGENTS_MD" "$INSTR"; then
      echo "✓ 已在 $AGENTS_MD 写入 peer 协作块(-y / AGENT_DUO_AUTO_INJECT)。"
    fi
    do_inject=1
    ;;
  prompt)
    cat <<EOF
agent-duo 需要让两个 agent 知道 peer 协作能力,注入方式:
  • Claude:启动参数 --append-system-prompt(临时,不写任何文件,会话结束即消失)
  • Codex :在 $AGENTS_MD 追加一个带标记、可撤销的块(它没有等价启动参数)
CLAUDE.md 不会被改动。
EOF
    printf '是否继续? [y/N] '
    read -r ans || ans=""
    if adk_answer_yes "$ans"; then
      adk_inject_codex "$AGENTS_MD" "$INSTR" && echo "✓ 已写入 $AGENTS_MD。"
      do_inject=1
    else
      do_inject=0
      cat <<EOF
已跳过自动注入。若想手动启用,把 docs/AGENT-INSTRUCTIONS.md 的正文追加到:
  • 本项目的 CLAUDE.md(给 Claude Code)
  • 本项目的 AGENTS.md(给 Codex)
EOF
    fi
    ;;
  skip)
    do_inject=0
    cat <<EOF
[提示] 非交互环境,已跳过提示词注入。如需自动注入请加 -y 或设 AGENT_DUO_AUTO_INJECT=1。
手动方式:把 docs/AGENT-INSTRUCTIONS.md 的正文追加到项目的 CLAUDE.md 和 AGENTS.md。
EOF
    ;;
esac
CLAUDE_LAUNCH="$(adk_claude_cmd "$do_inject" "$INSTR")"

# 窗口 1: claude
tmux new-session -d -s "$SESSION" -n claude -c "$WORKDIR"
tmux send-keys -t "$SESSION:claude" \
  "export AGENT_NAME=claude AGENT_SESSION=$SESSION PATH=\"$BIN_DIR:\$PATH\"; $CLAUDE_LAUNCH" Enter

# 窗口 2: codex
tmux new-window -t "$SESSION" -n codex -c "$WORKDIR"
tmux send-keys -t "$SESSION:codex" \
  "export AGENT_NAME=codex AGENT_SESSION=$SESSION PATH=\"$BIN_DIR:\$PATH\"; codex" Enter

cat <<EOF
✅ 会话 '$SESSION' 已创建(工作目录: $WORKDIR)

在 iTerm2 中附加(推荐,两个窗口会变成原生 tab):
    tmux -CC attach -t $SESSION

如果被打开成两个 macOS 窗口:
    iTerm2 Settings > General > tmux > When attaching, restore windows as... = Tabs in the attaching window

或普通模式附加:
    tmux attach -t $SESSION

结束会话:
    tmux kill-session -t $SESSION
EOF
