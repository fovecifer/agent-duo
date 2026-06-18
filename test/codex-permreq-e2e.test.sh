#!/usr/bin/env bash
# test/codex-permreq-e2e.test.sh — 真实交互式 Codex CLI 的 PermissionRequest schema 端到端 smoke。
#
# 为什么单独有这条:Codex 各 hook 事件的输出 schema 不同——
#   PreToolUse        -> hookSpecificOutput.permissionDecision
#   PermissionRequest -> hookSpecificOutput.decision.behavior   (它不认 permissionDecision)
# broker 曾对所有事件都发 permissionDecision,使 PermissionRequest 的 allow/deny 变成 silent
# no-op(= 原生审批路径 fail-open)。见 [Codex hook 投递方案决策] 的「⑥」节。本测试用真实
# Codex 在 `-a untrusted`(非 trusted 命令会升级 → 触发 PermissionRequest)下验证修复。
#
# 判别力说明:
#   ALLOW 路径是真正的判别器。`-a untrusted` 下 apply_patch(写文件,对 Codex 非 trusted)需审批
#     → PermissionRequest 触发 → broker 返回 decision.behavior=allow。只有正确 schema 才会让
#     apply_patch 真正执行并建出文件;旧代码发 permissionDecision 被忽略 → 回落原生审批弹窗 →
#     tmux 无人应答 → 文件建不出。故「文件被建出」== schema 被正确解析。
#   DENY 路径是安全性 + 「hook 确实被调用」的佐证,但不是判别器:旧代码会因挂在原生弹窗而同样
#     不创建文件。靠 marker(hook 被实际调用)+ 审计 deny 记录 + 文件未创建三者共同佐证。
#
# 默认跳过(真实调用 Codex/模型、慢、要联网+鉴权)。显式开启:
#   AGENT_DUO_E2E_CODEX=1 bash test/codex-permreq-e2e.test.sh
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
source "$DIR/assert.sh"

skip() { printf 'skip %s: %s\n' "codex-permreq-e2e" "$1"; exit 0; }

[[ "${AGENT_DUO_E2E_CODEX:-}" == "1" ]] || skip "set AGENT_DUO_E2E_CODEX=1 to run (real Codex session)"
command -v codex >/dev/null 2>&1 || skip "codex CLI not installed"
command -v tmux  >/dev/null 2>&1 || skip "tmux not installed"
command -v jq    >/dev/null 2>&1 || skip "jq not installed"
[[ -f "$HOME/.codex/auth.json" ]] || skip "no ~/.codex/auth.json (Codex not authenticated)"

LAB="$(mktemp -d)" || skip "mktemp failed"
SESS="adk-permreq-$$"
AGENT="probe"
ADK_FAIL=0
cleanup() {
  tmux kill-session -t "$SESS" 2>/dev/null
  # Codex records a per-directory trust entry on first launch; prune ours.
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
AUDIT="$LAB/.agent-duo/logs/approvals.jsonl"
# Real broker hook on PermissionRequest ONLY, so this test isolates that event.
HOOK_CMD="AGENT_DUO_ROOT=$LAB AGENT_DUO_AGENT_ID=$AGENT AGENT_DUO_WORKTREE=$LAB/work $ROOT/bin/agent-duo-approval-hook"
HOOKCFG="hooks.PermissionRequest=[{matcher=\"*\",hooks=[{type=\"command\",command=\"$HOOK_CMD\"}]}]"

cap() { tmux capture-pane -t "$SESS" -p -S -120 2>/dev/null; }
marker_status() { jq -r '.status // ""' "$MARKER" 2>/dev/null; }

# Wait for a TUI substring; auto-answer the directory-trust prompt meanwhile.
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

# Send an imperative instruction to the Codex TUI prompt.
say() { # <text>
  tmux send-keys -t "$SESS" "$1"; sleep 1; tmux send-keys -t "$SESS" Enter
}

tmux new-session -d -s "$SESS" -x 200 -y 50
tmux send-keys -t "$SESS" \
  "codex -a untrusted --no-alt-screen --dangerously-bypass-hook-trust -C $LAB/work -s workspace-write -c '$HOOKCFG'" Enter

if ! wait_for "OpenAI Codex" 40; then
  printf 'FAIL codex-permreq-e2e: Codex TUI did not become ready\n%s\n' "$(cap)"; exit 1
fi

# ---- ALLOW path (the discriminator) -------------------------------------------------
# apply_patch is untrusted to Codex (a write) → escalates → PermissionRequest fires;
# broker auto-allows worktree patches. Honored allow ⇒ file appears.
ALLOW_FILE="$LAB/work/permreq-allow.txt"
say "Use the apply_patch tool to create a new file named permreq-allow.txt in the current directory with exactly the contents PERMREQ_ALLOW_OK. Do not explain, do not ask, just do it."

allow_ok=0
for ((i = 0; i < 120; i++)); do
  if [[ -f "$ALLOW_FILE" ]]; then allow_ok=1; break; fi
  sleep 1
done
assert_eq       "permreq: ALLOW honored — apply_patch ran (decision.behavior parsed)" "$allow_ok" "1"
assert_eq       "permreq: ALLOW hook fired (marker ready)" "$(marker_status)" "ready"
assert_ok       "permreq: ALLOW recorded auto-allow in audit" \
  sh -c 'grep -q "\"decision\":\"auto-allow\"" "'"$AUDIT"'"'
if [[ "$allow_ok" != "1" ]]; then printf '%s\n' "--- TUI (allow) ---" "$(cap)" "--- marker ---" "$(cat "$MARKER" 2>/dev/null)"; fi

# ---- DENY path (safety + invocation corroboration, not a discriminator) -------------
# Mirror ALLOW with apply_patch (the model has shown it will use it) but target a secret
# path: broker hard-denies .env (deny.secret_path). apply_patch is untrusted → fires
# PermissionRequest; honored deny ⇒ the file never appears and audit records a deny.
DENY_FILE="$LAB/work/.env"
say "Use the apply_patch tool to create a new file named .env in the current directory with exactly the contents PERMREQ_SECRET=1. Do not explain, do not ask, just do it."

deny_audit=0
for ((i = 0; i < 90; i++)); do
  if grep -Eq '"decision":"(escalate|hard-deny)"' "$AUDIT" 2>/dev/null; then deny_audit=1; break; fi
  sleep 1
done
assert_eq       "permreq: DENY hook fired and decided deny (audit)" "$deny_audit" "1"
assert_ok       "permreq: DENY blocked — secret file not created" test ! -e "$DENY_FILE"
if [[ "$deny_audit" != "1" || -e "$DENY_FILE" ]]; then printf '%s\n' "--- TUI (deny) ---" "$(cap)" "--- audit ---" "$(cat "$AUDIT" 2>/dev/null)"; fi

exit "$ADK_FAIL"
