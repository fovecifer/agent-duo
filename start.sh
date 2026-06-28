#!/usr/bin/env bash
# start.sh — 创建一个 tmux 会话,起一个 supervisor 窗口(默认 claude),
#            并注入 peer 工具,使 supervisor 可按需 `peer agent add` 长出更多 agent。
#
# 用法:
#   ./start.sh [工作目录] [--supervisor claude|codex] [--with <provider>:<role>[:isolated]]
#   ./start.sh                       # 默认为当前目录,supervisor=claude,无额外 worker
#   ./start.sh --supervisor codex    # supervisor 用 codex
#   ./start.sh --with codex:worker   # 额外起一个 codex worker(等价稍后 peer agent add)
#   ./start.sh --with codex:worker:isolated  # worker 在隔离 git worktree 中启动
#
# 启动后在 iTerm2 里执行:
#   tmux -CC attach -t agents
# iTerm2 可把 tmux 窗口渲染成原生 tab。若被打开成 macOS 窗口,
# 到 iTerm2 Settings > General > tmux 将 "When attaching, restore windows as..."
# 设为 "Tabs in the attaching window"。

set -euo pipefail

usage() {
  cat <<'EOF'
用法:
  agent-duo-start [工作目录] [--supervisor claude|codex] [--with <provider>:<role>[:isolated]] [-y]

示例:
  agent-duo-start
  agent-duo-start --supervisor codex
  agent-duo-start --with codex:worker
  agent-duo-start --with codex:worker:isolated

选项:
  -y, --yes        非交互注入 peer 协作说明
  -h, --help       显示帮助
EOF
}

usage_error() { # <message>
  printf '错误: %s\n\n' "$1" >&2
  usage >&2
  exit 2
}

SESSION="${AGENT_SESSION:-agents}"

# 解析 -y/--yes、-h/--help、--supervisor <provider>、--with <provider>:<role>[:isolated](其余参数原样保留);
# AGENT_DUO_AUTO_INJECT=1 等价于 -y。
AUTO=0
[[ "${AGENT_DUO_AUTO_INJECT:-0}" == "1" ]] && AUTO=1
SUPERVISOR_PROVIDER="claude"
WITH_SPEC=""   # 形如 codex:worker 或 codex:worker:isolated
WITH_PROVIDER=""
WITH_ROLE=""
WITH_ISOLATED=0
_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -y|--yes) AUTO=1; shift ;;
    --supervisor)
      [[ $# -ge 2 && "${2:-}" != --* ]] || usage_error "--supervisor 需要参数 claude 或 codex"
      SUPERVISOR_PROVIDER="$2"
      shift 2
      ;;
    --with)
      [[ $# -ge 2 && "${2:-}" != --* ]] || usage_error "--with 需要参数 <provider>:<role>[:isolated]"
      WITH_SPEC="$2"
      shift 2
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        _args+=("$1")
        shift
      done
      ;;
    -*) usage_error "未知选项 '$1'" ;;
    *) _args+=("$1"); shift ;;
  esac
done
set -- ${_args[@]+"${_args[@]}"}
if [[ "$#" -gt 1 ]]; then
  usage_error "只能指定一个工作目录"
fi

WORKDIR="$(cd -- "${1:-$PWD}" && pwd)"
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
if [[ -n "$WITH_SPEC" ]]; then
  if [[ "$WITH_SPEC" != *:* ]]; then
    echo "错误: --with 必须形如 <provider>:<role> 或 <provider>:<role>:isolated,当前为 '$WITH_SPEC'。" >&2
    exit 1
  fi
  if [[ "$WITH_SPEC" == *:*:*:* ]]; then
    echo "错误: --with 必须形如 <provider>:<role> 或 <provider>:<role>:isolated,当前为 '$WITH_SPEC'。" >&2
    exit 1
  fi
  WITH_PROVIDER="${WITH_SPEC%%:*}"
  WITH_REST="${WITH_SPEC#*:}"
  if [[ "$WITH_REST" == *:* ]]; then
    WITH_ROLE="${WITH_REST%%:*}"
    WITH_MODE="${WITH_REST#*:}"
    if [[ "$WITH_MODE" != "isolated" ]]; then
      echo "错误: --with 的第三段只支持 isolated,当前为 '$WITH_MODE'。" >&2
      exit 1
    fi
    WITH_ISOLATED=1
  else
    WITH_ROLE="$WITH_REST"
  fi
  if ! reg_validate_provider "$WITH_PROVIDER"; then
    echo "错误: --with 的 provider 必须是 claude 或 codex,当前为 '$WITH_PROVIDER'。" >&2
    exit 1
  fi
  if [[ -z "$WITH_ROLE" ]]; then
    echo "错误: --with 必须指定非空 role,当前为 '$WITH_SPEC'。" >&2
    exit 1
  fi
  if ! reg_is_role_token "$WITH_ROLE"; then
    echo "错误: --with 的 role 只能包含字母、数字、点、下划线和连字符,且必须以字母或数字开头,当前为 '$WITH_ROLE'。" >&2
    exit 1
  fi
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

write_launch_script() { # <root> <agent-id> <body>
  local root="$1" agent_id="$2" body="$3" dir path tmp
  dir="$root/.agent-duo/state/$agent_id"
  path="$dir/launch.sh"
  mkdir -p "$dir"
  tmp="$path.$$"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -uo pipefail\n'
    printf '%s\n' "$body"
    cat <<'EOF'
status=$?
printf '\n[agent-duo] launch exited with status %s\n' "$status" >&2
exec "${SHELL:-/bin/zsh}" -l
EOF
  } > "$tmp"
  chmod +x "$tmp"
  mv -f "$tmp" "$path"
  printf '%s' "$path"
}

launch_script_command() { # <script-path>
  printf '/bin/bash %q' "$1"
}

write_supervisor_session_settings() { # <root>
  local root="$1" settings_dir settings_path tmp user_hook stop_hook user_cmd stop_cmd
  settings_dir="$root/.agent-duo/state/supervisor"
  settings_path="$settings_dir/session-settings.json"
  mkdir -p "$settings_dir"
  user_hook="$SCRIPT_DIR/scripts/supervisor-user-prompt-submit-hook"
  stop_hook="$SCRIPT_DIR/scripts/supervisor-stop-drain-hook"
  user_cmd="AGENT_DUO_ROOT=$(shell_quote "$root") /bin/bash $(shell_quote "$user_hook")"
  stop_cmd="AGENT_DUO_ROOT=$(shell_quote "$root") /bin/bash $(shell_quote "$stop_hook")"
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
  jq -Rn -r --arg s "$1" '$s | @json'
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

codex_shell_env_args() { # <agent_duo_bin_dir>
  local bin_dir="$1" tool_path
  tool_path="$bin_dir:${PATH:-}"
  printf -- '-c shell_environment_policy.inherit=all -c %s' \
    "$(shell_quote "shell_environment_policy.set.PATH=$(toml_string "$tool_path")")"
}

codex_tmux_access_args() {
  local sock_dir
  if [[ -n "${TMUX:-}" ]]; then
    sock_dir="${TMUX%%,*}"
    sock_dir="${sock_dir%/*}"
  else
    sock_dir="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"
  fi
  if [[ -d "$sock_dir" ]]; then
    sock_dir="$(cd "$sock_dir" && pwd -P)"
  fi
  printf -- '--sandbox workspace-write --add-dir %s -c %s' \
    "$(shell_quote "$sock_dir")" \
    "$(shell_quote "network.allow_unix_sockets=[$(toml_string "$sock_dir")]")"
}

SESSION_Q="$(shell_quote "$SESSION")"
BIN_DIR_Q="$(shell_quote "$BIN_DIR")"
WORKDIR_Q="$(shell_quote "$WORKDIR")"
SUP_SETTINGS="$(write_supervisor_session_settings "$WORKDIR")"
SUP_SETTINGS_Q="$(shell_quote "$SUP_SETTINGS")"
SUP_USER_CMD="$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$SUP_SETTINGS")"
SUP_STOP_CMD="$(jq -r '.hooks.Stop[0].hooks[0].command' "$SUP_SETTINGS")"

if [[ "$SUPERVISOR_PROVIDER" == "claude" ]]; then
  SUP_LAUNCH="$CLAUDE_LAUNCH --settings $SUP_SETTINGS_Q"
else
  SUP_LAUNCH="codex $(codex_shell_env_args "$BIN_DIR") $(codex_tmux_access_args) -c $(shell_quote "$(codex_hook_config UserPromptSubmit "$SUP_USER_CMD")") -c $(shell_quote "$(codex_hook_config Stop "$SUP_STOP_CMD")")"
fi
SUP_LAUNCH_SCRIPT="$(write_launch_script "$WORKDIR" supervisor \
  "export AGENT_SESSION=$SESSION_Q AGENT_DUO_ROOT=$WORKDIR_Q AGENT_DUO_AGENT_ID=supervisor AGENT_DUO_AGENT_ROLE=supervisor AGENT_DUO_AGENT_PROVIDER=$SUPERVISOR_PROVIDER AGENT_DUO_SUPERVISOR_SETTINGS=$SUP_SETTINGS_Q PATH=$BIN_DIR_Q:\$PATH; $SUP_LAUNCH")"

# 单 supervisor 窗口(默认 claude,可用 --supervisor 指定 codex)。
# 身份主路径走 tmux per-pane 用户选项 @agent_*;同时注入 AGENT_DUO_AGENT_ID,
# 兜底 Codex/Claude 工具子进程丢失 TMUX_PANE 的场景。
SUP_PANE="$(tmux new-session -d -s "$SESSION" -n supervisor -c "$WORKDIR" -P -F '#{pane_id}' "$(launch_script_command "$SUP_LAUNCH_SCRIPT")")"
tmux set-option -p -t "$SUP_PANE" @agent_id supervisor
tmux set-option -p -t "$SUP_PANE" @agent_role supervisor
tmux set-option -p -t "$SUP_PANE" @agent_provider "$SUPERVISOR_PROVIDER"

# loopd 是可见 pane:负责 cursor 投递、liveness/tick 与看板。
LOOPD_LAUNCH_SCRIPT="$(write_launch_script "$WORKDIR" loopd \
  "export AGENT_SESSION=$SESSION_Q AGENT_DUO_ROOT=$WORKDIR_Q AGENT_DUO_AGENT_ID=loopd AGENT_DUO_AGENT_ROLE=daemon AGENT_DUO_AGENT_PROVIDER=bash PATH=$BIN_DIR_Q:\$PATH; peer loopd")"
LOOPD_PANE="$(tmux new-window -t "$SESSION" -n loopd -c "$WORKDIR" -P -F '#{pane_id}' "$(launch_script_command "$LOOPD_LAUNCH_SCRIPT")")"
tmux set-option -p -t "$LOOPD_PANE" @agent_id loopd
tmux set-option -p -t "$LOOPD_PANE" @agent_role daemon
tmux set-option -p -t "$LOOPD_PANE" @agent_provider bash
mkdir -p "$WORKDIR/.agent-duo/state"
date +%s > "$WORKDIR/.agent-duo/state/daemon.expected"

# --with <provider>:<role> → 立即再起一个 worker(等价 peer agent add)。
if [[ -n "$WITH_SPEC" ]]; then
  W_PROVIDER="$WITH_PROVIDER"
  W_ROLE="$WITH_ROLE"
  W_WORKDIR="$WORKDIR"
  if [[ "$WITH_ISOLATED" == "1" ]]; then
    W_WORKDIR="$(reg_create_worktree "$W_ROLE" "$WORKDIR" "$SESSION")"
    reg_write_worktree_record "$WORKDIR" "$W_ROLE" "$W_WORKDIR" "$(reg_worktree_branch "$W_ROLE")"
  fi
  W_WORKDIR_Q="$(shell_quote "$W_WORKDIR")"
  W_SETTINGS="$(/bin/bash "$APPROVAL_BROKER" install \
    --agent-id "$W_ROLE" \
    --provider "$W_PROVIDER" \
    --hook "$APPROVAL_HOOK" \
    --root "$WORKDIR" \
    --worktree "$W_WORKDIR")"
  W_LAUNCH="$(reg_provider_launch_cmd "$W_PROVIDER" "$INSTR")"
  if [[ "$W_PROVIDER" == "claude" ]]; then
    W_LAUNCH="$W_LAUNCH --settings $(shell_quote "$W_SETTINGS")"
  else
    W_HOOK_CMD="$(jq -r '.codex.managed_hook_command' "$W_SETTINGS")"
    W_LAUNCH="$W_LAUNCH $(codex_shell_env_args "$BIN_DIR")"
    W_LAUNCH="$W_LAUNCH $(codex_tmux_access_args)"
    W_LAUNCH="$W_LAUNCH -c $(shell_quote "$(codex_hook_config PreToolUse "$W_HOOK_CMD" "*")")"
    W_LAUNCH="$W_LAUNCH -c $(shell_quote "$(codex_hook_config PermissionRequest "$W_HOOK_CMD" "*")")"
  fi
  W_ID_Q="$(shell_quote "$W_ROLE")"
  APPROVAL_HOOK_Q="$(shell_quote "$APPROVAL_HOOK")"
  W_SETTINGS_Q="$(shell_quote "$W_SETTINGS")"
  W_LAUNCH_SCRIPT="$(write_launch_script "$WORKDIR" "$W_ROLE" \
    "export AGENT_SESSION=$SESSION_Q AGENT_DUO_ROOT=$WORKDIR_Q AGENT_DUO_AGENT_ID=$W_ID_Q AGENT_DUO_AGENT_ROLE=$W_ID_Q AGENT_DUO_AGENT_PROVIDER=$W_PROVIDER AGENT_DUO_WORKTREE=$W_WORKDIR_Q AGENT_DUO_APPROVAL_HOOK=$APPROVAL_HOOK_Q AGENT_DUO_APPROVAL_SETTINGS=$W_SETTINGS_Q PATH=$BIN_DIR_Q:\$PATH; $W_LAUNCH")"
  W_PANE="$(tmux new-window -t "$SESSION" -n "$W_ROLE" -c "$W_WORKDIR" -P -F '#{pane_id}' "$(launch_script_command "$W_LAUNCH_SCRIPT")")"
  tmux set-option -p -t "$W_PANE" @agent_id "$W_ROLE"
  tmux set-option -p -t "$W_PANE" @agent_role "$W_ROLE"
  tmux set-option -p -t "$W_PANE" @agent_provider "$W_PROVIDER"
  if [[ "$WITH_ISOLATED" == "1" ]]; then
    tmux set-option -p -t "$W_PANE" @agent_worktree "$W_WORKDIR"
  fi
  # broker 起始为 unverified:hook 未被 provider 实际调用前不得假设其生效(等价 peer agent add)。
  # 必须覆盖同一 workdir 旧 session 可能残留的 fresh ready marker,否则硬门会误放行未信任的新 worker。
  /bin/bash "$APPROVAL_BROKER" mark --agent-id "$W_ROLE" --status unverified --root "$WORKDIR" >/dev/null 2>&1 || true
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

if [[ -n "$WITH_SPEC" ]]; then
  echo
  echo "新 worker '$W_ROLE' 的 Approval Broker 起始为 unverified(hook 未被 provider 实际调用前不可信)。"
  echo "派任务前先在 supervisor pane 运行 'peer approval check $W_ROLE' 验证 broker 生效——"
  echo "否则首次 'peer tell $W_ROLE ...' 会被硬门 fail-closed 拒发。"
fi

if [[ "$SUPERVISOR_PROVIDER" == "codex" || "${WITH_PROVIDER:-}" == "codex" ]]; then
  echo
  echo "Codex hook 提示: 若 Codex 启动时提示 hooks need review，请在该 Codex pane 内运行 /hooks 并信任 agent-duo hook；未信任前不要假设 Approval Broker 已生效。"
fi
