#!/usr/bin/env bash
# test/inject.test.sh — lib/inject.sh 的单元测试
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
source "$DIR/assert.sh"
source "$ROOT/lib/inject.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 注:下面多处特意写死标记字面量(如 '<!-- agent-duo:start -->'),作为对输出契约的
# 回归保护——不引用 $AGENT_DUO_MARK_START,避免常量被改后测试仍假绿。

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

# --- adk_claude_cmd ---
cmd_no="$(adk_claude_cmd 0 "$instr")"
assert_eq "claude_cmd: no-inject is plain" "$cmd_no" "claude"

cmd_yes="$(adk_claude_cmd 1 "$instr")"
assert_contains "claude_cmd: has flag"   "$cmd_yes" '--append-system-prompt'
assert_contains "claude_cmd: has cat sub" "$cmd_yes" '"$(cat'
assert_contains "claude_cmd: has path"   "$cmd_yes" "$instr"

# --- adk_plan (has_block, auto_inject, is_tty) ---
assert_eq "plan: block present → reminder" "$(adk_plan 1 0 0)" "reminder"
assert_eq "plan: block present beats auto" "$(adk_plan 1 1 1)" "reminder"
assert_eq "plan: no block + auto → auto"   "$(adk_plan 0 1 0)" "auto"
assert_eq "plan: no block + tty → prompt"  "$(adk_plan 0 0 1)" "prompt"
assert_eq "plan: no block, no tty → skip"  "$(adk_plan 0 0 0)" "skip"

# --- adk_answer_yes ---
assert_ok     "yes: y"     adk_answer_yes "y"
assert_ok     "yes: Y"     adk_answer_yes "Y"
assert_ok     "yes: yes"   adk_answer_yes "yes"
assert_ok     "yes: YES"   adk_answer_yes "YES"
assert_ok     "yes: Yes"   adk_answer_yes "Yes"
assert_not_ok "yes: n"     adk_answer_yes "n"
assert_not_ok "yes: empty" adk_answer_yes ""
assert_not_ok "yes: junk"  adk_answer_yes "maybe"

# --- instructions file is pure (no editorial HTML comment, real content present) ---
INSTR_FILE="$ROOT/docs/AGENT-INSTRUCTIONS.md"
firstline="$(sed -n '1p' "$INSTR_FILE")"
assert_not_contains "instr: no leading HTML comment" "$firstline" '<!--'
allbody="$(cat "$INSTR_FILE")"
assert_contains "instr: keeps collaboration heading" "$allbody" '与另一个编码 Agent 协作'
assert_contains "instr: keeps peer tell"             "$allbody" 'peer tell'

exit "$ADK_FAIL"
