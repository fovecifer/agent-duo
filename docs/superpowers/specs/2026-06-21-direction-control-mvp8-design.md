# Direction Control（MVP 8）设计

日期：2026-06-21
状态：设计稿，待实现（交付 Codex 实现，作者 review）
关联：[supervisor-loop roadmap](../../../agent-duo-supervisor-loop-roadmap.md) §Direction Control / §MVP 8、[Supervisor Loop（MVP 5）设计](./2026-06-21-supervisor-loop-mvp5-design.md)、[Loop Validation + Success Signals 设计](./2026-06-21-loop-validation-success-signals-mvp-design.md)、[worker↔supervisor 契约](./2026-06-17-worker-supervisor-contract.md)（§2.1 delta/drift）

## 1. 目标与边界

补完 supervisor loop 的"纠偏"一条腿：worker 在长任务中常陷入局部细节或偏离目标，runtime 应**机械检测客观信号并 flag**，supervisor（活 LLM）据此**纠偏**。

**驱动模型：混合**（延续 MVP 5）——runtime 检测客观信号（`delta` 连续为空、`drift` 非空），发高优先事件；supervisor 判断 continue/reframe/stop 并发 `peer reframe`。守水线：supervisor 始终是可见、可插话的活 session。

**本 spec 范围（第一刀，全选）**：

- `detail_trap` 检测（`delta` 连续 N 轮为空）。
- `direction_drift` 检测（`report.drift` 非空）。
- `peer reframe`（发 `verb=reframe` + 记 `checkpoints.jsonl`）。
- `peer checkpoint`（只读方向摘要）。

**明确推后**：detail-trap 的其它启发式（diff 体积、引入新抽象、非关键文件耗轮）、定时 direction checkpoint、acceptance veto。本刀只用契约 §2.1 已定的客观信号（`delta`/`drift`）。

## 2. 架构总览

```
worker: peer report (--delta / --drift)  ──写──> rN.json
                                                   │
loopd (每 tick, eval_contracts 内) ── 检测器 ──────┤  读最近 N 个 rN.json 的 delta + 最新 drift
                                                   │  detail-trap(delta 连续 N 轮空)→ detail_trap 事件
                                                   │  drift(report.drift 非空)     → direction_drift 事件
                                                   │  幂等:确定性 id per (agent,round,kind)
                                                   ▼
                                  events/queue.jsonl ──注入──► supervisor(活 LLM)
                                                   │  「worker 卡在细节 / 跑偏了」
                                                   ▼  supervisor 判断
peer checkpoint <worker>  ──只读聚合方向摘要──────► (辅助判断)
peer reframe <worker> "…" ──broker 门 + verb=reframe + 记 checkpoints.jsonl──► 拉回 worker
```

检测器与 MVP 5 的 validation 同住 `eval_contracts`，**纯无状态读文件**（不写状态、不碰 loop.json），与 loop_stop/validation 的"读文件算状态"风格一致。顺序见 §5：**检测先于 validation 跑**，避免被同步 validation 阻塞。

## 3. loop.json 扩展（一个新字段）

```jsonc
{
  // …MVP 5 既有字段…
  "detail_trap_rounds": 3       // delta 连续空多少轮算 detail-trap;默认 3
}
```

`peer loop init` 加可选 `--detail-trap-rounds N`（正整数，默认 3；非正整数 fail-closed）。旧 loop.json 无此字段时检测器按默认 3。

## 4. 新事件类型 + 优先级

在 `ad_loop_event_priority` 注册（数字越小越优先；现有 blocked/loop_stop=10、validation_fail=15、checkpoint=90、tick=95）：

| 事件 | 优先级 | 含义 |
|---|---|---|
| `direction_drift` | **12** | worker 自报碰 non_goals/越界——"停下重想"信号，较急 |
| `detail_trap` | **20** | delta 连续 N 轮空——"卡细节、该拉回"信号，次急 |

drift 比 trap 急（碰红线 vs 陷细节）。事件 schema（同现有运行时事件）：

```jsonc
{ "id":"detailtrap-worker-7", "type":"detail_trap", "agent":"worker", "round":7,
  "summary":"detail trap: delta empty for 3 rounds (r5–r7)", "ref":".agent-duo/state/worker/r7.json" }
{ "id":"drift-worker-7", "type":"direction_drift", "agent":"worker", "round":7,
  "summary":"direction drift: 触碰 non_goal「不改 auth 流程」", "ref":".agent-duo/state/worker/r7.json" }
```

确定性 id `detailtrap-<agent>-<round>` / `drift-<agent>-<round>` → 每轮每类最多一条，`ad_loop_event_id_seen` 去重（同 loop_stop/validation）。

## 5. 检测器（核心逻辑）

两个检测器都在 `ad_loop_eval_contracts` 内、对 `status==active` 的 contract 运行，**先于 validation**、stop 判定之前。**纯事件发射 + 确定性 id 去重，不写任何状态**。前置：`current_round > 0`（已有 report）。

> **顺序（F1）**：`eval_contracts` 内对每个 active contract 的顺序为 **direction 检测（drift + detail_trap）→ validation → stop 判定**。检测放在 validation 之前，是因为 MVP 5 的 validation 当前**同步执行、最长阻塞到 `timeout_seconds`**（`wait "$pid"`）；若放其后，红线信号 `direction_drift`（优先级 12，比 `validation_fail` 急）会被一个慢 `go test` 拖到测试结束才入队。检测纯文件读、瞬时，先发不影响 validation。

### 5.1 direction_drift

```
读最新 report.json 的 .drift
若 (.drift // "") 含非空白字符:
    event_id = drift-<agent>-<current_round>
    若 queue 未见该 id → append direction_drift 事件
        summary = "direction drift: " + one_line(drift)   # 截断到合理长度
        ref     = .agent-duo/state/<agent>/r<current_round>.json
```

- `peer report` 用 `json_nullable_str` 写 drift：空则 `null`，否则字符串。所以"非空白"= worker 确实自报了越界。
- 每轮最多一条（id 含 round），`ad_loop_event_id_seen` 去重。

### 5.2 detail_trap（delta 连续 N 轮空）

```
N = loop.json.detail_trap_rounds(缺失 → 静默默认 3;present 但非正整数 → 默认 3 + 每 tick stderr 告警)
R = current_round
rounds_used = R - frozen_round + 1

# 仅当本 loop 内已积累足够轮次,且窗口不越过冻结轮
若 rounds_used < N → 不检测(轮次不够,无法确认 streak)

# 向后读窗口 r<R-N+1> … r<R>
empty_streak = true
for i in (R-N+1 .. R):
    file = r<i>.json
    若 file 不存在/不可读 → empty_streak=false; break   # 无法确认 → 保守不报
    若 (file.delta // "") 含非空白字符 → empty_streak=false; break

若 empty_streak:
    event_id = detailtrap-<agent>-<R>
    若 queue 未见该 id → append detail_trap 事件
        summary = "detail trap: delta empty for N rounds (r<R-N+1>–r<R>)"
        ref     = .agent-duo/state/<agent>/r<R>.json
```

**明确点**：

- **"空 delta"** = `(.delta // "")` 不含任何非空白字符（`peer report` 的 delta 恒为字符串，空即 `""`）。
- **窗口锁在 loop 内**：`rounds_used >= N` 保证 `R-N+1 >= frozen_round`，不读冻结前旧轮。
- **缺文件保守不报**：窗口内任一 rN.json 缺失/坏 → 不报 trap（宁可漏报，不误报）。
- **持续 trap 每轮重报（有意）**：第 R 轮报 `detailtrap-…-R`，第 R+1 轮若仍 streak 则报 `detailtrap-…-(R+1)`——不同 id、不算重复。持续卡住 → 持续被 nudge，直到 supervisor reframe 让 delta 变化打断 streak。优先级 20 较低，不淹没 blocked/drift。

### 5.3 与 stop 判定的关系

检测纯**附加**：发 nudge 事件，**不影响** done/failed/max_rounds 的 stop 判定。一个 worker 可"卡在 detail-trap"同时 loop 仍 active（等 supervisor reframe 或最终 max_rounds 截停）。

## 6. `peer reframe`

### 6.1 命令面

```
peer reframe [<worker>] "<message>" [--force]
```

要求非空 `<message>`（纠偏指令本身）。`<worker>` 省略按两人默认回查（同 tell/ask）。

### 6.2 执行流程

```
1. ensure_session;解析 target / target_id(同 tell)
2. 【loop 窄守卫,非 --force】复用 loop_guard_ask 的条件(见下):
     target loop.json status==stopped 或 rounds_used>=max_rounds → 拒发 exit 1
     near-budget 但 active(rounds_used<max)→ 放行;无 loop.json / 不可读 → fail-open 放行
3. 【broker 门】check_target_dispatch_allowed "$target_id" "$target"
     → 工作型角色非 fresh ready 时拒发
4. 发送(fire-and-forget,照搬 gate resolve 的 verb-send):
     buf = peer-${ME}2${target_id}-reframe
     text = «AGENTDUO verb=reframe»\n<message>
     load-buffer → paste-buffer -d -p → sleep 0.5 → send-keys Enter
5. 记 checkpoints.jsonl(见 6.3)
6. echo "已发送 reframe 给 '$target_id'。"
```

- **窄守卫 = `loop_guard_ask` 同条件（F2）**：仅当 worker **已 `stopped` 或 `rounds_used>=max_rounds`** 时拒发——堵住"无 `--force` 继续驱动一个已到界 worker"。**near-budget 但仍 active 的 worker 照常可 reframe**（保留纠偏意图）。该条件与 `loop_guard_ask` 完全一致，**复用同一判定**，仅把错误文案换成 `peer reframe --force`（实现上参数化 `loop_guard <cmd>` 或加薄包装 `loop_guard_reframe` 均可）。
- `--force` 复用 tell 的 `FORCE_SEND` 语义，**同时跳过窄守卫与 broker 门**（与 ask/tell 一致）。
- **不等待**（reframe 是控制指令，worker 收到后自行继续；不像 ask 等新 report）。
- loopd 的 detail_trap / max_rounds 检测**依旧独立生效**——reframe 不绕过任何检测。

### 6.3 checkpoints.jsonl（审计，仅记有副作用的动作）

路径 `.agent-duo/logs/checkpoints.jsonl`，append-only（同 decisions.jsonl 风格，单行 printf 防并发交错）：

```jsonc
{ "ts":"2026-06-21T…Z", "type":"reframe", "agent":"worker",
  "by":"supervisor", "round":7, "message":"停下 lint,先把登录主流程跑通" }
```

- `agent`=被 reframe 的 worker；`by`=发起者（ME）；`round`=发送时 target 的最新 report 轮次（读 report.json `.round`，无则 0）。
- 在**发送成功之后**追加（只记真正发出的 reframe；broker 拒发时直接 exit、不留审计行）。
- `peer checkpoint`（§7）是纯读，**不**写此日志——日志只记 reframe 这种有副作用的纠偏动作。

## 7. `peer checkpoint`（只读聚合器）

### 7.1 命令面

```
peer checkpoint [<worker>] [--json]
```

**纯读、无副作用**。把方向相关的散落状态聚合成摘要，供 supervisor 判 continue/reframe/stop。`<worker>` 解析同 tell/ask/peek（`reg_pick_other`）：**显式 `<worker>` 优先；正好两人时默认对方；多 agent 时必须显式指定**（checkpoint 是 supervisor 看 worker 状态，默认对方符合直觉）。

### 7.2 数据源（全部已存在，只读）

| 来源 | 取什么 |
|---|---|
| `loop.json` | mission、non_goals、success_signals、status、max_rounds、frozen_at_round、detail_trap_rounds → 派生 round/rounds_used/remaining |
| 最近 N 个 `rN.json` | N = `detail_trap_rounds`（默认 3）；每轮 round/status/delta/drift——正好是 trap 检测窗口 |
| `task.json`（若有） | 步骤按状态计数（done/in_progress/blocked/pending/failed）+ current_step |
| 最新 `validation-rR.json`（若有） | status、missing_signals、failed_validations |

### 7.3 输出

**默认文本**（沿用 loop_print/task_print 的 `LABEL\tvalue` 风格）：

```
CHECKPOINT	worker @ r7 (loop active, used 3/8)
MISSION	把登录失败错误提示修对并跑测试验证
NON_GOALS	不改 auth 流程; 不重构
SUCCESS_SIGNALS	auth.test.ts 全绿; 401/403 文案正确
RECENT	r5 in_progress delta="校验空密码" drift=-
RECENT	r6 in_progress delta="" drift=-
RECENT	r7 in_progress delta="" drift="碰 non_goal: 不改 auth 流程"
STEPS	2 done, 1 in_progress, 0 blocked, 1 pending (current: s2)
VALIDATION	r7 fail — missing: tests pass
```

**`--json`**：同样数据的单个 JSON 对象（`loop`/`recent[]`/`steps`/`validation` 四块），方便 supervisor 机器判断。

### 7.4 边界

- `loop.json` 与 `report.json` **都没有** → 报错退出（"无可汇报的方向状态"）。
- 有其一即可：缺的块留空/省略（无 task.json 则不打 STEPS 行；无 validation 则不打 VALIDATION 行）。
- 任一文件不可读 → 跳过该块，不让整条命令崩。
- 不写任何文件（包括不写 checkpoints.jsonl）。

## 8. 错误处理（汇总新增/跨切面）

- 检测器仅对 `status==active` 的 contract 跑；`stopped` → 跳过。需 `current_round > 0`。
- `detail_trap_rounds` 缺失 → 静默默认 3；present 但非正整数 → 默认 3 + 每 tick stderr 告警（检测器纯无状态，**不保证只告警一次**；loopd 单进程、stderr 输出，可接受。`peer loop init` 已在写入时 fail-closed，故无效值仅来自手工改文件，罕见）。
- detail_trap 窗口内任一 rN.json 缺失/坏 → 保守不报。
- drift 检测：report.json 不可读 → 跳过该 worker。
- `peer reframe`：空 message → 用法错误退出；broker 拒发 → 非零退出、**不**写 checkpoints.jsonl；target 解析失败 → 同 tell 报错。
- `peer checkpoint`：loop.json 与 report.json 全无 → 报错；任一块文件不可读 → 跳过该块、命令不崩；全程不写文件。

## 9. 测试矩阵（`test/loop.test.sh` + `test/peer.test.sh`，复用 stub，无 sleep）

**loop init（peer.test.sh）**

- `--detail-trap-rounds 5` 写入 loop.json；省略 → 默认 3；非正整数 → fail-closed。

**direction_drift（loop.test.sh，`loopd --once`）**

- report.drift 非空 → 一条 direction_drift 事件；drift 为 null → 无事件。
- 幂等：连跑两次 `--once` → 不重复（同 id）。
- stopped contract → 不评估、无事件。

**detail_trap（loop.test.sh）**

- N=3、最近 3 轮 delta 全空 → 一条 detail_trap，summary 含 `r<lo>–r<hi>`。
- 最近 3 轮有一轮 delta 非空 → 无事件。
- `rounds_used < N`（只 2 轮）→ 无事件。
- 窗口内缺 rN.json → 无事件（保守）。
- 幂等：同轮连跑 → 不重复；**持续**：推进到下一轮仍全空 → 新 id 新事件。

**peer reframe（peer.test.sh）**

- 发 `«AGENTDUO verb=reframe»` + message（buffer 内容比对）。
- broker 未 ready → 拒发、无 paste、**无** checkpoints.jsonl 行。
- **窄守卫（F2）**：loop `stopped` → 拒发、无 paste；`rounds_used>=max` → 拒发；near-budget 但 active（`rounds_used<max`）→ 正常发送。
- `--force` → 同时越过窄守卫与 broker 发送。
- 发送后 checkpoints.jsonl 记 `type=reframe`（agent/by/round/message）。
- 空 message → 用法错误。

**peer checkpoint（peer.test.sh）**

- 打印 MISSION/NON_GOALS/SUCCESS_SIGNALS + RECENT（窗口）+ STEPS（有 task.json 时）+ VALIDATION（有时）。
- `--json` 是合法 JSON，含 loop/recent/steps/validation。
- 无 loop.json + 无 report → 报错；无 task.json → 不打 STEPS，命令不崩。
- 不写任何文件（断言 checkpoints.jsonl 未被创建）。

## 10. 实现影响面

- `bin/peer`：`peer loop init` 加 `--detail-trap-rounds`；新增 `reframe`（复用 `check_target_dispatch_allowed` + `loop_guard_ask` 同条件窄守卫）、`checkpoint` 子命令；新增 checkpoints.jsonl 追加 helper。
- `lib/loop.sh`：`ad_loop_eval_contracts` 内加 drift + detail_trap 两检测器（纯发事件、确定性 id 去重）；`ad_loop_event_priority` 加 `direction_drift) 12`、`detail_trap) 20`。
- 文档：README（en/zh）、AGENT-INSTRUCTIONS/AGENTS、worker-supervisor 契约（§5 方向控制章节）同步。
- 不动：broker 门逻辑（reframe 复用 `check_target_dispatch_allowed`）、MVP 5 stop/validation 判定（检测纯附加）、loop_stop。

## 11. 非目标（YAGNI）

- 不把 supervisor 变无头——它始终是可见、可插话的 session（守水线）。
- 不做 detail-trap 的非客观启发式（diff 体积、抽象膨胀、文件热度）——本刀只用 `delta`/`drift`。
- 不做定时 direction checkpoint、acceptance veto、reframe 自动化——均留后续。

## 12. 评审修订（2026-06-21，交付前收紧）

实现者注意这 4 处已澄清/收紧的点：

1. **检测先于 validation 跑**（§2/§5）：MVP 5 validation 同步阻塞（`wait "$pid"`，最长 `timeout_seconds`），故 `eval_contracts` 顺序定为 **检测（drift+detail_trap）→ validation → stop**，避免红线信号 `direction_drift`（优先级 12）被慢 `go test` 拖住。
2. **`peer reframe` 加窄 loop 守卫**（§6）：复用 `loop_guard_ask` 同条件——`stopped` 或 `rounds_used>=max` 拒发（除非 `--force`），堵住"无 force 驱动已到界 worker"；near-budget 但 active 仍可 reframe。
3. **`detail_trap_rounds` 无效处理与"无状态"自洽**（§5.2/§8）：缺失→静默默认 3；present 但非正整数→默认 3 + **每 tick** stderr 告警（不写状态，不再声称"只告警一次"）。
4. **`peer checkpoint` 默认目标明确**（§7.1）：同 tell/ask/peek（`reg_pick_other`）——显式优先、两人默认对方、多 agent 必须显式。
