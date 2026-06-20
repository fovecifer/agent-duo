# Supervisor Loop（MVP 5）设计

日期：2026-06-21
状态：设计稿，待实现（交付 Codex 实现，作者 review）
关联：[supervisor-loop roadmap](../../../agent-duo-supervisor-loop-roadmap.md) §MVP 5、[loop-runtime 设计](./2026-06-17-loop-runtime-design.md)、[worker↔supervisor 契约](./2026-06-17-worker-supervisor-contract.md)（task.json 步骤账本见其 §2.4）

## 1. 目标与边界

把现在"事件 → 唤醒 supervisor → 它自由发挥"的 loop 骨架，升级成**有契约护栏、有 max_rounds/stop 机械截停、有原子 `peer ask` 原语**的可控 loop harness。

**驱动模型：混合**——runtime 机械执行硬边界，supervisor（可见 LLM）做软判断。守住 loop-runtime 设计的第一原则（水线）：supervisor 始终是人能看见、能插话的活 session，不是无头 `loop run`。

**本 spec 范围（第一刀）**：

- loop contract 数据模型 + `peer loop init` 冻结、`peer loop` 查看。
- `max_rounds` + 终态的机械截停（loopd 评估 + `loop_stop` 事件 + 看板）。
- `peer ask`（原子 tell+wait+取新 report 结果）+ loop 边界 fail-closed。

**明确推后（非本 spec）**：

- validation 命令自动跑 + 结果入 evidence。
- `success_signals` 的机械匹配（依赖 validation）。
- acceptance 组合规则（reviewer/evaluator veto，契约 §2.5）。
- `peer loop reset` / `--bump-max-rounds`（停止后的完整重置；cut1 用 `peer ask --force` 作逃生口）。

## 2. 架构总览

```
peer loop init <worker>  ──写──>  .agent-duo/state/<worker>/loop.json   (冻结契约)
                                          │
worker: peer report (rN)  ──────────────► │ 提供"轮次/终态"信号
                                          │
loopd (每 tick) ── ad_loop_eval_contracts ┤  读 loop.json + 最新 report
                                          │  边界命中 → 翻 status=stopped
                                          │  幂等 append 一条 loop_stop 事件 + 上看板
                                          ▼
                              events/queue.jsonl ──注入──► supervisor(活 LLM)
                                          ▲
peer ask <worker> "..."  ──fail-closed 查 loop.json──┘  越界拒发(除非 --force)
```

三个单一职责单元：

- **contract 数据层**（`loop.json` + `peer loop init`/`peer loop`）：纯文件读写，无 tmux 依赖，照搬 task.json 的 init/print 模式。
- **评估器**（`ad_loop_eval_contracts`，在 loopd 内）：纯函数式判定 + 幂等状态翻转，唯一执法点。
- **`peer ask`**：原子 tell+wait+取新 report，叠一道 loop 边界 fail-closed。

## 3. 数据模型：`loop.json`

路径 `.agent-duo/state/<worker>/loop.json`：

```jsonc
{
  "protocol": "1",
  "agent_id": "worker",
  "mission": "把登录失败错误提示修对并跑测试验证",   // 软护栏:供 supervisor 读
  "non_goals": ["不改 auth 流程", "不重构"],          // 软护栏
  "success_signals": ["auth.test.ts 全绿", "401/403 文案正确"], // 软护栏(cut1 不机械匹配)
  "max_rounds": 8,                  // 硬边界:机械截停
  "frozen_at_round": 1,
  "status": "active",               // active | stopped
  "stop": {
    "on_terminal": true,            // 硬边界:result(done)+全步done 或 failed 即停
    "reason": null,                 // 停时填:max_rounds | done | failed
    "stopped_at_round": null,
    "stopped_at": null
  },
  "created_at": "2026-06-21T...Z",
  "updated_at": "2026-06-21T...Z"
}
```

**硬边界 vs 软护栏（贴合混合模型）**：

- **硬边界（runtime 机械执行）**：`max_rounds`、`stop.on_terminal`。
- **软护栏（supervisor LLM 读，不机械执行）**：`mission`、`non_goals`、`success_signals`。cut1 不做 `success_signals` 自动匹配（那要 validation，已推后）。

> roadmap 写的是 `contract.yaml`，但本仓库是 jq-only、无 YAML parser，故用 JSON + `peer loop init` 结构化冻结，与 task.json/broker marker 的 per-worker scope 一致。

## 4. 命令面

### 4.1 `peer loop init`

```
peer loop init [<worker>] --mission "..." --max-rounds N \
      [--non-goal "..."]... [--success "..."]... [--round N]
```

- 冻结 `loop.json`；已存在则 fail-closed（照搬 task init）。
- `--mission`、`--max-rounds` 必填；`--max-rounds` 必须为正整数。
- `--non-goal` / `--success` 可重复，落入对应数组；空数组用 `${arr[@]+...}` 守 `set -u`，值经 `json_str` 转义。
- `<worker>` 省略默认 `ME`（供 supervisor 指定目标）；`--round` 默认 1，写入 `frozen_at_round`。
- 写入用 tmp+mv 原子可见。

### 4.2 `peer loop`

```
peer loop [<worker>]
```

打印契约 + 当前派生量：`round`=最新 rN（读 `report.json` 的 `.round`，无报告为 0）、`remaining`=`max_rounds - round`、`status`。

## 5. 评估器：`ad_loop_eval_contracts <root> <session>`

加进 `lib/loop.sh`，由 `ad_loop_once` 在渲染看板前调用一次。对每个**有 `loop.json` 且 `status==active`** 的 worker：

### 5.1 读两个信号（复用现成 helper，不新造计数器）

- `current_round` = `ad_loop_report_round`（读 `report.json` 的 `.round`，无报告为 0）。
- `report_status` = `ad_loop_report_status`（读 `.status`）。

> 关键简化：`peer report` 已经在 task.json 未全步 done 时把 `done` 降级为 `partial`。所以 **`report_status==done` 本身就蕴含"全步 done"**——评估器不必再读 task.json，report 状态就是终态真相。

### 5.2 停止判定（仅 `status==active` 时，按优先级）

```
if on_terminal and report_status == "done"    → stop(reason=done)       # 成功优先
elif on_terminal and report_status == "failed" → stop(reason=failed)
elif current_round >= max_rounds               → stop(reason=max_rounds)
else                                           → 不动(active)
```

终态优先于 `max_rounds`：worker 恰在第 `max` 轮报 done，记成功而非"耗尽"。

### 5.3 状态翻转 + 事件：照搬 report/gate/task 的 tmp+回滚纪律

命中停止时，**先 stage、event 成功后才 commit**——和仓库其它写入完全一致，保证不"静默停"也不重复发：

```
1. 把 stopped 版 loop.json 写到 tmp
   (status=stopped, stop.reason/stopped_at_round/stopped_at, updated_at)
2. append 一条 loop_stop 事件到 queue.jsonl
3. event 成功 → mv tmp → loop.json   (这一刻起 status=stopped,下个 tick 不再评估 → 天然幂等)
   event 失败 → rm tmp,loop.json 仍 active(下个 tick 重试,不会漏通知)
```

loopd 是单进程常驻、串行 tick，无并发重入，所以这套顺序既不漏发也不重发。

### 5.4 `loop_stop` 事件

```jsonc
{ "type": "loop_stop", "agent": "worker", "round": <current_round>,
  "summary": "loop stopped: max_rounds (8/8)",   // 或 done / failed
  "ref": ".agent-duo/state/worker/loop.json" }
```

- 在 `ad_loop_event_priority` 注册 **`loop_stop) printf '10'`**（与 `blocked` 同档，高优先，排在 checkpoint/tick 前）。supervisor idle 时被优先注入，拿到"loop 到界，因为 X"，再用人话向人汇报。

### 5.5 看板

`ad_loop_render_dashboard` 现有的每个 worker 行追加 loop 信息（有 `loop.json` 时）：

```
workers:
  worker pane=%2 round=8 status=done   loop=8/8 stopped:done
  helper pane=%3 round=3 status=in_progress   loop=3/8 active
```

## 6. `peer ask`（原子 tell+wait+取新结果）

### 6.1 命令面

```
peer ask [<worker>] "<消息>" [--timeout N] [--interval N] [--force]
```

原子地：① loop 边界 fail-closed 检查 → ② 下发消息 → ③ 等该 worker 这一轮报告 → ④ 只回这一轮的新结果。

### 6.2 为什么"新结果"= 新 report，而不是屏幕 diff

worker 是 Claude/Codex **全屏 TUI**——`capture-pane` 抓到的是当前重绘帧，不是 append 日志，两帧 diff 很脏、不可靠。而本仓库 worker→supervisor 的干净通道**就是 report**：`peer report` 打出的 sentinel（`«AGENTDUO:… round=N … file=…»`）是 TUI 里**显式、可锚定**的标记，`wait --round` 已经在用它判回合边界。

所以 `peer ask` 的"新输出"定义为：**这一轮产生的新 report 的 summary + ref**——干净、鲁棒、且正好是契约里 supervisor 该消费的东西。

> 定位：`peer ask` 是 **loop 原语**（report-gated），不替代 `tell`。要跟 reviewer 随口问一句、对方不会 report 的场景，supervisor 仍用 `tell + peek`。

### 6.3 执行流程

```
1. 解析 target(同 tell/peek:[<worker>] 省略时按两人默认回查)
2. 【loop fail-closed】读 target 的 loop.json(若存在)且非 --force:
     若 status==stopped              → 拒发,exit 1
     若 current_round >= max_rounds  → 拒发,exit 1
   (current_round 用 report.json 的 .round;这步同时挡住"loopd 还没 tick 到"的竞态)
3. 记录 pre-send 最新 report 轮次 R(无报告 → 0)
4. 下发消息:复用 tell 的 buffer+paste+enter 路径
     → ⚠️ tell 的 broker 硬门在此自动生效。即 ask 叠两道闸:loop 边界(新)+ broker ready(已有)
5. 等待该 worker 出现 round > R 的 report sentinel(复用 wait --round 的 sentinel 轮询)
6. 命中 → 读那条 rN.json,打印结构化结果:round / status / delta / next / needs + ref
   超时未出新 report → 非零退出 + 末屏 peek 兜底(best-effort)
```

### 6.4 fail-closed 文案（与 broker 门同风格）

```
错误: worker 'worker' 的 loop 已到界(reason=max_rounds, 8/8),已拒绝继续派发。
      经人确认后用 'peer ask --force worker "..."' 越界,或后续用 peer loop reset(待实现)。
```

### 6.5 两道闸的关系（明确，避免歧义）

| 闸 | 检查 | 触发点 | 越过 |
|---|---|---|---|
| **loop 边界**（本 spec 新增） | loop.json status/轮次 | `peer ask` 发送前 | `--force` |
| **broker 硬门**（已有） | 目标 broker fresh ready | tell 路径内 | `--force` / `AGENT_DUO_NO_BROKER_GATE=1` |

- `peer ask --force` 同时跳过 loop 边界**和** broker 门（复用 tell 的 `FORCE_SEND` 语义），与现有 `--force` 一致。
- `peer tell` 本身**不**加 loop 边界检查——loop 边界只属于 `ask` 这个 loop 原语，`tell` 维持现状（只受 broker 门）。

## 7. 错误处理与边界

**`peer loop init`**

- 已存在 `loop.json` → fail-closed。
- `--mission` 缺失、`--max-rounds` 缺失或非正整数 → 报错退出，不写文件。
- `--non-goal` / `--success` 可重复，空数组守 `set -u`，经 `json_str` 转义。

**评估器（loopd）**

- 无 `loop.json` 的 worker → 跳过。
- `status==stopped` → 跳过（不重评、不重发）。
- `loop.json` 损坏 / jq 解析失败 → **跳过且不翻转**（下个 tick 再看），stderr 一行告警，不污染状态。
- worker 还没 report（round 0）→ 不终态、0<max → active。
- event append 失败 → tmp 丢弃，`loop.json` 保持 active，下个 tick 重试（不漏通知、不留半 stopped）。

**`peer ask`**

- target 解析失败 → 同 tell 报错。
- 无 `loop.json` → 不挂 loop 闸（仍受 broker 门）。
- `loop.json` 存在但不可读 → loop 闸 **fail-open + 告警**（loop 闸是预算护栏不是安全闸；安全闸是 broker 门，不受影响），避免一个坏文件把 worker 焊死。
- 超时无新 report → 非零退出 + 末屏 peek 兜底。

## 8. 测试矩阵（`test/peer.test.sh` + `test/loop.test.sh`，复用 tmux stub，无 sleep）

**loop init / print（peer.test.sh）**

- init 成功，字段齐（mission/max_rounds/non_goals/success/status=active）。
- init 已存在 → fail-closed。
- 缺 `--max-rounds` → 报错；非整数 → 报错；缺 `--mission` → 报错。
- `--non-goal`/`--success` 可重复落数组。
- `peer loop` 打印契约 + round/remaining/status。

**评估器（loop.test.sh，用 `loopd --once`，照搬现有 stub 报告手法）**

- active、round<max、非终态 → 保持 active，**无** loop_stop 事件。
- round≥max、非终态 → stopped(max_rounds) + **恰一条** loop_stop。
- 终态 done（未到 max）→ stopped(done)。
- 终态 failed → stopped(failed)。
- **终态优先**：round==max 且 done → reason=done（非 max_rounds）。
- 幂等：连跑两次 `--once`，只有一条 loop_stop（第二次 status 已 stopped）。
- event append 失败 → loop.json 仍 active（无孤儿 stopped）。
- 看板显示 `loop=round/max status`。

**peer ask（peer.test.sh）**

- stopped → 拒发，无 paste。
- round≥max → 拒发，无 paste。
- `--force` → 越过 loop 闸，发送。
- 无 loop.json → 不挂 loop 闸（发送）。
- broker 未 ready + loop active → 仍被 broker 门拒（验证两闸独立）。
- 成功：stub 出 round>R 的 sentinel → 打印新 report 的 summary/ref。
- 超时无新 report → 非零退出 + 兜底提示。

## 9. 实现影响面

- `bin/peer`：新增 `loop` 子命令（init/print）、`ask` 子命令；新增 loop.json 读写 helper。
- `lib/loop.sh`：新增 `ad_loop_eval_contracts` + 在 `ad_loop_once` 调用；`ad_loop_event_priority` 加 `loop_stop) 10`；`ad_loop_render_dashboard` 加 loop 行。
- 文档：README（en/zh）、AGENTS/AGENT-INSTRUCTIONS、契约（loop contract 章节）、loop-runtime 设计同步。
- 不动：`approval_broker.sh`、broker 门逻辑、task.json 写入（只读它的 report 降级结果）。

## 10. 非目标（YAGNI）

- 不把 supervisor 变无头 `loop run`——它始终是可见、可插话的 session（守水线）。
- 不在人面前暴露结构化命令——`loop`/`ask`/契约全是 supervisor 的内部动作。
- 不做 validation 自动跑、success_signals 机械匹配、acceptance veto、loop reset——均留后续迭代。
