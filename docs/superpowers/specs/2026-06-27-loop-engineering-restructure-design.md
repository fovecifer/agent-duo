---
title: "agent-duo Loop Engineering 重定位与命令面重构"
date: 2026-06-27
status: design
tags: [loop-engineering, cli-restructure, positioning, agent-duo]
source: docs/agent-loop-三agent循环-提炼.md
---

# agent-duo Loop Engineering 重定位与命令面重构

## 1. 背景与动机

`agent-duo` 当前的对外定位是「supervised coding workbench」——在 iTerm2 标签页里跑可见的
Claude Code / Codex 会话，用 `peer` 命令让监督者驱动 worker。

但从 `docs/agent-loop-三agent循环-提炼.md` 提炼的 **loop engineering** 心智模型回看，
agent-duo 其实已经实现了该模型约 80% 的原语：loop 契约、轮次预算、validation 闸门、
reviewer veto、task 账本、direction control、human decision gate、approval broker、stop hook。
缺的不是能力，而是**定位与表达**——这些能力散落在一张扁平的 `peer` 命令表里，词汇也不统一
（`validation` vs 闸门、`review` vs 独立评判），让人看不出它本质上是一个 loop engineering 框架。

本设计做两件事：

1. **深度重构 `peer` 命令面**，按 loop engineering 的构件重新组织成「名词-动词」语法；
2. **重新定位文档**，用统一词汇把 agent-duo 表达为一个 loop engineering 框架。

**核心意图是「概念重构与定位」**，不是新增能力。所有缺失构件（真·预算执行、connectors、
auto-trigger 心跳）在本次仅作为「槽位」如实标注状态，不实现。

### 兼容性前提

项目处于 pre-1.0，**可自由破坏**。不保留旧命令别名；旧名→新名的对照仅以文档形式提供。

## 2. 三层心智模型（组织架构）

命令面分三层，每层对应 loop engineering 的一个抽象层级（呼应 Boris 的
`source code → agent → loop` 递进）：

```
┌─ 第 3 层：Steering（监督者热路径）─────────────────────┐
│   peer ask / checkpoint / reframe                      │  ← 驱动一个正在跑的 loop
├─ 第 2 层：Loop building-blocks（名词 = 构件）──────────┤
│   peer loop / agent / verify / judge / task /          │
│        report / gate / approval / budget               │
├─ 第 1 层：Transport（底层：眼睛与键盘）────────────────┤
│   peer peek / tell / wait / esc / status               │  ← 原始传输，loop 层之下
└────────────────────────────────────────────────────────┘
```

设计判断：

- **第 1 层 transport** 是基础设施（agent 互相「看」「打字」的能力），独立成最底层、行为不变。
- **第 2 层是重构主体**：每个 loop engineering 构件被提升为一等名词，`peer <noun> --help`
  即可发现。**语法本身在教心智模型**：`verify`=闸门、`judge`=独立评判、`budget`=护栏。
- **第 3 层 steering** 是监督者「写循环」的高频动词，作用**于**一个 loop 之上，
  保持简短的顶层动词，不强行塞进名词分组。
- `ask` / `checkpoint` / `reframe` **不**收进 `peer loop` 名词组——它们语义上是「驱动 loop」
  而非「配置 loop」，且是每轮都敲的热路径，`peer loop ask` 太啰嗦。

## 3. 命令面映射（老 → 新）

### 第 1 层 · Transport（行为完全不变）

| 现在 | 之后 |
|---|---|
| `peer peek [lines]` | `peer peek [lines]` |
| `peer tell "…"` / stdin | `peer tell "…"` / stdin |
| `peer wait [s] [interval] [stable]` | `peer wait …` |
| `peer esc` | `peer esc` |
| `peer status` | `peer status` |

### 第 3 层 · Steering（顶层热路径，不变）

| 现在 | 之后 |
|---|---|
| `peer ask <id> "…"` | `peer ask <id> "…"` |
| `peer checkpoint <id> [--json]` | `peer checkpoint <id> [--json]` |
| `peer reframe <id> "…" [--force]` | `peer reframe <id> "…" [--force]` |

### 第 2 层 · Loop building-blocks（重构主体）

| 现在 | 之后 | 说明 |
|---|---|---|
| `peer add --provider … --role … [--id] [--worktree]` | `peer agent add …` | 编队收进 `agent` 名词 |
| `peer rm [--force] <id>` | `peer agent rm [--force] <id>` | |
| *(无)* | `peer agent ls` | 新增：列出队员 |
| `peer loop init <id> --mission … --max-rounds N --validation id:cmd --review role:veto --detail-trap-rounds N` | `peer loop init <id> --mission … --max-rounds N --verify id:cmd --judge role:veto --detail-trap-rounds N` | 契约 flag 改名对齐名词：`--validation`→`--verify`、`--review`→`--judge` |
| `peer loop <id>` | `peer loop show <id>` | 显式动词（`peer loop <id>` 保留为 shorthand） |
| `peer loop reset <id> [--max-rounds N]` | `peer loop reset <id> [--max-rounds N]` | 不变 |
| `peer task init <id> --task … --step …` | `peer task init <id> …` | PLAN 账本，保持 `task` 名词 |
| `peer task next <id>` | `peer task next <id>` | |
| *(藏在 `loop --validation`)* | `peer verify ls <id>` / `peer verify show <id>` | verifier 升为一等名词；声明仍在契约（`loop init --verify`），查看走 `peer verify` |
| `peer report --type result --verdict approve --target-ref worker@N [--finding …]` | `peer judge <target-ref> --verdict approve [--finding …]` / `peer judge ls <id>` | 判定从 report 拆出，独立对抗式评判成独立名词 |
| `peer report --type request --status blocked --needs decision …` | `peer report --type request --status blocked --needs decision …` | report 收窄为「worker 真实进度」专用，不再承载 verdict |
| `peer gate` | `peer gate ls` | |
| `peer gate open …` / `peer gate resolve --choice …` | `peer gate open …` / `peer gate resolve --choice …` | 不变 |
| `peer approvals` | `peer approval ls` | 三命令并入 `approval` 名词 |
| `peer approve` / `peer deny` | `peer approval approve <id>` / `peer approval deny <id>` | |
| *(无，MVP9 未建)* | `peer budget status` | 预留槽：只读薄 stub（见 §6） |

### 三处实质改动（已确认）

1. **契约 flag 改名**：`--validation`→`--verify`、`--review`→`--judge`（仅 CLI flag 名）。
2. **report / judge 拆分**：`report --type result --verdict`（评判语义）搬到独立的 `peer judge`；
   `report` 从此只是 worker 的真实进度通道。把「制造者的声音」与「检查者的裁决」在命令面彻底分开，
   呼应文档「制造者远离检查者」。
3. **verifier 声明/查看分离**：validations 仍在 `loop init` 冻结（契约不可变），
   新增 `peer verify ls/show` 作为只读名词面。

## 4. 文档与定位产出

三种叙事视角各司其职、互不打架：

> **CLI 用三层名词模型**（稳定语法）· **README 用 plan-build-judge**（英雄叙事）·
> **概念文档用五阶段 + 五构件**（教学结构）

1. **`README.md` / `README.zh-CN.md` 重新定位**
   - 标题从「supervised coding workbench」改为 **loop engineering 框架**（workbench 退为实现细节）。
   - 开篇用 plan → build → judge 英雄叙事，配 §2 三层图。
   - `peer` 命令表按三层重排（transport / building-blocks / steering），结构本身传达分层。
   - 「Why these design choices」保留，新增一节把每个构件名词对回文档概念
     （verify=闸门、judge=独立评判、budget=护栏）。

2. **新建 `docs/loop-engineering.md`（概念正典）**
   - 五阶段解剖 `DISCOVER→PLAN→EXECUTE→VERIFY→ITERATE`，逐阶段标注承载命令。
   - 五构件 `auto-trigger / skill / sub-agent / connectors / verifier`，逐个标注「已实现 / 预留槽」。
   - 正确搭建顺序：手动跑通 → 存成 skill → 用 loop 包（闸门+停止）→ 上定时，对应 `peer` 各层。
   - 风险与护栏：token 复利、slop、采纳率（cost-per-accepted-change），讲清 `budget` 槽位的理由。
   - 含一张「旧名→新名」迁移小表。
   - 引用 `docs/agent-loop-三agent循环-提炼.md` 作来源/附录，不重复其内容。

3. **新建 `docs/glossary.md`（统一词汇表）**
   - 一处定义全部术语：loop / mission / round budget / verify / judge / gate / checkpoint /
     reframe / report / approval / budget。README、概念文档、specs、AGENTS.md 全部引用同一套词，
     消除「validation vs verify」「review vs judge」的同义漂移。

4. **`docs/AGENT-INSTRUCTIONS.md` + 注入块同步**
   - 注入进 `AGENTS.md` 的指令换成新命令名，并按三层重排，让 agent 看到的指令与文档/CLI 一致。
   - 注入块 marker 机制不变（`<!-- agent-duo:start -->` … `<!-- agent-duo:end -->`）。

5. **`agent-duo-supervisor-loop-roadmap.md` 收尾对齐**
   - 顶部加一段「术语已统一至 loop engineering 命名」的指针，不重写全文。

## 5. 迁移、测试与验收

### 改（命令面 + 文档层）

| 范围 | 动作 |
|---|---|
| `bin/peer` 调度器 | 重写参数路由为「名词-动词」两级分发；transport 与 steering 保持顶层单级 |
| CLI flag | `--validation`→`--verify`、`--review`→`--judge` |
| report/judge 拆分 | `report --type result --verdict` 处理路径搬到 `peer judge`；`report` 路径收窄 |
| 测试 | `test/peer.test.sh`、`loop.test.sh`、`integration.test.sh`、`approval.test.sh`、`registry.test.sh` 等中的 `peer …` 调用与调度器锁步改名 |
| 文档 | README ×2、新建 `loop-engineering.md` + `glossary.md`、`docs/AGENT-INSTRUCTIONS.md` 及注入块、roadmap 顶部指针 |

### 不改（限制爆炸半径）

- **磁盘 schema 与 lib 内部不动**：`.agent-duo/` 下 JSON 字段名（内部 `validation`/`review` 等）、
  `lib/*.sh` 函数名保持不变，只换 CLI 表层与面向用户字符串。理由：on-disk 是运行时临时态，
  改了只增风险无收益——这是「换门面」不是「换地基」。
- **顶层二进制名不变**：`peer`、`agent-duo-start` 不改 → Homebrew formula 不受影响。
- **transport 行为不变**：peek/tell/wait/esc/status 一字不动。
- **不新增能力**：budget 仅只读 stub；connectors / auto-trigger / 真·预算执行不在本次，
  文档如实标注为槽位。

### 迁移与验收门

1. 调度器改名与测试改名**锁步进行**（TDD：先改测试期望 → 再改调度器 → 跑绿）。
2. 验收门：`bash test/run.sh` 全绿 **且** `peer <noun> --help` 每个名词都能打印自述。
3. 不保留旧命令别名；旧名→新名迁移表放在 `loop-engineering.md`。

## 6. budget 薄 stub（预留槽）

- 新增 `peer budget status`，只读，打印形如「budget 护栏为预留能力，当前未启用」。
- 目的：把「护栏」这一构件立在命令面上，让「五构件」在 CLI 上不缺角；未来填实只改内部实现，
  命令面不再变。
- 不读写任何预算状态、不做任何拦截。

## 7. 明确不在范围（YAGNI）

- 真·预算执行 / TTL 租约 / `policy.toml`（roadmap MVP9）。
- connectors（自动开 PR、关联 ticket、频道 @）。
- auto-trigger 心跳 / 定时（`/loop`、`/schedule` 类）。
- on-disk JSON schema 字段改名、`lib/*.sh` 函数改名。
- 任何 transport 行为变化。

## 8. 开放问题

无（设计已逐段确认）。实现细节（report/judge 拆分时如何复用既有 report schema、
`peer judge` 的 target-ref 解析复用既有逻辑）在实现计划阶段细化。
