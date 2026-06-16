# Registry (MVP 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 agent-duo 从"claude/codex 双人固定"升级为"单 supervisor + 按需 `peer add` 生长"的动态多 agent 工作台，以 tmux per-pane 用户选项作为唯一身份真相源。

**Architecture:** 身份存在每个 pane 的 tmux 用户选项 `@agent_id/@agent_role/@agent_provider` 上（无配置文件、无同步问题）。纯逻辑（provider 校验、id 去重、选"另一个"、launch 字符串）抽进可独立单测的 `lib/registry.sh`；tmux 调用留在 `bin/peer` 与 `start.sh`，用 tmux-stub 集成测试覆盖。`peer` 通过 `$TMUX_PANE` 自识别身份，按 `@agent_id` 寻址；2 个 agent 时默认"另一个"，≥3 个强制指名。

**Tech Stack:** Bash 3.2 兼容（不用关联数组、不用 `${var,,}`）、tmux、现有 `test/*.test.sh` + `assert.sh` + tmux-stub 测试框架。

**命名决定（偏离 spec）：** spec 写的是 `peer spawn`，但 `docs/AGENT-INSTRUCTIONS.md` 已把 "spawn/派一个" 定义为"无头子 agent"。为避免歧义，本计划用 `peer add` / `peer rm` / `peer ls`。

---

## File Structure

- **Create `lib/registry.sh`** — 纯函数：`reg_validate_provider`、`reg_provider_launch_cmd`、`reg_derive_id`、`reg_pick_other`。无副作用，可不依赖 tmux 单测（仿照现有 `lib/inject.sh`）。
- **Create `test/registry.test.sh`** — `lib/registry.sh` 的纯函数单测。
- **Modify `bin/peer`** — 身份自识别改用 `$TMUX_PANE` + `@agent_id`（保留 `AGENT_NAME` 回退）；新增 `ls`/`add`/`rm`；`peek/tell/wait/status/esc` 接受可选 `<id>`；按 `@agent_id` 路由，含 2-agent 默认与 ≥3 强制指名。
- **Modify `test/peer.test.sh`** — 扩展 tmux-stub 支持 `list-panes`/`display-message @agent_id`/`set-option`/`new-window`/`kill-window`；新增 ls/add/rm/寻址用例。
- **Modify `start.sh`** — 改为单 supervisor bootstrap（默认 claude），新增 `--supervisor <provider>` 与 `--with <provider>:<role>`；给每个 pane 打 `@agent_*` 标签。
- **Modify `test/start.test.sh`** — 适配单 supervisor 启动与 `@agent_*` 标签、`--with` 行为。
- **Modify `docs/AGENT-INSTRUCTIONS.md`** — 新增 `peer ls/add/rm` 与"你可能是 supervisor、可按需添加 worker"的说明；澄清 `peer add`（可见队友）与既有"spawn 无头子 agent"的区别。

---

## Task 1: `lib/registry.sh` 纯函数 + 单测

**Files:**
- Create: `lib/registry.sh`
- Test: `test/registry.test.sh`

- [ ] **Step 1: Write the failing test**

Create `test/registry.test.sh`:

```bash
#!/usr/bin/env bash
# test/registry.test.sh — lib/registry.sh 纯函数单测(不依赖 tmux)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
source "$DIR/assert.sh"
source "$ROOT/lib/registry.sh"

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
```

Add the `assert_exit_code` helper at the top of the file (copied from `test/peer.test.sh:19-34`):

```bash
assert_exit_code() {
  local name="$1" expected="$2"; shift 2
  local rc=0
  if "$@"; then rc=0; else rc="$?"; fi
  if [[ "$rc" == "$expected" ]]; then printf 'ok   %s\n' "$name"
  else printf 'FAIL %s: exit [%s] want [%s]\n' "$name" "$rc" "$expected"; ADK_FAIL=1; fi
}
```

(Place it after `source "$ROOT/lib/registry.sh"`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/registry.test.sh`
Expected: FAIL — `lib/registry.sh` 不存在，source 报错。

- [ ] **Step 3: Write minimal implementation**

Create `lib/registry.sh`:

```bash
#!/usr/bin/env bash
# lib/registry.sh — agent registry 的纯函数(无副作用,不调用 tmux)。
# source 本文件不产生任何副作用;供 bin/peer、start.sh 与测试调用。
# 兼容 macOS 自带 bash 3.2:不使用关联数组、不使用 ${var,,}。

# reg_validate_provider <provider> → claude|codex 返回 0,否则 1。
reg_validate_provider() {
  case "$1" in
    claude|codex) return 0 ;;
    *) return 1 ;;
  esac
}

# reg_provider_launch_cmd <provider> <instr_path>
# 打印在新 pane 里启动该 provider 的命令字符串。
# claude 走 --append-system-prompt "$(cat <instr>)"(故意不展开 $(...),由目标 shell 启动时替换)。
reg_provider_launch_cmd() {
  local provider="$1" instr="$2"
  case "$provider" in
    claude) printf 'claude --append-system-prompt "$(cat %s)"' "$instr" ;;
    codex)  printf 'codex' ;;
    *)      return 1 ;;
  esac
}

# reg_derive_id <role> <existing_ids_newline_separated>
# role 未被占用 → role;否则 role-2、role-3 ... 直到不冲突。
reg_derive_id() {
  local role="$1" existing="$2" candidate="$role" n=1
  while printf '%s\n' "$existing" | grep -qx "$candidate"; do
    n=$(( n + 1 ))
    candidate="${role}-${n}"
  done
  printf '%s' "$candidate"
}

# reg_pick_other <self_id> <ids_newline_separated>
# 排除 self 后:正好 1 个 → 打印它返回 0;0 个 → 返回 2;>1 个 → 返回 3(歧义)。
reg_pick_other() {
  local self="$1" ids="$2" others count
  others="$(printf '%s\n' "$ids" | grep -vx "$self" | grep -v '^$' || true)"
  count="$(printf '%s\n' "$others" | grep -c . || true)"
  case "$count" in
    1) printf '%s' "$others"; return 0 ;;
    0) return 2 ;;
    *) return 3 ;;
  esac
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/registry.test.sh`
Expected: 全部 `ok`，退出码 0。

- [ ] **Step 5: Commit**

```bash
git add lib/registry.sh test/registry.test.sh
git commit -m "feat(registry): pure helpers for provider/id/target resolution"
```

---

## Task 2: `peer` 自识别身份改用 `$TMUX_PANE` + `@agent_id`

把 `bin/peer` 的 `AGENT_NAME → OTHER` 推导（`bin/peer:32-38`）替换为：用 `$TMUX_PANE` 读自己的 `@agent_id`；缺失时回退 `AGENT_NAME`。同时扩展 tmux-stub 支持新调用。本任务先不改寻址默认行为，只让身份来源切换且现有 peek/status 等仍工作。

**Files:**
- Modify: `bin/peer:22-38`（顶部身份解析）、`bin/peer` source 段
- Modify: `test/peer.test.sh`（扩展 stub + 调整 run_peer 环境）

- [ ] **Step 1: Extend the tmux stub and write a failing test for self-id**

在 `test/peer.test.sh` 的 `setup()` 里，把 stub registry 文件加入，并扩展 stub。先在 `setup()` 顶部新增：

```bash
  TMUX_STUB_REGISTRY="$SCENARIO_TMP/registry.tsv"
  # 默认两人:supervisor(claude,%1) + worker(codex,%2)
  printf '%%1\tsupervisor\tsupervisor\tclaude\n%%2\tworker\tworker\tcodex\n' > "$TMUX_STUB_REGISTRY"
```

在 stub 的 `case "$cmd"` 中新增分支（放在 `display-message)` 之前/之后均可），并改造 `display-message`：

```bash
  list-panes)
    # peer 用固定 -F '#{pane_id}\t#{@agent_id}\t#{@agent_role}\t#{@agent_provider}'
    [[ "${TMUX_STUB_HAS_SESSION:-1}" == "1" ]] || exit 1
    cat "$TMUX_STUB_REGISTRY"
    ;;
  set-option)
    : # 仅记录(开头已 append 到 LOG)
    ;;
  new-window)
    printf '%s\n' "${TMUX_STUB_NEW_PANE:-%9}"
    ;;
  kill-window)
    : # 仅记录
    ;;
```

并把现有 `display-message)` 分支改为支持读取 `@agent_id`：

```bash
  display-message)
    [[ "${TMUX_STUB_HAS_SESSION:-1}" == "1" ]] || exit 1
    [[ "${TMUX_STUB_PANE_EXISTS:-1}" == "1" ]] || exit 1
    if [[ "$*" == *'@agent_id'* ]]; then
      # 找 -t <pane> 的 pane,在 registry 里查它的 id(第 2 列)
      pane=""
      set -- $*
      while [[ $# -gt 0 ]]; do [[ "$1" == "-t" ]] && { pane="$2"; break; }; shift; done
      awk -F'\t' -v p="$pane" '$1==p{print $2}' "$TMUX_STUB_REGISTRY"
    else
      printf '%s\n' "${TMUX_STUB_PANE_SESSION:-${AGENT_SESSION:-agents}}"
    fi
    ;;
```

在 `run_peer()` 的环境注入里加上 `TMUX_PANE` 与 registry 路径，并默认让自己是 `%1`(supervisor)：

```bash
    TMUX_PANE="${TEST_TMUX_PANE:-%1}" \
    TMUX_STUB_REGISTRY="$TMUX_STUB_REGISTRY" \
    TMUX_STUB_NEW_PANE="${TMUX_STUB_NEW_PANE:-%9}" \
```

然后新增测试用例（放在 status 用例附近）：

```bash
# 身份:从 $TMUX_PANE 的 @agent_id 自识别(而非 AGENT_NAME)。
setup
TEST_TMUX_PANE="%1" assert_ok "identity: self from tmux pane" run_peer status
assert_contains "identity: prints self id" "$(cat "$OUT")" 'supervisor'
teardown
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/peer.test.sh`
Expected: 新 `identity:` 用例 FAIL（`peer` 仍打印 `我是: claude`，且未读 `@agent_id`）；同时旧 `status:` 等用例可能因身份来源变化而需要后续步骤一起调整。

- [ ] **Step 3: Replace identity resolution in `bin/peer`**

把 `bin/peer:22-38` 段：

```bash
SESSION="${AGENT_SESSION:-agents}"
ME="${AGENT_NAME:-}"

if [[ -z "$ME" ]]; then
  echo "错误: 未设置 AGENT_NAME(应为 claude 或 codex)。请通过 start.sh 启动。" >&2
  exit 1
fi

case "$ME" in
  claude) OTHER="codex"; OTHER_PANE="${AGENT_CODEX_PANE:-}" ;;
  codex)  OTHER="claude"; OTHER_PANE="${AGENT_CLAUDE_PANE:-}" ;;
  *) echo "错误: AGENT_NAME 必须是 claude 或 codex,当前为 '$ME'" >&2; exit 1 ;;
esac

TARGET="${OTHER_PANE:-${SESSION}:${OTHER}}"
```

替换为：

```bash
SESSION="${AGENT_SESSION:-agents}"

# 定位仓库根,source 纯函数库。
PEER_SRC="${BASH_SOURCE[0]}"
while [ -L "$PEER_SRC" ]; do PEER_SRC="$(readlink "$PEER_SRC")"; done
PEER_ROOT="$(cd "$(dirname "$PEER_SRC")/.." && pwd)"
# shellcheck source=lib/registry.sh
source "$PEER_ROOT/lib/registry.sh"

SELF_PANE="${TMUX_PANE:-}"

# 自识别:优先读自己 pane 的 @agent_id;缺失则回退 AGENT_NAME(迁移兼容)。
self_id() {
  local id=""
  if [[ -n "$SELF_PANE" ]]; then
    id="$(tmux display-message -p -t "$SELF_PANE" '#{@agent_id}' 2>/dev/null || true)"
  fi
  if [[ -z "$id" ]]; then
    id="${AGENT_NAME:-}"
  fi
  printf '%s' "$id"
}

ME="$(self_id)"
if [[ -z "$ME" ]]; then
  echo "错误: 无法确定自身身份(既无 pane @agent_id 也无 AGENT_NAME)。请通过 start.sh 启动。" >&2
  exit 1
fi
```

`status` 子命令里把 `我是: $ME    对方: $OTHER` 改为先不引用 `$OTHER`（下个任务才有寻址）。临时改 `bin/peer` status 分支第一行为：

```bash
    echo "我是: $ME    会话: $SESSION"
```

（`目标:`/`对方:` 行将在 Task 4 随寻址改造一起补回。）

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/peer.test.sh`
Expected: `identity:` 用例 PASS。注意：依赖 `$OTHER`/`TARGET` 的旧用例（peek/tell/esc/wait/status 的 `目标: %2`）此时会 FAIL —— 这些在 Task 4/5 修复，本步只确认身份自识别通过且无语法错误。

> 说明：Task 2→5 是一个连续重构。若按 subagent-driven 执行，可把 Task 2-5 作为一组在同一分支推进，每步只让本步新增的断言转绿、不回归更早任务已转绿的断言。

- [ ] **Step 5: Commit**

```bash
git add bin/peer test/peer.test.sh
git commit -m "feat(peer): self-identify via \$TMUX_PANE @agent_id with AGENT_NAME fallback"
```

---

## Task 3: `peer ls` 枚举 registry

**Files:**
- Modify: `bin/peer`（新增 `ls` 分支 + `list_agents` 辅助）
- Modify: `test/peer.test.sh`

- [ ] **Step 1: Write the failing test**

在 `test/peer.test.sh` 新增：

```bash
# ls:列出 registry 内所有 agent;未注册 pane 显示 (unregistered)。
setup
assert_ok "ls: succeeds" run_peer ls
assert_contains "ls: shows supervisor" "$(cat "$OUT")" 'supervisor'
assert_contains "ls: shows worker"     "$(cat "$OUT")" 'worker'
assert_contains "ls: shows provider"   "$(cat "$OUT")" 'codex'
assert_contains "ls: marks self"       "$(cat "$OUT")" '*'   # 自己一行带标记
teardown

# ls:未注册 pane(无 @agent_id)显示占位。
setup
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%7\t\t\t\n' > "$TMUX_STUB_REGISTRY"
assert_ok "ls: unregistered succeeds" run_peer ls
assert_contains "ls: unregistered marked" "$(cat "$OUT")" '(unregistered)'
teardown
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/peer.test.sh`
Expected: `ls:` 用例 FAIL（`ls` 落入 help 分支）。

- [ ] **Step 3: Implement `list_agents` + `ls`**

在 `bin/peer` 的辅助函数区（`self_id` 之后）新增：

```bash
# list_agents → 每行: pane_id<TAB>agent_id<TAB>role<TAB>provider(原样来自 tmux)。
list_agents() {
  tmux list-panes -s -t "$SESSION" \
    -F '#{pane_id}	#{@agent_id}	#{@agent_role}	#{@agent_provider}' 2>/dev/null
}

# agent_ids → 已注册(@agent_id 非空)的 id,每行一个。
agent_ids() {
  list_agents | awk -F'\t' '$2 != "" { print $2 }'
}
```

在 `case "$cmd"` 中新增分支（放在 `status)` 之前）：

```bash
  ls)
    if ! tmux has-session -t "$SESSION" 2>/dev/null; then
      echo "错误: tmux 会话 '$SESSION' 不存在。" >&2
      exit 1
    fi
    printf '%-3s %-16s %-12s %-10s %s\n' '' 'ID' 'ROLE' 'PROVIDER' 'PANE'
    while IFS=$'\t' read -r pane id role provider; do
      [[ -z "$pane" ]] && continue
      local mark=' '
      [[ "$pane" == "$SELF_PANE" ]] && mark='*'
      if [[ -z "$id" ]]; then
        printf '%-3s %-16s %-12s %-10s %s\n' "$mark" '(unregistered)' '-' '-' "$pane"
      else
        printf '%-3s %-16s %-12s %-10s %s\n' "$mark" "$id" "$role" "$provider" "$pane"
      fi
    done < <(list_agents)
    ;;
```

> bash 3.2 下 `local` 只能用于函数内。若 `case` 分支不在函数里，把 `local mark` 改为普通 `mark=`。本计划假定 `case` 在脚本顶层 → 用 `mark=' '`（去掉 `local`）。

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/peer.test.sh`
Expected: `ls:` 两组用例 PASS。

- [ ] **Step 5: Commit**

```bash
git add bin/peer test/peer.test.sh
git commit -m "feat(peer): add 'peer ls' to enumerate the session registry"
```

---

## Task 4: `peek/status/esc/wait` 的可选 `<id>` 寻址（数字消歧）

这些子命令的非 id 参数都是整数，可据此区分前置可选 `<id>`：非整数首参 → id。再用 `reg_pick_other` 实现"正好两人默认另一个、≥3 强制指名、永不发自己"。

**Files:**
- Modify: `bin/peer`（新增 `pane_for_id`/`resolve_target_pane`；改 `ensure_target`/`capture`/各子命令）
- Modify: `test/peer.test.sh`

- [ ] **Step 1: Write the failing tests**

```bash
# 寻址:peek 无 id,正好两人 → 默认另一个(worker=%2)。
setup
assert_ok "addr: peek default other" run_peer peek 7
assert_contains "addr: peek default captures %2" "$(cat "$TMUX_STUB_LOG")" 'capture-pane -p -J -t %2 -S -7'
teardown

# 寻址:peek 显式 id → 路由到该 pane。
setup
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%2\tworker\tworker\tcodex\n%%3\treviewer\treviewer\tclaude\n' > "$TMUX_STUB_REGISTRY"
assert_ok "addr: peek explicit id" run_peer peek reviewer 9
assert_contains "addr: peek explicit captures %3" "$(cat "$TMUX_STUB_LOG")" 'capture-pane -p -J -t %3 -S -9'
teardown

# 寻址:≥3 人且省略 id → 报错要求指名。
setup
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%2\tworker\tworker\tcodex\n%%3\treviewer\treviewer\tclaude\n' > "$TMUX_STUB_REGISTRY"
assert_not_ok "addr: ambiguous rejected" run_peer peek
assert_contains "addr: ambiguous error" "$(cat "$ERR")" '请指定目标'
teardown

# 寻址:未知 id → 报错。
setup
assert_not_ok "addr: unknown id rejected" run_peer peek nobody
assert_contains "addr: unknown id error" "$(cat "$ERR")" "找不到 agent 'nobody'"
teardown

# status:打印自身与目标。
setup
assert_contains "status: prints target pane" "$(run_peer status; cat "$OUT")" '%2'
teardown
```

并删除/替换旧的、依赖固定 `目标: %2` 与窗口名回退的过时断言（`peek: fallback ...`、`status: prints pane target` 已不再适用；窗口名回退随 Task 2 移除）。具体：删除 `test/peer.test.sh` 中 "peek:没有 pane ID 时回退到窗口名定位" 整个用例块，和 `status: prints pane target`/`status: lists windows` 两条断言（status 不再 list-windows）。

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/peer.test.sh`
Expected: 新 `addr:` 用例 FAIL（尚无寻址解析）。

- [ ] **Step 3: Implement target resolution**

在 `bin/peer` 辅助区新增：

```bash
# pane_for_id <id> → 打印该 id 的 pane;找不到返回 1。
pane_for_id() {
  local want="$1"
  list_agents | awk -F'\t' -v w="$want" '$2==w { print $1; found=1 } END{ exit found?0:1 }'
}

# resolve_target_pane <maybe_id> → 打印目标 pane,出错时写 stderr 并 exit。
#   maybe_id 非空 → 必须是已注册 id;否则报错。
#   maybe_id 为空 → reg_pick_other(self, ids):两人取另一个;0 人/≥2 候选报错。
resolve_target_pane() {
  local maybe_id="$1" pane other ids rc
  if [[ -n "$maybe_id" ]]; then
    if ! pane="$(pane_for_id "$maybe_id")"; then
      echo "错误: 找不到 agent '$maybe_id'。用 'peer ls' 查看在线 agent。" >&2
      exit 1
    fi
    printf '%s' "$pane"
    return 0
  fi
  ids="$(agent_ids)"
  if other="$(reg_pick_other "$ME" "$ids")"; then
    pane_for_id "$other"
    return 0
  fi
  rc=$?
  if [[ "$rc" == "2" ]]; then
    echo "错误: 会话里没有其他 agent 可作为目标。" >&2
  else
    echo "错误: 会话内有多个 agent,请指定目标。可用: $(printf '%s ' $(printf '%s\n' "$ids" | grep -vx "$ME"))" >&2
  fi
  exit 1
}
```

把 `ensure_target` 改为只校验 session 存在（pane 校验交给 resolve）：

```bash
ensure_session() {
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "错误: tmux 会话 '$SESSION' 不存在。" >&2
    exit 1
  fi
}
```

`capture` 改为接收 pane：

```bash
capture() { # <pane> <lines>
  local pane="$1" lines="${2:-80}"
  tmux capture-pane -p -J -t "$pane" -S "-$lines"
}
```

改 `peek` 分支（解析可选首参 id：非整数 → id）：

```bash
  peek)
    ensure_session
    maybe_id=""
    if [[ -n "${1:-}" ]] && ! is_positive_int "$1"; then maybe_id="$1"; shift; fi
    lines="${1:-80}"
    if ! is_positive_int "$lines"; then
      echo "错误: peer peek 的行数必须是正整数。" >&2; exit 1
    fi
    target="$(resolve_target_pane "$maybe_id")"
    echo "===== 终端最近输出 ====="
    capture "$target" "$lines"
    echo "===== 输出结束 ====="
    ;;
```

> peek 的标题行不再硬编对方名字（多 agent 下没有"对方"），改为通用标题；如需显示目标 id，可在解析后回查，但 YAGNI，先用通用标题。原断言 `===== [codex] 终端最近输出 =====` 需在测试里改为 `===== 终端最近输出 =====`（见 Step 1 已覆盖 peek 的新断言用 capture 日志判定，无需匹配标题；删除旧标题断言 `peek: output header`）。

`check_safe_to_send_keys` 改为接收 pane：

```bash
check_safe_to_send_keys() { # <pane>
  local pane="$1"
  if [[ "$FORCE_SEND" == "1" || "${PEER_FORCE:-0}" == "1" ]]; then
    echo "提示: 已跳过对方权限弹窗检测(--force / PEER_FORCE=1)。" >&2
    return 0
  fi
  local lines="${PEER_PROMPT_CHECK_LINES:-80}"
  if ! is_positive_int "$lines"; then
    echo "错误: PEER_PROMPT_CHECK_LINES 必须是正整数。" >&2; exit 1
  fi
  local screen
  screen="$(capture "$pane" "$lines")"
  if looks_like_prompt "$screen"; then
    echo "错误: 目标 agent 疑似正在等待权限确认/弹窗,peer 未发送按键。请人工查看;如确认强制发送,用 --force 或 PEER_FORCE=1。" >&2
    exit 3
  fi
}
```

改 `esc` 分支：

```bash
  esc)
    ensure_session
    maybe_id=""
    if [[ -n "${1:-}" ]]; then maybe_id="$1"; shift; fi
    if [[ "${1:-}" == "--force" ]]; then FORCE_SEND=1; shift; fi
    target="$(resolve_target_pane "$maybe_id")"
    check_safe_to_send_keys "$target"
    tmux send-keys -t "$target" Escape
    echo "已发送 Escape。"
    ;;
```

改 `wait` 分支首部解析可选 id（其余整数参数逻辑不变，`capture` 调用改成带 pane）：

```bash
  wait)
    ensure_session
    maybe_id=""
    if [[ -n "${1:-}" ]] && ! is_positive_int "$1"; then maybe_id="$1"; shift; fi
    target="$(resolve_target_pane "$maybe_id")"
    # ... 原有 timeout/interval/stable_needed/lines 解析与校验保持不变 ...
    # 把两处 prev/cur 的 capture "$lines" 改为 capture "$target" "$lines"
```

改 `status` 分支：

```bash
  status)
    ensure_session
    target="$(resolve_target_pane "" 2>/dev/null || true)"
    echo "我是: $ME    会话: $SESSION"
    [[ -n "$target" ]] && echo "目标(默认): $target"
    printf '%s\n' "--- agents ---"
    "$0" ls
    ;;
```

> `status` 复用 `peer ls` 展示全员；`目标(默认)` 仅在正好两人时有值（否则 resolve 失败被吞掉，不打印）。Step 1 的 `status: prints target pane` 断言匹配 `%2`，在两人默认下成立。

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/peer.test.sh`
Expected: `addr:`、`status:` 新用例 PASS；旧 peek/esc/wait 用例在更新断言后 PASS。

- [ ] **Step 5: Commit**

```bash
git add bin/peer test/peer.test.sh
git commit -m "feat(peer): optional <id> addressing for peek/wait/status/esc with 2-agent default"
```

---

## Task 5: `peer tell` 的可选 `<id>` 寻址

`tell` 的消息是自由文本，无法用"是否整数"消歧。规则：**首参精确匹配某个已注册 `@agent_id` 且后面还有内容（或走 stdin）→ 首参是目标**；否则全部参数当消息（两人默认）。stdin 形式 `... | peer tell [<id>]` 里唯一可选位置参数就是 id。

**Files:**
- Modify: `bin/peer`（`tell` 分支）
- Modify: `test/peer.test.sh`

- [ ] **Step 1: Write the failing tests**

```bash
# tell:显式 id 首参(已注册)→ 路由该 pane,其余为消息。
setup
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%2\tworker\tworker\tcodex\n%%3\treviewer\treviewer\tclaude\n' > "$TMUX_STUB_REGISTRY"
assert_ok "tell: explicit id routes" run_peer tell reviewer "please review"
assert_eq "tell: explicit id buffer" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-supervisor2reviewer")" "please review"
assert_contains "tell: explicit id paste" "$(cat "$TMUX_STUB_LOG")" 'paste-buffer -b peer-supervisor2reviewer -t %3 -d -p'
teardown

# tell:首参不是已注册 id → 整句当消息,两人默认发给另一个。
setup
assert_ok "tell: plain message default other" run_peer tell "hello there"
assert_eq "tell: plain buffer" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker")" "hello there"
teardown

# tell:stdin + 显式 id(stdin 形式下唯一位置参数即目标 id)。
setup
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%2\tworker\tworker\tcodex\n%%3\treviewer\treviewer\tclaude\n' > "$TMUX_STUB_REGISTRY"
run_peer tell reviewer <<< $'multi\nline'
printf 'multi\nline\n' > "$SCENARIO_TMP/expected"
assert_ok "tell: stdin with id buffer" cmp -s "$SCENARIO_TMP/expected" "$TMUX_STUB_BUFFER_DIR/peer-supervisor2reviewer"
teardown
```

同时更新旧 tell 断言里的 buffer 名：旧用例 `peer-claude2codex` → 现在 self=supervisor、other=worker，应为 `peer-supervisor2worker`。逐条把 `test/peer.test.sh` 里 `peer-claude2codex` 改为 `peer-supervisor2worker`，`-t %2` 保持（worker 仍是 %2）。旧 `run_peer tell "hello" "codex"`（期望 buffer "hello codex"）改为 `run_peer tell "hello codex"`，期望 buffer `hello codex`（"hello" 不是注册 id，整句为消息）。

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/peer.test.sh`
Expected: 新 `tell: explicit id ...` 用例 FAIL（当前 tell 把 `reviewer` 当消息一部分）。

- [ ] **Step 3: Implement tell addressing**

把 `bin/peer` 的 `tell` 分支改为：

```bash
  tell)
    ensure_session
    if [[ "${1:-}" == "--force" ]]; then FORCE_SEND=1; shift; fi
    # 首参若精确匹配某已注册 id → 作为目标消费掉。
    maybe_id=""
    if [[ -n "${1:-}" ]] && agent_ids | grep -qx "$1"; then
      maybe_id="$1"; shift
    fi
    target="$(resolve_target_pane "$maybe_id")"
    # 目标 id(用于 buffer 命名);两人默认时回查 other。
    if [[ -n "$maybe_id" ]]; then
      target_id="$maybe_id"
    else
      target_id="$(reg_pick_other "$ME" "$(agent_ids)")"
    fi
    check_safe_to_send_keys "$target"
    buf="peer-${ME}2${target_id}"
    if [[ $# -gt 0 ]]; then
      printf '%s' "$*" | tmux load-buffer -b "$buf" -
    elif [[ ! -t 0 ]]; then
      tmux load-buffer -b "$buf" -
    else
      echo "用法: peer tell [<id>] \"消息\"  或  echo \"消息\" | peer tell [<id>]" >&2
      exit 1
    fi
    tmux paste-buffer -b "$buf" -t "$target" -d -p
    sleep 0.5
    tmux send-keys -t "$target" Enter
    echo "已投递。(提示: 'peer wait' 等它完成,再 'peer peek' 查看回复)"
    ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/peer.test.sh`
Expected: 全部 PASS（含新旧 tell 用例）。

- [ ] **Step 5: Commit**

```bash
git add bin/peer test/peer.test.sh
git commit -m "feat(peer): optional <id> addressing for tell (registry-membership of first arg)"
```

---

## Task 6: `peer add` 创建并注册一个新 agent

**Files:**
- Modify: `bin/peer`（新增 `add` 分支）
- Modify: `test/peer.test.sh`

- [ ] **Step 1: Write the failing test**

```bash
# add:新建 window、写三个 @agent_* 标签、send-keys 启动 provider、打印 id。
setup
TMUX_STUB_NEW_PANE="%5" assert_ok "add: succeeds" run_peer add --provider codex --role worker --id helper
assert_contains "add: new-window called" "$(cat "$TMUX_STUB_LOG")" 'new-window'
assert_contains "add: tags id"       "$(cat "$TMUX_STUB_LOG")" 'set-option -p -t %5 @agent_id helper'
assert_contains "add: tags role"     "$(cat "$TMUX_STUB_LOG")" 'set-option -p -t %5 @agent_role worker'
assert_contains "add: tags provider" "$(cat "$TMUX_STUB_LOG")" 'set-option -p -t %5 @agent_provider codex'
assert_contains "add: launches codex" "$(cat "$TMUX_STUB_LOG")" 'send-keys -t %5'
assert_contains "add: prints id" "$(cat "$OUT")" 'helper'
teardown

# add:省略 --id → 由 role 派生;已存在 worker → worker-2。
setup
TMUX_STUB_NEW_PANE="%5" assert_ok "add: derive id" run_peer add --provider codex --role worker
assert_contains "add: derived worker-2" "$(cat "$TMUX_STUB_LOG")" 'set-option -p -t %5 @agent_id worker-2'
teardown

# add:非法 provider 报错。
setup
assert_not_ok "add: bad provider" run_peer add --provider gpt --role worker
assert_contains "add: bad provider error" "$(cat "$ERR")" 'provider 必须是 claude 或 codex'
teardown
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/peer.test.sh`
Expected: `add:` 用例 FAIL（落入 help）。

- [ ] **Step 3: Implement `add`**

在 `bin/peer` 顶部辅助区，定位 INSTR 路径（供 claude worker 注入用）：

```bash
PEER_INSTR="$PEER_ROOT/docs/AGENT-INSTRUCTIONS.md"
```

新增 `add` 分支（放在 `ls)` 附近）：

```bash
  add)
    ensure_session
    provider=""; role=""; want_id=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --provider) provider="${2:-}"; shift 2 ;;
        --role)     role="${2:-}"; shift 2 ;;
        --id)       want_id="${2:-}"; shift 2 ;;
        *) echo "错误: 未知参数 '$1'。用法: peer add --provider claude|codex --role <role> [--id <id>]" >&2; exit 1 ;;
      esac
    done
    if ! reg_validate_provider "$provider"; then
      echo "错误: provider 必须是 claude 或 codex,当前为 '$provider'。" >&2; exit 1
    fi
    if [[ -z "$role" ]]; then
      echo "错误: 必须用 --role 指定角色。" >&2; exit 1
    fi
    new_id="$want_id"
    if [[ -z "$new_id" ]]; then
      new_id="$(reg_derive_id "$role" "$(agent_ids)")"
    elif agent_ids | grep -qx "$new_id"; then
      echo "错误: id '$new_id' 已被占用。" >&2; exit 1
    fi
    # 新建 window(裸 shell),捕获 pane;按 start.sh 模式 send-keys 导出环境并启动 provider。
    new_pane="$(tmux new-window -t "$SESSION" -n "$new_id" -c "$PWD" -P -F '#{pane_id}')"
    tmux set-option -p -t "$new_pane" @agent_id "$new_id"
    tmux set-option -p -t "$new_pane" @agent_role "$role"
    tmux set-option -p -t "$new_pane" @agent_provider "$provider"
    launch="$(reg_provider_launch_cmd "$provider" "$PEER_INSTR")"
    bin_dir="$(dirname "$PEER_SRC")"
    tmux send-keys -t "$new_pane" \
      "export AGENT_SESSION=$(printf '%q' "$SESSION") PATH=$(printf '%q' "$bin_dir"):\$PATH; $launch" Enter
    echo "已创建 agent '$new_id'(role=$role, provider=$provider, pane=$new_pane)。"
    ;;
```

> worker 自识别靠它自己 pane 的 `@agent_id`(已设置)+ `$TMUX_PANE`，因此**无需**注入 `AGENT_NAME`。codex worker 的 peer 提示词来自 WORKDIR/AGENTS.md（start.sh 已注入）；claude worker 走 `--append-system-prompt`（launch 字符串已含）。

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/peer.test.sh`
Expected: `add:` 用例全 PASS。

- [ ] **Step 5: Commit**

```bash
git add bin/peer test/peer.test.sh
git commit -m "feat(peer): 'peer add' spawns + atomically registers a new agent pane"
```

---

## Task 7: `peer rm` 移除一个 agent

**Files:**
- Modify: `bin/peer`（新增 `rm` 分支）
- Modify: `test/peer.test.sh`

- [ ] **Step 1: Write the failing test**

```bash
# rm:按 id 找到 pane 并 kill-window。
setup
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%2\tworker\tworker\tcodex\n' > "$TMUX_STUB_REGISTRY"
assert_ok "rm: succeeds" run_peer rm worker
assert_contains "rm: kills window" "$(cat "$TMUX_STUB_LOG")" 'kill-window -t %2'
teardown

# rm:未知 id 报错。
setup
assert_not_ok "rm: unknown id" run_peer rm ghost
assert_contains "rm: unknown error" "$(cat "$ERR")" "找不到 agent 'ghost'"
teardown

# rm:拒绝移除自己。
setup
assert_not_ok "rm: refuse self" run_peer rm supervisor
assert_contains "rm: refuse self error" "$(cat "$ERR")" '不能移除自己'
teardown
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/peer.test.sh`
Expected: `rm:` 用例 FAIL。

- [ ] **Step 3: Implement `rm`**

```bash
  rm)
    ensure_session
    rm_id="${1:-}"
    if [[ -z "$rm_id" ]]; then
      echo "用法: peer rm <id>" >&2; exit 1
    fi
    if [[ "$rm_id" == "$ME" ]]; then
      echo "错误: 不能移除自己。" >&2; exit 1
    fi
    if ! rm_pane="$(pane_for_id "$rm_id")"; then
      echo "错误: 找不到 agent '$rm_id'。" >&2; exit 1
    fi
    tmux kill-window -t "$rm_pane"
    echo "已移除 agent '$rm_id'(pane=$rm_pane)。"
    ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/peer.test.sh`
Expected: `rm:` 用例全 PASS。

- [ ] **Step 5: Commit**

```bash
git add bin/peer test/peer.test.sh
git commit -m "feat(peer): 'peer rm <id>' removes an agent (refuses self)"
```

---

## Task 8: `start.sh` 单 supervisor bootstrap + `--supervisor` / `--with`

**Files:**
- Modify: `start.sh`（参数解析、单窗口创建、`@agent_*` 标签、`--with`）
- Modify: `test/start.test.sh`

- [ ] **Step 1: Write the failing test**

在 `test/start.test.sh` 的 tmux stub 里，给 `new-session`/`new-window` 返回可区分的 pane，并记录 `set-option`。stub 的 `case` 已记录所有调用到 `$SENDLOG`？当前 start stub 只记录 send-keys。新增：把所有命令都 append 到一个统一日志。修改 stub：

```bash
cat > "$STUB_BIN/tmux" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SENDLOG"
case "\$1" in
  has-session) exit 1 ;;
  new-session) printf '%%1\n'; exit 0 ;;
  new-window)  printf '%%2\n'; exit 0 ;;
  *)           exit 0 ;;
esac
STUB
```

新增/调整断言（替换原"两个窗口"相关断言）：

```bash
# 默认:只起一个 supervisor 窗口(claude),并打 @agent_* 标签。
assert_contains "start: single supervisor window" "$(cat "$SENDLOG")" 'new-session -d -s agents -n supervisor'
assert_contains "start: tags supervisor id"       "$(cat "$SENDLOG")" 'set-option -p -t %1 @agent_id supervisor'
assert_contains "start: tags supervisor provider" "$(cat "$SENDLOG")" 'set-option -p -t %1 @agent_provider claude'
assert_contains "start: launches claude"          "$(cat "$SENDLOG")" 'send-keys -t %1'
assert_not_contains "start: no second window by default" "$(cat "$SENDLOG")" 'new-window'
```

并为 `--supervisor codex` 与 `--with codex:worker` 各加一组（分别断言 supervisor provider=codex；以及 `--with` 下出现 `new-window` + `@agent_id worker` + `@agent_provider codex`）。

> 注意：原 start.test.sh 里断言"注入 AGENT_NAME=claude/codex"的用例需移除或改写——新模型不再注入 `AGENT_NAME`，身份走 `@agent_*` 标签。

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/start.test.sh`
Expected: 新断言 FAIL（start.sh 仍建两个固定窗口、仍注入 AGENT_NAME）。

- [ ] **Step 3: Implement single-supervisor bootstrap**

在 `start.sh` 顶部 source 区，追加 source registry：

```bash
# shellcheck source=lib/registry.sh
source "$LIB_DIR/registry.sh"
```

参数解析（在现有 `-y/--yes` 循环里）扩展 `--supervisor` 与 `--with`：

```bash
SUPERVISOR_PROVIDER="claude"
WITH_SPEC=""   # 形如 codex:worker
_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) AUTO=1; shift ;;
    --supervisor) SUPERVISOR_PROVIDER="${2:-}"; shift 2 ;;
    --with) WITH_SPEC="${2:-}"; shift 2 ;;
    *) _args+=("$1"); shift ;;
  esac
done
set -- ${_args[@]+"${_args[@]}"}
```

校验 supervisor provider：

```bash
if ! reg_validate_provider "$SUPERVISOR_PROVIDER"; then
  echo "错误: --supervisor 必须是 claude 或 codex,当前为 '$SUPERVISOR_PROVIDER'。" >&2
  exit 1
fi
```

把"窗口 1 claude / 窗口 2 codex"（`start.sh:132-142`）替换为单 supervisor + 可选 `--with`：

```bash
SUP_PANE="$(tmux new-session -d -s "$SESSION" -n supervisor -c "$WORKDIR" -P -F '#{pane_id}')"
tmux set-option -p -t "$SUP_PANE" @agent_id supervisor
tmux set-option -p -t "$SUP_PANE" @agent_role supervisor
tmux set-option -p -t "$SUP_PANE" @agent_provider "$SUPERVISOR_PROVIDER"

if [[ "$SUPERVISOR_PROVIDER" == "claude" ]]; then
  SUP_LAUNCH="$CLAUDE_LAUNCH"
else
  SUP_LAUNCH="codex"
fi
tmux send-keys -t "$SUP_PANE" \
  "export AGENT_SESSION=$SESSION_Q PATH=$BIN_DIR_Q:\$PATH; $SUP_LAUNCH" Enter

# --with <provider>:<role> → 立即再起一个 worker(等价 peer add)。
if [[ -n "$WITH_SPEC" ]]; then
  w_provider="${WITH_SPEC%%:*}"
  w_role="${WITH_SPEC#*:}"
  if ! reg_validate_provider "$w_provider"; then
    echo "错误: --with 的 provider 必须是 claude 或 codex,当前为 '$w_provider'。" >&2
    exit 1
  fi
  W_PANE="$(tmux new-window -t "$SESSION" -n "$w_role" -c "$WORKDIR" -P -F '#{pane_id}')"
  tmux set-option -p -t "$W_PANE" @agent_id "$w_role"
  tmux set-option -p -t "$W_PANE" @agent_role "$w_role"
  tmux set-option -p -t "$W_PANE" @agent_provider "$w_provider"
  W_LAUNCH="$(reg_provider_launch_cmd "$w_provider" "$INSTR")"
  tmux send-keys -t "$W_PANE" \
    "export AGENT_SESSION=$SESSION_Q PATH=$BIN_DIR_Q:\$PATH; $W_LAUNCH" Enter
fi
```

> 注意：`CLAUDE_LAUNCH` 仍由现有注入逻辑（`adk_claude_cmd`）产生，保持 supervisor=claude 时的 `--append-system-prompt` 行为。`claude`/`codex` 二进制存在性检查（`start.sh:59-68`）保留即可（两者仍可能被用到）。

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/start.test.sh`
Expected: 单 supervisor、`--supervisor`、`--with` 三组用例 PASS。

- [ ] **Step 5: Commit**

```bash
git add start.sh test/start.test.sh
git commit -m "feat(start): single-supervisor bootstrap with --supervisor and --with flags"
```

---

## Task 9: 更新 `docs/AGENT-INSTRUCTIONS.md`

让 supervisor agent 知道新能力，并澄清 `peer add`（可见队友）vs 既有"spawn 无头子 agent"。

**Files:**
- Modify: `docs/AGENT-INSTRUCTIONS.md`

- [ ] **Step 1: 更新命令清单与身份说明**

把开头 "环境变量 `AGENT_NAME` 标识了你自己的身份" 一句改为：

```
你自己的身份由所在 tmux pane 的 @agent_id 标记(可用 `peer ls` 查看;
你可能是 supervisor,也可能是某个 worker/reviewer)。
```

在 `peer status` 一行后,补充新命令:

```
- `peer ls` — 列出本会话所有 agent(id / role / provider / pane),自己一行带 `*`
- `peer add --provider claude|codex --role <role> [--id <id>]` — 新建一个**可见的**队友 tab 并自动注册;返回它的 id
- `peer rm <id>` — 移除一个队友 tab
- 寻址:`peer tell/peek/wait/esc [<id>]` 可指定目标 id;**正好两个 agent 时可省略**(默认发给"另一个");三个及以上必须显式指定 id
```

- [ ] **Step 2: 澄清术语冲突**

在"术语与消歧"表格后,追加一条:

```
5. `peer add` 创建的是**可见的、长期存活的 peer 队友**(在新 tab 里,用户看得见,
   用 `peer ls`/`peer tell <id>` 与之交互),与第 2 条"派生无头子 agent(codex exec)"
   完全不同——前者是 agent-duo 工作台的一等成员,后者是临时零工。
```

并把"使用规则"第 1 条扩展,允许 supervisor 在用户要求编队时执行 `peer add`/`peer rm`:

```
1. **仅在用户明确要求时**才向对方发送指令(`peer tell` / `peer esc`)或改变团队
   编制(`peer add` / `peer rm`);`peer peek` / `peer ls` 用于查看状态,可在用户
   询问时主动使用。
```

- [ ] **Step 3: 跑全量测试确认无回归**

Run: `bash test/run.sh`
Expected: `ALL TESTS PASSED`。

- [ ] **Step 4: Commit**

```bash
git add docs/AGENT-INSTRUCTIONS.md
git commit -m "docs: document peer ls/add/rm and the new supervisor-led team model"
```

---

## 最终验证

- [ ] 运行 `bash test/run.sh`，确认 `ALL TESTS PASSED`。
- [ ] 在真实 iTerm2 里 `./start.sh`，确认开局单 tab(supervisor=claude)。
- [ ] 在 supervisor 里 `peer add --provider codex --role worker`，确认出现第二个 tab 跑 codex 且 `peer ls` 能看到两员。
- [ ] `peer tell "..."`(省略 id)默认发给 worker；`peer add` 第三个 agent 后，省略 id 的 `peer tell` 报错要求指名。
- [ ] `peer rm worker` 关掉该 tab，`peer ls` 不再列出。

## 已知限制 / 后续(本 MVP 外)

- worker 的 cwd 取 supervisor 当前 `$PWD`，无 worktree 隔离(MVP 4)。
- `peer add` 仅支持 claude/codex；新 provider 后续扩 `reg_provider_launch_cmd`。
- 不持久化团队状态到磁盘，session 关闭即消失(durable state 属 MVP 9)。
- 不支持运行中 `reassign` 角色(spawn 时定角色)。
