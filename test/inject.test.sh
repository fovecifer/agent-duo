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

exit "$ADK_FAIL"
