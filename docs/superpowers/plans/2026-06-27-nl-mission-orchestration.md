# NL Mission 入口与 supervisor 自动编排 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让人类只写一份自然语言 mission（或直接说），supervisor 当「运行时」自动组队、把完成条件物化成 verify/judge 闸门、跑 plan-build-judge 的 Ralph 循环、只在人类 gate 与最终合门时回来——`peer` 命令对人隐身。

**Architecture:** 纯 doc 优先（Phase 1）：三段 NL mission 模板 + 可复用角色定义 + 一张「相位状态机」编排 playbook（按需加载，注入块只放一行触发指针）。playbook 调用的全是**现有** `peer` 命令，不改 `bin/peer`/`lib/*`。Phase 2 再把「不达合门不准停」从 supervisor 自觉升级为 `supervisor-stop-drain-hook` 机械硬门。loop/verifier 永远是脊柱。

**Tech Stack:** Markdown（doc/playbook/角色/模板）、Bash（Phase 2 的 hook、journey 测试）、现有 `peer` 命令面、`jq`。

**权威 spec:** `docs/superpowers/specs/2026-06-27-nl-mission-orchestration-design.md`。任一处冲突以 spec 为准。

## Global Constraints

- **最高约束**：借 Agent Teams 入口人体工学，但全在 agent-duo 自有、工具无关底座原生实现，**不依赖原生 Agent Teams**；**loop/verifier 永远是脊柱**，任何简化不得削弱 verify/judge/stop 闸门，不得削弱跨工具桥。
- **NL-first**：人类接口是自然语言 + mission 文件；**不新增任何给人敲的命令**；`peer` 退为 supervisor 内部细节。
- **Phase 1 不改代码逻辑**：只新增/修改 markdown；playbook 引用的 `peer` 命令必须是**现有真实命令**（用 `peer <noun> --help` 核对）。
- **工具无关**：playbook/角色/触发指针是**纯 markdown**，不做成 Claude-only skill（supervisor 可能是 Codex）。
- **三条不变量**：每轮交互源自人/supervisor；不许 teammate 私下互聊；红线升级人类 gate。
- **角色定义文件**放 `docs/roles/<role>.md`（版本化），不放 `.agent-duo/`（运行时态）。
- **playbook 是 journey 测试来源**：playbook 变更与 journey 断言锁步。
- **频繁提交**：每个 Task 末尾 commit。

---

## 文件结构（目标态）

```
docs/
  mission-template.md                 # 人类要填的三段 NL 模板
  roles/{planner,builder,reviewer,evaluator}.md   # 可复用角色定义(#6)
  SUPERVISOR-LOOP-PLAYBOOK.md         # 相位状态机编排 playbook（按需加载）
  AGENT-INSTRUCTIONS.md               # 注入块加一行触发指针
scripts/
  supervisor-stop-drain-hook          # Phase 2：接合门集读取 + 三分支
test/
  …journey…                           # journey 驱动 playbook 命令序列（对齐测试架构 spec）
```

**实现顺序**：Phase 1 = Task 1–5（纯 doc，先出体验）；Phase 2 = Task 6–7（hook 硬门）。

---

### Task 1: 可复用角色定义（#6）

**Files:**
- Create: `docs/roles/planner.md`、`docs/roles/builder.md`、`docs/roles/reviewer.md`、`docs/roles/evaluator.md`

**Interfaces:**
- Produces: 四个角色定义文件，每个含三节固定结构：`## 职责`、`## 默认 verify/judge 取向`、`## 派发 prompt 模板`。playbook（Task 3）按 `docs/roles/<role>.md` 引用并实例化。

- [ ] **Step 1: 写 `docs/roles/builder.md`**（其余三个同构）

```markdown
# Role: builder

## 职责
实现产品、写测试、写结构化 report。不做代码审查、不自评完成。建议隔离 worktree。

## 默认 verify/judge 取向
- verify：优先机械硬闸门（仓库测试命令 / smoke test）。无栈时用零依赖 HTML/CSS/JS + 一个 `test/run.sh`。
- 受 judge 约束：reviewer veto=request_changes,reject；evaluator veto=fail,request_changes。
- 默认 `--max-rounds 6 --detail-trap-rounds 3`。

## 派发 prompt 模板
"请实现 <MISSION_GOAL>。约束：先读 docs/product/brief.md 与 acceptance.md；首屏即可用工具不做 landing page；
数据本地持久化；补 smoke test；每完成一个 task step 写 peer report --step；最终 done 必带
--evidence-cmd/--evidence-result。不做：<NON_GOALS>。"
```

> `planner.md`：职责=写 brief+acceptance 契约、不写代码；verify=契约文件存在；模板=「只 plan 不写码，输出 brief/acceptance」。`reviewer.md`：职责=代码+产品契约审查、不改码、写 `peer judge`；模板=「按 acceptance 审查，verdict 绑定 builder@N，blocking finding 给复现路径」。`evaluator.md`：职责=像用户一样试用、不改码、写 `peer judge` 带 evidence；模板=「按 Evaluator Script 操作，verdict 带 evidence」。`<MISSION_GOAL>`/`<NON_GOALS>` 是 supervisor 实例化时替换的占位。

- [ ] **Step 2: 一致性检查** — 四文件都含三节标题：

Run: `for r in planner builder reviewer evaluator; do grep -q '## 职责' docs/roles/$r.md && grep -q '## 派发 prompt 模板' docs/roles/$r.md && echo "$r ok" || echo "$r MISSING"; done`
Expected: 四行均 `ok`。

- [ ] **Step 3: commit**

```bash
git add docs/roles/
git commit -m "docs(roles): 可复用角色定义 planner/builder/reviewer/evaluator(#6)"
```

---

### Task 2: mission 文件 NL 模板

**Files:**
- Create: `docs/mission-template.md`

**Interfaces:**
- Produces: 人类要填的三段模板；playbook 的 PARSE 相位按这三节标题解析。

- [ ] **Step 1: 写 `docs/mission-template.md`**

```markdown
# Mission: <一句话目标>

## 要做什么 (Goal)          ← 必填
<2–4 句自然语言：是什么、给谁、核心场景>

## 完成条件 (Done means)    ← 必填，这是 loop 的停止条件
- <可机械验证>：如「smoke 测试通过」「npm run build 无错」
- <主观质量>：如「首屏即可用工具、不是 landing page」「移动端可用」
- <独立验收>：如「reviewer、evaluator 都不 veto」

## 不做 / 红线 (Non-goals & guardrails)   ← 推荐
- 不做：<范围外>
- 红线（必须升级人类 gate）：部署、花钱、碰生产、删数据
```

末尾加一段说明：「也可不写文件，直接对 supervisor 说这三段。若完成条件无任何可机械验证项，supervisor 会主动提议补一个 smoke test，或明确告警 slop 风险——绝不默默跑没有硬闸门的循环。」

- [ ] **Step 2: 检查三节标题齐全**

Run: `grep -c -E '^## (要做什么|完成条件|不做)' docs/mission-template.md`
Expected: `3`

- [ ] **Step 3: commit**

```bash
git add docs/mission-template.md
git commit -m "docs: NL mission 三段模板"
```

---

### Task 3: supervisor 编排 playbook（相位状态机）

**Files:**
- Create: `docs/SUPERVISOR-LOOP-PLAYBOOK.md`

**Interfaces:**
- Consumes: `docs/roles/*.md`（Task 1）、`docs/mission-template.md`（Task 2）。
- Produces: 相位 0–8 的确定性 checklist，每相位点名现有 `peer` 命令；DONE 相位定义【合门集】。

- [ ] **Step 1: 写 playbook 主体（相位 0–8）**

按 spec §4.2 写，每相位列出**现有** peer 命令。合门集逐字写死：

```markdown
# Supervisor Loop Playbook

当用户给你一份 mission（见 docs/mission-template.md）或要你把一个目标「跑成 loop」时，严格按下列相位执行。
全程 peer 命令对用户隐身；只在【人类 gate】与【最终合门】回来找人。

## 合门集（唯一停止条件）
verify 全 pass  ∧  无未决 judge veto  ∧  builder done report 带 evidence  ∧  轮次未超 max-rounds
任一不满足 → 不算完成。

## 相位
0. PARSE     读 mission → goal / done-criteria / 红线
1. PROPOSE   按 docs/roles/*.md 实例化编队，把 done-criteria 物化成 verify/judge，回显一屏等用户确认
2. PROVISION peer agent add ×N  →  peer approval check <id>（每个工作型 agent）
3. PLAN      peer task init planner … / peer loop init planner --verify <契约存在> → peer ask planner …
             → peer verify show planner
4. BUILD     peer task init builder … / peer loop init builder --verify <硬闸门> --judge reviewer:request_changes,reject --judge evaluator:fail,request_changes
             → peer ask builder …（done 必带 evidence）
5. JUDGE     builder done → peer ask reviewer / evaluator（独立 judge builder@N）→ 各自 peer judge builder@N --verdict …
6. LOOP      每轮检查【合门集】；未达 → peer reframe builder（只修阻塞项）[+ peer loop reset --max-rounds N] → 回 4
             detail-trap/stuck → reframe 收敛不扩范围
7. GATE      命中红线 或 需人类判断 → peer gate open … → 找人
8. DONE      仅当【合门集】全真 → 带证据汇报（verify/judge/final report 路径）；否则绝不宣布完成

## 纪律
- 合门集是唯一停止条件；builder 不能自评 done 就停。
- 制造者≠检查者：reviewer/evaluator 独立 judge。
- 红线只开 gate、不自作主张。
- 用户可随时用自然语言插话改向；不许 teammate 私下互聊。
```

- [ ] **Step 2: 命令真实性检查（关键）** — playbook 引用的每个 peer 子命令都必须存在：

Run: `for c in "agent add" "approval check" "task init" "loop init" "ask" "verify show" "judge" "reframe" "loop reset" "gate open" "checkpoint"; do bin/peer ${c% *} --help >/dev/null 2>&1 && echo "$c ok" || echo "$c MISSING"; done`
Expected: 全 `ok`。任何 `MISSING` 说明 playbook 引用了不存在的命令，回改 playbook 对齐真实命令面（`peer <noun> --help`）。

- [ ] **Step 3: commit**

```bash
git add docs/SUPERVISOR-LOOP-PLAYBOOK.md
git commit -m "docs(playbook): supervisor 相位状态机编排 playbook(0-8 + 合门集)"
```

---

### Task 4: 注入块触发指针

**Files:**
- Modify: `docs/AGENT-INSTRUCTIONS.md`（在 `<!-- agent-duo:start -->` … `<!-- agent-duo:end -->` 块内加一行）

**Interfaces:**
- Produces: supervisor 看到的注入指令里出现一行触发指针，指向 playbook。marker 机制不变。

- [ ] **Step 1: 在注入块加触发指针**

在 `docs/AGENT-INSTRUCTIONS.md` 的使用规则末尾加一条：

```markdown
6. **跑 loop / 接 mission**：当用户给你一份 mission（见 `docs/mission-template.md`）或要你把一个目标
   「跑成 loop」时，先读 `docs/SUPERVISOR-LOOP-PLAYBOOK.md` 并严格按它执行；peer 命令对用户隐身，
   只在人类 gate 与最终合门时回来找人。
```

- [ ] **Step 2: 检查指针在 marker 块内** — 确认新行位于 start/end 之间：

Run: `awk '/agent-duo:start/{f=1} f&&/SUPERVISOR-LOOP-PLAYBOOK/{hit=1} /agent-duo:end/{f=0} END{print (hit?"ok":"MISSING")}' docs/AGENT-INSTRUCTIONS.md`
Expected: `ok`

- [ ] **Step 3: commit**

```bash
git add docs/AGENT-INSTRUCTIONS.md
git commit -m "docs(inject): 注入块加 playbook 触发指针(NL→跑 loop)"
```

---

### Task 5: journey 测试驱动 playbook 命令序列

**Files:**
- Create/Modify: `test/integration/journey-supervisor-loop.test.sh`（若测试架构迁移已落地用该路径；否则放 `test/integration.test.sh` 并标注）

**Interfaces:**
- Consumes: harness `integration_setup`/`run_peer`/`run_peer_as`/`run_loopd_once`（测试架构 spec）；若 harness 未就绪，用现有 `test/integration.test.sh` 的 setup。
- Produces: 一个端到端 journey，照 playbook 相位 2–8 的命令序列断言用户可见输出。

- [ ] **Step 1: 写 journey（照 playbook 相位，断言用户可见输出）**

```bash
# 三人台：supervisor + reviewer + worker(builder)；逐相位走 playbook
integration_setup 2>/dev/null || setup
harness_registry $'%1\tsupervisor\tsupervisor\tclaude' $'%2\treviewer\treviewer\tcodex' $'%3\tbuilder\tbuilder\tcodex' 2>/dev/null || true
harness_broker_ready builder 2>/dev/null || true

# 相位 4：loop init builder（verify 硬闸门 + judge 契约）
assert_ok "journey: loop init builder" run_peer loop init builder \
  --mission "实现 X" --max-rounds 5 --verify smoke:"true" --judge reviewer:request_changes
# builder 带 evidence 报 done
assert_ok "journey: builder done w/ evidence" run_peer_as "%3" report \
  --type result --status done --round 1 --delta "done" --evidence-result "smoke pass"
# 相位 5：reviewer 用 judge 给 veto
assert_ok "journey: reviewer judge veto" run_peer_as "%2" judge builder@1 \
  --round 1 --verdict request_changes --finding blocking:"修这个"
# 相位 6：loopd tick → builder 保持 active、dashboard 用新词
run_loopd_once 2>/dev/null || true
assert_ok "journey: checkpoint readable" run_peer checkpoint builder
assert_contains "journey: dashboard shows judge gate" "$(cat "$OUT")" 'judge='
teardown 2>/dev/null || true
echo "journey-supervisor-loop: ok"
```

> 实现者把参数对齐**当前真实命令面**（`bin/peer --help`），并按需补相位 7（gate）断言。

- [ ] **Step 2: 跑绿**

Run: `bash test/run.sh integration 2>/dev/null || bash test/integration.test.sh`
Expected: 末行 `ALL TESTS PASSED`（或该文件无 FAIL）。

- [ ] **Step 3: 反向自检** — 临时把 playbook 里 BUILD 相位的 judge 契约删掉一行，确认 journey 仍能跑但合门语义变化被你察觉（或改坏一个被断言的命令名让 journey 红），验证后还原。

- [ ] **Step 4: commit**

```bash
git add test/
git commit -m "test(journey): 照 playbook 相位驱动端到端 + 反向自检"
```

---

### Task 6: Phase 2 — stop-hook 接合门集（机械硬门）

**Files:**
- Modify: `scripts/supervisor-stop-drain-hook`（加「读合门集 → 放行/拦截/升级」三分支）

**Interfaces:**
- Consumes: 磁盘 loop runtime 状态——`.agent-duo/state/<id>/loop.json`（max-rounds/veto_on）、`validation-rN.json`（verify）、`reviews/*.json`（judge verdict）、`report.json`（round/status/evidence）。复用 `lib/loop.sh` 既有读取函数（如 `ad_loop_report_round`、acceptance 判定），**不重写判定逻辑**。
- Produces: hook 在 stop 时计算合门集，未达且预算未尽→非 0 退出 + 注入「继续修」定向指令；预算耗尽未达→开人类 gate；全真→放行。

- [ ] **Step 1: 写失败测试**

```bash
# 未合门(verify fail)时 hook 拦截；预算耗尽时升级 gate；全真放行
setup 2>/dev/null || true
# 造一个 verify fail 的 builder round（参照 loop.test.sh 造 validation-rN.json status=fail）
# … 构造 state …
assert_not_ok "stop-hook: 未合门则拦截(非0)" run_stop_hook builder
assert_contains "stop-hook: 注入继续指令" "$(cat "$OUT")" '继续'
teardown 2>/dev/null || true
```

> `run_stop_hook` 是 harness 里对 `scripts/supervisor-stop-drain-hook` 的封装（若无则本 Task 顺带加）。

- [ ] **Step 2: 跑红** → FAIL（hook 尚无合门集逻辑）。

- [ ] **Step 3: 实现三分支** — 在 `scripts/supervisor-stop-drain-hook` 调用 `lib/loop.sh` 算合门集：

```bash
# 伪结构：
gate_state="$(ad_loop_acceptance_state "$root" "$agent")"   # 复用既有判定
if [[ "$gate_state" == satisfied ]]; then exit 0            # 放行
elif budget_remaining "$root" "$agent"; then
  echo "合门未达（$gate_state）：继续修复，勿停。" >&2; exit 2   # 拦截
else
  peer gate open "$agent" --title "预算耗尽未合门，请人类决策"; exit 0   # 升级
fi
```

- [ ] **Step 4: 跑绿** — Run: `bash test/run.sh` → `ALL TESTS PASSED`。

- [ ] **Step 5: commit**

```bash
git add scripts/supervisor-stop-drain-hook test/
git commit -m "feat(hook): stop-drain 接合门集三分支(放行/拦截/预算升级)——Ralph 机械硬门"
```

---

### Task 7: Phase 2 — 防跑飞与降级验证

**Files:**
- Test: 同 Task 6 测试文件补用例

**Interfaces:** 固化「两条出口纪律」：成功放行 + 预算耗尽升级人类（不无限拦截）。

- [ ] **Step 1: 写防跑飞测试**

```bash
setup 2>/dev/null || true
# 预算耗尽(round >= max-rounds)且未合门 → hook 退 0 且开了 gate，而非继续拦截
assert_ok "stop-hook: 预算耗尽不再拦截" run_stop_hook builder_exhausted
assert_contains "stop-hook: 预算耗尽开 gate" "$(cat "$OUT")" 'gate'
teardown 2>/dev/null || true
```

- [ ] **Step 2: 跑绿 + commit**

```bash
bash test/run.sh
git add test/
git commit -m "test(hook): 防跑飞——预算耗尽升级人类而非无限拦截"
```

---

## 最终验收

- [ ] `docs/mission-template.md` 三节齐全；`docs/roles/{planner,builder,reviewer,evaluator}.md` 各含三节。
- [ ] `docs/SUPERVISOR-LOOP-PLAYBOOK.md` 相位 0–8 + 合门集齐全；引用的 peer 命令全部 `--help` 通过（Task 3 Step 2）。
- [ ] `docs/AGENT-INSTRUCTIONS.md` 注入块含 playbook 触发指针（在 marker 内）。
- [ ] journey 测试绿，且能反向自检（改坏命令面会红）。
- [ ] Phase 2：`bash test/run.sh` 全绿；stop-hook 三分支（放行/拦截/预算升级）各有测试。
- [ ] 未新增任何「给人敲」的命令；Phase 1 未改 `bin/peer`/`lib/*` 逻辑。
