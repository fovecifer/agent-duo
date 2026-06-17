#!/usr/bin/env bash
# test/registry.test.sh — lib/registry.sh 纯函数单测(不依赖 tmux)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
source "$DIR/assert.sh"
source "$ROOT/lib/registry.sh"

assert_exit_code() {
  local name="$1" expected="$2"; shift 2
  local rc=0
  if "$@"; then rc=0; else rc="$?"; fi
  if [[ "$rc" == "$expected" ]]; then printf 'ok   %s\n' "$name"
  else printf 'FAIL %s: exit [%s] want [%s]\n' "$name" "$rc" "$expected"; ADK_FAIL=1; fi
}

# reg_validate_provider
assert_ok      "validate: claude ok" reg_validate_provider claude
assert_ok      "validate: codex ok"  reg_validate_provider codex
assert_not_ok  "validate: bad rejected" reg_validate_provider gpt

# reg_provider_launch_cmd
assert_eq "launch: codex"  "$(reg_provider_launch_cmd codex /x/instr.md)" "codex"
assert_eq "launch: claude" "$(reg_provider_launch_cmd claude /x/instr.md)" \
  'claude --append-system-prompt "$(cat /x/instr.md)"'

# reg_derive_id: role 没占用 → role 本身;占用 → 追加 -2,-3
assert_eq "derive: free role"     "$(reg_derive_id worker $'supervisor\nreviewer')" "worker"
assert_eq "derive: collide once"  "$(reg_derive_id worker $'supervisor\nworker')"   "worker-2"
assert_eq "derive: collide twice" "$(reg_derive_id worker $'worker\nworker-2')"     "worker-3"

# reg_pick_other: 正好两人 → 另一个;无对方 → exit 2;多于一个 → exit 3
assert_eq "pick: the other" "$(reg_pick_other supervisor $'supervisor\nworker')" "worker"
assert_exit_code "pick: none"      2 reg_pick_other lonely $'lonely'
assert_exit_code "pick: ambiguous" 3 reg_pick_other supervisor $'supervisor\nworker\nreviewer'

exit "$ADK_FAIL"
