# Loop Engineering 命令面重构 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `agent-duo` 的 `peer` 命令面按 loop engineering 心智模型重构为「transport / building-block 名词 / steering」三层的名词-动词语法，并配套统一文档与用户可见术语；纯重定位，不新增能力（budget 仅薄 stub）。

**Architecture:** 重写 `bin/peer` 顶层 dispatch 为两级（名词-动词）路由：transport（peek/tell/wait/esc/status）与 steering（ask/checkpoint/reframe）保持顶层单级；`loop/agent/approval/verify/judge/gate/budget/task` 走两级；`report` 为 flag-style 名词；`loopd` 顶层运行时分支原样保留。落盘 JSON schema、`.agent-duo/` 记录结构、`lib/*.sh` 函数名一律不动——只换 CLI 表层与面向用户字符串（含 event 的人类 `summary` prose）。pre-1.0，**不保留任何旧命令别名**，旧命令一律 fail-closed 并提示新名。

**Tech Stack:** Bash（`bin/peer` 单文件 dispatch + `lib/*.sh`）、`jq`、`tmux`(stub)；测试为 `test/*.test.sh`，跑 `bash test/run.sh`，断言库 `test/assert.sh`（`assert_ok` / `assert_not_ok` / `assert_contains` / `assert_eq`）+ `test/peer.test.sh` 的 `setup`/`teardown`/`run_peer`/`run_peer_as`。

**权威 spec:** `docs/superpowers/specs/2026-06-27-loop-engineering-restructure-design.md`。本计划任一处与 spec 冲突，以 spec 为准。

## Global Constraints

- **不保留旧命令别名**：`peer ls` / `peer loop <id>`(裸) / `peer task <id>`(裸) / `peer approvals` / `peer approve` / `peer deny` / `peer broker-status` / `peer broker-check` / `peer report --verdict|--target-ref|--finding` 全部删除，调用即**非 0 退出**且 stderr 提示对应新命令。
- **只换门面不换地基**：`.agent-duo/` 下 JSON 字段名（`validation`/`review`/`status`/`verdict` 等）、event `type`（`review_required`/`validation_pass`/`validation_fail`）、event_id（`reviewreq-…`/`validation-…`）、`lib/*.sh` 函数名**均不改**。只改 CLI flag 名、命令结构、面向用户字符串（含 event 的人类 `summary` prose）。
- **顶层二进制名不变**：`peer`、`agent-duo-start` 不改；Homebrew formula 不动。
- **transport 行为不变**：peek/tell/wait/esc/status 的语义与全部 flag/变体保留（含 `wait <id> --round N [--timeout][--interval]`、`tell/esc [--force]`、前置 `peer --force tell/esc`）。
- **CLI flag 整族改名**：`--validation`→`--verify`、`--validation-satisfies`→`--verify-satisfies`、`--validation-timeout`→`--verify-timeout`、`--review`→`--judge`；`--non-goal`/`--success`/`--round`/`--detail-trap-rounds` 保留不改名。
- **文档 grep-replace 范围**：代码（`bin/`、`scripts/`、`*.sh`）、测试、当前 agent 指令（`docs/AGENT-INSTRUCTIONS.md` 注入块）、本次新建/改动文档；**不含 `docs/superpowers/specs/` 历史设计**。
- **验收门**：`bash test/run.sh` 全绿 **且** 每个名词 `peer <noun> --help`（含 flag-style `peer report --help`）exit 0 **且** 全部旧命令负向用例非 0+提示新命令。
- **TDD + 频繁提交**：每个 Task 先写失败测试 → 跑红 → 改实现 → 跑绿 → commit。

---

## 文件结构

- `bin/peer` — 唯一的 CLI dispatch；本次重写顶层 `case` 为两级路由，新增 `verify`/`judge`/`budget` 名词分支，抽 `_emit_result_report` 私有 helper，更新所有面向用户提示串与顶层 help 横幅。
- `lib/loop.sh` — 仅改面向用户的 `summary` prose（`review …`→`judge …`、`validation …`→`verify …`）与 dashboard 标签；函数名/event type/字段名不动。
- `start.sh` — 改启动引导文案里的 `peer broker-check` 等旧命令名。
- `docs/AGENT-INSTRUCTIONS.md` — 注入块命令清单换新名并按三层重排。
- `README.md` / `README.zh-CN.md` — 重定位为 loop engineering 框架。
- `docs/loop-engineering.md`（新建）/ `docs/glossary.md`（新建）— 概念正典与统一词汇表。
- `agent-duo-supervisor-loop-roadmap.md` — 顶部加术语统一指针。
- 测试：`test/peer.test.sh`、`test/loop.test.sh`、`test/integration.test.sh`、`test/approval.test.sh`、`test/registry.test.sh`、`test/start.test.sh` 同步改名；新增负向别名测试与 verify/judge/budget 用例。

**实现顺序建议**：先做不依赖彼此的纯改名（Task 1–4），再做拆分与新名词（Task 5–7），再做术语/横幅（Task 8–9），最后文档（Task 10）。每个 Task 结束 `bash test/run.sh` 必须全绿。

---

### Task 1: `agent` 名词（ls/add/rm 迁移 + 旧名负向）

**Files:**
- Modify: `bin/peer`（顶层 `ls)` `add)` `rm)` 分支 → 合并进 `agent)` 两级分支；旧 `ls)`/`add)`/`rm)` 顶层分支删除）
- Modify: `bin/peer`（`peer status` 内部对 `ls` 的调用改到新内部函数）
- Test: `test/peer.test.sh`

**Interfaces:**
- Produces: `peer agent ls`、`peer agent add --provider … --role … [--id …] [--worktree]`、`peer agent rm [--force] <id>`（`--force` 前/后置均支持）。旧 `peer ls`/`peer add`/`peer rm` 删除。

- [ ] **Step 1: 写失败测试（新命令通 + 旧命令非 0）**

在 `test/peer.test.sh` 末尾 `teardown` 前追加：

```bash
# agent 名词迁移
setup
assert_ok "agent ls: succeeds" run_peer agent ls
assert_contains "agent ls: lists worker" "$(cat "$OUT")" 'worker'
assert_not_ok "agent: old 'peer ls' removed" run_peer ls
assert_contains "agent: old ls hints new" "$(cat "$ERR")" 'peer agent ls'
assert_not_ok "agent: old 'peer add' removed" run_peer add --provider codex --role helper
assert_contains "agent: old add hints new" "$(cat "$ERR")" 'peer agent add'
assert_not_ok "agent: old 'peer rm' removed" run_peer rm worker
assert_contains "agent: old rm hints new" "$(cat "$ERR")" 'peer agent rm'
teardown
```

- [ ] **Step 2: 跑红**

Run: `bash test/peer.test.sh`
Expected: 上述 `agent ls` 等断言 FAIL（命令尚不存在 / 旧命令仍存在）。

- [ ] **Step 3: 实现 `agent` 两级分支**

在 `bin/peer` 顶层 `case` 中：删除独立的 `ls)`、`add)`、`rm)` 分支体，移入新 `agent)` 分支，按子命令 `ls|add|rm` 分发（复用原有实现体，逐字搬运不改逻辑）。骨架：

```bash
  agent)
    subcmd="${2:-}"; shift 2 2>/dev/null || shift $#
    case "$subcmd" in
      ls)   # ←原 ls) 分支体
        ... ;;
      add)  # ←原 add) 分支体（注意原来用 $2.. 解析，需相应 shift 调整）
        ... ;;
      rm)   # ←原 rm) 分支体
        ... ;;
      ""|--help|-h)
        echo "用法: peer agent ls | peer agent add --provider claude|codex --role <role> [--id <id>] [--worktree] | peer agent rm [--force] <id>"; exit 0 ;;
      *) echo "用法: peer agent <ls|add|rm> ..." >&2; exit 1 ;;
    esac
    ;;
```

把原 `peer status` 里调用 `ls` 的内部处（grep `bin/peer` 中 status 分支对 ls 的调用）改为直接调用搬运后的 ls 实现函数或内联逻辑。

为旧命令加 fail-closed 提示分支（与其它旧命令统一，见 Task 11 也会汇总；这里先就地加）：

```bash
  ls)  echo "已移除: 'peer ls' → 改用 'peer agent ls'" >&2; exit 1 ;;
  add) echo "已移除: 'peer add' → 改用 'peer agent add ...'" >&2; exit 1 ;;
  rm)  echo "已移除: 'peer rm' → 改用 'peer agent rm ...'" >&2; exit 1 ;;
```

- [ ] **Step 4: 跑绿**

Run: `bash test/peer.test.sh`
Expected: PASS（新旧断言全过）。其余既有用例里凡调用 `peer add`/`peer rm`/`peer ls` 的，一并改成 `peer agent …`（grep `run_peer add`/`run_peer rm`/`run_peer ls`）。

- [ ] **Step 5: commit**

```bash
git add bin/peer test/peer.test.sh
git commit -m "refactor(peer): agent 名词(ls/add/rm)两级迁移 + 旧名 fail-closed"
```

---

### Task 2: `approval` 名词（approvals/approve/deny + broker-status/check）

**Files:**
- Modify: `bin/peer`（`approvals)`/`approve)`/`deny)`/`broker-status)`/`broker-check)` 顶层分支 → `approval)` 两级；旧分支转 fail-closed）
- Modify: `start.sh`、`bin/peer` 内 `peer add` 后/broker 硬门拒发的提示串（`broker-check`→`approval check` 等）
- Test: `test/peer.test.sh`、`test/approval.test.sh`

**Interfaces:**
- Produces: `peer approval ls [--all]`、`peer approval approve <id>`、`peer approval deny <id> [--reason …]`、`peer approval status [<id>]`、`peer approval check [<id>] [--nonce …]`。

- [ ] **Step 1: 写失败测试**

`test/peer.test.sh`：

```bash
setup
assert_ok "approval ls: succeeds" run_peer approval ls
assert_not_ok "approval: old 'peer approvals' removed" run_peer approvals
assert_contains "approval: old approvals hints" "$(cat "$ERR")" 'peer approval ls'
assert_not_ok "approval: old 'peer broker-check' removed" run_peer broker-check worker
assert_contains "approval: old broker-check hints" "$(cat "$ERR")" 'peer approval check'
teardown
```

- [ ] **Step 2: 跑红** — Run: `bash test/peer.test.sh` → FAIL。

- [ ] **Step 3: 实现 `approval)` 两级分支**，子命令 `ls|approve|deny|status|check`，分别搬运原 `approvals)`/`approve)`/`deny)`/`broker-status)`/`broker-check)` 分支体（逻辑不变，仅迁移 + 调整 `shift`）。`--all`（ls）、`--reason`（deny）、`--nonce`（check）原样保留。旧顶层分支改为 fail-closed 提示。

- [ ] **Step 4: 改提示串** — grep `bin/peer`、`start.sh` 中 `broker-check`/`broker-status`/`peer approvals`/`peer approve`/`peer deny`，逐处替换为新命令名（范围见 Global Constraints；不碰历史 specs）。

- [ ] **Step 5: 跑绿** — Run: `bash test/run.sh`（含 approval.test.sh）→ 把其中旧命令调用改新名后 PASS。

- [ ] **Step 6: commit**

```bash
git add bin/peer start.sh test/peer.test.sh test/approval.test.sh
git commit -m "refactor(peer): approval 名词收口(approvals/approve/deny/broker-*) + 提示串改名"
```

---

### Task 3: `loop show` / `task show`（删裸 shorthand）

**Files:**
- Modify: `bin/peer`（`loop)` 分支：`*)` 裸 id show → 显式 `show)` 子命令；`task)` 分支同理）
- Test: `test/peer.test.sh`、`test/loop.test.sh`

**Interfaces:**
- Produces: `peer loop show <id>`、`peer task show [<id>]`。删除 `peer loop <id>`(裸)、`peer task <id>`(裸) 的查看入口。

- [ ] **Step 1: 写失败测试**

```bash
setup
# 需要先有 loop.json/task.json；用既有 init 路径或直接造 state（参照本文件其它用例）
assert_ok "loop show: works" run_peer loop show worker || true   # 若无契约应有明确退出码，按实现断言
assert_not_ok "loop: bare '<id>' shorthand removed" run_peer loop worker
assert_contains "loop: bare hints show" "$(cat "$ERR")" 'peer loop show'
assert_not_ok "task: bare '<id>' shorthand removed" run_peer task worker
assert_contains "task: bare hints show" "$(cat "$ERR")" 'peer task show'
teardown
```

- [ ] **Step 2: 跑红** → FAIL。

- [ ] **Step 3: 实现** — `loop)` 分支把现有 `*) loop_print …` 改为 `show) loop_print "$target"`，并对未知子命令/裸 id 报错提示 `peer loop show <id>`。`task)` 分支把 `""|*) task_print` 改为 `show) task_print`。`init`/`next`/`reset` 不变。

- [ ] **Step 4: 跑绿** — 把 `test/peer.test.sh`、`test/loop.test.sh` 中 `peer task worker`/`peer loop worker` 改为 `peer task show worker`/`peer loop show worker`。Run: `bash test/run.sh` → PASS。

- [ ] **Step 5: commit**

```bash
git add bin/peer test/peer.test.sh test/loop.test.sh
git commit -m "refactor(peer): loop show / task show 显式动词，删裸 id shorthand"
```

---

### Task 4: 契约 flag 整族改名（`--verify*` / `--judge`）

**Files:**
- Modify: `bin/peer`（`loop init` 解析：`--validation`→`--verify`、`--validation-satisfies`→`--verify-satisfies`、`--validation-timeout`→`--verify-timeout`、`--review`→`--judge`）
- Test: `test/peer.test.sh`、`test/integration.test.sh`、`test/loop.test.sh`

**Interfaces:**
- Produces: `peer loop init <id> --mission … --max-rounds N [--non-goal …] [--success …] [--round N] [--verify id:cmd] [--verify-satisfies …] [--verify-timeout …] [--judge role:veto] [--detail-trap-rounds N]`。on-disk 字段名仍是 `validation`/`review`（不改）。

- [ ] **Step 1: 写失败测试** — 新 flag 能冻结契约；旧 flag 报错：

```bash
setup
assert_ok "loop init: --verify accepted" run_peer loop init worker --mission "m" --max-rounds 3 --verify tests:"true"
assert_not_ok "loop init: old --validation rejected" run_peer loop init worker --mission "m" --max-rounds 3 --validation tests:"true"
assert_contains "loop init: --validation hints --verify" "$(cat "$ERR")" '--verify'
assert_not_ok "loop init: old --review rejected" run_peer loop init worker --mission "m" --max-rounds 3 --judge reviewer:request_changes --review reviewer:request_changes
teardown
```

- [ ] **Step 2: 跑红** → FAIL。

- [ ] **Step 3: 实现** — `loop init` 参数解析里把 `--validation*`/`--review` case 标签改为 `--verify*`/`--judge`；内部仍写入既有 `validation`/`review` 契约字段（即只改 case 标签与用户错误串，不改写入 jq 字段）。旧 flag 落到 `*)` 未知参数分支自然报错，错误串里点名新 flag。

- [ ] **Step 4: 跑绿** — grep 全仓测试里 `--validation`/`--validation-satisfies`/`--validation-timeout`/`--review` 改新名。Run: `bash test/run.sh` → PASS。

- [ ] **Step 5: commit**

```bash
git add bin/peer test/*.test.sh
git commit -m "refactor(peer): 契约 flag 整族 --verify*/--judge 改名(on-disk 字段不动)"
```

---

### Task 5: report/judge 拆分（私有 helper + report fail-closed + `peer judge`）

**Files:**
- Modify: `bin/peer`（`report)` 分支：移除 `--verdict`/`--target-ref`/`--finding` 解析；抽 `_emit_result_report` 私有函数；新增 `judge)` 分支调它）
- Test: `test/peer.test.sh`、`test/integration.test.sh`

**Interfaces:**
- Consumes: 既有 `write_report_json`、`route_verdict_record`、`build_findings_json`、`next_report_round`、event 写入逻辑。
- Produces:
  - `peer judge <target-ref> --verdict V [--round R] [--status done] [--finding sev:note]… [--delta …] [--evidence-cmd/--evidence-result/--evidence-ref …] [--step/--step-ref sN] [--goal/--goal-ref …] [--drift …] [--next …]`，注入 `--type result`，默认 `--status done`（继承无 evidence→unknown 降级）。
  - `peer judge ls <id>`：列 `state/<id>/reviews/*.json`，排序 target_round↓→时间↓→role↑；`--json` 输出 `[{verdict,by,role,target_round,ref}]`；存在性按 `state/<id>/` 判定（不存在→非 0；存在无 reviews→退 0 空）。
  - `peer report` 不再接受 `--verdict`/`--target-ref`/`--finding`（fail-closed，提示 `peer judge`）。

- [ ] **Step 1: 写失败测试**

```bash
# judge 落盘等价 + report 拒绝 verdict
setup
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%2\treviewer\treviewer\tcodex\n%%3\tworker\tworker\tcodex\n' > "$TMUX_STUB_REGISTRY"
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "judge: verdict succeeds" \
  run_peer judge worker@5 --round 1 --verdict approve --finding blocking:"401/403 反了"
assert_contains "judge: routed verdict" "$(cat "$PROJECT/.agent-duo/state/worker/reviews/reviewer-r5.json")" '"verdict":"approve"'
assert_contains "judge: reviewer own report verdict" "$(cat "$PROJECT/.agent-duo/state/reviewer/r1.json")" '"verdict":"approve"'
assert_ok "judge ls: lists" run_peer judge ls worker
assert_not_ok "judge ls: unknown target non-zero" run_peer judge ls nope
teardown

setup
TEST_TMUX_PANE="%2" assert_not_ok "report: --verdict rejected" \
  run_peer report --type result --status done --round 1 --verdict approve --target-ref worker@3
assert_contains "report: verdict hints judge" "$(cat "$ERR")" 'peer judge'
assert_ok "report: no file written on rejected verdict" test ! -e "$PROJECT/.agent-duo/state/reviewer/r1.json"
teardown
```

- [ ] **Step 2: 跑红** → FAIL。

- [ ] **Step 3: 实现私有 helper** — 把 `report)` 分支里「构造 findings_json + 写 result report + `route_verdict_record` + sentinel + result event」那段抽成 `_emit_result_report`（入参沿用现有局部变量），由 `report` 历史 result 路径与新 `judge)` 共用。

- [ ] **Step 4: report 去 verdict** — `report)` 参数解析里删除 `--verdict`/`--target-ref`/`--finding` 三个 case，落入 `*)` 未知参数分支报错并提示 `peer judge`；确保报错时**不写任何文件**（在解析阶段即 `exit 1`，早于 mkdir/写盘）。

- [ ] **Step 5: 实现 `judge)` 分支** — 解析位置参数 `<target-ref>`（规范化为 `worker@N`）、`--round`(可选→`next_report_round`)、`--verdict`、`--status`(默认 done)、`--finding`/`--delta`/`--evidence-*`/`--step`/`--goal`/`--drift`/`--next`；注入 `type=result`；缺 `<target-ref>` 或 `--verdict` 即 fail-closed 不写盘；调 `_emit_result_report`。子命令 `ls)` 实现 judge ls（读 `state/<id>/reviews/`，排序与 `--json` 形态见 Interfaces；存在性按 `state/<id>/`）。

- [ ] **Step 6: 跑绿** — `test/peer.test.sh`/`test/integration.test.sh` 中针对 verdict 的断言把被测命令从 `report --type result --verdict …` 改成 `judge …`，文件路径/字段/事件序列不变。Run: `bash test/run.sh` → PASS。

- [ ] **Step 7: commit**

```bash
git add bin/peer test/peer.test.sh test/integration.test.sh
git commit -m "refactor(peer): report/judge 拆分(私有 helper + report fail-closed + peer judge/judge ls)"
```

---

### Task 6: `verify` 名词（ls/show + JSON wrapper）

**Files:**
- Modify: `bin/peer`（新增 `verify)` 两级分支）
- Test: `test/peer.test.sh`、`test/loop.test.sh`

**Interfaces:**
- Consumes: 冻结契约 `state/<id>/loop.json` 的 `validation[]` 声明、`state/<id>/validation-rN.json`（顶层 `status` + `results[]`）、`state/<id>/validation-rN.running`、`state/<id>/report.json`（当前 round，`ad_loop_report_round` 口径 `.round // 0`）。
- Produces: `peer verify ls <id> [--round N] [--json]`、`peer verify show <id> [--round N] [--json]`。`--json` 二者输出相同 wrapper：

```json
{ "agent":"worker", "round":3,
  "round_status":"pass|fail|error|running|not_run|pending|no_gates",
  "gates":[ {"id":"tests","cmd":"…","satisfies":["…"],
             "status":"pass|fail|error|running|not_run|pending","result":null } ] }
```

- 单 gate `status`：按 gate `id` 匹配 `validation-rR.json` 的 `results[].status`（顶层 status 仅作 `round_status`）；无匹配 results→`not_run`；只有 `.running`→`running`；无 report→`pending`。契约无闸门→`gates:[]` + `round_status:"no_gates"` + 退 0。无 `loop.json`→非 0 提示先 `peer loop init`。

- [ ] **Step 1: 写失败测试**

```bash
setup
# 冻结一个带 verify 闸门的契约（worker 尚无 report → pending、round 0）
run_peer loop init worker --mission "m" --max-rounds 3 --verify tests:"true"
assert_ok "verify ls: succeeds with contract" run_peer verify ls worker
assert_contains "verify ls: gate listed" "$(cat "$OUT")" 'tests'
run_peer verify ls worker --json
assert_contains "verify ls --json: round 0 (no report yet)" "$(cat "$OUT")" '"round":0'
assert_contains "verify ls --json: pending gate status" "$(cat "$OUT")" '"status":"pending"'
# 无 loop.json 的目标 → 非 0
assert_not_ok "verify ls: no loop.json non-zero" run_peer verify ls nope
assert_contains "verify ls: no-contract hints loop init" "$(cat "$ERR")" 'peer loop init'
# ls --json == show --json（同一 wrapper）
run_peer verify ls worker --json;  ls_json="$(cat "$OUT")"
run_peer verify show worker --json; show_json="$(cat "$OUT")"
assert_eq "verify: ls --json == show --json" "$ls_json" "$show_json"
teardown
```

- [ ] **Step 2: 跑红** → FAIL。

- [ ] **Step 3: 实现 `verify)` 分支** — 子命令 `ls|show`；共享一个内部函数 `_verify_collect <id> <round>` 产出 wrapper JSON（用 jq 读契约 `validation[]` 与 `validation-rN.json` 的 `results[]`，按上表映射状态）；`--json` 直接打印 wrapper；文本模式由 wrapper 渲染（`ls` 一行一 gate；`show` 展开 + 末行 `round_status`）。round 缺省取 `report.json` 的 `.round // 0`，`--round` 覆盖。无 `loop.json` 非 0。

- [ ] **Step 4: 跑绿** — Run: `bash test/run.sh` → PASS。建议加一条 `ls --json` == `show --json` 的相等断言。

- [ ] **Step 5: commit**

```bash
git add bin/peer test/peer.test.sh test/loop.test.sh
git commit -m "feat(peer): verify 名词(ls/show + 稳定 JSON wrapper)"
```

---

### Task 7: `budget` 薄 stub

**Files:**
- Modify: `bin/peer`（新增 `budget)` 分支）
- Test: `test/peer.test.sh`

**Interfaces:**
- Produces: `peer budget status` — 只读，打印「budget 护栏为预留能力，当前未启用」，exit 0；不读写任何状态、不拦截。

- [ ] **Step 1: 写失败测试**

```bash
setup
assert_ok "budget status: exit 0" run_peer budget status
assert_contains "budget status: reserved msg" "$(cat "$OUT")" '预留'
teardown
```

- [ ] **Step 2: 跑红** → FAIL。
- [ ] **Step 3: 实现** — `budget)` 分支：`status)` 打印保留文案 exit 0；`--help` 同；未知子命令 exit 1。
- [ ] **Step 4: 跑绿** — Run: `bash test/peer.test.sh` → PASS。
- [ ] **Step 5: commit**

```bash
git add bin/peer test/peer.test.sh
git commit -m "feat(peer): budget status 薄 stub(预留槽)"
```

---

### Task 8: 用户可见术语统一（verify=/judge= + summary prose）

**Files:**
- Modify: `lib/loop.sh`（dashboard 标签 `VALIDATION`/`ACCEPTANCE`、`validation=`/`accept=`；event `summary` prose `review pending/vetoed`/`validation pass/fail`）
- Modify: `bin/peer`（`loop_print`/`checkpoint` 等打印里的同类标签）
- Test: `test/integration.test.sh`、`test/loop.test.sh`、`test/peer.test.sh`

**Interfaces:**
- 仅改**显示字符串与人类 `summary` prose**：`VALIDATION`→`VERIFY`、`ACCEPTANCE`→`JUDGE`、`validation=`→`verify=`、`accept=`→`judge=`、`summary="review pending/vetoed: …"`→`"judge pending/vetoed: …"`、`summary="validation pass: …"`→`"verify pass: …"`。**event `type`/`id`/JSON 字段名一律不动。**

- [ ] **Step 1: 写失败测试** — 断言 dashboard/summary 用新词（参照 `test/integration.test.sh` 现有 `validation=pass accept=reviewer:vetoed(...)` 那行，改期望为 `verify=pass judge=reviewer:vetoed(...)`）：

```bash
assert_contains "dashboard: verify/judge labels" "$(cat "$OUT")" 'verify=pass judge=reviewer:vetoed(request_changes)'
```

- [ ] **Step 2: 跑红** → FAIL。
- [ ] **Step 3: 实现** — 在 `lib/loop.sh`/`bin/peer` 中逐处替换上述**显示串与 summary 文案**；确认替换的不是 `event …_required`/`validation_pass` 这类 event type、也不是 jq 字段名。
- [ ] **Step 4: 跑绿** — 同步把所有断言旧标签/旧 summary 的测试期望改新词。Run: `bash test/run.sh` → PASS。
- [ ] **Step 5: commit**

```bash
git add lib/loop.sh bin/peer test/*.test.sh
git commit -m "refactor: 用户可见术语统一 verify=/judge= + summary prose(结构化键不动)"
```

---

### Task 9: 顶层 help 横幅 + `gate ls`

**Files:**
- Modify: `bin/peer`（顶层 `help|*)` 用法横幅按三层+名词重写；`gate)` 的 `*)`/裸→显式 `ls`）
- Test: `test/peer.test.sh`

**Interfaces:**
- Produces: `peer`(裸)/`peer --help` 打印新命令面横幅 exit 0；`peer gate ls [--all]`；每个名词 `peer <noun> --help` exit 0（含 `peer report --help`）。

- [ ] **Step 1: 写失败测试**

```bash
setup
assert_ok "help: bare peer exit 0" run_peer --help
assert_contains "help: shows loop noun" "$(cat "$OUT")" 'loop'
assert_contains "help: shows judge noun" "$(cat "$OUT")" 'judge'
for n in loop agent approval verify judge gate budget task report; do
  assert_ok "help: $n --help exit 0" run_peer "$n" --help
done
assert_ok "gate ls: succeeds" run_peer gate ls
assert_not_ok "gate: bare 'peer gate' removed" run_peer gate
assert_contains "gate: bare hints 'gate ls'" "$(cat "$ERR")" 'peer gate ls'
teardown
```

- [ ] **Step 2: 跑红** → FAIL。
- [ ] **Step 3: 实现** — 重写 `help|*)` 横幅文本（三层分组列全部名词与 steering/transport）；`gate)` 把现有 `*)`(裸列表)→`ls)`，未知子命令提示 `peer gate ls`；确保每个名词分支都有 `--help|-h` → exit 0。
- [ ] **Step 4: 跑绿** — Run: `bash test/run.sh` → PASS。
- [ ] **Step 5: commit**

```bash
git add bin/peer test/peer.test.sh
git commit -m "feat(peer): 顶层 help 横幅按三层重写 + gate ls 显式动词 + 各名词 --help exit 0"
```

---

### Task 10: 无别名负向测试汇总（验收门固化）

**Files:**
- Test: `test/peer.test.sh`

**Interfaces:** 把 Global Constraints 的「不保留旧命令别名」固化成一组可执行断言。

- [ ] **Step 1: 写测试**

```bash
setup
for pair in \
  "ls|peer agent ls" \
  "approvals|peer approval ls" \
  "approve|peer approval" \
  "deny|peer approval" \
  "broker-check|peer approval check" \
  "broker-status|peer approval status"; do
  old="${pair%%|*}"; newhint="${pair##*|}"
  assert_not_ok "no-alias: '$old' removed" run_peer $old
  assert_contains "no-alias: '$old' hints '$newhint'" "$(cat "$ERR")" "$newhint"
done
assert_not_ok "no-alias: 'loop <id>' bare removed" run_peer loop worker
assert_not_ok "no-alias: 'task <id>' bare removed" run_peer task worker
assert_not_ok "no-alias: report --verdict removed" run_peer report --type result --status done --round 1 --verdict approve --target-ref worker@3
teardown
```

- [ ] **Step 2: 跑** — Run: `bash test/peer.test.sh` → 应已 PASS（前序 Task 已实现各 fail-closed 分支）。若有遗漏，回到对应 Task 补分支。
- [ ] **Step 3: commit**

```bash
git add test/peer.test.sh
git commit -m "test(peer): 无别名负向测试汇总(旧命令均非0+提示新命令)"
```

---

### Task 11: 文档重定位（README ×2 / loop-engineering.md / glossary.md / AGENT-INSTRUCTIONS / roadmap）

**Files:**
- Create: `docs/loop-engineering.md`、`docs/glossary.md`
- Modify: `README.md`、`README.zh-CN.md`、`docs/AGENT-INSTRUCTIONS.md`、`agent-duo-supervisor-loop-roadmap.md`
- Test: `test/start.test.sh`（若断言注入块内容则同步）

- [ ] **Step 1: 新建 `docs/glossary.md`** — 一处定义 loop / mission / round budget / verify / judge / gate / checkpoint / reframe / report / approval / budget；注明「历史 specs 不回改」。

- [ ] **Step 2: 新建 `docs/loop-engineering.md`** — 五阶段解剖（DISCOVER→PLAN→EXECUTE→VERIFY→ITERATE，逐阶段标命令）、五构件（标已实现/预留槽）、正确搭建顺序、风险与护栏、旧名→新名迁移表；引用 `docs/agent-loop-三agent循环-提炼.md` 作来源。

- [ ] **Step 3: 重写 `README.md`/`README.zh-CN.md`** — 标题改 loop engineering 框架；plan→build→judge 英雄叙事 + 三层图；`peer` 命令表按三层重排；新增「构件名词↔文档概念」对照节。

- [ ] **Step 4: 更新 `docs/AGENT-INSTRUCTIONS.md` 注入块** — 命令清单换新名并按三层重排；marker 机制不变。若 `test/start.test.sh` 断言注入块字符串，同步改期望。

- [ ] **Step 5: `agent-duo-supervisor-loop-roadmap.md` 顶部加术语统一指针**（不重写全文）。

- [ ] **Step 6: 跑绿 + commit**

```bash
bash test/run.sh   # 期望: ALL TESTS PASSED
git add README.md README.zh-CN.md docs/loop-engineering.md docs/glossary.md docs/AGENT-INSTRUCTIONS.md agent-duo-supervisor-loop-roadmap.md test/start.test.sh
git commit -m "docs: 重定位为 loop engineering 框架(README/概念正典/glossary/注入块/roadmap)"
```

---

## 最终验收

- [ ] `bash test/run.sh` 输出 `ALL TESTS PASSED`。
- [ ] `for n in loop agent approval verify judge gate budget task report; do bin/peer "$n" --help >/dev/null && echo "$n ok"; done` 全部 ok（exit 0）。
- [ ] 旧命令 `peer ls`/`peer loop worker`/`peer task worker`/`peer approvals`/`peer approve`/`peer deny`/`peer broker-check`/`peer broker-status`/`peer report --verdict …` 全部非 0 且 stderr 含新命令名。
- [ ] grep `docs/superpowers/specs/` 未被改动（历史 specs 不回改）。
