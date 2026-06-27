# 测试架构重构 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `agent-duo` 测试套件重组为「子系统 × 真实度」矩阵——抽出单一共享 harness、按 noun/层拆分 monster 文件、新增防「绿但坏」的 Journey 测试、升级 `run.sh` 为层感知 runner。

**Architecture:** 四级真实度梯子（unit/cli/integration/e2e），每级一条 stub 契约；目录=层、文件名=子系统。共享 `test/lib/harness.sh` 是 tmux stub 的单一真相源，三个按层 setup（`unit_setup`/`cli_setup`/`integration_setup`）把 stub 政策编码进调用名。Journey 测试照搬文档工作流端到端断言用户可见输出。纯搬运+拆分，不重写断言。

**Tech Stack:** Bash、`jq`、tmux(stub)；测试为 `test/**/*.test.sh`，跑 `bash test/run.sh`，断言库 `test/lib/assert.sh`。

**权威 spec:** `docs/superpowers/specs/2026-06-27-test-architecture-design.md`。本计划任一处与 spec 冲突，以 spec 为准。

## Global Constraints

- **每阶段结束 `bash test/run.sh` 必须输出 `ALL TESTS PASSED`**，且**断言数不减**（`grep -rho 'assert_[a-z_]*' test/ | wc -l` 拆分前后不减；journey 阶段只增不减）。
- **纯搬运+拆分，不重写断言逻辑**；不改 `bin/peer`/`lib/*` 实现（journey 若暴露真 bug 另开修复）。
- **tmux stub 单一真相源**：只在 `test/lib/harness.sh` 一处实现；现有 env 开关接口（capture 模式、sentinel、codec tag、on-send 回调）平移不改语义。
- **四级 stub 契约**：unit 零进程/无 stub；cli 仅 stub tmux；integration 仅 stub tmux+外部 LLM 二进制；e2e 几乎不 stub 且自带 `skip` 门控（`AGENT_DUO_E2E_*` + 能力探测）。
- **`run.sh` 保留 `ALL TESTS PASSED` / `SOME TESTS FAILED` 哨兵行**（goal/CI grep 它）。
- **优先用 `git mv`** 搬文件（保留历史）。
- **频繁提交**：每个 Task 末尾 commit。

---

## 文件结构（目标态）

```
test/
  lib/{assert.sh, harness.sh}
  unit/{loop,broker,registry,inject}.test.sh
  cli/peer-{transport,steering,agent,approval,loop,task,verify,judge,gate,budget,report,aliases}.test.sh
  integration/{supervisor-loop, journey-supervisor-loop, start}.test.sh
  e2e/{codex-hook, codex-permreq, journey-codex}.test.sh
  run.sh
```

迁移按 spec §8 的 7 个 Phase，**每 Phase 一个 Task**，每 Task 结束 `run.sh` 绿。

---

### Task 0: 基线绿 + 提交

**Files:**
- Modify: 无（仅确认+提交 Codex 已实现的工作树）

**Interfaces:**
- Produces: 一个「已知良好」的 git 基线提交，后续重排都从它出发。

- [ ] **Step 1: 跑基线**

Run: `bash test/run.sh`
Expected: 末行 `ALL TESTS PASSED`。若为 `SOME TESTS FAILED`，**停止**——先修绿再继续（属重构实现的遗留，不在本计划范围；记录失败用例并反馈）。

- [ ] **Step 2: 记录断言基数**

Run: `git stash list >/dev/null; grep -rho 'assert_[a-z_]*' test/ | wc -l`
Expected: 打印一个整数 N（记下它，作为后续「断言守恒」基准）。把 N 写进提交信息。

- [ ] **Step 3: 提交基线**

```bash
git add -A
git commit -m "test: 基线——loop-engineering 重构实现(Codex)绿，断言基数 N=<填入>"
```

---

### Task 1: 抽共享 harness（`test/lib/`）

**Files:**
- Create: `test/lib/assert.sh`（= 现 `test/assert.sh` 内容）
- Create: `test/lib/harness.sh`（抽出 `make_tmp` / tmux stub / `setup`·`teardown` / `run_peer` / `run_peer_as` / `run_loopd_once` / registry·broker fixtures）
- Modify: `test/peer.test.sh`、`test/integration.test.sh`、`test/loop.test.sh`、`test/approval.test.sh`、`test/start.test.sh`、`test/registry.test.sh`、`test/inject.test.sh`、`test/codex-*-e2e.test.sh`（改为 source `test/lib/...`，删内联 dupe）
- Modify: `test/run.sh`（暂不动发现逻辑，仅确认仍能跑）

**Interfaces:**
- Produces（`test/lib/harness.sh` 导出）:
  - `harness_tmp` — 设 `SCENARIO_TMP`/`PROJECT`/`AGENT_DUO_ROOT`/`OUT`/`ERR`，不装 stub
  - `harness_install_tmux_stub` — 写 tmux stub 进 `STUB_BIN`，前置 `PATH`
  - `harness_registry [rows...]` — 写 `registry.tsv`，默认 `%1 supervisor claude` + `%2 worker codex`
  - `harness_broker_ready <id>` — 写 broker ready+nonce marker
  - `teardown` — `rm -rf "$SCENARIO_TMP"`
  - `unit_setup` = `harness_tmp`
  - `cli_setup` = `harness_tmp` + `harness_install_tmux_stub` + `harness_registry`
  - `integration_setup` = `cli_setup`
  - `run_peer [args...]` / `run_peer_as <pane> [args...]` / `run_loopd_once`

- [ ] **Step 1: 建 `test/lib/assert.sh`**

```bash
mkdir -p test/lib
git mv test/assert.sh test/lib/assert.sh
```

- [ ] **Step 2: 建 `test/lib/harness.sh`**

把 `test/peer.test.sh` 现有的 `make_tmp`、tmux stub 生成块、`setup`、`teardown`、`run_peer`、`run_peer_as`（若存在）逐字搬进 `test/lib/harness.sh`，并补 `run_loopd_once`（从 `integration.test.sh` 搬其 loopd-tick 逻辑）。在文件顶部解析 `ROOT`：

```bash
# test/lib/harness.sh — tmux-stub 测试 harness 单一真相源
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HARNESS_DIR/../.." && pwd)"
source "$HARNESS_DIR/assert.sh"
# make_tmp / harness_install_tmux_stub / harness_tmp / harness_registry /
# harness_broker_ready / teardown / run_peer / run_peer_as / run_loopd_once …
# 三个按层 setup：
unit_setup()        { harness_tmp; }
cli_setup()         { harness_tmp; harness_install_tmux_stub; harness_registry; }
integration_setup() { cli_setup; }
```

> 注：把现有 `setup()` 的 tmux-stub 部分放进 `harness_install_tmux_stub`，把 PROJECT/OUT/ERR 部分放进 `harness_tmp`，把默认 registry 写入放进 `harness_registry`。`run_peer` 的 env 长清单逐字保留。

- [ ] **Step 3: 现有文件改 source harness，删内联 dupe**

每个 `test/*.test.sh` 顶部把 `source "$DIR/assert.sh"`（及内联的 `make_tmp`/`setup`/`run_peer`/tmux stub）替换为：

```bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
source "$DIR/lib/harness.sh"
```

把文件内原来的 `setup`（cli 性质的）调用改为 `cli_setup`，integration 的改 `integration_setup`，纯 lib 测（loop/registry/inject）改 `unit_setup`。删掉文件内重复定义的 `make_tmp`/tmux-stub/`run_peer`。

- [ ] **Step 4: 跑绿**

Run: `bash test/run.sh`
Expected: `ALL TESTS PASSED`。若某文件因 stub env 开关漂移失败，核对 `harness_install_tmux_stub` 是否漏搬某个 `TMUX_STUB_*` 分支。

- [ ] **Step 5: 断言守恒**

Run: `grep -rho 'assert_[a-z_]*' test/ | wc -l`
Expected: ≥ Task 0 的 N。

- [ ] **Step 6: commit**

```bash
git add -A
git commit -m "test(harness): 抽 test/lib/{assert,harness}.sh 单一真相源，删三份内联 dupe"
```

---

### Task 2: 平移非拆分文件进层目录 + run.sh 层感知

**Files:**
- Move: `loop.test.sh`/`registry.test.sh`/`inject.test.sh` → `test/unit/`；`start.test.sh` → `test/integration/`；`codex-hook-e2e.test.sh`/`codex-permreq-e2e.test.sh` → `test/e2e/codex-hook.test.sh`/`test/e2e/codex-permreq.test.sh`
- Modify: 被移动文件顶部的 `source` 路径（深度 +1：`$DIR/lib/harness.sh` → `$DIR/../lib/harness.sh`）
- Rewrite: `test/run.sh`（层感知发现 + 选层 + 顺序 + 汇总 + skip 计数 + 哨兵行）

**Interfaces:**
- Produces: `bash test/run.sh [unit|cli|integration|e2e ...]`；无参=四层全跑（unit→cli→integration→e2e）。

- [ ] **Step 1: git mv 文件**

```bash
mkdir -p test/unit test/integration test/e2e
git mv test/loop.test.sh     test/unit/loop.test.sh
git mv test/registry.test.sh test/unit/registry.test.sh
git mv test/inject.test.sh   test/unit/inject.test.sh
git mv test/start.test.sh    test/integration/start.test.sh
git mv test/codex-hook-e2e.test.sh    test/e2e/codex-hook.test.sh
git mv test/codex-permreq-e2e.test.sh test/e2e/codex-permreq.test.sh
```

- [ ] **Step 2: 修被移动文件的 source 路径**

每个被移动文件顶部改为（多了一级目录）：

```bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
source "$DIR/../lib/harness.sh"
```

- [ ] **Step 3: 重写 `test/run.sh`**

```bash
#!/usr/bin/env bash
# test/run.sh — 层感知 runner。无参=四层全跑(unit→cli→integration→e2e)；可传层名选跑。
set -u
shopt -s nullglob
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYERS=("$@"); [[ ${#LAYERS[@]} -eq 0 ]] && LAYERS=(unit cli integration e2e)
rc=0
for layer in "${LAYERS[@]}"; do
  pass=0; fail=0; skip=0
  printf '── %s ──\n' "$layer"
  for t in "$DIR/$layer"/*.test.sh; do
    out="$(bash "$t" 2>&1)"; trc=$?
    name="$(basename "$t" .test.sh)"
    if [[ "$trc" != 0 ]]; then printf '%s\n%s ✗\n' "$out" "$name"; fail=$((fail+1)); rc=1
    elif printf '%s' "$out" | grep -q '^skip '; then printf '%s ⤬skip\n' "$name"; skip=$((skip+1))
    else printf '%s ✓\n' "$name"; pass=$((pass+1)); fi
  done
  printf '  → %s: %d passed, %d skipped, %d failed\n' "$layer" "$pass" "$skip" "$fail"
done
echo "==============="
[[ "$rc" == 0 ]] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit "$rc"
```

> 注：cli/ 目录此刻还没文件（Task 3 才建），`nullglob` 让空层无害跳过。

- [ ] **Step 4: 跑绿**

Run: `bash test/run.sh`
Expected: `ALL TESTS PASSED`（unit 3 文件 + integration 2 文件 + e2e 2 文件 skip + peer.test.sh 仍在 test/ 顶层——见下注）。

> 重要：`peer.test.sh`/`approval.test.sh`/`integration.test.sh` 此刻仍在 `test/` 顶层，新 `run.sh` 只扫层目录**不会**再跑它们。为不丢覆盖，本 Task 暂时**也把这三个文件 mv 到临时归属**：`peer.test.sh`→`test/cli/peer.test.sh`、`approval.test.sh`→`test/unit/approval.test.sh`、`integration.test.sh`→`test/integration/supervisor-loop.test.sh`（先整体搬，Task 3/4/5 再拆）。同步修它们的 source 路径深度。重跑 `bash test/run.sh` 确认 `ALL TESTS PASSED`。

- [ ] **Step 5: 断言守恒 + commit**

```bash
grep -rho 'assert_[a-z_]*' test/ | wc -l   # ≥ N
git add -A
git commit -m "test(layout): 平移文件进 unit/integration/e2e + run.sh 层感知发现"
```

---

### Task 3: 拆 peer monster → `cli/peer-*.test.sh` ×12

**Files:**
- Split: `test/cli/peer.test.sh` → `test/cli/peer-{transport,steering,agent,approval,loop,task,verify,judge,gate,budget,report,aliases}.test.sh`
- Delete: `test/cli/peer.test.sh`（拆空后）

**Interfaces:**
- 每个新文件顶部统一：

```bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
source "$DIR/../lib/harness.sh"
```

- [ ] **Step 1: 建 12 个文件骨架** — 每个文件写上述头部 + 末尾留空。按 noun 归属：transport=peek/tell/wait/esc/status；steering=ask/checkpoint/reframe；agent=agent\*；approval=approval\*(CLI)；loop=loop init/show/reset；task=task\*；verify=verify\*；judge=judge\*；gate=gate\*；budget=budget\*；report=report；aliases=旧命令负向。

- [ ] **Step 2: 逐 noun 搬断言** — 从 `test/cli/peer.test.sh` 把每个 `setup … teardown` 测试块按其被测命令剪切到对应文件。一次搬一个 noun，搬完即 `bash test/run.sh cli` 跑一遍（部分文件有内容即可）。`setup` 调用统一为 `cli_setup`。

- [ ] **Step 3: 清空原文件** — `test/cli/peer.test.sh` 所有块搬完后 `git rm test/cli/peer.test.sh`。

- [ ] **Step 4: 跑绿** — Run: `bash test/run.sh` → `ALL TESTS PASSED`。

- [ ] **Step 5: 断言守恒（关键）**

Run: `grep -rho 'assert_[a-z_]*' test/cli | wc -l`
Expected: == 拆前 `peer.test.sh` 的断言数（剪切不增不减）。再 `grep -rho 'assert_[a-z_]*' test/ | wc -l` ≥ N。

- [ ] **Step 6: commit**

```bash
git add -A
git commit -m "test(cli): 拆 peer monster 为 12 个按-noun 文件(断言守恒)"
```

---

### Task 4: 拆 approval → `unit/broker` + `cli/peer-approval`

**Files:**
- Split: `test/unit/approval.test.sh` → `test/unit/broker.test.sh`（测 `lib/approval_broker.sh` 函数的块）+ 合并进 `test/cli/peer-approval.test.sh`（测 `peer approval *` CLI 的块）
- Delete: `test/unit/approval.test.sh`

**Interfaces:**
- `unit/broker.test.sh` 用 `unit_setup` + `source "$ROOT/lib/approval_broker.sh"`；CLI 块用 `cli_setup` + `run_peer approval …` 进 `cli/peer-approval.test.sh`。

- [ ] **Step 1: 分类** — 阅读 `test/unit/approval.test.sh`，把每个测试块标为「lib 函数」或「CLI」。`source lib/approval_broker.sh` 后直调函数的→broker；`run_peer approval …` 的→CLI。

- [ ] **Step 2: 建 `test/unit/broker.test.sh`** — 头部用 `unit_setup`；搬「lib 函数」块。

- [ ] **Step 3: 并 CLI 块进 `cli/peer-approval.test.sh`** — 搬「CLI」块（`cli_setup`）。

- [ ] **Step 4: 删原文件** — `git rm test/unit/approval.test.sh`。

- [ ] **Step 5: 跑绿 + 守恒**

```bash
bash test/run.sh                                  # ALL TESTS PASSED
grep -rho 'assert_[a-z_]*' test/ | wc -l          # ≥ N
```

- [ ] **Step 6: commit**

```bash
git add -A
git commit -m "test: 拆 approval 为 unit/broker + cli/peer-approval(按层)"
```

---

### Task 5: 拆 integration → supervisor-loop + 抽 journey 骨架

**Files:**
- Split: `test/integration/supervisor-loop.test.sh`（现含全部 integration 块）→ 保留分项断言；抽端到端流程到新 `test/integration/journey-supervisor-loop.test.sh`（本 Task 先建骨架，Task 6 填实）

**Interfaces:**
- `journey-supervisor-loop.test.sh` 用 `integration_setup` + `run_peer` + `run_loopd_once`。

- [ ] **Step 1: 建 journey 骨架文件**

```bash
# test/integration/journey-supervisor-loop.test.sh
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
source "$DIR/../lib/harness.sh"
# Journey 占位：Task 6 填实完整用户流程断言。
echo "journey-supervisor-loop: pending (Task 6)"
```

> 注：骨架不含断言，`run.sh` 视其为 pass（exit 0）。Task 6 会替换为真实流程。

- [ ] **Step 2: 跑绿 + commit**

```bash
bash test/run.sh   # ALL TESTS PASSED
git add -A
git commit -m "test(integration): supervisor-loop 分项保留 + journey 骨架占位"
```

---

### Task 6: 写 Journey（新覆盖）+ 反向自检

**Files:**
- Rewrite: `test/integration/journey-supervisor-loop.test.sh`（完整用户流程，CI 版）
- Create: `test/e2e/journey-codex.test.sh`（门控真 codex/真 tmux 骨架）

**Interfaces:**
- Consumes: `integration_setup`、`run_peer`、`run_peer_as`、`run_loopd_once`、`harness_registry`、`harness_broker_ready`。

- [ ] **Step 1: 写 CI journey 完整流程** — 照 README quickstart + plan-build-judge，逐步断言**用户可见输出**。骨架（按真实命令面填实参数）：

```bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
source "$DIR/../lib/harness.sh"

integration_setup
# 三人台：supervisor + reviewer + worker
harness_registry $'%1\tsupervisor\tsupervisor\tclaude' $'%2\treviewer\treviewer\tcodex' $'%3\tworker\tworker\tcodex'
harness_broker_ready worker

# 1) 冻结 loop 契约（verify 闸门 + judge 评审）
assert_ok "journey: loop init" run_peer loop init worker \
  --mission "实现 X" --max-rounds 5 --verify tests:"true" --judge reviewer:request_changes
# 2) worker 汇报一轮（带 evidence → done 不降级）
assert_ok "journey: worker report r1" run_peer_as "%3" report \
  --type result --status done --round 1 --delta "done" --evidence-result "validated"
# 3) reviewer 用 judge 给 veto
assert_ok "journey: reviewer judge veto" run_peer_as "%2" judge worker@1 \
  --round 1 --verdict request_changes --finding blocking:"需修正"
# 4) loopd tick → worker 保持 active + dashboard 用新词
run_loopd_once
assert_ok "journey: checkpoint readable" run_peer checkpoint worker
assert_contains "journey: dashboard uses verify=/judge=" "$(cat "$OUT")" 'judge='
# 5) 人类决策门 → 解决
# （按真实 gate 流程补 peer gate ls / resolve 的断言）
teardown
echo "journey-supervisor-loop: ok"
```

> 实现者须把参数对齐**当前真实命令面**（以 `bin/peer --help` 与 spec §3 为准），并把第 5 步 gate 流程补全。每加一步 `bash test/run.sh integration` 跑一次。

- [ ] **Step 2: 反向自检（证明 journey 抓得住「绿但坏」）**

临时改坏一个 noun（如把 `bin/peer` 里 `judge)` 分支名拼错），Run: `bash test/run.sh integration`
Expected: `journey-supervisor-loop` **变红**（`SOME TESTS FAILED`）。确认后 `git checkout bin/peer` **还原**，重跑确认恢复绿。

- [ ] **Step 3: 写 e2e journey 门控骨架**

```bash
# test/e2e/journey-codex.test.sh
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
source "$DIR/../lib/assert.sh"
skip() { printf 'skip %s: %s\n' "journey-codex" "$1"; exit 0; }
[[ "${AGENT_DUO_E2E_CODEX:-}" == "1" ]] || skip "set AGENT_DUO_E2E_CODEX=1 to run (real codex journey)"
command -v codex >/dev/null 2>&1 || skip "codex CLI not installed"
command -v tmux  >/dev/null 2>&1 || skip "tmux not installed"
[[ -f "$HOME/.codex/auth.json" ]] || skip "no ~/.codex/auth.json"
# 真 start.sh 起会话 + 真 peer 流程的端到端骨架（后续填实）。
echo "journey-codex: gated skeleton ok"
```

- [ ] **Step 4: 跑绿 + 守恒（journey 阶段断言只增）**

```bash
bash test/run.sh                              # ALL TESTS PASSED（e2e journey skip）
grep -rho 'assert_[a-z_]*' test/ | wc -l      # > N（新增 journey 断言）
```

- [ ] **Step 5: commit**

```bash
git add -A
git commit -m "test(journey): CI 版完整用户流程(防绿但坏) + e2e 门控骨架 + 反向自检通过"
```

---

### Task 7: 收尾 runner + 文档指针

**Files:**
- Modify: `test/run.sh`（若 Task 2 已含选层/汇总/skip 计数则仅复核；补 `--help`/未知层名提示）
- Modify: `README.md`（测试章节，若有：指向新 `test/` 布局与 `run.sh [layer]` 用法）

**Interfaces:**
- Produces: `bash test/run.sh` 与 `bash test/run.sh <layer...>` 定稿；哨兵行保留。

- [ ] **Step 1: 复核/补全 run.sh** — 确认选层、顺序、按层汇总、skip 计数、哨兵行齐全；加未知层名的友好报错：

```bash
for layer in "${LAYERS[@]}"; do
  [[ -d "$DIR/$layer" ]] || { echo "未知层: $layer（可选 unit|cli|integration|e2e）" >&2; exit 2; }
  ...
done
```

- [ ] **Step 2: README 测试章节指针**（若存在测试说明）——一句指向 `test/{unit,cli,integration,e2e}/` 与 `bash test/run.sh [layer]`；不展开。

- [ ] **Step 3: 全量跑绿**

Run: `bash test/run.sh`
Expected: `ALL TESTS PASSED`，按层计数行齐全。
Run: `bash test/run.sh unit` / `bash test/run.sh cli` — 各自只跑对应层且绿。

- [ ] **Step 4: commit**

```bash
git add -A
git commit -m "test(runner): run.sh 选层/汇总定稿 + README 测试布局指针"
```

---

## 最终验收

- [ ] `bash test/run.sh` → `ALL TESTS PASSED`，输出按层计数（unit/cli/integration/e2e）。
- [ ] `bash test/run.sh unit` / `cli` / `integration` 各自只跑对应层且绿。
- [ ] 目录布局 == spec §5（`test/lib`、`test/{unit,cli,integration,e2e}`）。
- [ ] tmux stub 只在 `test/lib/harness.sh` 出现一次：`grep -rl 'STUB/tmux\|new-window\|capture-pane' test/ | grep -v 'lib/harness.sh'` 为空（除 e2e 真 tmux）。
- [ ] `grep -rho 'assert_[a-z_]*' test/ | wc -l` > Task 0 的 N（journey 净增）。
- [ ] 反向自检已验证：改坏命令面会让 `journey-supervisor-loop` 变红（Task 6 Step 2 记录）。
