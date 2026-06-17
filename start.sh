#!/usr/bin/env bash
# start.sh — 创建一个 tmux 会话,起一个 supervisor 窗口(默认 claude),
#            并注入 peer 工具,使 supervisor 可按需 `peer add` 长出更多 agent。
#
# 用法:
#   ./start.sh [工作目录] [--supervisor claude|codex] [--with <provider>:<role>]
#   ./start.sh                       # 默认为当前目录,supervisor=claude,无额外 worker
#   ./start.sh --supervisor codex    # supervisor 用 codex
#   ./start.sh --with codex:worker   # 额外起一个 codex worker(等价稍后 peer add)
#
# 启动后在 iTerm2 里执行:
#   tmux -CC attach -t agents
# iTerm2 可把 tmux 窗口渲染成原生 tab。若被打开成 macOS 窗口,
# 到 iTerm2 Settings > General > tmux 将 "When attaching, restore windows as..."
# 设为 "Tabs in the attaching window"。

set -euo pipefail

SESSION="${AGENT_SESSION:-agents}"

# 解析 -y/--yes、--supervisor <provider>、--with <provider>:<role>(其余参数原样保留);
# AGENT_DUO_AUTO_INJECT=1 等价于 -y。
AUTO=0
[[ "${AGENT_DUO_AUTO_INJECT:-0}" == "1" ]] && AUTO=1
SUPERVISOR_PROVIDER="claude"
WITH_SPEC=""   # 形如 codex:worker
_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) AUTO=1; shift ;;
    --supervisor) SUPERVISOR_PROVIDER="${2:-}"; shift 2 ;;
    --with) WITH_SPEC="${2:-}"; shift 2 ;;
    *) _args+=("$1"); shift ;;
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
APPROVAL_BROKER="$SCRIPT_DIR/lib/approval_broker.sh"
APPROVAL_HOOK="$SCRIPT_DIR/bin/agent-duo-approval-hook"
if [[ ! -f "$LIB_DIR/inject.sh" ]]; then
  echo "错误: 找不到 $LIB_DIR/inject.sh,请确认 agent-duo 安装完整。" >&2
  exit 1
fi
if [[ ! -f "$LIB_DIR/registry.sh" ]]; then
  echo "错误: 找不到 $LIB_DIR/registry.sh,请确认 agent-duo 安装完整。" >&2
  exit 1
fi
if [[ ! -f "$INSTR" ]]; then
  echo "错误: 找不到 $INSTR,请确认 agent-duo 安装完整。" >&2
  exit 1
fi
if [[ ! -f "$APPROVAL_BROKER" || ! -f "$APPROVAL_HOOK" ]]; then
  echo "错误: 找不到 approval broker 组件,请确认 agent-duo 安装完整。" >&2
  exit 1
fi
# shellcheck source=lib/inject.sh
source "$LIB_DIR/inject.sh"
# shellcheck source=lib/registry.sh
source "$LIB_DIR/registry.sh"

if ! reg_validate_provider "$SUPERVISOR_PROVIDER"; then
  echo "错误: --supervisor 必须是 claude 或 codex,当前为 '$SUPERVISOR_PROVIDER'。" >&2
  exit 1
fi

if ! command -v tmux >/dev/null; then
  echo "请先安装 tmux: brew install tmux" >&2
  exit 1
fi

if ! command -v jq >/dev/null; then
  echo "请先安装 jq: brew install jq" >&2
  exit 1
fi

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "会话 '$SESSION' 已存在。附加: tmux -CC attach -t $SESSION"
  exit 0
fi

missing_cmd=0
for agent_cmd in claude codex; do
  if ! command -v "$agent_cmd" >/dev/null; then
    echo "错误: 找不到 $agent_cmd,请先安装并确保它在 PATH 上。" >&2
    missing_cmd=1
  fi
done
if (( missing_cmd != 0 )); then
  exit 1
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
      do_inject=1
    else
      echo "✗ 写入 $AGENTS_MD 失败,已跳过注入。" >&2
      do_inject=0
    fi
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
      if adk_inject_codex "$AGENTS_MD" "$INSTR"; then
        echo "✓ 已写入 ${AGENTS_MD}。"
        do_inject=1
      else
        echo "✗ 写入 $AGENTS_MD 失败,已跳过注入。" >&2
        do_inject=0
      fi
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

shell_quote() {
  printf '%q' "$1"
}

write_supervisor_session_settings() { # <root>
  local root="$1" settings_dir settings_path tmp user_hook stop_hook user_cmd stop_cmd
  settings_dir="$root/.agent-duo/state/supervisor"
  settings_path="$settings_dir/session-settings.json"
  mkdir -p "$settings_dir"
  user_hook="$SCRIPT_DIR/scripts/supervisor-user-prompt-submit-hook"
  stop_hook="$SCRIPT_DIR/scripts/supervisor-stop-drain-hook"
  user_cmd="AGENT_DUO_ROOT=$(shell_quote "$root") $(shell_quote "$user_hook")"
  stop_cmd="AGENT_DUO_ROOT=$(shell_quote "$root") $(shell_quote "$stop_hook")"
  tmp="$settings_path.$$"
  jq -cn \
    --arg user_cmd "$user_cmd" \
    --arg stop_cmd "$stop_cmd" \
    '{
      agent_duo_loop: {version: 1, role: "supervisor"},
      hooks: {
        UserPromptSubmit: [{hooks: [{type: "command", command: $user_cmd}]}],
        Stop: [{hooks: [{type: "command", command: $stop_cmd}]}]
      }
    }' > "$tmp"
  mv -f "$tmp" "$settings_path"
  printf '%s' "$settings_path"
}

toml_string() { # <value>
  jq -Rn --arg s "$1" '$s | @json'
}

codex_hook_config() { # <event> <command> [matcher]
  local event="$1" command="$2" matcher="${3:-}" command_toml
  command_toml="$(toml_string "$command")"
  if [[ -n "$matcher" ]]; then
    printf 'hooks.%s=[{matcher="%s",hooks=[{type="command",command=%s}]}]' "$event" "$matcher" "$command_toml"
  else
    printf 'hooks.%s=[{hooks=[{type="command",command=%s}]}]' "$event" "$command_toml"
  fi
}

SESSION_Q="$(shell_quote "$SESSION")"
BIN_DIR_Q="$(shell_quote "$BIN_DIR")"
WORKDIR_Q="$(shell_quote "$WORKDIR")"
SUP_SETTINGS="$(write_supervisor_session_settings "$WORKDIR")"
SUP_SETTINGS_Q="$(shell_quote "$SUP_SETTINGS")"
SUP_USER_CMD="$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$SUP_SETTINGS")"
SUP_STOP_CMD="$(jq -r '.hooks.Stop[0].hooks[0].command' "$SUP_SETTINGS")"

# 单 supervisor 窗口(默认 claude,可用 --supervisor 指定 codex)。
# 身份走 tmux per-pane 用户选项 @agent_*,不再注入 AGENT_NAME。
SUP_PANE="$(tmux new-session -d -s "$SESSION" -n supervisor -c "$WORKDIR" -P -F '#{pane_id}')"
tmux set-option -p -t "$SUP_PANE" @agent_id supervisor
tmux set-option -p -t "$SUP_PANE" @agent_role supervisor
tmux set-option -p -t "$SUP_PANE" @agent_provider "$SUPERVISOR_PROVIDER"

if [[ "$SUPERVISOR_PROVIDER" == "claude" ]]; then
  SUP_LAUNCH="$CLAUDE_LAUNCH --settings $SUP_SETTINGS_Q"
else
  SUP_LAUNCH="codex -c $(shell_quote "$(codex_hook_config UserPromptSubmit "$SUP_USER_CMD")") -c $(shell_quote "$(codex_hook_config Stop "$SUP_STOP_CMD")")"
fi
tmux send-keys -t "$SUP_PANE" \
  "export AGENT_SESSION=$SESSION_Q AGENT_DUO_ROOT=$WORKDIR_Q AGENT_DUO_SUPERVISOR_SETTINGS=$SUP_SETTINGS_Q PATH=$BIN_DIR_Q:\$PATH; $SUP_LAUNCH" Enter

# loopd 是可见 pane:负责 cursor 投递、liveness/tick 与看板。
LOOPD_PANE="$(tmux new-window -t "$SESSION" -n loopd -c "$WORKDIR" -P -F '#{pane_id}')"
tmux set-option -p -t "$LOOPD_PANE" @agent_id loopd
tmux set-option -p -t "$LOOPD_PANE" @agent_role daemon
tmux set-option -p -t "$LOOPD_PANE" @agent_provider bash
tmux send-keys -t "$LOOPD_PANE" \
  "export AGENT_SESSION=$SESSION_Q AGENT_DUO_ROOT=$WORKDIR_Q PATH=$BIN_DIR_Q:\$PATH; peer loopd" Enter

# --with <provider>:<role> → 立即再起一个 worker(等价 peer add)。
if [[ -n "$WITH_SPEC" ]]; then
  W_PROVIDER="${WITH_SPEC%%:*}"
  W_ROLE="${WITH_SPEC#*:}"
  if ! reg_validate_provider "$W_PROVIDER"; then
    echo "错误: --with 的 provider 必须是 claude 或 codex,当前为 '$W_PROVIDER'。" >&2
    exit 1
  fi
  W_PANE="$(tmux new-window -t "$SESSION" -n "$W_ROLE" -c "$WORKDIR" -P -F '#{pane_id}')"
  tmux set-option -p -t "$W_PANE" @agent_id "$W_ROLE"
  tmux set-option -p -t "$W_PANE" @agent_role "$W_ROLE"
  tmux set-option -p -t "$W_PANE" @agent_provider "$W_PROVIDER"
  W_SETTINGS="$(bash "$APPROVAL_BROKER" install \
    --agent-id "$W_ROLE" \
    --provider "$W_PROVIDER" \
    --hook "$APPROVAL_HOOK" \
    --root "$WORKDIR" \
    --worktree "$WORKDIR")"
  W_LAUNCH="$(reg_provider_launch_cmd "$W_PROVIDER" "$INSTR")"
  if [[ "$W_PROVIDER" == "claude" ]]; then
    W_LAUNCH="$W_LAUNCH --settings $(shell_quote "$W_SETTINGS")"
  else
    W_HOOK_CMD="$(jq -r '.codex.managed_hook_command' "$W_SETTINGS")"
    W_LAUNCH="$W_LAUNCH -c $(shell_quote "$(codex_hook_config PreToolUse "$W_HOOK_CMD" "*")")"
  fi
  W_ID_Q="$(shell_quote "$W_ROLE")"
  APPROVAL_HOOK_Q="$(shell_quote "$APPROVAL_HOOK")"
  W_SETTINGS_Q="$(shell_quote "$W_SETTINGS")"
  tmux send-keys -t "$W_PANE" \
    "export AGENT_SESSION=$SESSION_Q AGENT_DUO_ROOT=$WORKDIR_Q AGENT_DUO_AGENT_ID=$W_ID_Q AGENT_DUO_WORKTREE=$WORKDIR_Q AGENT_DUO_APPROVAL_HOOK=$APPROVAL_HOOK_Q AGENT_DUO_APPROVAL_SETTINGS=$W_SETTINGS_Q PATH=$BIN_DIR_Q:\$PATH; $W_LAUNCH" Enter
fi

cat <<EOF
✅ 会话 '$SESSION' 已创建(工作目录: $WORKDIR)

在 iTerm2 中附加(推荐,窗口会变成原生 tab):
    tmux -CC attach -t $SESSION

如果被打开成 macOS 窗口:
    iTerm2 Settings > General > tmux > When attaching, restore windows as... = Tabs in the attaching window

或普通模式附加:
    tmux attach -t $SESSION

结束会话:
    tmux kill-session -t $SESSION
EOF
