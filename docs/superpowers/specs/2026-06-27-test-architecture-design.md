---
title: "agent-duo 测试架构：子系统 × 真实度矩阵 + Journey"
date: 2026-06-27
status: implemented-design
tags: [testing, test-architecture, layering, journey, agent-duo]
related: 2026-06-27-loop-engineering-restructure-design.md
---

# agent-duo 测试架构：子系统 × 真实度矩阵 + Journey

## 1. 背景与动机

loop-engineering 命令面重构（见 `2026-06-27-loop-engineering-restructure-design.md`）落地后，
测试现状的三个结构性问题更突出：

1. **harness 重复**：tmux stub / `make_tmp` / `setup` / `run_peer` 在 `peer.test.sh`、
   `integration.test.sh`、`loop.test.sh` 各有一份拷贝，漂移风险高。
2. **monster 文件**：`peer.test.sh` 1583 行 / 534 断言，把所有 noun 混在一个扁平文件里；
   重构新增 verify/judge/budget/负向用例后只会更大。
3. **runner 简陋**：`run.sh` 只平铺 glob 跑完报 ALL/SOME，无选层、无计数、无隔离保证。

更深的隐患是「**测试全绿但实际使用出问题**」：unit/cli 各自 stub 太多，没有任何测试验证这些命令
**组合成真实用户工作流**时还能跑通。

本设计确立一套**子系统 × 真实度**的测试矩阵，并把「真实使用场景」（Journey）升为一等公民。
**核心是分层策略**：明确每层真跑什么、允许 stub 什么，让「stub 边界」从靠自觉变成靠结构。

## 2. 真实度梯子（纵轴）与每层 stub 契约

四级真实度，每级一条硬契约：

| 层 | 真跑什么 | 允许 stub | 禁止 | 入口 |
|---|---|---|---|---|
| **unit** | 单个 `lib/*` 函数 | 无外部进程 | 不准起 tmux/loopd/codex | `source lib/*.sh` 直调 |
| **cli** | 真 `bin/peer` dispatch | **仅** tmux（+ 时钟/随机/codec tag） | 不准 stub `lib/*`、不准跳过真实解析 | harness `run_peer` |
| **integration** | peer + loopd + lib 串起来真跑 | **仅** tmux 与外部 codex/claude 二进制 | 不准 stub `lib/loop.sh` 等内部 | `run_peer` + `run_loopd_once` |
| **e2e** | 真 codex hook / 真二进制 / 真 tmux | 几乎不 stub | — | `AGENT_DUO_E2E_*` 门控，缺能力 `skip` |

两条约定：

- **`bin/peer` 不进 unit 层**——它是脚本不是库，source 即触发 dispatch；其内部逻辑由 cli 层覆盖。
  纯算法型 helper 若值得单测，先下沉进 `lib/` 再在 unit 测（YAGNI：不为单测硬拆）。
- **e2e 门控沿用现有约定**——e2e 文件自带 `skip`：缺 `AGENT_DUO_E2E_*` / codex / `~/.codex/auth.json`
  即 exit 0 跳过，保证 `run.sh` 在任何机器上绿。

## 3. Journey（真实使用场景）测试 — 跨层一等公民

**定位**：不测单个命令，而是**照搬文档里告诉用户的完整工作流**端到端走一遍，断言**用户真正看到的输出**。
它横跨矩阵，落在两个真实度档：

| Journey 档 | 跑什么 | stub | 进 CI | 抓什么「绿但坏」 |
|---|---|---|---|---|
| **journey (integration)** | 真 `bin/peer` + 真 `lib/*` + 真 loopd 串完整流程 | 仅 tmux + 外部 LLM 二进制 | ✅ 默认跑 | 命令面**组合**断裂：各 noun 单测都过、但 `add→approval check→loop init→ask→report→judge→gate` 串起来某环对不上 |
| **journey (e2e)** | 真 tmux + 真 codex hook + 真 `start.sh` 起 pane | 几乎不 stub | ⛔ 门控，缺能力 skip | 真 tmux 粘贴/bracketed-paste 时序、真 codex 调 hook、真 pane 编排——纯 stub 测不到的那层 |

**CI 版场景**（`integration/journey-supervisor-loop.test.sh`，直接对应 README quickstart + plan-build-judge）：

```
起会话 → peer agent add codex:worker → peer approval check worker(就绪)
→ peer loop init worker --verify tests:... --judge reviewer:...
→ peer ask worker "..." → worker peer report → peer judge 验收
→ 命中 veto 保持 active → peer gate resolve → loop done
```

逐步断言**用户可见输出**（dashboard 行如 `verify=pass judge=reviewer:vetoed(...)`、`peer checkpoint`
摘要、各命令 stderr 提示），而非只查内部 JSON 字段。

**三条铁律**（防止 journey 退化成又一个永远绿的 stub 过家家）：

1. **从文档派生**：journey 的命令序列必须就是 README / `docs/AGENT-INSTRUCTIONS.md` 教用户敲的那串——
   文档变了 journey 跟着红，强制「文档=现实」。
2. **只 stub 不可避免的外部**（tmux、外部 LLM 二进制），内部 `lib/*` / loopd 一律真跑。
3. **断言用户视角**：看屏幕输出 / 退出码 / 提示，不看实现细节。

于是纵轴实际是 unit → cli → integration → **journey** → e2e，其中 journey 横跨 integration（CI 版）与
e2e（门控真跑版）两档。

## 4. 子系统 × 层 矩阵（稀疏）

✓ = 该子系统在该层有用例；稀疏是有意的，不强行填满。

| 子系统 \ 层 | unit | cli | integration | e2e |
|---|---|---|---|---|
| peer CLI dispatch (`bin/peer`) | — | ✓（按 noun 拆 12 文件） | ✓ | — |
| loop runtime (`lib/loop.sh`) | ✓ | — | ✓ | — |
| approval broker (`lib/approval_broker.sh`) | ✓ | ✓(`peer approval`) | — | ✓ |
| registry (`lib/registry.sh`) | ✓ | — | — | — |
| inject (`lib/inject.sh`) | ✓ | — | — | — |
| documentation contract (`docs/*`) | ✓ | — | — | — |
| start (`start.sh`) | — | — | ✓ | — |
| journey（跨子系统） | — | — | ✓(CI) | ✓(门控) |

## 5. 目录布局与文件拆分

```
test/
  lib/
    assert.sh                       # ← 由旧 test/assert.sh 平移
    harness.sh                      # ← tmux stub / make_tmp / setup·teardown
                                    #   / run_peer / run_peer_as / run_loopd_once / registry fixture
  unit/
    loop.test.sh                    # ← 由旧 loop.test.sh 平移
    broker.test.sh                  # ← approval.test.sh 中测 lib/approval_broker.sh 函数的部分
    registry.test.sh                # ← 平移
    inject.test.sh                  # ← 平移
    docs.test.sh                    # ← 当前文档契约结构回归
  cli/                              # 真跑 bin/peer，只 stub tmux —— peer.test.sh 按 noun 拆
    peer-transport.test.sh          #   peek/tell/wait/esc/status
    peer-steering.test.sh           #   ask/checkpoint/reframe
    peer-agent.test.sh              #   agent add/rm/ls
    peer-approval.test.sh           #   approval ls/approve/deny/status/check（CLI 部分）
    peer-loop.test.sh               #   loop init/show/reset
    peer-task.test.sh               #   task init/next/show
    peer-verify.test.sh             #   verify ls/show
    peer-judge.test.sh              #   judge / judge ls
    peer-gate.test.sh               #   gate ls/open/resolve
    peer-budget.test.sh             #   budget status
    peer-report.test.sh             #   report（收窄后）
    peer-aliases.test.sh            #   负向：旧命令全非 0 + 提示新名
  integration/
    supervisor-loop.test.sh         # ← 由旧 integration.test.sh 的分项断言平移
    journey-supervisor-loop.test.sh # ← 完整用户流程 journey（CI 版）
    start.test.sh                   # ← 平移
  e2e/
    codex-hook.test.sh              # ← 由旧 codex-hook-e2e.test.sh 平移（去名字里冗余 -e2e）
    codex-permreq.test.sh           # ← 由旧 codex-permreq-e2e.test.sh 平移
    journey-codex.test.sh           # ← journey 真 codex/真 tmux 门控骨架
  run.sh                            # 升级为层感知发现 + 选层（§7）
```

**老文件 → 新位置 映射**

| 现状 | 去向 | 备注 |
|---|---|---|
| `assert.sh` | `lib/assert.sh` | 平移 |
| `peer.test.sh`(1583) | `cli/peer-*.test.sh` ×12 | 按 noun 拆；内联 harness 抽走 |
| `loop.test.sh`(804) | `unit/loop.test.sh` | 平移（已是 unit 性质） |
| `approval.test.sh`(451) | `unit/broker.test.sh` + `cli/peer-approval.test.sh` | 按层拆：lib 函数 vs CLI |
| `integration.test.sh`(361) | `integration/supervisor-loop.test.sh` + 抽 `journey-supervisor-loop.test.sh` | 分项断言留原文件，端到端升为 journey |
| `registry.test.sh` / `inject.test.sh` | `unit/…` | 平移 |
| `start.test.sh` | `integration/start.test.sh` | 平移 |
| `codex-*-e2e.test.sh` | `e2e/codex-*.test.sh` | 平移 |

两个拆分判据：
- **peer.test.sh 按 noun 切**：一个 noun 一文件，对齐重构后命令面。
- **approval.test.sh 按层切**：测 `lib/approval_broker.sh` 函数→`unit/broker.test.sh`；测 `peer approval *`
  CLI→`cli/peer-approval.test.sh`——同一子系统跨两层，正是矩阵的体现。

## 6. 共享 harness 接口（`test/lib/harness.sh`）

把现在三份重复的 stub/setup 收成一份，并用**三个按层 setup** 把「这层允许 stub 什么」编码进调用名。

**核心原语**
```bash
harness_tmp                  # 建 SCENARIO_TMP；导出 PROJECT / AGENT_DUO_ROOT / OUT / ERR；不装任何 stub
harness_install_tmux_stub    # 把 tmux stub 写进 STUB_BIN 并前置 PATH（唯一一份 stub 实现）
harness_registry [rows...]   # 写 registry.tsv；默认 supervisor(%1,claude)+worker(%2,codex)
harness_broker_ready <id>    # 写 broker ready+nonce marker
teardown                     # rm -rf SCENARIO_TMP
```

**三个按层 setup（每个 test 文件 setup 一行，层政策即调用名）**
```bash
unit_setup        # = harness_tmp                                      # 零 stub、零进程
cli_setup         # = harness_tmp + harness_install_tmux_stub + harness_registry
integration_setup # = cli_setup（外加 run_loopd_once 可用）
```

**运行入口**
```bash
run_peer            [args...]   # 以 %1(supervisor/claude) 身份跑真 bin/peer，输出落 $OUT/$ERR
run_peer_as <pane>  [args...]   # 以指定 pane 身份跑（多 agent 场景）
run_loopd_once                  # 跑一次 loopd tick（仅 integration/journey 用）
```

**各层用法（契约即代码）**

| 层 | source | setup | 典型调用 | 结构性保证 |
|---|---|---|---|---|
| unit | `assert.sh`+`harness.sh` | `unit_setup` | `source lib/loop.sh` 后直调 | 没装 stub → 物理上起不了进程 |
| cli | 同上 | `cli_setup` | `run_peer verify ls worker` | 只 tmux 被 stub，`lib/*` 真跑 |
| integration/journey | 同上 | `integration_setup` | `run_peer …`+`run_loopd_once` | 内部全真，仅 tmux+外部二进制 stub |
| e2e | `assert.sh` | 自带 `skip` 门控 | 真 tmux/codex | 不碰 harness stub |

两个要点：
1. **tmux stub 单一真相源**——只在 `harness.sh` 一处实现；现有可调行为（capture 模式、sentinel、
   codec tag、on-send 回调）的 env 开关接口**平移不改语义**。
2. **unit 层物理隔离**——`unit_setup` 不装 stub、不建 STUB_BIN，所以 unit 测试想起进程也起不了，
   §2 的 stub 契约从「靠自觉」变「靠结构」。

## 7. `run.sh` 升级

**用法**
```bash
bash test/run.sh                      # 默认：unit → cli → integration → e2e（e2e 自跳过）
bash test/run.sh unit                 # 只跑 unit 层
bash test/run.sh cli integration      # 多层（仍按规范顺序）
bash test/run.sh e2e                  # 只跑 e2e（需 AGENT_DUO_E2E_* 否则各文件 skip）
```

**行为规则**
1. **发现**：按层目录 `unit/ cli/ integration/ e2e/` 各自 glob `*.test.sh`；无参数 = 四层全跑。
2. **顺序**：永远 unit → cli → integration → e2e（快→慢，先暴露底层失败）。
3. **e2e 门控不变**：e2e 自带 `skip`，默认跑也不会让 CI 变红。
4. **跑全不 fail-fast**：选定层内所有文件跑完再汇总。
5. **汇总**：按层 + 总计输出「通过/跳过/失败」计数；末尾**保留 `ALL TESTS PASSED` /
   `SOME TESTS FAILED` 哨兵行**（goal 命令与 CI grep 它，不可改）。
6. **skip 计数**：文件输出以 `skip ` 开头即记为 skipped，与 passed 区分，避免「e2e 没真跑」被误读成全过。

**输出形态（示意）**
```
── unit ──────────────  loop ✓  broker ✓  registry ✓  inject ✓  docs ✓
── cli ───────────────  peer-verify ✓  peer-judge ✓  … peer-aliases ✓
── integration ───────  supervisor-loop ✓  journey-supervisor-loop ✓  start ✓
── e2e ───────────────  codex-hook ⤬skip  codex-permreq ⤬skip  journey-codex ⤬skip
=====================================================
unit 5/5  cli 12/12  integration 3/3  e2e 0/3(3 skipped)
ALL TESTS PASSED
```

**不做（YAGNI）**：不引入并行、不引入 TAP/JUnit 输出、不做 watch 模式。

## 8. 迁移策略

铁律：**每阶段结束 `bash test/run.sh` 必须绿，且断言数不减**——绝不在搬动中悄悄丢覆盖。
现有 test 文件已是新命令面的断言（重构实现已落地），故本次是**搬运 + 拆分**，不是重写断言。

**前提（Phase 0）**：先确认当前 `test/run.sh` 全绿并提交，作为「已知良好」基线。

| Phase | 动作 | 验证 |
|---|---|---|
| 1 · 抽 harness | 建 `test/lib/assert.sh` + `test/lib/harness.sh`（三份 stub 拷贝收一份），现有文件改 source、删内联 dupe；`run.sh` 暂不动 | run.sh 绿；stub 行为不变 |
| 2 · 平移非拆分文件 | `git mv` loop/registry/inject→`unit/`、start→`integration/`、codex-*→`e2e/`；`run.sh` 升级为层感知发现（§7） | run.sh 绿；选层跑可用 |
| 3 · 拆 peer monster | `peer.test.sh`→`cli/peer-*.test.sh` ×12（按 noun 切，断言原样搬） | run.sh 绿 + 断言数 == 拆前 |
| 4 · 拆 approval | →`unit/broker.test.sh` + `cli/peer-approval.test.sh`（按层切） | run.sh 绿 + 断言数守恒 |
| 5 · 拆 integration | →`integration/supervisor-loop.test.sh` + 抽 `journey-supervisor-loop.test.sh` 骨架 | run.sh 绿 |
| 6 · 写 journey（新覆盖） | `journey-supervisor-loop.test.sh` 照 README/loop 流程端到端断言用户可见输出；`e2e/journey-codex.test.sh` 门控骨架 | run.sh 绿；journey 反向自检通过 |
| 7 · 收尾 runner | `run.sh` 选层/汇总/skip 计数定稿，保留哨兵行 | run.sh 绿；哨兵不破 |

**两个迁移护栏**
1. **断言守恒**：拆分前后 `grep -rc 'assert_' test/<相关文件>` 总数不减（journey 阶段只增不减）。
2. **journey 反向自检**（Phase 6）：故意改坏某 noun 命令面，确认 journey 会变红——证明它真能抓
   「绿但坏」，而非又一个永远绿的摆设。改坏验证后**还原**。

## 9. 明确不在范围（YAGNI）

- 不重写现有断言逻辑（只搬运/分区）。
- 不改 `bin/peer` / `lib/*` 实现（除非 journey 暴露真 bug，那另开修复）。
- 不引入新测试框架、不并行、不 TAP/JUnit、不 watch。
- 不为 unit 而硬拆 `bin/peer`（只在 helper 本就该下沉到 `lib/` 时才下沉）。

## 10. 开放问题

无（设计已逐段确认）。实现细节（harness 的 env 开关逐项平移清单、各 cli/peer-*.test.sh 的断言归属切分）
在实现计划阶段细化。
