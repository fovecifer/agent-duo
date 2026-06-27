#!/usr/bin/env bash
# test/registry.test.sh — lib/registry.sh 纯函数单测(不依赖 tmux)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
source "$DIR/../lib/harness.sh"
source "$ROOT/lib/registry.sh"

exit_code_helper="assert""_exit_code"
assert_eq "harness: exit-code helper exported" "$(type -t "$exit_code_helper")" "function"

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

# worktree path:同 basename 但不同绝对路径的 repo 不应撞默认路径。
WT_ROOT="$(mktemp -d)"
REPO_A="$WT_ROOT/a/repo"
REPO_B="$WT_ROOT/b/repo"
mkdir -p "$REPO_A" "$REPO_B"
path_a="$(reg_worktree_path "$REPO_A" agents worker)"
path_b="$(reg_worktree_path "$REPO_B" agents worker)"
if [[ "$path_a" != "$path_b" ]]; then
  printf 'ok   worktree path: repo key prevents collisions\n'
else
  printf 'FAIL worktree path: [%s] unexpectedly equals [%s]\n' "$path_a" "$path_b"
  ADK_FAIL=1
fi
case "$path_a" in
  */.agent-duo-worktrees/repo-*/agents/worker) printf 'ok   worktree path: default shape\n' ;;
  *)
    printf 'FAIL worktree path: unexpected shape [%s]\n' "$path_a"
    ADK_FAIL=1
    ;;
esac
rm -rf "$WT_ROOT"

exit "$ADK_FAIL"
