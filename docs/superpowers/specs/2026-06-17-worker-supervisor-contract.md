# agent-duo Worker ↔ Supervisor 交互契约

日期：2026-06-17
状态：设计稿，待实现
关联：[supervisor-loop roadmap](../../../agent-duo-supervisor-loop-roadmap.md)、[loop runtime 设计](./2026-06-17-loop-runtime-design.md)、[registry MVP 3 design](./2026-06-16-registry-mvp3-design.md)

> 本契约是**水线以下**的内部协议（worker↔supervisor）。人这一层永远只说自然语言，见 [loop runtime 设计 §水线](./2026-06-17-loop-runtime-design.md#第一原则水线凌驾于所有机制之上)。

## 为什么先定这个

supervisor-loop roadmap 里后续所有机制——checkpoint、approval、human gate、evidence、direction、budget——本质上都是**同一份 worker↔supervisor 契约的投影**：

- checkpoint = 上行消息的几个 `type`
- approval / human gate = 一种**阻塞型**上行消息 + 对应下行回复
- evidence gate = 契约 schema 的一条**约束**（`done` 必须带 evidence，否则降级）
- budget = 每回合上行消息**大小有界**、supervisor 读结构化文件而非全屏 peek

所以契约定死，后面的 `peer approve / gate / report / reframe` 等命令就只是它的**表层语法**。本文档定义这份契约。

## 目标

- 定义 worker 与 supervisor 之间消息的**封闭词汇表**（双向）、**数据结构**、**状态机**和**不变式**。
- 让契约在 agent-duo 的**真实信道**（tmux pane + `peer tell/peek/wait`）上可表达。
- 覆盖三个关键场景：多 reviewer 审查、多步骤任务中的反复 stall、stall 触发的重规划。

## 非目标（YAGNI）

- 不定义 budget 数值策略、policy 规则细节（属于后续 MVP）。
- 不要求干净的 JSON-RPC 总线——契约必须能跑在抓屏 + 敲键的 TUI 现实上。
- 不实现 park-and-continue（stall 时默认整体 halt，见 [Halt 语义](#halt-语义stall-默认整体停)）。

---

## 0. 信道前提：不对称

agent-duo 的现实是 supervisor 往 worker 的输入框敲字（`peer tell`），worker 输出靠 `peek` 抓屏。这逼出**上行结构化、下行指令化**：

- **下行（Supervisor→Worker）**：worker 是 LLM，能读自然语言 ⇒ 「结构前缀 + 自然语言 payload」的混合指令。
- **上行（Worker→Supervisor）**：屏幕不可靠又贵 ⇒ **事实来源是 worker 写到磁盘的结构化文件**，屏幕只是给人看的镜像 + 同步信号（见 [Sentinel](#5-sentinel--cli-codec)）。

这条直接服务 budget：supervisor 读 JSON 文件几乎免费，不必每轮全屏 peek。

---

## 1. 词汇表（双向封闭集）

封闭是关键——worker 不能随便"叙述"，supervisor 才能廉价解析、不被忽悠。

### 上行 Worker → Supervisor（每条都是一个 Report 对象，带 `type`）

| type | 含义 | 阻塞？ | 对应检查点 |
|---|---|---|---|
| `plan` | 动手前回写计划（把指令拆成可寻址步骤清单） | **是**（等 `proceed`） | Plan Checkpoint |
| `checkpoint` | 周期 / 里程碑心跳 | 否 | Heartbeat |
| `request` | 显式索取（授权 / 决策 / 信息 / 改 scope / 重规划发现） | **是**（等答复） | Boundary Gate |
| `result` | 任务 / 子任务终态 | `done` 时**是**（等验收） | Done Checkpoint |

### 下行 Supervisor → Worker（封闭动词集）

| verb | 含义 | 表层命令 |
|---|---|---|
| `assign` | 派任务 + contract 引用 + budget（可含 `steps[]`） | `peer tell` |
| `proceed` | 批准 plan / 解阻后继续 | `peer tell` |
| `approve` / `deny` | 答复授权请求 | `peer approve` / `peer deny` |
| `decision` | 答复 human gate（选了哪个选项） | `peer gate resolve` |
| `require_evidence` | 驳回 claim，要证据 | `peer require-evidence` |
| `reframe` | 拉回 mission / 局部重新 scope | `peer reframe` |
| `assign`（replan） | 发现重大问题，拆法失效，重新冻结 `steps[]` | `peer tell` |
| `stop` / `handoff` | 终止 / 移交 | `peer budget handoff` |

下行同样有最小结构（`peer tell` 注入带前缀的一行 + 自由文本）：

```
«AGENTDUO verb=proceed»
«AGENTDUO verb=reframe» 只修断言，别动 auth 模块
«AGENTDUO verb=decision choice=staging-db»
```

---

## 2. 核心数据结构

### 2.1 Report（上行的唯一对象）

```jsonc
{
  "protocol": "1",
  "round": 3,
  "agent_id": "worker-impl",        // 来自 @agent_id（见 registry MVP 3）
  "role": "worker",                 // worker | reviewer | evaluator …
  "type": "checkpoint",             // plan | checkpoint | request | result
  "status": "in_progress",          // in_progress | blocked | partial | done | failed | unknown
  "goal_ref": "fix-login-error-copy",
  "step_ref": "s2",                 // 多步骤任务中当前所在步；单步任务可省

  "delta": "auth.test.ts 现在覆盖了空密码用例",  // 相比上轮哪个 success_signal 前进了
  "drift": null,                    // 触碰 non_goals / 越界则填，否则 null
  "evidence": [                     // status=done|partial 必须非空，否则降级为 unknown
    {"cmd": "npm test", "result": "1 failing", "ref": ".agent-duo/logs/worker-impl/r3.log"}
  ],
  "needs": [],                      // 见下；空表示无阻塞诉求
  "next": "修正断言，不重构 auth 模块"        // 下一步意图，一句话

  // role=reviewer|evaluator 的 result 额外携带：
  // "target_ref": "worker-impl@r5",
  // "verdict": "request_changes",  // approve | request_changes | reject（evaluator: pass | fail）
  // "findings": [{"severity":"blocking","loc":"auth.ts:42","issue":"…","suggest":"…"}]
}
```

`delta` 与 `drift` 是专门给 supervisor 做调整判断的字段：`delta` 连续为空 → detail trap；`drift` 非空 → direction drift。supervisor 不读全屏，只看这两个字段即可决定 continue / reframe / stop。

### 2.2 needs[]（阻塞诉求，决定 stall 路由到谁）

```jsonc
{
  "kind": "approval",   // approval | decision | info | scope | discovery
  "detail": "迁移需要写权限",
  "options": ["new-vm", "existing-dev-vm"]   // kind=decision 时给候选
}
```

- `approval` → Approval Broker（低风险可自动放行）
- `decision` → Human Decision Gate（人来选）
- `info` → supervisor 补充信息
- `scope` → supervisor `reframe`
- `discovery` → **不是要放行，而是"我发现了可能掀桌子的东西"** → supervisor 重规划，**不得降级成按个 yes**

### 2.3 task.json（持久化的 step ledger，多步骤任务的共享真相）

`assign` 下发或 worker `plan` 回写后由 supervisor `proceed` 冻结。状态落盘，使得即便 worker 换 session / 被 handoff 也不丢进度。

```jsonc
{
  "task": "add tenant_id end-to-end",
  "frozen_at_round": 1,
  "steps": [
    {"id": "s1", "desc": "schema 加 tenant_id", "deps": [],     "done_when": "go build", "status": "done",        "evidence": [{"cmd":"go build","ref":"…"}]},
    {"id": "s2", "desc": "写迁移并跑通",        "deps": ["s1"], "gate": "needs db write", "status": "in_progress", "evidence": []},
    {"id": "s3", "desc": "更新 API 文档",        "deps": [],                              "status": "pending",     "evidence": []}
  ]
}
```

步骤状态：`pending | in_progress | blocked | done | failed | kept`（`kept` 见重规划）。每个 `done` 步各自带 evidence。

### 2.4 acceptance（验收组合规则，写进 loop contract）

```yaml
acceptance:
  require_evidence: true
  reviews:
    - role: reviewer     # 代码审
      veto_on: ["blocking"]      # 有 blocking finding → 不能 accept；nit 不阻塞
    - role: evaluator    # 浏览器 / 截图验收
      veto_on: ["fail"]
  policy: no_blocking_findings   # 或 all_approve
```

---

## 3. 阻塞规则（协议的心脏）

> **发出阻塞型消息后，worker 必须停下，直到收到对应下行回复，才能继续。**

`plan`、`request`、`result(done)` 阻塞；`checkpoint` 不阻塞。这一条把 gate vs notify 写死进协议——危险动作过不去，心跳不打断。

---

## 4. 状态机

宏状态不随步骤数变化；`in_progress` 内部带一个 **step cursor** 在 `task.json` 的步骤间游走。

```
            assign            worker:plan(阻塞)
  idle ───────────► planning ──────────────► awaiting_plan_ack
                       ▲                          │ sup:proceed（冻结 task.json）
                       └── sup:reframe ───────────┤
                                                  ▼
        worker:checkpoint(不阻塞) ┌──────► in_progress ◄─────┐
                                  └──────────┘ │  (step cursor) │ sup:proceed / reframe
                                worker:request │ │              │
                                   (阻塞)      ▼ ▼ worker:result │
                                           blocked            awaiting_acceptance
                          ┌──────────────────┤                   │（worker 泊住、不烧 token）
                  sup:approve/decision/info   │ sup:assign(replan)│ sup:require_evidence ─┘
                          └───► in_progress   └───► planning      │ reviewer 流程 / sup:accept
                                                                  ▼
                                                                done
```

- `awaiting_acceptance` 是 review 流程发生的地方（见 §6），worker 在此**泊住不烧 token**。
- `done` 之前必须经 `awaiting_acceptance` 与（若配置了）reviewer：**worker 只能"声称"完成，supervisor 才能"确认"完成**。

### Halt 语义（stall 默认整体停）

stall 大概率是**硬 gate** 或**之前没发现的重大问题**。若 park-and-continue，会在一个可能被推翻的步骤之上继续盖后续步，反而更糟。因此初版**默认整体 halt（方案 A）**。

halt 后一个阻塞 `request` 的下行出口有四种，不止"proceed"：

| 出口 | 何时 | 对 task.json 的影响 |
|---|---|---|
| `proceed` | 纯 gate，答完即可继续 | 不变，resume 同一步 |
| `reframe` | 范围要收 / 调，但任务仍成立 | 局部改 `steps` |
| `assign`（replan） | 发现重大问题（`needs.kind=discovery`），拆法失效 | **重新冻结** `steps[]` |
| `stop` / `handoff` | 太大，超出本 loop | 落 handoff packet |

park-and-continue 留作后续 step 图显式声明 `independent` 后才开启的可选项，初版不实现。

---

## 5. Sentinel & CLI codec

文件解决 payload，但解决不了三件事，必须由 sentinel 补：

1. **新报告何时出现**——文件写入对盯屏的 harness 和 `peer wait` 不可见。
2. **worker 在跑还是已停在输入框等你**——这是终端交互事实，文件表达不了，却是 gate 能否被响应的前提。
3. **屏幕状态 ↔ 文件 的对应**——supervisor 怎么确认"现在这一屏就是我以为的那一轮"，而非旧的 / 被截断的输出。

Sentinel = 架在「文件(payload)」与「TUI 现实(在跑 / 已停 / 卡在 prompt)」之间的一行同步标记。

### 格式

一行，罕见定界符 + **每会话随机 tag**（防碰撞、防伪造）+ 指向文件的指针与校验：

```
«AGENTDUO:7f3a» round=3 type=checkpoint status=in_progress file=.agent-duo/state/worker-impl/r3.json sha=ab12cd… ts=2026-06-17T…
```

- `7f3a` 在 `assign` 时分配给该会话，worker 无法伪造他人的 sentinel，正常输出也几乎不可能撞上。
- `sha` 是刚写文件的哈希，让屏幕截断 / 篡改**可检测**（同 roadmap 的 `prompt_hash` 思路）。

### 顺序与谁来发

**写文件 → fsync → 再打印 sentinel（带该文件 sha）。** 保证 supervisor 只要看到 sentinel，文件就一定写完且匹配——消灭"读到半截文件"的竞态。

**sentinel 不是 LLM 手敲的，是 `peer report` CLI 发的**：

```
worker 调用：  peer report --type checkpoint --status in_progress --step s2 --file r3.json
             └─ 命令内部：① 写文件 ② 打印带 sha+tag 的 sentinel（原子）
```

即 **CLI 就是 codec**：模型永不手写 marker（不会格式错、不漏 sha），下行 `peer tell/reframe` 同理负责格式化指令前缀。worker 只管"调命令"，framing 是工具的事。

### 两个角色

1. **同步令牌**：`peer wait worker-impl --round 4` 的语义从"等屏幕 idle 瞎猜"变成"等 round=4 的 sentinel 出现"，精确回合边界。
2. **halt 信号**：`status=blocked` 的 sentinel 告诉 supervisor"它停下了、在等你回"，是 gate 可被响应的触发点。

### 为什么不能纯靠 inotify 轮询

supervisor 可额外 poll 目录，但替代不了 sentinel：文件系统告诉不了你"worker 已 halt 在 prompt 上等输入"（纯交互事实）；没有人类可见信号（违背"用户眼前真实会话"的立身之本）；无法把"屏幕这一屏"与"哪一轮文件"对应（sha 关联）。

### 边界情况

- **sentinel 在、文件缺 / sha 不符** → 视为损坏，supervisor 重新 peek 或要求重发。
- **sentinel 滚出 scrollback** → `report.json` 始终是 latest 指针，按 round 直接读文件兜底；peek 开大窗口。
- **worker 在散文里"描述"sentinel 而非真发** → 因 CLI 发、带会话 tag，描述出来的不带正确 tag/sha，自动失效。

---

## 6. Review 场景：不要新协议，reviewer 就是 role=reviewer 的 worker

review 不是新消息类型，而是**同一份契约作用在另一个角色上**。这样契约不膨胀，且天然满足"agent 之间不能无监督直连"——reviewer 永不跟 worker 说话，全部过 supervisor 中继（星型拓扑）。

### 流程：`done` 进入"待审"，不是终点

```
worker-impl:   result(done, evidence, worktree=…)      → awaiting_acceptance（泊住）
supervisor:    不直接 accept，而是 assign reviewer {
                  target_ref: "worker-impl@r5",
                  artifact:   worktree 路径 + diff ref   // 就是 worker 那条 result 的 evidence
               }
worker-review: result(done, verdict=request_changes, findings[])
supervisor:    把 findings 映射成 reframe/assign 回发 worker-impl  → 重新 in_progress
               …循环…
worker-review: result(done, verdict=approve)
supervisor:    accept worker-impl                       → done
```

### 要点

- **verdict 只出现在 reviewer/evaluator 的 result 上**；普通 worker 没有 verdict，只有 status。
- **findings 流向**：reviewer→supervisor→(reframe/assign)→worker，从不直连；每跳进 `reports.jsonl`，可回放"为什么打回"。
- **证据双用途**：worker 的 `evidence[]`（worktree、diff、log 引用）对 supervisor 是证明，对 reviewer 同时是输入。这也是为什么 worktree 隔离（MVP 4）是前提——reviewer 只读 worker 的 worktree。
- **天然扩展到 N 审 + evaluator**：supervisor 扇出多个 reviewer/evaluator，收齐 verdict 按 `acceptance.policy` 聚合。evaluator 的 verdict 是 `pass/fail`，evidence 是截图。
- **`severity` 让"带 nit 接受"成为可能**——不是每条意见都触发新一轮，否则永不收敛。

这套机械化了 contract 里的 `stop.success: "reviewer has no blocking findings"`。

---

## 7. 多步骤任务 + 反复 stall

消息层面，"卡 N 次、每次找不同的人"通过 `request(阻塞) → 处理 → proceed` 循环即可，`needs[]` 可同时带多个诉求并按 `kind` 路由。缺的不是这个，而是**任务的步骤粒度状态**（见 §2.3 task.json）。

### 三条保证

- **幂等 resume**：`proceed` 后 worker 先读 `task.json`，从 `blocked` / 下一个 `pending` 步继续，**绝不重做 `done` 步**。状态落盘 ⇒ 换 session / handoff 也不丢。
- **done = 全步 done**：`result(done)` 仅当每步 `done`（各带 evidence）或被显式 waive，否则只能 `partial` 并列出剩余步。杀掉"某步糊弄过去"。
- **per-step stuck**：`max_rounds_without_validation_progress` 按步计数，单步连卡即升级，不被别的步进展稀释。

### 重规划（replan）下的幂等

`needs.kind=discovery` 触发 `assign`(replan)、重新冻结 `steps[]` 时：已 `done` 且证据仍有效的步标 `kept`，不重做；受影响的步才重置为 `pending`。

### 走查（一条指令、卡两次、分别找 broker 和人）

```
assign: 1.schema加字段  2.写迁移跑通  3.更新文档
plan:   s1, s2(deps s1, 会撞 db 权限), s3(独立)   → supervisor proceed，冻结 task.json
proceed
 s1: in_progress → done            report(step=s1, status=done, ev=diff)         ← 非阻塞心跳
 s2: in_progress → 撞权限           request(step=s2, needs=approval)   ⏸阻塞
                  supervisor approve → proceed（读 task.json，s1 已 done 不重做）
                  跑迁移失败:缺生产库凭据 request(step=s2, needs=decision: 用哪个库?)  ⏸阻塞
                  human gate → decision=staging-db → proceed → s2 done
 s3: in_progress → done
result(done)  ← 此刻才合法，s1/s2/s3 各有 evidence
```

---

## 8. 不变式（协议的保证）

1. **没有静默 done。** worker `status=done` 只是 claim，必须 supervisor `accept`（且通过配置的 review）。→ 兑现 evidence/review gate。
2. **阻塞消息一定挂起 worker。** 不许越过 gate 凭假设往前跑。
3. **claim 无证据即降级。** `done/partial` 缺 `evidence[]` → 自动变 `unknown`。→ Truthful Progress 写成 schema 约束。
4. **一回合一 Report，大小有界。** → supervisor 读取成本有上界，兑现 budget。
5. **幂等 resume。** 解阻后从 `task.json` 续，不重做 `done`/`kept` 步。
6. **agent 间不直连。** reviewer/worker 一切经 supervisor 中继，每跳可审计。

---

## 9. 与 peer 命令面的映射

契约是语义层，`peer` 命令是它的表层语法：

| 契约动作 | peer 命令 |
|---|---|
| 上行任意 Report（写文件 + sentinel） | `peer report --type … --status … [--step …] --file …` |
| `peer wait` 等回合边界 | `peer wait <id> --round N`（等 sentinel） |
| answer approval | `peer approve` / `peer deny` |
| answer human gate | `peer gate resolve --choice …` |
| 驳回 claim | `peer require-evidence --for …` |
| 拉回方向 | `peer reframe` |
| 移交 | `peer budget handoff` |

`peer report` 与 `peer wait --round` 是本契约引入的**新表层**，其余复用 roadmap 既有草案。

---

## 10. 落地顺序建议

本契约横跨 roadmap 多个 MVP，建议按依赖增量落地，而非一次做全：

1. **codec 地基**（无安全面）：`peer report`（写文件 + sentinel）、`peer wait --round`、Report schema、单步 `result`。让上行结构化、回合边界精确。
2. **step ledger**：`task.json`、`plan`→`proceed` 冻结、`step_ref`、幂等 resume、per-step stuck。
3. **阻塞与出口**：`request`/`needs` 路由、四出口（proceed/reframe/replan/stop）、`discovery` kind。
4. **review**：`target_ref/verdict/findings`、`acceptance` 聚合（依赖 MVP 4 worktree 隔离）。

每步都可独立验证、独立产出价值，符合 roadmap"小步可实现"的取舍。
