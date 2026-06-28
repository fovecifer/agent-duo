#!/usr/bin/env bash
# test/cli/peer-approval.test.sh - peer approval and broker gate tests
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
source "$DIR/../lib/harness.sh"

approval_run_hook() {
  local payload="$1"
  : > "$OUT"
  : > "$ERR"
  (
    cd "$PROJECT"
    printf '%s' "$payload" | \
      AGENT_DUO_ROOT="$PROJECT" \
      AGENT_DUO_AGENT_ID="worker" \
      AGENT_DUO_WORKTREE="$PROJECT" \
      "$ROOT/bin/agent-duo-approval-hook" >"$OUT" 2>"$ERR"
  )
}

approval_latest_id() {
  local f
  f="$(ls "$PROJECT/.agent-duo/approvals"/*.json | sort | tail -n 1)"
  basename "$f" .json
}

# approval check --help 是纯帮助路径,不应要求 tmux pane / agent 身份,也不应触发 grep 选项噪音。
setup
assert_ok "approval check help: no identity required" run_peer_without_agent approval check --help
assert_contains "approval check help: prints usage" "$(cat "$OUT")" 'peer approval check'
assert_not_contains "approval check help: no missing agent error" "$(cat "$ERR")" '找不到 agent'
assert_not_contains "approval check help: no grep usage" "$(cat "$ERR")" 'usage: grep'
teardown

# peer approval ls/approve/deny are supervisor-internal actions over approval files.
setup
if ! approval_run_hook '{"tool_name":"Bash","tool_input":{"command":"python deploy.py"},"round":7}'; then
  printf 'FAIL peer approval fixture: creates pending request\n'
  ADK_FAIL=1
fi
pending_id="$(approval_latest_id)"
assert_ok "peer approval ls: lists pending" run_peer approval ls
assert_contains "peer approval ls: shows id" "$(cat "$OUT")" "$pending_id"

assert_ok "peer approval approve: marks approved" run_peer approval approve "$pending_id"
assert_contains "peer approval approve: file approved" "$(cat "$PROJECT/.agent-duo/approvals/$pending_id.json")" '"status":"approved"'

assert_ok "hook: approved request allows once" approval_run_hook \
  '{"tool_name":"Bash","tool_input":{"command":"python deploy.py"},"round":8}'
assert_eq "hook: approved request allow output" "$(cat "$OUT")" "{}"
assert_contains "hook: approved request consumed" "$(cat "$PROJECT/.agent-duo/approvals/$pending_id.json")" '"status":"consumed"'

assert_ok "hook: creates second pending request" approval_run_hook \
  '{"tool_name":"Bash","tool_input":{"command":"python deploy.py"},"round":9}'
deny_id="$(approval_latest_id)"
assert_ok "peer approval deny: marks denied" run_peer approval deny "$deny_id" --reason "not now"
assert_contains "peer approval deny: file denied" "$(cat "$PROJECT/.agent-duo/approvals/$deny_id.json")" '"status":"denied"'
assert_contains "peer approval deny: reason recorded" "$(cat "$PROJECT/.agent-duo/approvals/$deny_id.json")" 'not now'
teardown

# broker-status:无 marker 时报 unverified。
setup
assert_ok "broker-status: succeeds" run_peer approval status worker
assert_contains "broker-status: unverified default" "$(cat "$OUT")" '"status":"unverified"'
teardown

# broker-status:已有 ready marker 时如实回报。
setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
printf '{"agent":"worker","status":"ready","updated_epoch":%s,"nonce":"n1"}\n' "$(date +%s)" > "$PROJECT/.agent-duo/state/worker/broker.json"
assert_ok "broker-status: reads marker" run_peer approval status worker
assert_contains "broker-status: ready reported" "$(cat "$OUT")" '"status":"ready"'
assert_not_contains "broker-status: no hint when ready" "$(cat "$ERR")" 'approval check'
teardown

# broker-status:ready 但过期(老 epoch)→ 报 stale,并给出 approval check 提示。
setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
printf '{"agent":"worker","status":"ready","updated_epoch":1000000000,"nonce":"n1"}\n' > "$PROJECT/.agent-duo/state/worker/broker.json"
assert_ok "broker-status: stale surfaced" run_peer approval status worker
assert_contains "broker-status: stale status" "$(cat "$OUT")" '"status":"stale"'
assert_contains "broker-status: stale hint to approval check" "$(cat "$ERR")" 'approval check'
teardown

# approval check:投递自检探针(带 sentinel+nonce),未匹配时标记 fail-open 并非零退出。
setup
AGENT_DUO_BROKER_CHECK_TIMEOUT=2 assert_exit_code "approval check: fail-open when hook never fires" 1 \
  run_peer approval check worker --nonce fixednonce
assert_contains "approval check: probe carries sentinel+nonce" \
  "$(cat "$TMUX_STUB_BUFFER_DIR/peer-brokercheck-worker")" 'AGENT_DUO_BROKER_SELFCHECK_fixednonce'
assert_contains "approval check: warns fail-open" "$(cat "$ERR")" 'FAIL-OPEN'
assert_contains "approval check: marker set fail-open" \
  "$(cat "$PROJECT/.agent-duo/state/worker/broker.json")" '"status":"fail-open"'
teardown

# approval check:marker 已是 ready+匹配 nonce → 报 READY 并零退出。
setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
printf '{"agent":"worker","status":"ready","nonce":"fixednonce"}\n' > "$PROJECT/.agent-duo/state/worker/broker.json"
AGENT_DUO_BROKER_CHECK_TIMEOUT=3 assert_ok "approval check: ready when marker matches nonce" \
  run_peer approval check worker --nonce fixednonce
assert_contains "approval check: reports READY" "$(cat "$OUT")" 'READY'
teardown

# approval check:旧 marker 的 nonce 不匹配本次探针 → 不算通过(fail-open)。
setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
printf '{"agent":"worker","status":"ready","nonce":"stale"}\n' > "$PROJECT/.agent-duo/state/worker/broker.json"
AGENT_DUO_BROKER_CHECK_TIMEOUT=2 assert_exit_code "approval check: stale nonce is not a pass" 1 \
  run_peer approval check worker --nonce freshnonce
teardown

# approval check:未知 id 报错。
setup
assert_not_ok "approval check: unknown id" run_peer approval check ghost
assert_contains "approval check: unknown error" "$(cat "$ERR")" "找不到 agent 'ghost'"
teardown

# ② Broker dispatch hard gate: tell to a worker refuses unless broker is fresh ready.

# worker + no marker (unverified) → refuse, nonzero, no buffer written.
setup
assert_exit_code "gate: unverified worker refused" 1 run_peer tell worker "do work"
assert_contains "gate: unverified error mentions fresh ready" "$(cat "$ERR")" 'fresh ready'
assert_contains "gate: unverified error suggests approval check" "$(cat "$ERR")" 'approval check'
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

# peer agent add installs per-agent broker session settings and exports hook env into the worker session.
setup
printf '%%1\tsupervisor\tsupervisor\tclaude\n' > "$TMUX_STUB_REGISTRY"
TMUX_STUB_NEW_PANE="%2" assert_ok "peer agent add: installs approval hook settings" \
  run_peer agent add --provider codex --role worker --id worker
SETTINGS="$PROJECT/.agent-duo/state/worker/session-settings.json"
assert_ok "peer agent add: settings file exists" test -f "$SETTINGS"
assert_contains "peer agent add: settings contains hook" "$(cat "$SETTINGS")" 'PreToolUse'
assert_contains "peer agent add: settings contains permission hook" "$(cat "$SETTINGS")" 'PermissionRequest'
assert_contains "peer agent add: settings contains hook command" "$(cat "$SETTINGS")" 'agent-duo-approval-hook'
assert_contains "peer agent add: send exports hook" "$(cat "$TMUX_STUB_LOG")" 'AGENT_DUO_APPROVAL_HOOK='
assert_contains "peer agent add: send exports worker id" "$(cat "$TMUX_STUB_LOG")" 'AGENT_DUO_AGENT_ID=worker'
assert_contains "peer agent add: send exports worker role" "$(cat "$TMUX_STUB_LOG")" 'AGENT_DUO_AGENT_ROLE=worker'
assert_contains "peer agent add: send exports worker provider" "$(cat "$TMUX_STUB_LOG")" 'AGENT_DUO_AGENT_PROVIDER=codex'
assert_contains "peer agent add: codex inherits shell env" "$(cat "$TMUX_STUB_LOG")" 'shell_environment_policy.inherit=all'
assert_contains "peer agent add: codex pins tool PATH" "$(cat "$TMUX_STUB_LOG")" 'shell_environment_policy.set.PATH'
assert_contains "peer agent add: codex send has hook config" "$(cat "$TMUX_STUB_LOG")" 'hooks.PreToolUse'
assert_contains "peer agent add: codex send has permission hook config" "$(cat "$TMUX_STUB_LOG")" 'hooks.PermissionRequest'

TMUX_STUB_NEW_PANE="%3" assert_ok "peer agent add claude: loads approval settings" \
  run_peer agent add --provider claude --role reviewer --id reviewer
assert_contains "peer agent add claude: send has --settings" "$(cat "$TMUX_STUB_LOG")" '--settings'
assert_contains "peer agent add claude: send has reviewer settings path" "$(cat "$TMUX_STUB_LOG")" '.agent-duo/state/reviewer/session-settings.json'
teardown

exit "$ADK_FAIL"
