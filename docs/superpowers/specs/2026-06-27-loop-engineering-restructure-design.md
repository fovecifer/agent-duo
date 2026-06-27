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

项目处于 pre-1.0，**可自由破坏**。不保留任何旧命令别名（**包括不保留 `peer loop <id>`
裸调用 shorthand**——一律走 `peer loop show <id>`）；旧名→新名的对照仅以文档形式提供。

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
| `peer peek [<id>] [lines]` | `peer peek [<id>] [lines]` |
| `peer tell [--force] [<id>] "…"` / stdin | `peer tell [--force] [<id>] "…"` / stdin（`--force` 跳过权限弹窗检测/broker 硬门，保留） |
| `peer wait [<id>] [s] [interval] [stable]` **及** `peer wait <id> --round N [--timeout 秒] [--interval 秒]` | 同左**全部保留**（`--round` 回合边界等待是测试覆盖的能力，不可丢） |
| `peer esc [<id>] [--force]` | `peer esc [<id>] [--force]` |
| `peer --force tell/esc`（前置 `--force` 形式） | 保留 |
| `peer status` | `peer status` |

### 第 3 层 · Steering（顶层热路径，不变）

| 现在 | 之后 |
|---|---|
| `peer ask [<id>] "…" [--timeout N] [--interval N] [--force]` | 同左**全部保留**（id 可省略、`--timeout`/`--interval`/`--force` 不可丢） |
| `peer checkpoint [<id>] [--json]` | `peer checkpoint [<id>] [--json]`（id 可省略） |
| `peer reframe [<id>] "…" [--force]` | `peer reframe [<id>] "…" [--force]`（id 可省略） |

### 第 2 层 · Loop building-blocks（重构主体）

| 现在 | 之后 | 说明 |
|---|---|---|
| `peer add --provider … --role … [--id] [--worktree]` | `peer agent add …` | 编队收进 `agent` 名词 |
| `peer rm [--force] <id>` | `peer agent rm [--force] <id>` | |
| `peer ls` | `peer agent ls` | **既有 `peer ls` 改名**（非新增）；`peer status` 内部对 `ls` 的调用同步改到新 dispatch（grep `bin/peer` 中 `status` 分支对 `ls` 的内部调用） |
| `peer loop init <id> --mission … --max-rounds N [--non-goal …] [--success …] [--round N] [--validation id:cmd] [--validation-satisfies …] [--validation-timeout …] [--review role:veto] [--detail-trap-rounds N]` | `peer loop init <id> --mission … --max-rounds N [--non-goal …] [--success …] [--round N] [--verify id:cmd] [--verify-satisfies …] [--verify-timeout …] [--judge role:veto] [--detail-trap-rounds N]` | 契约 flag **整族**改名对齐名词：`--validation`→`--verify`、`--validation-satisfies`→`--verify-satisfies`、`--validation-timeout`→`--verify-timeout`、`--review`→`--judge`；这些**及 `--non-goal`/`--success`/`--round`/`--detail-trap-rounds` 均可选**（`--verify`/`--judge` 缺省即「契约无闸门」，对应 §6.1 `no_gates`）；`--non-goal`/`--success`/`--round`/`--detail-trap-rounds` 原样保留不改名 |
| `peer loop <id>` | `peer loop show <id>` | 显式动词；**不保留 `peer loop <id>` 裸调用 shorthand**（见 §1 无别名规则） |
| `peer loop reset <id> [--max-rounds N]` | `peer loop reset <id> [--max-rounds N]` | 不变 |
| `peer task init <id> --task … --step …` | `peer task init <id> …` | PLAN 账本，保持 `task` 名词 |
| `peer task next <id>` | `peer task next <id>` | |
| `peer task [<id>]`（裸调用 = 查看 ledger，`task_print`） | `peer task show [<id>]` | **补映射**：现有裸 `peer task <id>` 查看入口按无-shorthand 规则改显式动词 `show`（对齐 `loop show`）；`test/peer.test.sh` 里 `peer task worker` 改 `peer task show worker` |
| *(藏在 `loop --validation`)* | `peer verify ls <id>` / `peer verify show <id>` | verifier 升为一等名词；声明仍在契约（`loop init --verify`），查看走 `peer verify`（输出契约见 §6.1） |
| `peer report --type result --verdict approve --target-ref worker@N [--round R] [--finding …]` | `peer judge <target-ref> --verdict approve [--round R] [--finding …]` / `peer judge ls <id>` | 判定从 report 拆出，独立对抗式评判成独立名词；`--round` 可选（缺省 auto next-round），**产出物与行为不变**，见 §6.2 |
| `peer report --type request --status blocked --needs decision …` | `peer report --type request --status blocked --needs decision …` | report 收窄为「worker 真实进度」专用，不再承载 verdict |
| `peer gate [--all]` | `peer gate ls [--all]` | `--all` flag 保留迁到 `ls` |
| `peer gate open …` / `peer gate resolve --choice …` | `peer gate open …` / `peer gate resolve --choice …` | 不变 |
| `peer approvals [--all]` | `peer approval ls [--all]` | 整个 Approval Broker 并入 `approval` 名词；`--all` 保留迁到 `ls` |
| `peer approve <id>` / `peer deny <id> [--reason …]` | `peer approval approve <id>` / `peer approval deny <id> [--reason …]` | `--reason` flag 保留迁到 `approval deny` |
| `peer broker-status [<id>]` | `peer approval status [<id>]` | **broker 命令并入 `approval`**（broker 与 approve/deny 同属一个构件，不另立 `broker` 名词） |
| `peer broker-check [<id>] [--nonce …]` | `peer approval check [<id>] [--nonce …]` | 同上；`start.sh` 等启动引导文案同步改为新名（见 §5 scope） |
| *(无，MVP9 未建)* | `peer budget status` | 预留槽：只读薄 stub（见 §6） |

### 运行时内部命令（不属三层用户面，保留不改名）

- **`peer loopd`** — 运行时守护入口（`bin/peer` 里 `exec scripts/loopd "$@"`），由 `start.sh` 启动的 loopd
  pane 执行，负责 cursor 投递 / liveness-tick / 看板。它**不是用户敲的 loop 动词**（与 `peer loop` 契约名词无关），
  属基础设施层，**保留为内部顶层命令、不改名、不收进任何名词组**。两级 dispatch 改写时必须**保留 `loopd` 这条顶层分支**；
  `start.sh` 的 `peer loopd` 启动行与相关测试纳入验收（见 §5）。

### 实质改动（已确认）

1. **契约 flag 整族改名**：`--validation` / `--validation-satisfies` / `--validation-timeout` → `--verify*`，
   `--review`→`--judge`（仅 CLI flag 名；on-disk 字段不动）。
2. **report / judge 拆分**：`report --type result --verdict`（评判语义）搬到独立的 `peer judge`；
   `report` 从此只是 worker 的真实进度通道。把「制造者的声音」与「检查者的裁决」在命令面彻底分开，
   呼应文档「制造者远离检查者」。落盘产出物不变（§6.2）。
3. **verifier 声明/查看分离**：validations 仍在 `loop init` 冻结（契约不可变），
   新增 `peer verify ls/show` 作为只读名词面（§6.1）。
4. **Approval Broker 收口为单一 `approval` 名词**：`approvals`/`approve`/`deny`/`broker-status`/`broker-check`
   全部并入 `peer approval <verb>`；连带 `start.sh` 等启动引导文案改名，避免引导已删除命令。

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
     reframe / report / approval / budget。**新建/本次改动的文档与当前 agent 指令**
     （README ×2、`loop-engineering.md`、`docs/AGENT-INSTRUCTIONS.md` 注入块、本 spec）引用同一套词，
     消除「validation vs verify」「review vs judge」的同义漂移。
   - **历史 specs 不回改**：`docs/superpowers/specs/` 下既往设计文档保留其写作时的术语（属历史记录），
     不强制套用新词汇表，避免制造虚假的全树改写要求。

4. **`docs/AGENT-INSTRUCTIONS.md` + 注入块同步**
   - 注入进 `AGENTS.md` 的指令换成新命令名，并按三层重排，让 agent 看到的指令与文档/CLI 一致。
   - 注入块 marker 机制不变（`<!-- agent-duo:start -->` … `<!-- agent-duo:end -->`）。

5. **`agent-duo-supervisor-loop-roadmap.md` 收尾对齐**
   - 顶部加一段「术语已统一至 loop engineering 命名」的指针，不重写全文。

6. **用户可见输出标签同步改词（决策项）**
   - `loop_print` / `checkpoint` / loopd dashboard 等**打印给人看的字符串**里的
     `VALIDATION`→`VERIFY`、`ACCEPTANCE`→`JUDGE`、`validation=…`→`verify=…`、`accept=…`→`judge=…`
     一并改词，否则 CLI 名词是 `verify`/`judge`、看板却仍印 `validation`/`accept`，正是本 spec 要消灭的漂移。
   - **边界（结构化键冻结 vs 人类文案改词）**：
     - **冻结（不改）**：event `type`（仍 `review_required` / `validation_pass` / `validation_fail`）、
       event_id（仍 `reviewreq-…` / `validation-…`）、JSON 字段名（`validation`/`status`/`verdict` 等）、
       `.agent-duo/` 记录结构——这些是被解析的结构化键（守 §5「换门面不换地基」）。
     - **改词（人类可读文案）**：上述显示标签，**以及 event 的人类 `summary` prose**——
       runtime queue 里 `summary="review pending: …"` / `"review vetoed: …"` / `"validation pass: N/total"`
       这类展示给 supervisor 的散文，改为 `judge pending/vetoed` / `verify pass: …`。summary 虽落盘，
       但它是**人类文案而非解析键**，统一改词；事件 `type`/`id` 不变保证解析方不受影响。
   - 受影响的输出断言（如集成测试里 `validation=pass accept=reviewer:vetoed(...)` 一行、以及 summary prose 断言）
     **与改词锁步更新**。

## 5. 迁移、测试与验收

### 改（命令面 + 文档层）

| 范围 | 动作 |
|---|---|
| `bin/peer` 调度器 | 重写参数路由为「名词-动词」两级分发：`loop`/`agent`/`approval`/`verify`/`judge`/`gate`/`budget`/`task` 走两级（含**关键的 `peer loop show <id>`**）；transport 与 steering 保持顶层单级；`report` 为 **flag-style 名词**（`peer report --type …`，不带子动词，见下注）；**`loopd` 顶层分支必须原样保留**（运行时入口） |
| 名词内小 flag 保留 | `gate ls [--all]`、`gate open … [--round N]`、`approval ls [--all]`、`approval deny [--reason …]`、`task show [<id>]`、`task init [--round N]`、`agent rm [--force] <id>`（`--force` 前/后置都保留）、`wait <id> --round N [--timeout] [--interval]`、`ask [--timeout][--interval][--force]`、`tell/esc [--force]`——迁到新动词时**逐个保留原 flag/变体**，不得丢失 |
| 用户可见文案改词 | 显示标签 `VALIDATION`/`ACCEPTANCE`/`validation=`/`accept=` → `VERIFY`/`JUDGE`/`verify=`/`judge=`，**外加 runtime event 的人类 `summary` prose**（`review pending/vetoed`→`judge …`、`validation pass`→`verify …`）；event `type`/`id`/字段名不动（见 §4.6），相关输出与 summary 断言锁步改 |
| CLI flag 整族 | `--validation`→`--verify`、`--validation-satisfies`→`--verify-satisfies`、`--validation-timeout`→`--verify-timeout`、`--review`→`--judge` |
| report/judge 拆分 | `report --type result --verdict` 处理路径搬到 `peer judge`；`report` 路径收窄（产出物不变，见 §6.2） |
| broker 命令并入 | `broker-status`→`approval status`、`broker-check`→`approval check`；调度与内部提示文案同步 |
| 启动引导文案 | `start.sh` 里的 `peer broker-check` 引导、`bin/peer` 内 `peer add` 之后及 broker 硬门拒发时打印的提示串改为新命令名（grep 全仓 `broker-check`/`broker-status`/`peer approvals`/`peer approve`/`peer deny`/`peer ls`/`peer loop <id>` 逐处替换），避免引导用户敲已删除命令 |
| 测试 | `test/peer.test.sh`（含 `peer task worker`→`peer task show worker`）、`loop.test.sh`、`integration.test.sh`、`approval.test.sh`、`registry.test.sh`、`start.test.sh`（含 `peer loopd` 启动行）等中的 `peer …` 调用与调度器锁步改名 |
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
2. 验收门：`bash test/run.sh` 全绿 **且** `peer <noun> --help` 每个名词都能打印自述并 **exit 0**——
   含两级动词名词（`loop`/`agent`/`approval`/`verify`/`judge`/`gate`/`budget`/`task`）**与 flag-style 的
   `report`**（`peer report --help` 同样必须 exit 0；它是保留的 flag-style 名词，不走两级动词）。
3. 不保留旧命令别名；旧名→新名迁移表放在 `loop-engineering.md`。

## 6. 新读命令的输出契约

### 6.1 `peer verify`（verifier 的只读名词面）

读取对象就是 runtime 现有的产出物，不新增存储：

**轮次选取规则**（两命令一致）：默认跟随该 worker 的**当前 report round**
（读 `state/<id>/report.json` 的 round，即 `ad_loop_report_round`）；`--round N` 显式覆盖。
**不**取「磁盘上最大 N」——避免显示一个 worker 尚未汇报的轮次。
**无 report 时 round 取 `0`**（与 `ad_loop_report_round` 的 `.round // 0` 行为一致），
此时全部闸门为 `pending`，JSON wrapper 的 `"round"` 字段即为整数 `0`（不省略、不为 null）。

**每个闸门在选定轮次 R 的状态**按磁盘事实映射。**注意**：`validation-rR.json` 的**顶层 `status`
是整轮汇总**（任一闸门 fail → 整轮 fail），**不能**拿来当单个闸门状态；单闸门状态在该文件的
**`results[]` 数组里按 gate `id` 匹配** `results[].status`（`lib/loop.sh` 逐 validation 产出
`{id,cmd,status,…,satisfies}` append 进 `results`）。

| 磁盘事实 | 该闸门显示状态 |
|---|---|
| `validation-rR.json` 存在，且 `results[]` 中有匹配 `id` 的项 | 用该项的 `results[].status`（`pass`/`fail`/`error`） |
| `validation-rR.json` 存在，但 `results[]` 无匹配 `id`（声明了却没结果） | `not_run` |
| 只有 `validation-rR.running`（无 `.json`） | `running` |
| 两者都没有，但 worker 已有 report（report.json 存在） | `not_run` |
| 契约声明了闸门但该 worker 还没有任何 report（report.json 不存在） | `pending` |

顶层 round summary 仅用于 `show` 的整轮一行摘要，不下放到单闸门。

- `peer verify ls <id> [--round N] [--json]` — 列出契约声明的 verify 闸门 id + 各自在「当前/指定轮次」的上表状态（一行一闸门）。
  契约里没声明任何闸门 → 打印空集并提示、退出 0；**无 loop 契约**（`loop.json` 不存在）→ 非 0 退出并提示先 `peer loop init`。
- `peer verify show <id> [--round N] [--json]` — 同 `ls` 的口径与退出语义，但展开每个闸门的 cmd/satisfies/结果记录，并附整轮 summary 一行。
- **`ls` 与 `show` 都支持 `--round N` 与 `--json`**。**`--json` 下二者输出完全相同**——同一个
  wrapper（含 `gates[]`，每个 gate 带**完整 `result` 对象**，有记录时非 null）。`ls` 与 `show` 的差异
  **仅体现在人类可读文本**：`ls` 一行一闸门紧凑列表、`show` 展开 cmd/satisfies/result 并附整轮 summary 行。
  这样测试可断言「`ls --json` == `show --json`」，不存在分叉。
- 两命令**只读**，不触发验证执行（验证由 loop runtime 在轮次推进时跑，本次不引入手动 `verify run`）。

**`--json` 稳定 wrapper schema**（因 pending/not_run/running 时无 `validation-rN.json` 原始记录可吐，
必须用固定外壳，`result` 字段在无记录时为 `null`）：

```json
{
  "agent": "worker",
  "round": 3,
  "round_status": "pass|fail|error|running|not_run|pending|no_gates",
  "gates": [
    { "id": "tests", "cmd": "…", "satisfies": ["…"],
      "status": "pass|fail|error|running|not_run|pending",
      "result": null }
  ]
}
```

- **`round_status`（顶层整轮汇总）**：当 `validation-rN.json` 存在时取其顶层 `status`；否则取该轮的派生态
  （全 `pending` → `pending`、有 `.running` → `running`、声明了但未跑 → `not_run`）。供 JSON 消费者直接读整轮结论，
  无需自行聚合 `gates[]`。`ls` 与 `show` 的 `--json` 共用此 wrapper（per-gate + 顶层 summary 都在），schema 不分叉。
- **契约无闸门**（`gates: []`）：`round_status` 取专用值 **`no_gates`**（不复用 `not_run`/`pass`，语义更清晰），
  仍**退出 0**；文本模式打印空集提示。`no_gates` 是 `round_status` 取值集里仅当 `gates` 为空时出现的额外值。
- `cmd` / `satisfies` 取自冻结契约的闸门声明；**`satisfies` 为数组**（与 contract/result 一致，
  `lib/loop.sh` 的 validation 执行逻辑已用 `map(tostring)` 把 satisfies 规整为数组，空时为 `[]`）；`status` 按上表映射（来自 `results[]` 匹配项）；
  `result` 仅当该闸门在 `validation-rN.json` 的 `results[]` 中有匹配项时为该项对象，否则 `null`。
- `gates` 为契约声明顺序；契约无闸门则为 `[]`。`--json` 下「无 loop 契约」仍非 0 退出（与文本模式一致）。

### 6.2 `peer judge`（产出物与现状一致，仅换命令名）

`peer judge` 复用 `report --type result` 的**内部落盘逻辑**，但**不是转调公开的 `peer report`**——
否则旧命令面等于没删。实现口径定死：

- 把今天 `report` 路径里处理 verdict 的那段抽成**私有 helper / 内部函数**（如
  `_emit_result_report`），`peer judge` 与（历史的）result 路径都调它——**文件结构、字段语义、事件顺序与现状一致**
  （时间戳 / event id / sentinel sha 等运行时值天然不同，命令名变化也不落盘，不在此承诺范围）。
- **公开 `peer report` 必须 fail-closed 拒绝 `--verdict` / `--target-ref` / `--finding`**：
  这三个 flag 从 `peer report` 的参数解析里移除，遇到即报错非 0 退出，引导改用 `peer judge`。
  即 `report` 在命令面上**真的不再承载 verdict**（呼应 §1 无别名 + §3 拆分）。
- **新增测试覆盖**：`peer report --verdict …` 被拒（fail-closed、不写任何文件）；
  `peer judge …` 的落盘与既有 verdict 断言等价（路径/字段/事件不变）。

**CLI 契约：**

```
peer judge <target-ref> --verdict V [--round R] [--status done] [--finding sev:note]… \
           [--delta …] [--evidence-cmd/--evidence-result/--evidence-ref …] \
           [--step/--step-ref sN] [--goal/--goal-ref …] [--drift …] [--next …]
```

- **必填**：位置参数 `<target-ref>`（= `--target-ref worker@N`）、`--verdict V`。
- **可选 `--round R`**：评判方**自己**的轮次；**缺省时沿用既有 `report` 行为**——
  自动取该评判方 state 目录的下一轮（复用既有 `next_report_round`）。集成测试里 reviewer
  显式给 `--round 1` / `--round 2` 是允许而非强制。
- **默认注入**：`--type result`；`--status` 默认 `done`，可显式覆盖。
- **透传（result 报告的全部有意义 flag）**：`--finding`（可重复）、`--delta`、`--evidence-*`、
  以及 `--status`、`--step/--step-ref`、`--goal/--goal-ref`、`--drift`、`--next` 原样转发给既有 result 落盘逻辑
  （这些都是 `write_report_json` 真实写入的字段：`goal_ref`/`step_ref`/`drift`/`next` 等）。
- **judge 拒绝的 flag**（分三类，各有不同原因）：
  - `--needs`/`--needs-kind`/`--needs-detail`/`--needs-option` —— 属 `peer report --type request`
    （开 Human Decision Gate）的语义，与「记录一条 verdict」无关，judge 不暴露。
  - `--type` —— 由 judge 固定注入 `result`，不接受外部覆盖。
  - 显式 `--target-ref` —— judge 的目标走**位置参数 `<target-ref>`**（等价旧 `--target-ref`），
    因此不再接受 flag 形式，避免位置参数与 flag 两条入口冲突。
- **缺参 fail-closed**：缺位置参数 `<target-ref>` 或缺 `--verdict` 即报错、不写任何 report
  （复用既有耦合校验逻辑）。实现上 judge 先把位置参数 `<target-ref>` 规范化为内部
  `target_ref`（`worker@N`）再交给私有 helper，校验口径与旧 `--target-ref` 路径一致。

**status 降级规则继承（不要踩坑）：** 默认传 `--status done`，但走的就是既有 result 路径，
因此**继承「`done`/`partial` 且无任何 `--evidence-*` → 降级为 `unknown`」**（既有 result 路径里
计算 `effective_status` 的那段降级逻辑）。
即不带 evidence 的 `peer judge … --verdict approve` 落盘后评判方自身 report 的 `status` 是 `unknown`。
**但这与 verdict 无关**：路由到目标 worker 的 verdict 记录里 `verdict` 字段照实为 `approve`/`request_changes`，
不受 status 降级影响（集成测试中无 evidence 的 `approve` 仍断言路由 verdict 记录 `verdict==approve`）。
本次**不**改默认 status，也**不**改降级规则——如实继承，避免测试预期错位。

**落盘产出（与今天 `report --type result --verdict` 文件结构/字段语义/事件顺序一致）：**

1. 评判方自身的 report 记录（`state/<reviewer-role>/rR.json`，含 `verdict` / `target_ref` / `findings`）;
2. 路由到目标 worker 的 verdict 记录（`state/<worker>/reviews/<reviewer-role>-r<targetN>.json`，含
   `verdict` / `by` / `role` / `target_round`）;
3. 既有 sentinel **+ 评判方自己的 `result` runtime event**。

**事件边界（重要，避免与 loopd 重复）：** `peer judge` **只**写评判方自己的 `result` event
（`event_type_for_report` result/done），**绝不**直接发 `review_required`。目标 loop 的 `review_required`
仍由 loopd 在读取上述路由 verdict 记录后派生（`ad_loop_acceptance_emit_review_required`），
事件来源与顺序均不变。

**`peer judge ls <id>` 最小契约：**

- **列出**：路由到该 worker 的全部 verdict 记录（`state/<worker>/reviews/<reviewer-role>-r<targetN>.json`），
  每条含 `verdict` / `by` / `role` / `target_round`。
- **排序**：`target_round` 倒序为主键；同一 `target_round` 内按记录时间倒序；仍并列时以 `role` 升序兜底，
  保证**确定性**（测试可稳定断言顺序）。
- **目标不存在**（`<id>` 不是已注册 agent）→ **非 0 退出** + 错误提示（与其它命令的未知 id 口径一致）。
- **目标存在但无任何 verdict** → **退出 0**，文本模式打印空集提示、`--json` 输出空数组 `[]`。
- **`--json` 支持**：输出 `[{verdict, by, role, target_round, ref}, …]`（同上排序）；`ref` 为该 verdict 记录的相对路径。

因此 `test/peer.test.sh` / `test/integration.test.sh` 中针对 verdict 落盘的断言只需把被测命令从
`report --type result --verdict …` 改成 `judge … --verdict …`，断言的文件路径、字段、事件序列均不变。

## 6.3 budget 薄 stub（预留槽）

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

无。原先悬而未决的两点已在 review 后定稿：

- **judge 落盘语义** → §6.2：文件结构/字段语义/事件顺序与现状一致，仅换命令名（产出三类记录不变）。
- **verify ls/show 输出契约** → §6.1：只读现有 `validation-rN.json`，不引入手动执行。

实现阶段仅需细化 `bin/peer` 两级 dispatch 的具体改法与提示文案逐处替换清单。
