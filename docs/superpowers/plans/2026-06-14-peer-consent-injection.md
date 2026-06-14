# Consent-Gated Auto-Injection of peer Instructions — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps below are checked because the plan has been implemented.

**Goal:** Make `agent-duo-start` inject the peer collaboration prompt into both agents after asking the user once — Claude via `--append-system-prompt` (no file touched), Codex via a marked, reversible block in the project `AGENTS.md`.

**Status:** Implemented on 2026-06-14. This plan is retained as an implementation record; task checkboxes below reflect completed work.

**Architecture:** Extract pure injection logic into a sourceable `lib/inject.sh` (marker detection, block building, idempotent file write, launch-command building, and a pure plan/decision function). `start.sh` sources it and wires real TTY/stdin/env into the decision. Logic is unit-tested with a zero-dependency bash test harness; the `start.sh` wiring gets one integration test using tmux/claude/codex stubs.

**Tech Stack:** POSIX-ish Bash (must run on macOS system bash 3.2 — no associative arrays, no `${var,,}`), tmux, plain-bash test scripts (no bats dependency).

---

## File Structure

- `lib/inject.sh` — **new.** Pure injection helpers + constants. No side effects on source. The single source of injection logic, sourced by both `start.sh` and tests.
- `start.sh` — **modify.** Parse `-y`/`--yes`, source `lib/inject.sh`, run the consent flow before creating tmux windows, launch the claude window with the computed command.
- `docs/AGENT-INSTRUCTIONS.md` — **modify.** Remove the outdated leading HTML comment so the body is pure instructions (used verbatim for both the Claude system-prompt append and the Codex block).
- `test/assert.sh` — **new.** Tiny assertion helpers (sourced by test files).
- `test/inject.test.sh` — **new.** Unit tests for `lib/inject.sh`.
- `test/start.test.sh` — **new.** Integration test for `start.sh` with stubs.
- `test/run.sh` — **new.** Runs all test files; exits non-zero on any failure.
- `README.md`, `README.zh-CN.md` — **modify.** Update Quick start to describe auto-injection, first-run consent, `AGENT_DUO_AUTO_INJECT`, and manual fallback.

Function interface defined in `lib/inject.sh` (names are fixed — later tasks depend on them):

- `adk_has_block <agents_md_path>` → exit 0 if file exists and contains the start marker.
- `adk_block <instructions_file>` → prints `start-marker`, file body, `end-marker`.
- `adk_inject_codex <agents_md_path> <instructions_file>` → idempotent; appends block (creates file if missing); exit 0 if it wrote, 1 if block already present.
- `adk_claude_cmd <do_inject:0|1> <instructions_file>` → prints the claude launch command string.
- `adk_plan <has_block:0|1> <auto_inject:0|1> <is_tty:0|1>` → prints `reminder` | `auto` | `prompt` | `skip`.
- `adk_answer_yes <answer>` → exit 0 if answer is yes (`y`/`Y`/`yes`/`YES`/`Yes`), else 1.

---

## Task 1: Test harness (assert helpers + runner)

**Files:**
- Create: `test/assert.sh`
- Create: `test/run.sh`

- [x] **Step 1: Write the assert helpers**

Create `test/assert.sh`:

```bash
#!/usr/bin/env bash
# test/assert.sh — 极简断言助手(被各测试文件 source)。失败置 ADK_FAIL=1,不退出。
ADK_FAIL=0

assert_eq() { # <name> <actual> <expected>
  if [[ "$2" == "$3" ]]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: got [%s] want [%s]\n' "$1" "$2" "$3"; ADK_FAIL=1; fi
}

assert_contains() { # <name> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: [%s] missing [%s]\n' "$1" "$2" "$3"; ADK_FAIL=1; fi
}

assert_not_contains() { # <name> <haystack> <needle>
  if [[ "$2" != *"$3"* ]]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: [%s] should not contain [%s]\n' "$1" "$2" "$3"; ADK_FAIL=1; fi
}

assert_ok() { # <name> <cmd...>
  local name="$1"; shift
  if "$@"; then printf 'ok   %s\n' "$name"
  else printf 'FAIL %s (exit %d)\n' "$name" "$?"; ADK_FAIL=1; fi
}

assert_not_ok() { # <name> <cmd...>  (expects non-zero exit)
  local name="$1"; shift
  if "$@"; then printf 'FAIL %s (expected non-zero)\n' "$name"; ADK_FAIL=1
  else printf 'ok   %s\n' "$name"; fi
}
```

- [x] **Step 2: Write the runner**

Create `test/run.sh`:

```bash
#!/usr/bin/env bash
# test/run.sh — 运行 test/ 下所有 *.test.sh,任一失败则整体退出非零。
set -u
shopt -s nullglob   # 无匹配文件时让 glob 展开为空,而不是字面量路径
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
for t in "$DIR"/*.test.sh; do
  echo "=== $t ==="
  bash "$t" || rc=1
done
echo "==============="
[[ "$rc" == "0" ]] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit "$rc"
```

- [x] **Step 3: Make runner executable and verify it runs with no test files yet**

Run: `chmod +x test/run.sh && bash test/run.sh`
Expected: with `nullglob`, zero test files means the loop body is skipped; prints `===============` then `ALL TESTS PASSED`, exit 0.

- [x] **Step 4: Commit**

```bash
git add test/assert.sh test/run.sh
git commit -m "test: add zero-dependency bash assert harness and runner"
```

---

## Task 2: `adk_has_block` — marker detection

**Files:**
- Create: `lib/inject.sh`
- Create: `test/inject.test.sh`

- [x] **Step 1: Write the failing test**

Create `test/inject.test.sh`:

```bash
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
```

- [x] **Step 2: Run test to verify it fails**

Run: `bash test/inject.test.sh`
Expected: FAIL — `adk_has_block` / `lib/inject.sh` not found (source error or "command not found").

- [x] **Step 3: Write minimal implementation**

Create `lib/inject.sh`:

```bash
#!/usr/bin/env bash
# lib/inject.sh — peer 协作提示词的注入逻辑(纯函数 + 常量)。
# source 本文件不产生任何副作用;仅供 start.sh 与测试调用。
# 兼容 macOS 自带 bash 3.2:不使用关联数组、不使用 ${var,,}。

AGENT_DUO_MARK_START='<!-- agent-duo:start -->'
AGENT_DUO_MARK_END='<!-- agent-duo:end -->'

# adk_has_block <agents_md_path>
# 文件存在且包含起始标记 → 0;否则 → 1。
adk_has_block() {
  local f="$1"
  [[ -f "$f" ]] && grep -qF "$AGENT_DUO_MARK_START" "$f"
}
```

- [x] **Step 4: Run test to verify it passes**

Run: `bash test/inject.test.sh`
Expected: three `ok` lines, exit 0.

- [x] **Step 5: Commit**

```bash
git add lib/inject.sh test/inject.test.sh
git commit -m "feat: add adk_has_block marker detection"
```

---

## Task 3: `adk_block` — build the marked block

**Files:**
- Modify: `lib/inject.sh`
- Modify: `test/inject.test.sh`

- [x] **Step 1: Write the failing test**

Append to `test/inject.test.sh` BEFORE the final `exit "$ADK_FAIL"` line:

```bash
# --- adk_block ---
instr="$TMP/instr.md"
printf 'LINE-A\nLINE-B\n' > "$instr"
block="$(adk_block "$instr")"
assert_contains "block: has start marker" "$block" '<!-- agent-duo:start -->'
assert_contains "block: has end marker"   "$block" '<!-- agent-duo:end -->'
assert_contains "block: has body line A"  "$block" 'LINE-A'
assert_contains "block: has body line B"  "$block" 'LINE-B'
```

- [x] **Step 2: Run test to verify it fails**

Run: `bash test/inject.test.sh`
Expected: FAIL — `adk_block: command not found`.

- [x] **Step 3: Write minimal implementation**

Append to `lib/inject.sh`:

```bash
# adk_block <instructions_file>
# 打印带标记的完整块:起始标记 + 指令正文 + 结束标记。
adk_block() {
  local instr="$1"
  printf '%s\n' "$AGENT_DUO_MARK_START"
  cat "$instr"
  printf '%s\n' "$AGENT_DUO_MARK_END"
}
```

- [x] **Step 4: Run test to verify it passes**

Run: `bash test/inject.test.sh`
Expected: all `ok`, exit 0.

- [x] **Step 5: Commit**

```bash
git add lib/inject.sh test/inject.test.sh
git commit -m "feat: add adk_block to build the marked AGENTS.md block"
```

---

## Task 4: `adk_inject_codex` — idempotent file write

**Files:**
- Modify: `lib/inject.sh`
- Modify: `test/inject.test.sh`

- [x] **Step 1: Write the failing test**

Append to `test/inject.test.sh` before the final `exit`:

```bash
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
```

- [x] **Step 2: Run test to verify it fails**

Run: `bash test/inject.test.sh`
Expected: FAIL — `adk_inject_codex: command not found`.

- [x] **Step 3: Write minimal implementation**

Append to `lib/inject.sh`:

```bash
# adk_inject_codex <agents_md_path> <instructions_file>
# 幂等:块已存在 → 不动,返回 1;否则把块追加到文件(不存在则创建),返回 0。
# 文件已存在且非空时,先空一行再追加,保持可读。
adk_inject_codex() {
  local f="$1" instr="$2"
  if adk_has_block "$f"; then
    return 1
  fi
  if [[ -s "$f" ]]; then
    printf '\n' >> "$f"
  fi
  adk_block "$instr" >> "$f"
  return 0
}
```

- [x] **Step 4: Run test to verify it passes**

Run: `bash test/inject.test.sh`
Expected: all `ok`, exit 0.

- [x] **Step 5: Commit**

```bash
git add lib/inject.sh test/inject.test.sh
git commit -m "feat: add idempotent adk_inject_codex AGENTS.md writer"
```

---

## Task 5: `adk_claude_cmd` — build the claude launch command

**Files:**
- Modify: `lib/inject.sh`
- Modify: `test/inject.test.sh`

**Key detail:** When `do_inject=1` the command must be the LITERAL string
`claude --append-system-prompt "$(cat <path>)"`. The `$(cat ...)` is intentionally
left unexpanded so the **claude window's own shell** substitutes the file at launch
time — that keeps the multi-line instructions out of `tmux send-keys` (which would
submit on newlines) and out of `start.sh`'s shell. `printf` with a single-quoted
format string preserves it literally; `%q` safely quotes the path.

- [x] **Step 1: Write the failing test**

Append to `test/inject.test.sh` before the final `exit`:

```bash
# --- adk_claude_cmd ---
cmd_no="$(adk_claude_cmd 0 "$instr")"
assert_eq "claude_cmd: no-inject is plain" "$cmd_no" "claude"

cmd_yes="$(adk_claude_cmd 1 "$instr")"
assert_contains "claude_cmd: has flag"   "$cmd_yes" '--append-system-prompt'
assert_contains "claude_cmd: has cat sub" "$cmd_yes" '"$(cat'
assert_contains "claude_cmd: has path"   "$cmd_yes" "$instr"
```

- [x] **Step 2: Run test to verify it fails**

Run: `bash test/inject.test.sh`
Expected: FAIL — `adk_claude_cmd: command not found`.

- [x] **Step 3: Write minimal implementation**

Append to `lib/inject.sh`:

```bash
# adk_claude_cmd <do_inject:0|1> <instructions_file>
# do_inject=1 → 打印 claude --append-system-prompt "$(cat <path>)"($(...) 故意不展开,
#               由 claude 窗口自己的 shell 在启动时替换);否则打印纯 claude。
adk_claude_cmd() {
  local inject="$1" instr="$2"
  if [[ "$inject" == "1" ]]; then
    printf 'claude --append-system-prompt "$(cat %q)"' "$instr"
  else
    printf 'claude'
  fi
}
```

- [x] **Step 4: Run test to verify it passes**

Run: `bash test/inject.test.sh`
Expected: all `ok`, exit 0.

- [x] **Step 5: Commit**

```bash
git add lib/inject.sh test/inject.test.sh
git commit -m "feat: add adk_claude_cmd launch-command builder"
```

---

## Task 6: `adk_plan` + `adk_answer_yes` — pure decision logic

**Files:**
- Modify: `lib/inject.sh`
- Modify: `test/inject.test.sh`

- [x] **Step 1: Write the failing test**

Append to `test/inject.test.sh` before the final `exit`:

```bash
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
assert_not_ok "yes: n"     adk_answer_yes "n"
assert_not_ok "yes: empty" adk_answer_yes ""
assert_not_ok "yes: junk"  adk_answer_yes "maybe"
```

- [x] **Step 2: Run test to verify it fails**

Run: `bash test/inject.test.sh`
Expected: FAIL — `adk_plan: command not found`.

- [x] **Step 3: Write minimal implementation**

Append to `lib/inject.sh`:

```bash
# adk_plan <has_block:0|1> <auto_inject:0|1> <is_tty:0|1>
# 打印计划: reminder | auto | prompt | skip
#   块已存在            → reminder(不重写文件,但 claude 仍加参数)
#   无块 & auto         → auto    (直接写块 + claude 加参数)
#   无块 & 交互终端     → prompt  (询问用户)
#   无块 & 非交互       → skip    (不注入,打印手动说明)
adk_plan() {
  local hb="$1" ai="$2" tty="$3"
  if [[ "$hb" == "1" ]]; then echo reminder; return; fi
  if [[ "$ai" == "1" ]]; then echo auto; return; fi
  if [[ "$tty" == "1" ]]; then echo prompt; return; fi
  echo skip
}

# adk_answer_yes <answer> → 同意(y/Y/yes/YES/Yes) 返回 0,否则 1。
adk_answer_yes() {
  case "$1" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}
```

- [x] **Step 4: Run test to verify it passes**

Run: `bash test/inject.test.sh`
Expected: all `ok`, exit 0.

- [x] **Step 5: Commit**

```bash
git add lib/inject.sh test/inject.test.sh
git commit -m "feat: add adk_plan + adk_answer_yes decision logic"
```

---

## Task 7: Clean up `docs/AGENT-INSTRUCTIONS.md`

**Files:**
- Modify: `docs/AGENT-INSTRUCTIONS.md:1-3`
- Modify: `test/inject.test.sh`

The leading HTML comment ("将本段追加到...") is obsolete now that injection is
automated. Remove it so the body is pure instructions usable verbatim as both the
Claude system-prompt append and the Codex block.

- [x] **Step 1: Write the failing test**

Append to `test/inject.test.sh` before the final `exit`:

```bash
# --- instructions file is pure (no editorial HTML comment, real content present) ---
INSTR_FILE="$ROOT/docs/AGENT-INSTRUCTIONS.md"
firstline="$(sed -n '1p' "$INSTR_FILE")"
assert_not_contains "instr: no leading HTML comment" "$firstline" '<!--'
allbody="$(cat "$INSTR_FILE")"
assert_contains "instr: keeps collaboration heading" "$allbody" '与另一个编码 Agent 协作'
assert_contains "instr: keeps peer tell"             "$allbody" 'peer tell'
```

- [x] **Step 2: Run test to verify it fails**

Run: `bash test/inject.test.sh`
Expected: FAIL on "no leading HTML comment" (current line 1 starts with `<!--`).

- [x] **Step 3: Edit the file**

Remove lines 1–3 of `docs/AGENT-INSTRUCTIONS.md` — the two-line HTML comment and the blank line after it — so the file now starts directly with:

```
## 与另一个编码 Agent 协作
```

(Use the Edit tool: delete the `<!-- ... -->` comment block and the following blank line; leave the rest unchanged.)

- [x] **Step 4: Run test to verify it passes**

Run: `bash test/inject.test.sh`
Expected: all `ok`, exit 0.

- [x] **Step 5: Commit**

```bash
git add docs/AGENT-INSTRUCTIONS.md test/inject.test.sh
git commit -m "docs: drop obsolete manual-append comment from AGENT-INSTRUCTIONS"
```

---

## Task 8: Wire the consent flow into `start.sh`

**Files:**
- Modify: `start.sh`
- Create: `test/start.test.sh`

- [x] **Step 1: Write the failing integration test**

Create `test/start.test.sh`:

```bash
#!/usr/bin/env bash
# test/start.test.sh — start.sh 注入接线的集成测试(用 stub 替换 tmux/claude/codex)
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
source "$DIR/assert.sh"

# 为每个场景搭建:stub bin + 干净项目目录 + send-keys 日志
setup() {
  SCENARIO_TMP="$(mktemp -d)"
  STUB_BIN="$SCENARIO_TMP/bin"; mkdir -p "$STUB_BIN"
  PROJECT="$SCENARIO_TMP/project"; mkdir -p "$PROJECT"
  SENDLOG="$SCENARIO_TMP/sendkeys.log"; : > "$SENDLOG"

  # tmux stub:has-session 返回 1(无会话),send-keys 记录参数,其它成功。
  cat > "$STUB_BIN/tmux" <<STUB
#!/usr/bin/env bash
case "\$1" in
  has-session) exit 1 ;;
  send-keys)   printf '%s\n' "\$*" >> "$SENDLOG"; exit 0 ;;
  *)           exit 0 ;;
esac
STUB
  chmod +x "$STUB_BIN/tmux"
  # claude/codex stub:存在即可,绝不应被真正执行(start.sh 只 send-keys 字符串)
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/claude"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/codex"
  chmod +x "$STUB_BIN/claude" "$STUB_BIN/codex"
}
teardown() { rm -rf "$SCENARIO_TMP"; }

run_start() { # 在 stub PATH + 指定 stdin/env 下运行 start.sh
  PATH="$STUB_BIN:$PATH" AGENT_SESSION=adktest "$@" bash "$ROOT/start.sh" "$PROJECT" \
    >"$SCENARIO_TMP/out.txt" 2>&1
}

# 场景 A:AUTO_INJECT=1 → 无询问,写块,claude 带 --append-system-prompt
setup
AGENT_DUO_AUTO_INJECT=1 run_start </dev/null
assert_ok        "A: AGENTS.md created" test -f "$PROJECT/AGENTS.md"
assert_contains  "A: block written"     "$(cat "$PROJECT/AGENTS.md")" '<!-- agent-duo:start -->'
assert_contains  "A: claude got flag"   "$(cat "$SENDLOG")" '--append-system-prompt'
teardown

# 场景 B:已有块 → 友好提示,不重复块,claude 仍带参数
setup
printf '%s\n%s\n%s\n' '<!-- agent-duo:start -->' 'x' '<!-- agent-duo:end -->' > "$PROJECT/AGENTS.md"
run_start </dev/null
cnt="$(grep -cF '<!-- agent-duo:start -->' "$PROJECT/AGENTS.md")"
assert_eq        "B: no duplicate block" "$cnt" "1"
assert_contains  "B: friendly notice"    "$(cat "$SCENARIO_TMP/out.txt")" '已就绪'
assert_contains  "B: claude got flag"    "$(cat "$SENDLOG")" '--append-system-prompt'
teardown

# 场景 C:非交互(无 TTY)、无 AUTO → 跳过注入,裸 claude,打印手动说明
setup
run_start </dev/null
assert_ok        "C: no AGENTS.md written" test ! -f "$PROJECT/AGENTS.md"
assert_not_contains "C: claude is plain" "$(cat "$SENDLOG")" '--append-system-prompt'
assert_contains  "C: prints manual hint" "$(cat "$SCENARIO_TMP/out.txt")" 'AGENT_DUO_AUTO_INJECT'
teardown

exit "$ADK_FAIL"
```

- [x] **Step 2: Run test to verify it fails**

Run: `bash test/start.test.sh`
Expected: FAIL — current `start.sh` neither writes the block nor adds the flag (scenarios A/B fail).

- [x] **Step 3: Edit `start.sh` — parse flags and source the lib**

In `start.sh`, replace the current lines:

```bash
SESSION="${AGENT_SESSION:-agents}"
WORKDIR="$(cd "${1:-$PWD}" && pwd)"
```

with:

```bash
SESSION="${AGENT_SESSION:-agents}"

# 解析 -y/--yes(其余参数原样保留);AGENT_DUO_AUTO_INJECT=1 等价于 -y。
AUTO=0
[[ "${AGENT_DUO_AUTO_INJECT:-0}" == "1" ]] && AUTO=1
_args=()
for _a in "$@"; do
  case "$_a" in
    -y|--yes) AUTO=1 ;;
    *) _args+=("$_a") ;;
  esac
done
set -- ${_args[@]+"${_args[@]}"}

WORKDIR="$(cd "${1:-$PWD}" && pwd)"
```

- [x] **Step 4: Edit `start.sh` — source lib after computing `SCRIPT_DIR`/`BIN_DIR`**

Find the existing block:

```bash
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
BIN_DIR="$SCRIPT_DIR/bin"
```

and add immediately after it:

```bash
LIB_DIR="$SCRIPT_DIR/lib"
INSTR="$SCRIPT_DIR/docs/AGENT-INSTRUCTIONS.md"
# shellcheck source=lib/inject.sh
source "$LIB_DIR/inject.sh"
```

- [x] **Step 5: Edit `start.sh` — run the consent flow before creating windows**

Immediately before the `# 窗口 1: claude` comment, insert:

```bash
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
    fi
    do_inject=1
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
      adk_inject_codex "$AGENTS_MD" "$INSTR" && echo "✓ 已写入 $AGENTS_MD。"
      do_inject=1
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
```

- [x] **Step 6: Edit `start.sh` — use the computed claude command**

Replace the claude window launch:

```bash
tmux send-keys -t "$SESSION:claude" \
  "export AGENT_NAME=claude AGENT_SESSION=$SESSION PATH=\"$BIN_DIR:\$PATH\"; claude" Enter
```

with:

```bash
tmux send-keys -t "$SESSION:claude" \
  "export AGENT_NAME=claude AGENT_SESSION=$SESSION PATH=\"$BIN_DIR:\$PATH\"; $CLAUDE_LAUNCH" Enter
```

(Leave the codex window launch unchanged — it reads `AGENTS.md` itself.)

- [x] **Step 7: Run the integration test to verify it passes**

Run: `bash test/start.test.sh`
Expected: all `ok`, exit 0.

- [x] **Step 8: Run the full suite**

Run: `bash test/run.sh`
Expected: both files pass, `ALL TESTS PASSED`, exit 0.

- [x] **Step 9: Commit**

```bash
git add start.sh test/start.test.sh
git commit -m "feat: consent-gated injection of peer instructions in start.sh"
```

---

## Task 9: Update READMEs

**Files:**
- Modify: `README.md` (Quick start section)
- Modify: `README.zh-CN.md` (对应章节)

No automated test (docs). Verify by reading.

- [x] **Step 1: Update `README.md` Quick start**

In `README.md`, find the Quick start block that currently reads:

```
Append `docs/AGENT-INSTRUCTIONS.md` to your project's `CLAUDE.md` (read by Claude Code) **and** `AGENTS.md` (read by Codex). Same snippet for both — `peer` resolves "self" and "the other side" automatically from `$AGENT_NAME`.
```

Replace it with:

```
On first run in a project, `agent-duo-start` asks once before wiring the agents up:

- **Claude** gets the peer instructions via `--append-system-prompt` at launch — **no file is touched**, and it's gone when the session ends.
- **Codex** has no equivalent launch flag, so the instructions go into a marked, reversible block in your project's `AGENTS.md` (`<!-- agent-duo:start -->` … `<!-- agent-duo:end -->`). `CLAUDE.md` is never modified.

Answer `y` once and it won't ask again (the marker block records your consent); later runs just print a one-line reminder. Decline and it launches without injecting, printing the manual steps.

- Non-interactive shells (CI, pipes) skip injection by default — pass `-y` or set `AGENT_DUO_AUTO_INJECT=1` to inject without the prompt.
- Prefer to wire it up by hand? Append the body of `docs/AGENT-INSTRUCTIONS.md` to your project's `CLAUDE.md` and `AGENTS.md` yourself. Same snippet for both — `peer` resolves "self" and "the other side" automatically from `$AGENT_NAME`.
```

- [x] **Step 2: Update `README.zh-CN.md`**

Make the equivalent edit in `README.zh-CN.md`'s corresponding section: describe that the first run asks for consent, Claude uses `--append-system-prompt` (no file touched), Codex gets a marked reversible block in `AGENTS.md`, `CLAUDE.md` is untouched, consent is remembered (later runs just remind), declining launches without injection, and `-y` / `AGENT_DUO_AUTO_INJECT=1` covers non-interactive use; manual append remains as fallback. Match the surrounding Chinese tone and formatting of that file.

- [x] **Step 3: Verify wording**

Run: `grep -n "AGENT_DUO_AUTO_INJECT" README.md README.zh-CN.md`
Expected: at least one hit in each file.

- [x] **Step 4: Commit**

```bash
git add README.md README.zh-CN.md
git commit -m "docs: document consent-gated auto-injection in Quick start"
```

---

## Final verification

- [x] **Run the full test suite**

Run: `bash test/run.sh`
Expected: `ALL TESTS PASSED`, exit 0.

- [x] **Manual smoke (matches spec verification)**

```bash
# 新项目目录、交互式:应出现授权提示
tmpdir="$(mktemp -d)"; ( cd "$tmpdir" && /path/to/agent-duo/start.sh )   # 输入 y,确认 AGENTS.md 出现块;Ctrl-c/kill 会话后检查
tmux kill-session -t agents 2>/dev/null || true
```

Confirm: first run prompts; `y` writes the block; re-running prints the friendly reminder without duplicating; `AGENT_DUO_AUTO_INJECT=1` skips the prompt; piping `</dev/null` skips injection with a warning.
