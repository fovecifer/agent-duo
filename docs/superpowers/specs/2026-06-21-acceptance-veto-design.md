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
- 解析：role 必须过 `is_role_token`（§2.1，与 acceptance 匹配的 role 同一字符集，含点号）；veto-list 非空、每个 verdict 是 token（`[A-Za-z0-9_-]+`），否则 fail-closed。（评审 R2-②：role 用 `is_role_token`，不再写成不含点号的旧正则——否则 `reviewer.v2` 这类真实 role 配不上。）
- `peer loop reset` 不动 acceptance（同 mission/validation，只动预算/停止态）。

## 2. report verdict 字段 + verdict 路由

### 2.1 `peer report` 新增 verdict 字段（reviewer/evaluator 用）

```
peer report --type result --status <s> \
    --verdict <v> --target-ref <worker>@<round> [--finding <severity>:<note>]…
```

- **`--verdict <v>`**：非空 token（`[A-Za-z0-9_-]+`）。词表自由（approve/request_changes/reject/pass/fail/自定义）——veto 是拿它和 `acceptance.veto_on` 比对，任何 token 都行。
- **`--target-ref <worker>@<round>`**：解析出 `target_worker` + `target_round`（`@` 分割；round 容忍 `r` 前缀；round 必须正整数）。`target_worker` 必须过 `is_role_token`/id token（见下）。
- **`--finding <severity>:<note>`**：可重复 → `findings[]` 的 `{severity, note}`；无冒号则 `severity="note"`。可选载荷。空数组守 `set -u`。
- **耦合校验（fail-closed）**：`--verdict` 与 `--target-ref` 必须同时出现；`--finding` 需有 `--verdict`；`--verdict` 仅在 `--type result` 上合法。缺一即报错。
- **role/id token 安全（评审 R1-② / R3-①）**：判决记录路径含 `<reviewer-role>` 与 `<target_worker>`，二者都必须是**路径段安全**的 token——新增共享 `is_role_token` = `^[A-Za-z0-9][A-Za-z0-9._-]*$`（**首字符必须字母/数字**，从而拒绝 `.`、`..`、`.foo` 等；普通 role/id 如 `worker`/`reviewer.v2`/`worker-2` 不受影响）。注意 `^[A-Za-z0-9._-]+$` 会放行 `.`/`..`，作为 `<target_worker>` 写进 `state/<target_worker>/reviews/…` 时 `..` 会逃出 state 目录、`.` 会别名到 state 本身——故必须用首字符受限的版本。`peer report --verdict` 对 `self_role`（reviewer 自己的 `@agent_role`）与 `target_worker` **fail-closed** 校验——含 `/`/空白等 → 报错退出（否则判决会写到意外路径，done 门永远 pending）。**根因收紧**：`peer add --role`、`peer add --id`、`start --with` 的 role/id 同步要求 `is_role_token`（现 role 仅校验非空、`--id` 仅查重复，评审 R2-①），从入口杜绝坏 role/id——否则 `--id a/b` 之类会让后续 `--target-ref a/b@1` 路径异常、done 门永远 pending。`is_role_token` 同时充当 agent id 的 token 校验（同字符集）。

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
- 写入时机：**event append 成功之后**（同 gate `opened` 的顺序）——report 回滚则不留孤儿判决。
- **写失败必须可见（评审 R1-③）**：判决路由写失败时,`peer report` **不得静默成功**——必须 stderr 明示 + **非零退出**:`"判决已记入本 agent report,但路由到 <target>/reviews/<role>-r<N>.json 失败;请重跑同一条 peer report --verdict … 重试。"` 否则 reviewer 以为已提交、worker 永远卡 pending。重跑：**保留同一 `--target-ref`**（判决记录按 `target_round` 为 key，重写即覆盖）；若原命令**显式带了 reviewer 自己的 `--round`**，重试需**换新 round 或省略 `--round`** 让其自增——否则会撞 reviewer 自身的 `report round 已存在`（评审 R4-②）。

### 2.4 与 reviewer 自身的关系

reviewer 跑 `peer report --verdict …` 写的是 **reviewer 自己的 report**（它自己的轮次/事件）**外加**目标的判决记录；reviewer 自身不一定有 loop.json，不被 acceptance 门约束。判决记录是唯一的跨 agent 路由载体。

## 3. done 合门 + review_required

### 3.1 acceptance 判定：`ad_loop_acceptance_state <root> <worker> <round> <contract>`

```
acceptance 缺 / 无 acceptance.reviews 键 → satisfied(无 review 门,向后兼容)
acceptance.reviews 非数组,或任一条: role 非 token / veto_on 非"非空数组"/ veto_on 任一元素非 verdict token(`[A-Za-z0-9_-]+`)
    → blocked(config_invalid)        # fail-closed:坏 contract 不放行 done(评审 R4-① / R5-①)
acceptance.reviews == []           → satisfied(显式无 review)
for each {role, veto_on}:
    rec = .agent-duo/state/<worker>/reviews/<role>-r<round>.json
    rec 不存在/不可读     → 该 role MISSING
    rec.verdict ∈ veto_on → 该 role VETOED
    否则                  → 该 role OK
全 OK → satisfied;否则 blocked(记下 missing[] / vetoed[])
```

> **安全语义（R4-①）**：acceptance 是验收**安全门**——`acceptance.reviews` 存在但配置坏（手改 / 非数组 / 条目缺字段）时，最保守的行为是**不放行 done**（`config_invalid`），否则一个坏 contract 会让 worker 绕过 reviewer/evaluator。`peer loop init` 写入仍 fail-closed（坏 `--review` 直接拒），所以坏配置只来自手改，但门侧也必须兜住。

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

**按 phase 拆 id（评审 R1-①）**——同一轮 `pending` 与 `vetoed` 是不同 id，避免"先 pending、后 reviewer 给 request_changes"的状态变化被去重吞掉：

```jsonc
// 有 role MISSING 时(每轮每 phase 一条):
{ "id":"reviewreq-<worker>-<round>-pending", "type":"review_required", "agent":"<worker>", "round":N,
  "summary":"review pending: reviewer, evaluator", "ref":".agent-duo/state/<worker>/r<N>.json" }
// 有 role VETOED 时:
{ "id":"reviewreq-<worker>-<round>-vetoed",  "type":"review_required", "agent":"<worker>", "round":N,
  "summary":"review vetoed: reviewer(request_changes)", "ref":".agent-duo/state/<worker>/r<N>.json" }
```

- 每 tick(done∧vok∧!aok)：若 acceptance `config_invalid`（R4-①）→ 发 `…-configinvalid`（summary `acceptance config invalid`）；否则算 `(missing[], vetoed[])`，`missing` 非空且 `…-pending` 未见 → 发 pending，`vetoed` 非空且 `…-vetoed` 未见 → 发 vetoed。**各 phase 每轮一条**，`ad_loop_event_id_seen` 去重。
- 这样 `pending → vetoed` 的转变会**新发一条 vetoed**(不同 id)，supervisor 拿得到：`pending`(没人审)→ 去派 reviewer；`vetoed(request_changes)` → 让 worker 改。
- 优先级 **11**（高；blocked=10 与 validation_fail=15 之间）。
- worker 改完报 round N+1 → done 门按 N+1 重判（需 N+1 的新判决）→ 旧 N 的 vetoed/pending 自然被新轮取代。

### 3.4 边界 + 看板

- **无 review 超时（本刀）**：review 是 agent 判断、无 `timeout_seconds`。supervisor/人若一直不派 reviewer，worker 泊住等待（不烧 token，廉价）——水线下人在环路的责任，`review_required` 已 nudge。review 超时升级列为后续（YAGNI）。
- 看板每个 worker 行追加 acceptance 摘要（有 `acceptance.reviews` 时）：`accept=reviewer:ok,evaluator:pending`；配置坏时 `accept=config_invalid`（R4-①）。

## 4. 错误处理 + 测试 + 影响面

### 4.1 错误处理（新增/跨切面）

- **`peer report` 耦合校验（fail-closed）**：`--verdict`⇔`--target-ref` 必须成对；`--finding` 需 `--verdict`；`--verdict` 仅 `--type result`；`--target-ref` 不含 `@`/round 非正整数 → 全部报错退出。
- **role/id token（评审 R1-②/R3-①/R3-②，fail-closed）**：`self_role` 或 `target_worker` 非 `is_role_token`（路径段安全、拒 `.`/`..`）→ `peer report --verdict` 报错退出；`peer add --role`、**`peer add --id`**、`start --with` 的 role/id 同样要求 token。
- **判决路由写失败（评审 R1-③）**：stderr 明示 + 非零退出（**不静默成功**）；reviewer 重跑覆盖。
- **`peer loop init --review` 格式非法**（缺 role / 空 veto-list / 坏 token）→ fail-closed。
- **loop.json `acceptance` 手改坏（评审 R4-①，fail-closed）**：`acceptance.reviews` 存在但坏（非数组 / 条目缺 `role`/`veto_on`）→ `ad_loop_acceptance_state` 返回 `blocked(config_invalid)`，**done 不放行**（坏 contract 不得绕过 review）；发 `review_required` 的 `…-configinvalid` phase、看板 `accept=config_invalid`。`peer loop init` 写入仍 fail-closed。
- **`reviews/<role>-r<N>.json` 不可读/坏** → 当 **MISSING**（done 门侧 fail-closed：不拿坏判决放行 done）。

### 4.2 测试矩阵（`peer.test.sh` / `loop.test.sh`；tmux stub）

**report verdict（peer.test.sh）**

- `--verdict approve --target-ref worker@5` → reviewer report 带 `verdict/target_ref`；`state/worker/reviews/<role>-r5.json` 写入 `verdict/by/role`。
- `--finding blocking:"401/403 反了"` → `findings[]` 含 `{severity,note}`。
- 耦合错误：`--verdict` 缺 `--target-ref` / 反之 / `--finding` 无 `--verdict` / `--verdict` 配 `--type checkpoint` → 各报错。
- `--target-ref` 无 `@` / round 非整数 / `target_worker` 非 token → 报错（R1-②）。
- **坏 self_role**（`@agent_role` 含 `/`）→ `--verdict` 报错退出（R1-②）；`peer add --role 'a/b'` / `peer add --id 'a/b'`（R2-①）/ `start --with x:'a/b'` → 报错。
- **路径段攻击（R3-①）**：`peer add --id .` / `peer add --id ..` / `peer add --role ..` / `start --with codex:..` / `--target-ref ..@1` 全部拒绝（首字符受限）。
- **`--review reviewer.v2:reject`**（含点号的 role）→ 接受（R2-②，role 走 `is_role_token`）。
- **判决路由写失败**（stub 让 reviews/ 不可写）→ stderr 明示 + 非零退出（R1-③）。

**loop init --review（peer.test.sh）**

- `--review reviewer:request_changes,reject` → `acceptance.reviews` 写入；坏格式 → fail-closed。

**acceptance 门（loop.test.sh，`loopd --once`）**

- done + validation pass + reviewer 非-veto 判决在 → **stop(done)**。
- done + validation pass + reviewer **MISSING** → 不停 + `review_required`（summary `pending`）。
- done + validation pass + reviewer **VETOED**(request_changes) → 不停 + `review_required`（id `…-vetoed`）。
- **pending→vetoed 转变（R1-①）**：先 MISSING 出 `…-pending`,reviewer 再给 request_changes 后同轮出 `…-vetoed`(两条不同 id,后者不被吞)。
- done + validation **running** → **不发** `review_required`（先等 validation）。
- 无 `acceptance` → done 仅凭 validation 停（**回归**）。
- **坏 acceptance 配置 fail-closed（R4-① / R5-①）**：`acceptance.reviews` 手改成非数组 / 条目缺字段 / **`veto_on:[null]` / `veto_on:[""]` / `veto_on:["bad/value"]`（元素非 verdict token）** → done **不停**、发 `…-configinvalid`、看板 `accept=config_invalid`；空数组 `[]` → 视为无 review、done 照常停。
- 幂等：`…-pending` / `…-vetoed` / `…-configinvalid` 各每轮一条。
- reviewer+evaluator 都必需、一过一缺 → blocked。
- 看板含 `accept=…`。

### 4.3 实现影响面

- `bin/peer`：新增共享 `is_role_token`（`^[A-Za-z0-9][A-Za-z0-9._-]*$`，路径段安全、拒 `.`/`..`，R1-②/R3-①；同时用于 agent id 校验）；`report` 加 `--verdict/--target-ref/--finding`（耦合校验、token 校验、`write_report_json` 增字段、判决记录路由到目标 `reviews/`、路由写失败非零退出 R1-③）；`loop init` 加 `--review`（role 用 `is_role_token`，R2-②）；`add` 的 `--role` **与 `--id`** 收紧到 token（R2-①）。
- `start.sh`：`--with` 的 role 收紧到 `is_role_token`（R1-②）。
- `lib/loop.sh`：新增 `ad_loop_acceptance_state`；`eval_contracts` done 门合 validation+acceptance；`review_required` 按 `…-pending`/`…-vetoed`/`…-configinvalid` 拆 id（R1-①/R4-①）；`ad_loop_event_priority` 加 `review_required) 11`；看板 `accept=` 行。
- 文档：README（en/zh）、AGENT-INSTRUCTIONS/AGENTS、契约 §2.5（CLI 现已实现 acceptance）。
- **不动**：validation runner、direction、loop_stop、broker、worktree。

### 4.4 非目标（YAGNI）

- 不做 review 超时升级（worker 泊住等人派 reviewer）。
- 不做 findings-severity 级 veto（veto 按 verdict；findings 仅载荷）。
- 不做 policy 组合（`acceptance.reviews[]` 全过即唯一策略，无 `no_blocking_findings` vs `all_approve` 之分）。
- 不做同 role 多 reviewer 仲裁（一 role 一判决记录，后者覆盖）。

## 5. 评审修订（2026-06-21，交付前收紧）

1. **`review_required` 按 phase 拆 id（§3.3/§4.2）**：`reviewreq-<worker>-<round>-pending` 与 `…-vetoed` 各每轮一条；避免"先 pending、后 reviewer request_changes"的状态变化被固定 id 去重吞掉——vetoed 会新发一条。
2. **role/id token 安全（§2.1/§2.3/§4）**：判决记录路径含 `<reviewer-role>`/`<target_worker>`；新增共享路径段安全 token `is_role_token`（`^[A-Za-z0-9][A-Za-z0-9._-]*$`，拒 `.`/`..`）；`peer report --verdict` 对 `self_role`/`target_worker` fail-closed，`peer add --role`/`--id`/`start --with` 同步收紧（现仅校验非空/查重），杜绝坏 role/id 把判决写到意外路径或逃出 state、done 门永远 pending。
3. **判决路由写失败可见（§2.3/§4）**：`peer report` 路由写失败时 stderr 明示 + 非零退出，**不静默成功**；reviewer 重跑按 `target_round` 覆盖。

### 第二轮评审

4. **`peer add --id` 也收紧到 token（§2.1/§4）**：判决路径含 `<target_worker>`（= worker 的 id），故 id 也必须是 token。原只收紧了 `--role`/`start --with`，漏了 `peer add --id`（现仅查重复）——`--id a/b` 会让 `--target-ref a/b@1` 路径异常、done 永远 pending。`is_role_token` 同时充当 id 校验。
5. **`--review` 的 role 用 `is_role_token`（§1.3）**：原写成不含点号的 `[A-Za-z0-9_-]+`，与共享 `is_role_token`（含点号）不一致——真实 role `reviewer.v2` 会配不上。统一为 `is_role_token`。

### 第三轮评审

6. **`is_role_token` 改为路径段安全（§2.1/§4）**：原 `^[A-Za-z0-9._-]+$` 放行 `.`/`..`，而该 token 现也是 agent id / 路径段——`<target_worker>=..` 会逃出 `state/` 目录、`.` 别名到 `state` 本身。改为 `^[A-Za-z0-9][A-Za-z0-9._-]*$`（首字符字母/数字,拒 `.`/`..`）；测试补 `--id .`/`--id ..`/`--role ..`/`--with codex:..`/`--target-ref ..@1` 均拒。
7. **错误处理段同步补 `peer add --id`（§4.1）**：上轮测试/影响面已含 `--id`，错误处理清单漏了,现补齐,避免实现按清单漏掉。

### 第四轮评审

8. **坏 `acceptance.reviews` 改为 fail-closed（§3.1/§3.3/§3.4/§4）**：acceptance 是验收**安全门**——`reviews` 存在但配置坏时,原设计"跳过/无门"会让 worker 绕过 reviewer。改为 `blocked(config_invalid)`、done 不放行,发 `…-configinvalid` phase、看板 `accept=config_invalid`;空数组 `[]` 仍视为显式无 review。（缺 acceptance 键 = 无门,向后兼容,不变。）
9. **路由写失败的重跑文案修正（§2.3）**：原"重跑同一条命令"对显式 `--round` 不成立（撞 reviewer 自身 `report round 已存在`）。改为:保留同一 `--target-ref`;若显式带了 `--round`,重试换新 round 或省略 `--round`。

### 第五轮评审

10. **`veto_on` 元素也要是 verdict token（§3.1/§4）**：上轮只校验"非空数组",`veto_on:[null]`/`[""]`/`["bad/value"]` 仍是非空数组,但 `rec.verdict ∈ veto_on` 不会命中 → reviewer 任何 verdict 都当 OK,与 fail-closed 相反。改为:`veto_on` 必须是**非空 verdict-token 字符串数组**,任一元素非 token → `config_invalid`。
11. **影响面补 `…-configinvalid` phase（§4.3）**：设计/测试已要求,影响面只写了 pending/vetoed,同步补齐。
