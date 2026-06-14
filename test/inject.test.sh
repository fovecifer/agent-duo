#!/usr/bin/env bash
# test/inject.test.sh — lib/inject.sh 的单元测试
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
source "$DIR/assert.sh"
source "$ROOT/lib/inject.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- adk_has_block ---
missing="$TMP/none.md"
assert_not_ok "has_block: file missing" adk_has_block "$missing"

empty="$TMP/empty.md"; : > "$empty"
assert_not_ok "has_block: file empty" adk_has_block "$empty"

withblock="$TMP/with.md"
printf '%s\n' '<!-- agent-duo:start -->' > "$withblock"
assert_ok "has_block: marker present" adk_has_block "$withblock"

# --- adk_block ---
instr="$TMP/instr.md"
printf 'LINE-A\nLINE-B\n' > "$instr"
block="$(adk_block "$instr")"
assert_contains "block: has start marker" "$block" '<!-- agent-duo:start -->'
assert_contains "block: has end marker"   "$block" '<!-- agent-duo:end -->'
assert_contains "block: has body line A"  "$block" 'LINE-A'
assert_contains "block: has body line B"  "$block" 'LINE-B'

# --- adk_inject_codex ---
# 1) 文件不存在 → 创建并写入块,返回 0
newf="$TMP/new_agents.md"
assert_ok "inject: writes when missing" adk_inject_codex "$newf" "$instr"
assert_ok "inject: file now has block" adk_has_block "$newf"

# 2) 再次注入 → 块已存在 → 返回非零且不重复
assert_not_ok "inject: idempotent (already present)" adk_inject_codex "$newf" "$instr"
count="$(grep -cF '<!-- agent-duo:start -->' "$newf")"
assert_eq "inject: exactly one block" "$count" "1"

# 3) 追加到已有非空文件 → 原内容保留
existing="$TMP/existing.md"
printf 'USER CONTENT\n' > "$existing"
assert_ok "inject: appends to existing" adk_inject_codex "$existing" "$instr"
body="$(cat "$existing")"
assert_contains "inject: keeps user content" "$body" 'USER CONTENT'
assert_contains "inject: adds block"         "$body" '<!-- agent-duo:start -->'

exit "$ADK_FAIL"
