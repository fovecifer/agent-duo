# Loop Engineering 设计哲学与佐证资料

本文解释 `agent-duo` 为什么要被设计成“可见 live-session supervisor harness”，而不是一个简单的 agent 互聊器。内容基于本仓库已有设计文档与源码实现，并补充公开资料、官方文档和研究论文作为佐证。

## 1. 核心判断

Loop engineering 的重点不是“把同一句 prompt 重复跑很多次”，而是把过去由人手动完成的流程系统化：

```text
提出目标 -> 拆解计划 -> 执行 -> 观察结果 -> 验证 -> 纠偏 -> 再执行 -> 停止或升级
```

一个好 loop 至少需要：

- 明确目标和非目标。
- 可持久化的状态。
- 有界轮次和停止条件。
- 自动或半自动验证。
- 独立评判。
- 人类决策点。
- 工具权限控制。
- 审计记录。

`agent-duo` 的产品判断是：

> 不做无人监督的 agent 互聊器，而做由 supervisor 调度 worker、由 verify/judge/gate 约束完成条件的可见 loop engineering 框架。

如果要看这套方法如何从一句需求落到一个真实产品，请先读实际案例：[Loop Engineering 实际用例：多 Agent 从 0 做出一个产品](LOOP-ENGINEERING-PRODUCT-CASE.zh-CN.md)。它用 `planner`、`builder`、`reviewer`、`evaluator` 四个 agent 演示 plan/build/judge 循环如何做出一个本地优先的小产品。

## 2. 本地设计来源

本仓库已有材料已经形成了完整脉络：

- [docs/agent-loop-三agent循环-提炼.md](agent-loop-三agent循环-提炼.md)：把 plan/build/judge 三角色、verifier、memory、成本风险整理成 loop engineering 原型。
- [agent-duo-supervisor-loop-roadmap.md](../agent-duo-supervisor-loop-roadmap.md)：提出 agent-duo 从 peer transport 进化成 supervisor harness 的方向。
- [docs/loop-engineering.md](loop-engineering.md)：把命令面整理成 DISCOVER/PLAN/EXECUTE/VERIFY/ITERATE 五阶段。
- [docs/glossary.md](glossary.md)：统一 loop、verify、judge、gate、approval、budget 等术语。
- [docs/superpowers/specs/2026-06-17-worker-supervisor-contract.md](superpowers/specs/2026-06-17-worker-supervisor-contract.md)：定义 worker -> supervisor report 与 supervisor -> worker direction 的协议。
- [docs/superpowers/specs/2026-06-17-loop-runtime-design.md](superpowers/specs/2026-06-17-loop-runtime-design.md)：定义 loop runtime、水线、事件队列、liveness、tick。
- [docs/superpowers/specs/2026-06-17-approval-broker-design.md](superpowers/specs/2026-06-17-approval-broker-design.md)：把权限请求接入 loop，而不是模拟按确认键。
- [docs/superpowers/specs/2026-06-21-supervisor-loop-mvp5-design.md](superpowers/specs/2026-06-21-supervisor-loop-mvp5-design.md)：定义 `peer loop init`、`peer ask`、round budget、stop。
- [docs/superpowers/specs/2026-06-21-loop-validation-success-signals-mvp-design.md](superpowers/specs/2026-06-21-loop-validation-success-signals-mvp-design.md)：定义 verify gate 与 success signal。
- [docs/superpowers/specs/2026-06-21-acceptance-veto-design.md](superpowers/specs/2026-06-21-acceptance-veto-design.md)：定义 judge verdict 与 veto。
- [docs/superpowers/specs/2026-06-21-direction-control-mvp8-design.md](superpowers/specs/2026-06-21-direction-control-mvp8-design.md)：定义 checkpoint、reframe、detail trap 与 direction drift。
- [docs/superpowers/specs/2026-06-27-loop-engineering-restructure-design.md](superpowers/specs/2026-06-27-loop-engineering-restructure-design.md)：把命令面重构为 Transport、Loop building-blocks、Steering 三层。
- [docs/superpowers/specs/2026-06-27-nl-mission-orchestration-design.md](superpowers/specs/2026-06-27-nl-mission-orchestration-design.md)：定义自然语言 mission 入口、supervisor playbook、可复用角色定义和 stop-hook 合门硬门。

## 3. 外部资料

### 3.1 官方与行业资料

- Anthropic Claude Code 文档：[Hooks](https://docs.anthropic.com/en/docs/claude-code/hooks)、[Memory](https://docs.anthropic.com/en/docs/claude-code/memory)、[Subagents](https://docs.anthropic.com/en/docs/claude-code/sub-agents)、[Settings](https://docs.anthropic.com/en/docs/claude-code/settings)。这些资料证明现代 coding agent 已把 hooks、项目记忆、子 agent 与设置作为一等工作流能力，而不是只依赖一次性 prompt。
- Anthropic YouTube：[Reflecting on a year of Claude Code](https://www.youtube.com/watch?v=Hth_tLaC2j8)、[Build Agents That Run for Hours](https://www.youtube.com/watch?v=mR-WAvEPRwE)。本仓库的三角色 loop 提炼主要来自这两类官方内容：长期运行、独立评估、真实工具验证、结构化交接。
- OpenAI Codex 文档：[Hooks](https://developers.openai.com/codex/hooks)、[AGENTS.md guide](https://developers.openai.com/codex/guides/agents-md)、[Build iterative repair loops with Codex](https://developers.openai.com/cookbook/examples/codex/build_iterative_repair_loops_with_codex)。这些资料对应 agent-duo 里的 Codex hook 接入、项目指令注入、以及“失败 -> 修复 -> 再验证”的迭代修复模式。
- Addy Osmani 关于 AI agent / loop engineering 的公开讨论和文章：[agentic workflows](https://addyo.substack.com/) 与相关公开帖。本文只把其中“成本、质量、slop、verifier、budget guard”作为行业风险提示，不把具体商业产品宣传视为技术背书。

### 3.2 研究论文

- ReAct: [Synergizing Reasoning and Acting in Language Models](https://arxiv.org/abs/2210.03629)。ReAct 把 reasoning trace 和 action 交替，说明 agent loop 需要“思考-行动-观察”的闭环，而不只是静态回答。
- Reflexion: [Language Agents with Verbal Reinforcement Learning](https://arxiv.org/abs/2303.11366)。Reflexion 强调通过外部反馈和语言记忆改进下一轮，支持 agent-duo 把 report、task、checkpoint 存在文件系统而非只放上下文。
- Self-Refine: [Iterative Refinement with Self-Feedback](https://arxiv.org/abs/2303.17651)。Self-Refine 证明“生成 -> 反馈 -> 修改”的循环结构有效，但 agent-duo 进一步要求外部 verify/judge，避免单一 agent 自评过宽。
- Generative Agents: [Interactive Simulacra of Human Behavior](https://arxiv.org/abs/2304.03442)。该工作使用外部记忆、反思和计划组件，佐证长期 agent 系统需要模型外状态。
- LLM-as-a-Judge: [Judging LLM-as-a-Judge with MT-Bench and Chatbot Arena](https://arxiv.org/abs/2306.05685)。该方向说明 LLM 可以承担评估角色，但也提醒评估器本身需要明确 rubric 与独立上下文。

这些资料共同支持一个结论：可靠 agent loop 不是“更长上下文 + 更强模型”自动得到的，而是系统工程。

## 4. 五阶段 loop

agent-duo 把 loop engineering 映射为五阶段：

| 阶段 | 目标 | agent-duo 表面 |
| --- | --- | --- |
| DISCOVER | 读现状、找事实、理解约束 | `peer peek`、`peer checkpoint`、`peer task show` |
| PLAN | 冻结任务、成功标准、预算 | `peer task init`、`peer loop init` |
| EXECUTE | 派发、执行、汇报 | `peer ask`、`peer tell`、`peer report` |
| VERIFY | 机械验证与独立验收 | `peer verify`、runtime verify gates、`peer judge` |
| ITERATE | 纠偏、续预算、人工决策 | `peer reframe`、`peer loop reset`、`peer gate resolve` |

五阶段的重点是让每轮都有“下一步为什么继续或停止”的证据，而不是靠 worker 自信判断。
当前实现还增加了自然语言入口：用户可按 [mission-template.md](mission-template.md) 给 supervisor 一份 mission，
supervisor 再按 [SUPERVISOR-LOOP-PLAYBOOK.md](SUPERVISOR-LOOP-PLAYBOOK.md) 把 goal/done/non-goals 物化为
planner/builder/reviewer/evaluator 编队、verify gate、judge gate、Human Gate 和最终证据汇报。

## 5. 三层命令面

### 5.1 Transport

Transport 是 agent-duo 的最小能力：

- `peer peek`
- `peer tell`
- `peer wait`
- `peer esc`
- `peer status`

它只负责看屏、发字、等待稳定、打断。Transport 不理解任务是否完成，也不负责验收。

### 5.2 Loop Building Blocks

Building blocks 是 loop 的控制面：

- `peer agent`
- `peer task`
- `peer loop`
- `peer verify`
- `peer judge`
- `peer report`
- `peer gate`
- `peer approval`
- `peer budget`

它们把原本散落在对话里的“任务、轮次、验收、权限、决策”变成文件系统中的结构化事实。

### 5.3 Steering

Steering 是 supervisor 的热路径：

- `peer ask`
- `peer checkpoint`
- `peer reframe`

这层把多个 building blocks 组合成日常调度动作：派一轮、读状态、纠方向。

## 6. 为什么使用可见 session

很多 agent 编排系统会直接启动无头子进程。agent-duo 反而刻意对接用户眼前的 Claude/Codex tab，原因是：

1. 上下文完整。worker 的真实交互历史、工具输出、权限状态仍在原 tab。
2. 用户可检查。所有关键动作都能在 iTerm2 tab 里看见。
3. 心智简单。`peer tell` 就是帮用户把话粘贴到另一个终端。
4. 容易降级。即使 loop runtime 坏了，用户仍能手动 `peek/tell/wait`。
5. 避免黑盒。无头子进程的上下文、权限 prompt、失败状态常常不可见。

这也是 agent-duo 的安全姿态：透明度优先，自动化其次。

## 7. 为什么需要 supervisor/worker 分层

平级 agent 互相循环对话会产生几个问题：

- 谁负责停止？
- 谁决定是否偏离目标？
- 谁拥有权限审批权？
- 谁向用户汇报？
- 谁对成本负责？

agent-duo 把职责拆开：

| 角色 | 职责 |
| --- | --- |
| Human | 定目标、授权边界、做最终业务判断。 |
| Supervisor | 拆解、派发、读状态、纠偏、验收、升级人类 gate。 |
| Worker | 实现、调查、测试、报告事实。 |
| Reviewer/Evaluator | 独立判断 worker 输出是否达标。 |
| loopd | 运行机械事件、verify、liveness、看板。 |

Supervisor 不一定比 worker 更聪明，但它拥有不同状态和不同职责。

## 8. 为什么外部状态是核心

模型上下文不是可靠数据库。长循环中，如果只依赖对话摘要，会出现：

- 忘记已经尝试过的方案。
- 误报完成。
- 重复请求同一个权限。
- 把阻塞项藏在自然语言里。
- 不知道用户已经做了什么决策。

agent-duo 把状态落在 `.agent-duo/`：

- `task.json`：步骤账本。
- `loop.json`：轮次预算和成功条件。
- `rN.json`：每轮 report。
- `queue.jsonl`：runtime 事件。
- `validation-rN.json`：verify 结果。
- `reviews/<role>-rN.json`：judge verdict。
- `gates/*.json`：Human Decision Gate。
- `approvals/*.json`：工具权限请求。
- `logs/*.jsonl`：审计。

这对应 Reflexion、Generative Agents 等工作里的外部记忆思想，也对应 Claude Code 文档中把 `CLAUDE.md` / settings / hooks 作为工程环境的一部分。

## 9. 为什么 verifier 是命门

没有 verifier 的 loop 会放大错误。一个 worker 可以非常自信地：

- 没跑测试却说完成。
- 只修了 happy path。
- 解决了局部问题但偏离 mission。
- 在 UI、文档、边界条件上漏项。

agent-duo 设计了两类验收：

### 9.1 verify

`verify` 是机械闸门：

```bash
peer loop init worker \
  --verify tests:"bash test/run.sh" \
  --verify-satisfies tests:"tests-pass"
```

它适合：

- 测试。
- lint。
- typecheck。
- 构建。
- Playwright / 截图检查。
- 文档文件存在性检查。

优点是客观、可重复、便宜。缺点是只能覆盖写出来的规则。

### 9.2 judge

`judge` 是独立 reviewer/evaluator 的 verdict：

```bash
peer loop init worker --judge reviewer:request_changes,reject
peer judge worker@4 --verdict request_changes --finding major:"遗漏安装失败场景。"
```

它适合：

- 代码审查。
- UI 品质。
- 文档完整性。
- 架构一致性。
- 用户体验。

judge 不是简单“另一个 agent 点赞”。它必须基于明确 target round、证据和 finding 写入结构化记录。

### 9.3 stop-hook 合门硬门

`verify` 和 `judge` 都落盘后，supervisor Stop hook 会在 supervisor 准备停下时再次读取这些事实：

```text
verify pass ∧ 无 judge veto ∧ done report 带 evidence ∧ 轮次未超预算
```

未达合门且预算未尽时，hook 会拦截并注入继续修复指令；预算耗尽仍未达时，它会打开 Human Decision Gate。
这让“不能靠 worker 自评完成”从提示词纪律变成结构性约束。

## 10. 为什么要限制轮次

Loop engineering 的主要风险不是一次回答错，而是错误被反复放大：

- token 成本逐轮累积。
- 上下文越来越大。
- 低质量输出越来越多。
- worker 进入 detail trap。
- supervisor 也可能被重复事件淹没。

因此每个正式 loop 都应有：

- `--max-rounds`
- `--success`
- `--non-goal`
- `--verify`
- 必要时 `--judge`

`peer budget status` 目前只是预留命令，不能替代 `max_rounds`。

## 11. 为什么 Human Decision Gate 和 Approval Broker 分开

权限确认和人类决策是两类不同问题。

### 11.1 Approval Broker

Approval Broker 处理低层工具能力：

- 能不能读文件。
- 能不能跑测试。
- 能不能编辑 worktree 内文件。
- 能不能执行某条 shell 命令。

它应该尽可能被策略化和审计化。

### 11.2 Human Decision Gate

Human Decision Gate 处理高层判断：

- 是否部署。
- 是否购买云资源。
- 是否开放网络。
- 是否接受成本/安全/可用性取舍。
- 是否改变范围。
- 是否发布到生产。

这些不能被“自动 approve”替代。正确做法是暂停 loop，整理选项，让用户明确选择。

## 12. 为什么不自动按确认键

早期直觉可能是：worker 卡在权限 prompt，就让 supervisor 看到屏幕后按 yes。agent-duo 没有选择这个方向，因为：

- 屏幕识别不可靠。
- prompt 可能在观察后变化。
- “按 yes”没有可审计语义。
- 无法表达范围、时限、策略。
- 容易把业务决策误当工具权限。

当前设计是：

```text
provider hook -> broker policy -> auto-allow | pending approval | hard-deny
```

同时 `peer tell` 对 worker 有 broker ready 硬门。新 worker 没被 provider 实际调用 hook 前是 `unverified`，派发会 fail-closed。

## 13. Worktree 隔离的哲学

worktree 不是完美沙箱，但它解决了两个实际问题：

- worker 的编辑不会直接污染主工作区。
- Approval Broker 可以把“允许编辑”缩小到 worker 自己的 checkout。

这符合“安全靠边界，便利靠 allowlist”的原则：

- allowlist 是 UX。
- denylist/escalate 是风险分流。
- worktree 是实际文件边界。
- provider 权限模式和人类 gate 是最终安全阀。

## 14. Detail Trap 与 Direction Drift

长 loop 常见失败不是报错，而是“看似忙碌但没有进展”。

agent-duo 用两个信号处理：

- `drift`：worker report 中主动说明方向偏离。
- `detail_trap`：连续 N 轮 `delta` 为空，说明可能陷入无效细节。

runtime 会把这些写入事件队列，supervisor 可以：

```bash
peer checkpoint worker
peer reframe worker "收敛范围，只处理..."
```

这把“感觉不对”变成可见控制信号。

## 15. 什么时候值得上重型 loop

不是所有任务都需要完整 loop。建议用下面标准判断：

适合重型 loop：

- 任务会重复出现。
- 有自动验证信号。
- worker 能端到端推进。
- 完成标准能被写清。
- 失败成本可控。
- 需要多人/多 agent 分工。

不适合重型 loop：

- 一次性小问题。
- 完成标准完全主观。
- 需要频繁业务判断。
- 外部权限过多且不可自动化。
- 没有可运行验证。
- 成本比手工处理更高。

搭建顺序：

1. 先手动 `tell -> wait -> peek` 跑通一次。
2. 把重复动作写成项目指令或 skill。
3. 用 `task.json` 固化步骤。
4. 用 `loop.json` 加预算和成功标准。
5. 加 `verify`。
6. 加 `judge`。
7. 最后再考虑定时、外部触发或更多 worker。

## 16. agent-duo 的设计原则

### 16.1 可见优先

所有核心成员都是 tmux 里的可见 tab。用户可以直接看见 supervisor、worker、loopd。

### 16.2 人类拥有最终决策权

业务、成本、安全、部署、发布、网络、资源购买都通过 Human Decision Gate 升级。

### 16.3 结构化状态优先于自然语言屏幕

屏幕用于可见性，`.agent-duo/` 用于事实。

### 16.4 完成必须带证据

`done` / `partial` 无证据会降级为 `unknown`。正式 loop 应使用 verify/judge。

### 16.5 预算是边界，不是建议

`max_rounds` 到界后，`peer ask` / `peer reframe` 默认拒发。越界必须 `--force`。

### 16.6 approval 只处理能力，不处理业务判断

`peer approval approve` 不是“同意方案”，只是允许某一次工具调用。

### 16.7 reviewer 不是特殊协议

reviewer 也是 worker role 的一种，只是用 `peer judge` 对 target round 写 verdict。

### 16.8 历史兼容与命名收敛分开

内部 JSON 仍有 `validation` / `acceptance` 字段以兼容历史；用户命令和文档使用 `verify` / `judge`。

## 17. 与公开资料的对应关系

| 公开资料主题 | agent-duo 对应设计 |
| --- | --- |
| Claude Code hooks | supervisor stop drain、user prompt busy/idle、worker approval hook |
| Claude Code memory / `CLAUDE.md` | `AGENTS.md` / `docs/AGENT-INSTRUCTIONS.md` 注入协作规则 |
| Claude Code subagents / long-running agents | 可见 `peer agent add` worker/reviewer/evaluator |
| Codex hooks | `agent-duo-approval-hook`、PreToolUse、PermissionRequest |
| Codex `AGENTS.md` | Codex 项目指令注入 |
| Codex iterative repair loops | `peer ask` + `peer report` + verify + reframe |
| ReAct | 观察/行动/反馈循环 |
| Reflexion | report/checkpoint/task 的外部记忆 |
| Self-Refine | 生成/反馈/修改循环，但 agent-duo 加外部 verify/judge |
| LLM-as-a-Judge | 独立 reviewer/evaluator verdict |

## 18. 未完成或刻意保留的方向

当前实现不等于完整商业级编排平台：

- `peer budget status` 仍是预留面，没有真实 token/成本 enforcement。
- 没有内置 GitHub/Slack connector。
- 没有定时 scheduler；`loopd` 提供本地 tick，但不是 cron。
- worktree 不是强沙箱。
- Approval Broker policy 是内置 Bash 规则，还不是用户可编辑 policy.toml。
- `peer tell` 的 prompt 检测是启发式，不能替代 provider 权限模式。
- 无头 `codex exec` 不属于可见 peer worker，不应假设受 agent-duo broker 保护。

这些限制不是缺陷掩盖，而是产品定位：先把可见 loop 的控制面做扎实，再扩展自动化。

## 19. 结论

Loop engineering 是把 agentic coding 从“更会写 prompt”推进到“会设计反馈系统”。`agent-duo` 的关键贡献不是多一个聊天桥，而是把可见 session、结构化状态、验证、独立评判、人类决策和权限 broker 组合成一个小而可审计的 supervisor harness。

如果一个 loop 不能被观察、不能被验证、不能被停止、不能向人类升级，它就不应该自动运行。

## 20. 资料清单

本地：

- [docs/loop-engineering.md](loop-engineering.md)
- [docs/LOOP-ENGINEERING-PRODUCT-CASE.zh-CN.md](LOOP-ENGINEERING-PRODUCT-CASE.zh-CN.md)
- [docs/agent-loop-三agent循环-提炼.md](agent-loop-三agent循环-提炼.md)
- [agent-duo-supervisor-loop-roadmap.md](../agent-duo-supervisor-loop-roadmap.md)
- [docs/glossary.md](glossary.md)
- [docs/superpowers/specs](superpowers/specs)

外部：

- [Anthropic Claude Code Hooks](https://docs.anthropic.com/en/docs/claude-code/hooks)
- [Anthropic Claude Code Memory](https://docs.anthropic.com/en/docs/claude-code/memory)
- [Anthropic Claude Code Subagents](https://docs.anthropic.com/en/docs/claude-code/sub-agents)
- [Anthropic Claude Code Settings](https://docs.anthropic.com/en/docs/claude-code/settings)
- [OpenAI Codex Hooks](https://developers.openai.com/codex/hooks)
- [OpenAI Codex AGENTS.md guide](https://developers.openai.com/codex/guides/agents-md)
- [OpenAI Cookbook: Build iterative repair loops with Codex](https://developers.openai.com/cookbook/examples/codex/build_iterative_repair_loops_with_codex)
- [ReAct paper](https://arxiv.org/abs/2210.03629)
- [Reflexion paper](https://arxiv.org/abs/2303.11366)
- [Self-Refine paper](https://arxiv.org/abs/2303.17651)
- [Generative Agents paper](https://arxiv.org/abs/2304.03442)
- [LLM-as-a-Judge / MT-Bench paper](https://arxiv.org/abs/2306.05685)
