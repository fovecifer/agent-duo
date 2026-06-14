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

exit "$ADK_FAIL"
