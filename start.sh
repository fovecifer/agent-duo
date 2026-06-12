#!/usr/bin/env bash
# start.sh — 创建一个 tmux 会话,两个窗口分别运行 Claude Code 和 Codex,
#            并注入 peer 工具,使两者可以互相查看输出、互发指令。
#
# 用法:
#   ./start.sh [工作目录]     # 默认为当前目录
#
# 启动后在 iTerm2 里执行:
#   tmux -CC attach -t agents
# iTerm2 会把两个 tmux 窗口渲染成两个原生 tab,体验与平时无异。

set -euo pipefail

SESSION="${AGENT_SESSION:-agents}"
WORKDIR="$(cd "${1:-$PWD}" && pwd)"
# 解引用软链接,保证从 ~/.local/bin 调用时也能定位到仓库里的 bin/
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do SOURCE="$(readlink "$SOURCE")"; done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
BIN_DIR="$SCRIPT_DIR/bin"

if ! command -v tmux >/dev/null; then
  echo "请先安装 tmux: brew install tmux" >&2
  exit 1
fi

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "会话 '$SESSION' 已存在。附加: tmux -CC attach -t $SESSION"
  exit 0
fi

# 窗口 1: claude
tmux new-session -d -s "$SESSION" -n claude -c "$WORKDIR"
tmux send-keys -t "$SESSION:claude" \
  "export AGENT_NAME=claude AGENT_SESSION=$SESSION PATH=\"$BIN_DIR:\$PATH\"; claude" Enter

# 窗口 2: codex
tmux new-window -t "$SESSION" -n codex -c "$WORKDIR"
tmux send-keys -t "$SESSION:codex" \
  "export AGENT_NAME=codex AGENT_SESSION=$SESSION PATH=\"$BIN_DIR:\$PATH\"; codex" Enter

cat <<EOF
✅ 会话 '$SESSION' 已创建(工作目录: $WORKDIR)

在 iTerm2 中附加(推荐,两个窗口会变成原生 tab):
    tmux -CC attach -t $SESSION

或普通模式附加:
    tmux attach -t $SESSION

结束会话:
    tmux kill-session -t $SESSION
EOF
