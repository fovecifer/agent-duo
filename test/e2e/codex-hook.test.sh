#!/usr/bin/env bash
# test/codex-hook-e2e.test.sh — 真实交互式 Codex CLI 的 Approval Broker 端到端 smoke。
#
# 覆盖两件事(都用真实 Codex + 真实 broker hook,把手工记录固化成可复现实跑):
#   1. 设计文档 2026-06-18 「修正建议 #5」:`-c hooks.PreToolUse` 的 deny 能在工具执行前阻断。
#   2. issue #9:hook 真的被 Codex 调用时,broker 就绪 marker 翻成 ready+nonce
#      (= `peer approval check` 据以判定 fail-closed 的信号)。
#
# 默认跳过(会真实调用 Codex/模型、慢、要联网+鉴权)。显式开启:
#   AGENT_DUO_E2E_CODEX=1 bash test/codex-hook-e2e.test.sh
# 缺 codex / tmux / ~/.codex/auth.json 时自动跳过,保持 `test/run.sh` 在任何机器上绿。
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
source "$DIR/../lib/assert.sh"

skip() { printf 'skip %s: %s\n' "codex-hook-e2e" "$1"; exit 0; }

[[ "${AGENT_DUO_E2E_CODEX:-}" == "1" ]] || skip "set AGENT_DUO_E2E_CODEX=1 to run (real Codex session)"
command -v codex >/dev/null 2>&1 || skip "codex CLI not installed"
command -v tmux  >/dev/null 2>&1 || skip "tmux not installed"
[[ -f "$HOME/.codex/auth.json" ]] || skip "no ~/.codex/auth.json (Codex not authenticated)"

LAB="$(mktemp -d)" || skip "mktemp failed"
SESS="adk-e2e-$$"
AGENT="probe"
NONCE="e2e$$"
cleanup() {
  tmux kill-session -t "$SESS" 2>/dev/null
  # Codex records a per-directory trust entry on first launch; prune ours so the
  # user's ~/.codex/config.toml doesn't accumulate dead /tmp project blocks.
  local cfg="$HOME/.codex/config.toml" real
  if [[ -n "${LAB:-}" && -f "$cfg" ]]; then
    real="$(cd "$LAB/work" 2>/dev/null && pwd -P || printf '%s' "$LAB/work")"
    if grep -qF "[projects.\"$real\"]" "$cfg" 2>/dev/null; then
      awk -v blk="[projects.\"$real\"]" '
        $0 == blk { skip = 2; next }
        skip > 0  { skip--; next }
        { print }
      ' "$cfg" > "$cfg.adk.tmp" && mv "$cfg.adk.tmp" "$cfg"
    fi
  fi
  [[ -n "${LAB:-}" && -d "$LAB" && "$LAB" != "/" ]] && rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB/work"
MARKER="$LAB/.agent-duo/state/$AGENT/broker.json"
# Real broker hook, carrying its env inline (same shape `peer agent add` injects for Codex).
HOOK_CMD="AGENT_DUO_ROOT=$LAB AGENT_DUO_AGENT_ID=$AGENT AGENT_DUO_WORKTREE=$LAB/work $ROOT/bin/agent-duo-approval-hook"
PROBE_CMD="$(bash "$ROOT/lib/approval_broker.sh" selfcheck-cmd --nonce "$NONCE")"

cap() { tmux capture-pane -t "$SESS" -p -S -80 2>/dev/null; }

# 等待 TUI 出现某子串,期间自动应答目录信任提示(--dangerously-bypass-hook-trust
# 只跳过 hook 审核,不跳过目录信任)。超时返回 1。
wait_for() { # <needle> <timeout-seconds>
  local needle="$1" timeout="$2" i screen
  for ((i = 0; i < timeout; i++)); do
    screen="$(cap)"
    if [[ "$screen" == *"$needle"* ]]; then return 0; fi
    if [[ "$screen" == *"Do you trust the contents of this directory"* ]]; then
      tmux send-keys -t "$SESS" Enter; sleep 1; continue
    fi
    sleep 1
  done
  return 1
}

HOOKCFG="hooks.PreToolUse=[{matcher=\"*\",hooks=[{type=\"command\",command=\"$HOOK_CMD\"}]}]"
tmux new-session -d -s "$SESS" -x 200 -y 50
tmux send-keys -t "$SESS" \
  "codex -a never --no-alt-screen --dangerously-bypass-hook-trust -C $LAB/work -s workspace-write -c '$HOOKCFG'" Enter

if ! wait_for "OpenAI Codex" 30; then
  printf 'FAIL codex-hook-e2e: Codex TUI did not become ready\n%s\n' "$(cap)"; ADK_FAIL=1
  exit "$ADK_FAIL"
fi

# 让模型执行 broker 自检探针;真实 broker hook 应 deny(设计性)并写 ready+nonce marker。
tmux send-keys -t "$SESS" "Run this shell command now, do not explain, do not ask: $PROBE_CMD"
sleep 1
tmux send-keys -t "$SESS" Enter

# 轮询真实 marker 直到 ready+nonce(= hook 被 Codex 实际调用)或超时。
ready=0
for ((i = 0; i < 60; i++)); do
  if [[ -f "$MARKER" ]] \
    && [[ "$(jq -r '.status // ""' "$MARKER" 2>/dev/null)" == "ready" ]] \
    && [[ "$(jq -r '.nonce // ""' "$MARKER" 2>/dev/null)" == "$NONCE" ]]; then
    ready=1; break
  fi
  sleep 1
done

assert_eq        "e2e: broker marker ready with probe nonce" "$ready" "1"
assert_contains  "e2e: TUI shows hook blocked the probe"     "$(cap)" "blocked"
assert_ok        "e2e: probe file NOT created (denied)"      test ! -e "$LAB/work/AGENT_DUO_BROKER_SELFCHECK_$NONCE.tmp"
# Self-check must not leak a pending approval / blocked event.
assert_ok        "e2e: selfcheck created no approval record" sh -c '! ls "'"$LAB"'/.agent-duo/approvals/"*.json >/dev/null 2>&1'

exit "$ADK_FAIL"
