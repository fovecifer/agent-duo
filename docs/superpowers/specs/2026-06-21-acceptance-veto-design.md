# Acceptance Veto（reviewer/evaluator 验收门）设计

日期：2026-06-21
状态：设计稿，待实现（交付 Codex 实现，作者 review）
关联：[worker↔supervisor 契约](./2026-06-17-worker-supervisor-contract.md)（§2.1 reviewer 字段 / §2.5 acceptance / §4 awaiting_acceptance）、[Supervisor Loop（MVP 5）设计](./2026-06-21-supervisor-loop-mvp5-design.md)、[Loop Validation 设计](./2026-06-21-loop-validation-success-signals-mvp-design.md)

## 1. 架构 + acceptance 配置

### 1.1 核心：done 的第二道异步门

MVP 5 的 done 门已是"worker 自报 done + 机械 validation 通过"。acceptance veto 再加一道：**done 还需所有必需 review 给出非-veto verdict**。两道门都异步：

```
worker 报 done
   │
   ├─ validation(机械,runtime 跑)     ── pass ─┐
   │                                              ├─ 都满足 → stop(done)
   └─ acceptance(judgment,reviewer 给)── 非veto ─┘
          ▲                                  缺/veto → 不停、loop 留活
          │  supervisor(活 LLM)派 reviewer/evaluator 去审 worker@rN
          │  reviewer: peer report --verdict … --target-ref worker@rN
   runtime 发 review_required 事件 nudge supervisor(它不自己派)
```

延续混合模型：**runtime 门控 + 发信号，supervisor 编排派 reviewer**。这把契约 §4 的"worker 只能声称完成，supervisor 才能确认完成"机械化到位——确认 = validation + review 双绿。

### 1.2 loop.json `acceptance` 配置

```jsonc
{
  // …MVP 5/8 既有字段…
  "acceptance": {
    "reviews": [
      { "role": "reviewer",  "veto_on": ["request_changes", "reject"] },
      { "role": "evaluator", "veto_on": ["fail"] }
    ]
  }
}
```

- **通用 `reviews[]`**：每条 = `role` + `veto_on`（verdict 黑名单）。reviewer / evaluator 都是普通条目，无特判。
- 空 / 无 `acceptance.reviews` → 不挂 review 门（只走 validation，即现状），向后兼容。

### 1.3 `peer loop init` flag

```
peer loop init <id> … --review <role>:<veto1,veto2> [--review <role>:<veto>]…
# 例: --review reviewer:request_changes,reject --review evaluator:fail
```

- `--review` 可重复；格式 `role:veto-list`（逗号分隔 verdict）。
- 解析：role 非空、veto-list 非空且 token 合法（`[A-Za-z0-9_-]+`），否则 fail-closed。
- `peer loop reset` 不动 acceptance（同 mission/validation，只动预算/停止态）。

## 2. report verdict 字段 + verdict 路由

### 2.1 `peer report` 新增 verdict 字段（reviewer/evaluator 用）

```
peer report --type result --status <s> \
    --verdict <v> --target-ref <worker>@<round> [--finding <severity>:<note>]…
```

- **`--verdict <v>`**：非空 token（`[A-Za-z0-9_-]+`）。词表自由（approve/request_changes/reject/pass/fail/自定义）——veto 是拿它和 `acceptance.veto_on` 比对，任何 token 都行。
- **`--target-ref <worker>@<round>`**：解析出 `target_worker` + `target_round`（`@` 分割；round 容忍 `r` 前缀；round 必须正整数）。
- **`--finding <severity>:<note>`**：可重复 → `findings[]` 的 `{severity, note}`；无冒号则 `severity="note"`。可选载荷。空数组守 `set -u`。
- **耦合校验（fail-closed）**：`--verdict` 与 `--target-ref` 必须同时出现；`--finding` 需有 `--verdict`；`--verdict` 仅在 `--type result` 上合法。缺一即报错。

### 2.2 reviewer 自己的 report 也带这些字段

`write_report_json` 增写 `verdict`/`target_ref`/`findings`（契约 §2.1 的 reviewer 额外字段），非 review 时为 `null`/`[]`——reviewer 的 `state/<reviewer>/rN.json` 自带判决全貌。

### 2.3 verdict 路由：写到目标的 `reviews/` 记录

当 `peer report` 带 `--verdict` + `--target-ref`，**额外**写一条判决记录到**目标 worker** 下：

```
.agent-duo/state/<target_worker>/reviews/<reviewer-role>-r<target_round>.json =
  { "verdict": "request_changes", "by": "<reviewer-id>", "role": "<reviewer @agent_role>",
    "target": "<worker>", "target_round": N, "findings": [...], "ts": "…" }
```

- `role` = reviewer 自己的 `@agent_role`（`self_role`）——这是 done 门按 `acceptance.reviews[].role` 匹配的 key。
- 原子 `tmp+mv`；`mkdir -p reviews/`。
- 写入时机：**event append 成功之后**（同 gate `opened` 的顺序）——report 回滚则不留孤儿判决；判决写失败仅意味着该 review 暂"缺"，done 门照常 hold、supervisor/reviewer 重报即补上。

### 2.4 与 reviewer 自身的关系

reviewer 跑 `peer report --verdict …` 写的是 **reviewer 自己的 report**（它自己的轮次/事件）**外加**目标的判决记录；reviewer 自身不一定有 loop.json，不被 acceptance 门约束。判决记录是唯一的跨 agent 路由载体。

## 3. done 合门 + review_required

### 3.1 acceptance 判定：`ad_loop_acceptance_state <root> <worker> <round> <contract>`

```
reviews = contract.acceptance.reviews[]
reviews 空 → satisfied(无 review 门)
for each {role, veto_on}:
    rec = .agent-duo/state/<worker>/reviews/<role>-r<round>.json
    rec 不存在/不可读     → 该 role MISSING
    rec.verdict ∈ veto_on → 该 role VETOED
    否则                  → 该 role OK
全 OK → satisfied;否则 blocked(记下 missing[] / vetoed[])
```

### 3.2 done 合门（`eval_contracts`，validation 之后）

```
if report_status==done:
    vok = (validation_count==0) 或 (vstate==pass)        # MVP5 validation 门
    aok = ad_loop_acceptance_state(...) == satisfied      # 本设计 acceptance 门
    if vok 且 aok                 → reason=done            # 双绿才停
    elif vok 且 非 aok            → 发 review_required(幂等);不停        # 验收过、待评审
    else                         → (validation running/fail) 不停
elif report_status==failed → reason=failed
elif rounds_used>=max_rounds → reason=max_rounds
```

- **done 需 validation + acceptance 双绿**。任一未满足 → loop 留活、worker 按 `awaiting_acceptance` 泊住。
- **先 validation 后 review 的时序**：`review_required` 只在 `vok`（验收命令已过/未配）时发——不为一个测试还红的 worker 催评审。validation 还在 running → 先等 validation，这一 tick 不发 review_required。
- **done 优先于 max_rounds**：done+待评审时不会被 max_rounds 抢停（worker 泊住未推进轮次）。

### 3.3 `review_required` 事件

```jsonc
{ "id":"reviewreq-<worker>-<round>", "type":"review_required", "agent":"<worker>", "round":N,
  "summary":"review required: reviewer pending; evaluator vetoed(fail)",   // 区分 missing vs vetoed
  "ref":".agent-duo/state/<worker>/r<N>.json" }
```

- 确定性 id `reviewreq-<worker>-<round>` → 每轮最多一条，`ad_loop_event_id_seen` 去重。
- 优先级 **11**（高；blocked=10 与 validation_fail=15 之间）。
- **summary 区分 MISSING 与 VETOED**：supervisor 据此决策——`pending`（没人审）→ 去派 reviewer；`vetoed(request_changes)` → 让 worker 改、改完报新一轮（新 round 触发对该轮的新评审）。
- worker 改完报 round N+1 → done 门按 N+1 重判（需 N+1 的新判决）→ 旧 N 的 vetoed 自然被新轮取代。

### 3.4 边界 + 看板

- **无 review 超时（本刀）**：review 是 agent 判断、无 `timeout_seconds`。supervisor/人若一直不派 reviewer，worker 泊住等待（不烧 token，廉价）——水线下人在环路的责任，`review_required` 已 nudge。review 超时升级列为后续（YAGNI）。
- 看板每个 worker 行追加 acceptance 摘要（有 `acceptance.reviews` 时）：`accept=reviewer:ok,evaluator:pending`。

## 4. 错误处理 + 测试 + 影响面

### 4.1 错误处理（新增/跨切面）

- **`peer report` 耦合校验（fail-closed）**：`--verdict`⇔`--target-ref` 必须成对；`--finding` 需 `--verdict`；`--verdict` 仅 `--type result`；`--target-ref` 不含 `@`/round 非正整数 → 全部报错退出。
- **`peer loop init --review` 格式非法**（缺 role / 空 veto-list / 坏 token）→ fail-closed。
- **判决记录写失败**（event 之后）→ 该 role 暂"缺"，done 门 hold，reviewer 重报即补，不崩。
- **loop.json `acceptance` 手改坏**：单条 review 缺 `role`/`veto_on` → 跳过该条 + 告警（`peer loop init` 已在写入时校验，坏值仅来自手改，罕见）；全坏 → 无 review 门。
- **`reviews/<role>-r<N>.json` 不可读/坏** → 当 **MISSING**（done 门侧 fail-closed：不拿坏判决放行 done）。

### 4.2 测试矩阵（`peer.test.sh` / `loop.test.sh`；tmux stub）

**report verdict（peer.test.sh）**

- `--verdict approve --target-ref worker@5` → reviewer report 带 `verdict/target_ref`；`state/worker/reviews/<role>-r5.json` 写入 `verdict/by/role`。
- `--finding blocking:"401/403 反了"` → `findings[]` 含 `{severity,note}`。
- 耦合错误：`--verdict` 缺 `--target-ref` / 反之 / `--finding` 无 `--verdict` / `--verdict` 配 `--type checkpoint` → 各报错。
- `--target-ref` 无 `@` / round 非整数 → 报错。

**loop init --review（peer.test.sh）**

- `--review reviewer:request_changes,reject` → `acceptance.reviews` 写入；坏格式 → fail-closed。

**acceptance 门（loop.test.sh，`loopd --once`）**

- done + validation pass + reviewer 非-veto 判决在 → **stop(done)**。
- done + validation pass + reviewer **MISSING** → 不停 + `review_required`（summary `pending`）。
- done + validation pass + reviewer **VETOED**(request_changes) → 不停 + `review_required`（summary `vetoed`）。
- done + validation **running** → **不发** `review_required`（先等 validation）。
- 无 `acceptance` → done 仅凭 validation 停（**回归**）。
- 幂等：`review_required` 每轮一条。
- reviewer+evaluator 都必需、一过一缺 → blocked。
- 看板含 `accept=…`。

### 4.3 实现影响面

- `bin/peer`：`report` 加 `--verdict/--target-ref/--finding`（耦合校验、`write_report_json` 增字段、判决记录路由到目标 `reviews/`）；`loop init` 加 `--review`（写 `acceptance.reviews`）。
- `lib/loop.sh`：新增 `ad_loop_acceptance_state`；`eval_contracts` done 门合 validation+acceptance；`ad_loop_event_priority` 加 `review_required) 11`；看板 `accept=` 行。
- 文档：README（en/zh）、AGENT-INSTRUCTIONS/AGENTS、契约 §2.5（CLI 现已实现 acceptance）。
- **不动**：validation runner、direction、loop_stop、broker、worktree。

### 4.4 非目标（YAGNI）

- 不做 review 超时升级（worker 泊住等人派 reviewer）。
- 不做 findings-severity 级 veto（veto 按 verdict；findings 仅载荷）。
- 不做 policy 组合（`acceptance.reviews[]` 全过即唯一策略，无 `no_blocking_findings` vs `all_approve` 之分）。
- 不做同 role 多 reviewer 仲裁（一 role 一判决记录，后者覆盖）。
