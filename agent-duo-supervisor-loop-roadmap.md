# agent-duo 演进方向：Supervisor Harness 与动态多 Agent 工作台

日期：2026-06-16

## 背景

近期关于 Loop Engineering 的讨论，本质上不是“让 Agent 定时重复执行 prompt”，而是把人类过去手动完成的提示、观察、验收、纠偏过程，提升为一套可运行的反馈系统。

对 `agent-duo` 来说，这个方向非常自然：它已经不是在创建一个新的无头子进程，而是让 Claude Code 与 Codex CLI 这类真实、长期存活、用户可见的交互式 session 互相看屏和传话。因此它最适合演进成一个“可见的 live-session supervisor harness”。

核心判断：

> agent-duo 不应该变成 agent 互聊器，而应该变成一个由上位 Agent 监工、调度、验收、授权下位 Agent 的协作框架。

## 目标形态

理想的 loop 结构不是平级 Agent 互相循环对话，而是明确分层：

```text
Human
  -> Supervisor Agent
      -> Worker Agent(s)
      -> Evaluator / tests / logs / screenshots
      -> decide: continue | fix | stop | rollback | escalate
```

其中：

- Human 负责目标、授权边界、最终判断。
- Supervisor Agent 负责拆解任务、监控 Worker、收集结果、执行验收、控制预算和停止条件。
- Worker Agent 负责具体实现、调查、测试、修复。
- Evaluator 可以是另一个 Agent，也可以是测试、类型检查、lint、Playwright、日志、截图、CI 等可验证信号。

Supervisor 并不一定比 Worker “更聪明”，但它拥有不同职责：它维护任务契约、上下文摘要、风险策略、进度状态和验收标准。

## 当前 agent-duo 的优势

`agent-duo` 已经具备几个非常关键的基础能力：

- `peer peek`：观察另一个 Agent 的实时终端输出。
- `peer tell`：向另一个 Agent 的输入框发送指令。
- `peer wait`：等待对方输出稳定。
- 真实 session：操作的是用户正在看的 Claude/Codex tab，而不是隐藏的无头 subprocess。
- 人在环路中：现有提示词已经禁止无人监督的 Agent-to-Agent 闲聊。

这些能力刚好对应 Supervisor Loop 的最小动作：

```text
tell -> wait -> peek -> evaluate -> decide
```

也就是：

```text
下发任务 -> 等待完成 -> 读取结果 -> 验收 -> 决定下一轮
```

## 当前痛点：授权确认打断 loop

实际使用中，一个明显痛点是 Worker 经常卡在权限确认上，需要用户频繁手动按确认键。

这会破坏 supervisor loop：

- Worker 无法连续推进。
- Supervisor 只能观察，不能真正调度。
- 用户仍然被迫盯着屏幕做低价值确认。
- 多 Worker 并行时，确认成本会线性放大。

但直接让 Worker 自己无限按确认也不安全。正确方向不是“自动按 yes”，而是把授权抽象成：

> 可审计、可批量、可撤销、带范围和时限的 capability。

## 当前痛点：关键阶段需要人类判断

另一类痛点不是权限确认，而是执行到某些阶段时必须由人做判断。例如：

- 应该部署到哪台机器、哪个 region、哪个环境。
- 是否购买新的虚拟机，以及购买什么规格。
- 是否开通某条防火墙策略。
- 是否创建新的云资源、域名、证书、数据库或消息队列。
- 是否将改动发布到 staging、production 或某个客户环境。
- 成本、安全、合规、可用性之间如何取舍。

这类问题不能简单交给 Worker，也不应该被 `peer approve` 自动处理。它们属于高层决策，需要 Supervisor 暂停 loop，整理上下文和选项，然后让用户做明确选择。

因此 agent-duo 需要多个控制面：

```text
Agent Registry & Dynamic Roles
  -> 处理灵活编队：不把 agent 固定死在 claude/codex 两个窗口名上

Approval Broker
  -> 处理低层能力授权：能不能跑这个命令、写这个路径、执行这次测试

Human Decision Gate
  -> 处理高层判断：要不要买资源、部署到哪里、开放什么网络边界

Truthful Progress Protocol
  -> 处理执行真实性：做不到时及时上报，不能编造进度、结果或外部状态

Direction Control
  -> 处理方向漂移：防止 Worker 陷入局部细节，忘记目标、阶段和取舍

Quota & Budget Broker
  -> 处理额度和成本：避免上位 Agent 先耗尽额度，导致整个系统停摆
```

## Agent Registry & Dynamic Roles

目前 agent-duo 最大的结构问题是：Agent 固定死了。当前模型天然假设只有两个窗口、两个身份：`claude` 和 `codex`。这对 demo 很清晰，但对真正的 supervisor harness 不够灵活。

实际使用中，用户需要的是角色和能力，而不是固定品牌名：

- 一个 Agent 做 Supervisor。
- 一个 Agent 做实现 Worker。
- 一个 Agent 做 Reviewer。
- 一个 Agent 做 Evaluator，负责跑浏览器、截图、验收。
- 一个低成本 Agent 做日志压缩和状态整理。
- 一个备用 Agent 在 Supervisor 额度不足时接管。

这些角色不应该被绑定到 Claude 或 Codex。Claude 可以做 Worker，Codex 也可以做 Supervisor；同一个工具里也可能同时跑多个 Codex、多个 Claude，或者以后接入其他 CLI Agent。

### 从固定 peer 到动态 registry

当前模式可以理解为：

```text
AGENT_NAME=claude -> other=codex
AGENT_NAME=codex  -> other=claude
```

目标模式应该是：

```text
agent_id -> role -> provider -> session/window/pane -> capabilities -> budget -> state
```

示例：

```toml
# .agent-duo/agents.toml

[[agents]]
id = "supervisor-main"
role = "supervisor"
provider = "claude"
pane = "%12"
model = "opus"
capabilities = ["plan", "review", "gate", "budget"]
budget_profile = "expensive"

[[agents]]
id = "worker-impl"
role = "worker"
provider = "codex"
pane = "%13"
worktree = ".agent-duo/worktrees/worker-impl"
capabilities = ["edit", "test", "report"]
budget_profile = "standard"

[[agents]]
id = "worker-review"
role = "reviewer"
provider = "codex"
pane = "%14"
worktree = ".agent-duo/worktrees/worker-review"
capabilities = ["read", "review", "report"]
budget_profile = "cheap"
```

这样 `peer` 不再只有“对方”这个概念，而是可以面向具体 Agent 或角色路由：

```sh
peer ls
peer peek worker-impl
peer tell worker-review "Review worker-impl's diff"
peer ask evaluator-browser "Open the app and verify login flow"
peer broadcast --role worker "Pause and write compact report"
peer route --from supervisor-main --to worker-impl
```

### Role 不等于 Provider

必须明确区分：

| 概念 | 含义 | 示例 |
|---|---|---|
| `agent_id` | 当前 session 中的唯一身份 | `worker-impl` |
| `role` | 在 loop 里的职责 | `supervisor`、`worker`、`reviewer` |
| `provider` | 具体工具或模型来源 | `claude`、`codex` |
| `capabilities` | 被允许承担的能力 | `edit`、`test`、`approve` |
| `budget_profile` | 预算和额度策略 | `expensive`、`cheap` |

这样可以避免把“Claude = 上位 Agent”“Codex = 下位 Agent”写死。真正重要的是任务需要什么角色、什么能力、什么预算。

### 动态编队

Supervisor 应该能按任务动态组队：

```yaml
team:
  supervisor: "supervisor-main"
  workers:
    - id: "worker-impl"
      role: "implementation"
      provider: "codex"
    - id: "worker-review"
      role: "review"
      provider: "claude"
    - id: "evaluator-browser"
      role: "evaluator"
      provider: "codex"
      capabilities: ["browser", "screenshot", "test"]
```

并且支持替换：

```text
worker-impl 卡住
  -> Supervisor 生成 handoff packet
  -> 新建 worker-impl-2
  -> 继续同一任务

supervisor-main 额度不足
  -> 写出 state/handoff
  -> fallback-supervisor 接管
```

### agent 命令草案

可以引入：

```sh
agent-duo agent list
agent-duo agent add worker-impl --provider codex --role worker
agent-duo agent add reviewer --provider claude --role reviewer
agent-duo agent remove worker-impl
agent-duo agent assign worker-impl --role reviewer
agent-duo start --profile team.yaml
```

对应 `peer` 命令也要从隐式二人模式升级：

```sh
peer ls
peer status worker-impl
peer tell worker-impl "..."
peer peek worker-review 120
peer wait evaluator-browser
```

当 session 中只有两个 Agent 时，`peer tell` 可以继续默认发给“另一个”；当超过两个时，必须显式指定目标，避免误发。

## Approval Broker

建议引入 `Approval Broker` 作为 agent-duo 的核心演进模块。

它的职责不是盲目替用户按确认，而是基于 policy 判断当前权限请求是否可自动放行。

```text
Worker 卡在权限 prompt
  -> Supervisor/Approval Broker 读取屏幕
  -> 识别命令、cwd、目标路径、风险类型
  -> 匹配 policy
  -> 低风险自动批准
  -> 高风险升级给用户
  -> 所有动作写入审计日志
```

### 授权租约

授权对象不应该是“一次按键”，而应该是“某类能力在某段时间内可用”。

示例：

```toml
# .agent-duo/policy.toml

[allow.read]
commands = ["rg", "ls", "sed", "git status", "git diff"]

[allow.test]
prefixes = ["go test", "npm test", "make test", "cargo test"]
ttl = "30m"

[allow.write]
paths = ["./.agent-duo/worktrees/worker-*"]
ttl = "session"

[deny]
commands = ["sudo", "ssh", "git push", "rm -rf", "curl * | sh"]
paths = ["~/.ssh", "~/.aws", ".env", "/"]
```

这允许 Worker 在受限范围内高效工作，同时避免越权。

### approve 命令草案

可以逐步引入：

```sh
peer approvals
peer approve --once
peer approve --lease 30m --policy test
peer deny
```

含义：

- `peer approvals`：列出当前卡在权限确认的 Agent、命令、cwd、风险摘要。
- `peer approve --once`：只批准当前这一次请求。
- `peer approve --lease`：批准一类动作在限定时间内自动通过。
- `peer deny`：拒绝当前请求，可选择给 Worker 回写原因。

`peer approve` 必须满足三个条件：

1. 当前屏幕确实是权限确认 UI。
2. prompt hash 未变化，避免观察后界面被替换。
3. 命令和上下文命中 allow policy。

> **更新（2026-06-17）：优先用 hook 实现，而非抓屏+回车。** Claude Code 与 Codex 都提供 `PreToolUse` / `PermissionRequest` hook，能**程序化 allow/deny 工具调用**（返回 `permissionDecision`/`decision.behavior`）。因此 Approval Broker 应做成 worker session 上的 hook：工具执行前触发 → 脚本查 policy → 返回放行/拒绝/交回人工。这比"识别权限 UI + 校验 prompt hash + 发 Enter"更机械、可审计、不依赖屏幕渲染，且 Claude/Codex 通用。详见 [loop runtime 设计](docs/superpowers/specs/2026-06-17-loop-runtime-design.md) 与 [worker↔supervisor 契约](docs/superpowers/specs/2026-06-17-worker-supervisor-contract.md)。

## Human Decision Gate

`Human Decision Gate` 用来处理不能自动化的业务、基础设施和风险判断。

当 Worker 或 Supervisor 发现任务需要外部资源、部署目标、网络策略或成本决策时，loop 应该进入 `blocked-on-human-decision` 状态，而不是继续猜。

```text
Worker 发现需要部署/采购/开通策略
  -> Supervisor 停止继续授权
  -> 收集当前目标、环境、风险、候选方案
  -> 生成 Decision Packet
  -> 用户选择
  -> Supervisor 将选择转成下一步任务
```

### Decision Packet

Supervisor 应该给用户的是一份可决策的信息包，而不是一句“请确认”。

示例：

```markdown
## Decision Required: 选择部署目标

当前目标：
将 `agent-duo` demo 服务部署到一个可公网访问的测试环境。

当前状态：
- 本地构建通过
- 需要公网回调地址
- 当前没有可用 staging VM

选项：
1. 购买新 VM
   - 成本：约 $X/月
   - 优点：隔离、可长期使用
   - 风险：需要配置 SSH、防火墙、监控
   - 后续动作：创建 VM -> 开 22/80/443 -> 部署服务

2. 使用现有 dev VM
   - 成本：无新增成本
   - 优点：最快
   - 风险：可能污染现有环境
   - 后续动作：确认端口 -> 新建 systemd service -> 配置反代

3. 暂不部署，只生成部署脚本
   - 成本：无
   - 优点：无外部风险
   - 风险：无法完成端到端验证
   - 后续动作：生成 Terraform/Ansible/manual runbook

推荐：
如果只是验证 demo，选择 2；如果准备长期演示，选择 1。
```

### gate 命令草案

可以引入：

```sh
peer gate
peer gate open --title "选择部署目标"
peer gate resolve --choice 2
peer gate cancel
```

含义：

- `peer gate`：查看当前等待人类判断的 gate。
- `peer gate open`：由 Supervisor 创建一个决策请求。
- `peer gate resolve`：记录用户选择，并将结果传回 Worker。
- `peer gate cancel`：取消当前外部动作，让 Worker 改走不需要该决策的方案。

### 不应自动跨越的 gate

这些动作默认都应该进入 Human Decision Gate：

- 购买、升级、删除云资源。
- 开通公网访问、防火墙规则、安全组规则。
- 创建或旋转密钥、证书、token。
- 生产部署、数据迁移、回滚生产系统。
- 产生持续费用的动作。
- 改变组织、团队、客户可见行为的动作。
- 无法仅通过 git diff 回滚的动作。

> **更新（2026-06-17）：把"要不要人拍板"从判断变决策树，主轴是可逆性。** 上面最后一条是关键判据，提炼为一句可机械检查的规则：
>
> > **"这件事能不能只用 git 撤销？"** 改动只活在 worktree/git 里 → 可逆 → 倾向自主；碰到 git 以外任何东西（云资源、网络入口、钱、secret、别人能看到的状态）→ 不可逆 → 升级。
>
> supervisor 要自主做某事，须同时证明 **可逆 + 命中 policy + 在 scope 内**，任一证不出即升级；默认偏向升级。判断**判错也不致命**：危险动作由 `PreToolUse`/`PermissionRequest` policy hook 在执行前独立拦截（UX 分档 ≠ 安全闸门，二者解耦）。升级有三个独立来源：worker 的 `needs.kind=decision`、supervisor 的类别匹配、policy hook 的拦截。完整决策树见 [loop runtime 设计 §5](docs/superpowers/specs/2026-06-17-loop-runtime-design.md)。

## Truthful Progress Protocol

另一个关键痛点是：当 AI 不能继续有效执行时，它应该及时上报，而不是硬编数据、假装已经完成，或用没有证据的状态描述糊弄过去。

这类问题在长 loop 中尤其危险：

- Worker 卡住后继续编造“已修复”“已部署”“测试通过”。
- Worker 没有真实访问外部系统，却声称已经检查过。
- Worker 误把计划当结果，把推测当事实。
- Worker 在同一个错误上反复尝试，却不升级给 Supervisor。
- Supervisor 只看最终文字总结，没有核验证据。

因此需要一个 `Truthful Progress Protocol`：任何阶段性汇报都必须区分事实、推测、阻塞和下一步请求。

### 汇报状态

Worker 的汇报不应该只有“完成/未完成”，而应该使用明确状态：

```text
done
  -> 已完成，且有证据

partial
  -> 部分完成，明确剩余问题

blocked
  -> 无法继续，需要权限、信息、环境、决策或人工介入

failed
  -> 尝试过但失败，附失败证据和已排除路径

unknown
  -> 无法确认，不允许伪装成 done
```

### Evidence Packet

任何关键结论都应该带证据。没有证据的 claim 只能标记为 `unknown` 或 `hypothesis`。

示例：

```markdown
## Worker Report

status: blocked

goal:
部署 demo 服务到公网测试环境。

facts:
- 本地 `npm test` 已通过。
- Docker 镜像已在本机成功构建。
- 当前没有可用公网 VM 凭据。

evidence:
- command: `npm test`
- result: passed
- log_ref: `.agent-duo/logs/worker-impl/20260616-1203-npm-test.log`
- diff_ref: `git diff --stat`

blocked_on:
- 需要用户选择部署目标。
- 需要确认是否购买新 VM 或使用现有 dev VM。

not_done:
- 未部署到公网。
- 未验证防火墙。
- 未验证外部回调。

request:
请打开 `deploy-target` Human Decision Gate。
```

### 不允许的汇报

以下都应该被 Supervisor 视为无效结果：

- “应该已经好了”，但没有测试、日志或 diff。
- “已经部署了”，但没有目标地址、版本、命令记录或健康检查。
- “我检查过了”，但没有说明检查了什么、在哪里检查、结果是什么。
- “问题可能解决了”，却把状态标成 done。
- “测试通过”，但没有命令、时间、输出摘要或日志引用。
- 需要外部权限或资源时继续编造替代事实。

### Stuck Detector

Supervisor 应该主动检测 Worker 是否卡住，而不是完全相信 Worker 自报。

触发条件可以包括：

- 同一个错误连续出现两轮。
- 连续 N 轮没有产生 diff、测试结果或新的证据。
- Worker 重复修改同一处但验证结果不变。
- Worker 输出大量计划，但没有执行命令或产生文件变化。
- Worker 声称完成，但 validation command 没有运行。
- Worker 需要外部环境、凭据、网络、资源或人类决策。
- Worker 进入权限 prompt 或 TUI 卡住状态超过阈值。

触发后 Supervisor 应该进入：

```text
blocked-on-worker-limit
blocked-on-missing-evidence
blocked-on-human-decision
blocked-on-permission
blocked-on-external-system
```

而不是继续让 Worker 自己消耗 token。

### report 命令草案

可以引入：

```sh
peer report
peer report --json
peer require-evidence --for "tests pass"
peer mark-blocked --reason "missing deployment target"
```

含义：

- `peer report`：让 Worker 按固定模板汇报状态。
- `peer report --json`：方便 Supervisor 解析状态、证据和阻塞原因。
- `peer require-evidence`：要求 Worker 为某个 claim 补证据。
- `peer mark-blocked`：Supervisor 主动标记当前 loop 无法继续。

## Direction Control

还有一类常见问题是：AI 很容易陷入某个局部细节，不断优化、排查、重构或争辩一个小点，却失去对大方向的掌握。

这不是 Worker 不努力，而是长期任务中常见的方向漂移：

- 花大量时间修一个边缘 lint，却忘了主功能还没跑通。
- 为了“架构正确”开始扩展抽象，但用户要的只是一个可验证 demo。
- 反复优化实现细节，却没有推动验收条件。
- 在一个失败路径上越挖越深，没有及时换策略。
- Worker 完成了很多局部动作，但和原始目标的关系越来越弱。

因此需要 `Direction Control`：Supervisor 不只看 Worker 有没有动，还要看它的动作是否仍然服务于目标。

### Mission Compass

每个 loop 应该有一个持续可见的 `Mission Compass`：

```yaml
mission:
  outcome: "让 agent-duo 支持安全的多 Agent supervisor loop"
  current_phase: "设计 Approval Broker MVP"
  non_goals:
    - "暂不实现完整云端调度平台"
    - "暂不支持无监督生产部署"
  success_signals:
    - "低风险权限确认可以自动处理"
    - "高风险动作会进入 human gate"
    - "done 状态必须有证据"
  tradeoffs:
    optimize_for: ["可控", "可审计", "小步可实现"]
    avoid: ["过度抽象", "无人监管", "隐藏执行"]
```

Worker 每轮汇报时，都应该回答：

- 当前动作服务于哪个 outcome？
- 当前处于哪个 phase？
- 本轮推进了哪个 success signal？
- 是否偏离了 non-goals？
- 是否应该停止当前细节，回到主线？

### Detail Trap Detector

Supervisor 应该主动检测 Worker 是否陷入细节陷阱。

触发条件可以包括：

- 连续多轮没有改变主验收状态。
- Worker 在非关键文件或非关键问题上消耗过多轮次。
- diff 体积增长很快，但 success signal 没有变化。
- Worker 开始引入新抽象、新依赖或大范围重构，却没有 contract 要求。
- Worker 反复解释一个局部问题，而不是提出可执行的下一步。
- Worker 的下一步计划无法映射到 mission outcome。

触发后 Supervisor 应该执行方向校准：

```text
pause detail work
  -> summarize current state
  -> compare against mission/outcome
  -> identify smallest useful next step
  -> continue, re-scope, or escalate
```

### Direction Checkpoint

建议每隔固定轮次或时间做一次方向检查：

```text
每 2 轮：
  - 当前离目标更近了吗？
  - 有哪些证据证明更近了？
  - 当前最大风险是什么？
  - 下一步是不是最小有效推进？

每 30 分钟：
  - 是否需要缩小 scope？
  - 是否需要换 Worker 或换策略？
  - 是否需要人类做产品/架构/部署决策？
```

### reframe 命令草案

可以引入：

```sh
peer reframe
peer reframe --against contract.yaml
peer checkpoint
peer checkpoint --json
```

含义：

- `peer reframe`：要求 Worker 从大目标重新解释当前工作。
- `peer reframe --against`：对照 contract 检查是否跑偏。
- `peer checkpoint`：生成方向检查摘要。
- `peer checkpoint --json`：方便 Supervisor 判断继续、缩小范围或升级。

## Quota & Budget Broker

还有一个现实问题是：上位 Agent 和下位 Agent 可能使用不同订阅套餐、不同模型、不同额度池。最麻烦的情况是 Supervisor 额度先耗尽，Worker 明明还能继续干活，但整个工作流因为控制面消失而停滞。

这说明 Supervisor 不能被设计成高频、重 token、持续在线的唯一大脑。它应该更像控制平面：轻量、事件驱动、可持久化、可接管。

典型风险：

- Supervisor 高频 `peek` 和长篇总结，比 Worker 更快耗尽额度。
- Supervisor 负责所有判断、汇总、改写、复盘，成为 token 热点。
- Worker 还在运行，但 Supervisor 没额度读取结果和下发下一步。
- 上位 Agent session 断掉后，任务状态只存在上下文里，无法恢复。
- 不同平台的套餐、速率限制、上下文长度不一致，导致调度策略失效。

### 控制面轻量化

Supervisor 应尽量少消耗模型 token：

- 优先读取结构化 `report.json`，少读整屏 TUI。
- `peer ask` 默认只返回增量输出，不反复读取完整上下文。
- 日常轮询由脚本完成，只有异常、gate、证据缺失、方向漂移时才唤醒 Supervisor。
- 长篇总结延后到 checkpoint 或用户请求时生成。
- Worker 自己产出结构化报告，Supervisor 只做验证和路由。

### 状态持久化

Supervisor 不能把关键状态只放在自己的上下文窗口里。

应该把 loop 状态落盘：

```text
.agent-duo/state/
  loop.yaml
  workers.json
  budget.json
  latest-reports/
  checkpoints/
```

这样即使上位 Agent 额度耗尽、session 断掉，另一个 Agent 或人类也能接管。

### Budget Policy

contract 中应该显式描述每个角色的预算和降级策略：

```yaml
budget:
  max_rounds: 5
  max_duration: 45m
  supervisor:
    max_tokens_per_checkpoint: 3000
    max_peek_lines: 80
    mode: "event-driven"
    fallback_agent: "codex"
  workers:
    worker-impl:
      max_rounds: 4
      max_runtime: "30m"
      report_format: "json"
    worker-review:
      max_rounds: 2
      max_runtime: "15m"
  degradation:
    on_supervisor_quota_low:
      - "stop nonessential summaries"
      - "require workers to write compact reports"
      - "switch to checkpoint-only supervision"
      - "offer handoff packet to human or fallback supervisor"
```

### Handoff Packet

当 Supervisor 额度不足时，不应该继续消耗到突然中断，而应该提前生成 `Handoff Packet`：

```markdown
## Supervisor Handoff

loop: login-error-copy-fix
status: partial

current mission:
修复登录失败时错误提示不准确的问题，并通过测试验证。

worker states:
- worker-impl: implementation done, tests failing in auth.test.ts
- worker-review: not started

latest evidence:
- diff: `.agent-duo/state/checkpoints/round-3.diff`
- test log: `.agent-duo/logs/worker-impl/auth-test-round-3.log`

open gates:
- none

next recommended action:
让 worker-impl 只修复 auth.test.ts 中的错误断言，不要重构 auth 模块。
```

这个 packet 可以交给：

- 用户。
- 另一个 Supervisor Agent。
- 低成本模型。
- 同一个 Agent 的新 session。

### quota 命令草案

可以引入：

```sh
peer budget
peer budget snapshot
peer budget handoff
peer budget compact
```

含义：

- `peer budget`：查看当前 loop 的预算、轮次、剩余策略。
- `peer budget snapshot`：写出当前状态快照。
- `peer budget handoff`：生成接管包。
- `peer budget compact`：压缩历史，只保留任务状态、证据和下一步。

## 安全边界

Approval Broker 的默认策略应该保守：

### 可以考虑自动批准

- 只读命令：`rg`、`ls`、`sed`、`cat`、`git status`、`git diff`。
- 本地测试：`go test`、`npm test`、`make test`、`cargo test`。
- 格式化：`gofmt`、`prettier`、`ruff format` 等项目内格式化命令。
- 写入隔离 worktree 内的普通文件。
- 创建临时文件、日志、测试输出。

### 默认需要人工确认

- `git push`、发 PR、发布 release。
- `sudo`、系统级安装、修改 shell profile。
- 访问或修改 secret：`.env`、`~/.ssh`、`~/.aws`、token 文件。
- 跨 workspace 写入。
- 删除大范围文件。
- 网络下载执行，例如 `curl ... | sh`。
- 部署、迁移生产数据、操作云资源。
- 购买虚拟机、开通防火墙策略、创建外部网络入口。

### 永远不应自动做的事

- 替用户接受未知权限弹窗。
- 在没有 policy 命中的情况下发送 Enter。
- 让 Worker 自行修改自己的授权 policy。
- 让 Worker 在无人监督下给另一个 Worker 开更大权限。
- 自动跨越需要人类判断的 Decision Gate。
- 接受没有证据的 done 状态。
- 让 Worker 把推测、计划或愿望描述成事实。
- 允许 Worker 在没有 contract 支撑的情况下大范围重构、引入依赖或扩大 scope。
- 在 Supervisor 额度低时继续做非必要长篇总结、全量 peek 或无意义轮询。

## Worktree 隔离

为了解决多 Worker 并行和写权限风险，建议把 Worker 默认放进隔离 worktree：

```text
.agent-duo/
  worktrees/
    worker-impl/
    worker-review/
    worker-experiment/
  logs/
    approvals.jsonl
    sessions.jsonl
  policy.toml
```

优势：

- Worker 可以大胆修改自己的分支。
- Supervisor 可以对比 diff、跑测试、选择合并或丢弃。
- 多 Worker 不会互相踩同一份工作区。
- 自动写权限更容易被限制在安全范围内。

典型流程：

```text
Supervisor:
  1. 创建 worker-impl worktree
  2. 派 Worker 实现功能
  3. 允许 Worker 在该 worktree 内改文件和跑测试
  4. 收集 diff/test result
  5. 派 Reviewer/Evaluator 审查
  6. 决定合并、继续修复或丢弃
```

## Supervisor Loop 的契约

每个 loop 都应该有显式 contract，而不是一句模糊 prompt。

建议 contract 包含：

```yaml
goal: "修复登录失败时错误提示不准确的问题"
workers:
  - name: worker-impl
    role: implementation
  - name: worker-review
    role: review
budget:
  max_rounds: 5
  max_duration: 45m
team:
  supervisor: "supervisor-main"
  agents:
    - id: "worker-impl"
      role: "implementation"
      provider: "codex"
      worktree: ".agent-duo/worktrees/worker-impl"
    - id: "worker-review"
      role: "review"
      provider: "claude"
      worktree: ".agent-duo/worktrees/worker-review"
    - id: "evaluator-browser"
      role: "evaluator"
      provider: "codex"
      capabilities: ["browser", "screenshot", "test"]
  supervisor:
    mode: "event-driven"
    max_peek_lines: 80
    max_tokens_per_checkpoint: 3000
    fallback_agent: "codex"
  degradation:
    on_supervisor_quota_low:
      - "write handoff packet"
      - "switch workers to compact json reports"
      - "pause nonessential summarization"
reporting:
  require_evidence_for:
    - "tests pass"
    - "deployment complete"
    - "external service configured"
  invalid_claims:
    - "done without evidence"
    - "deployed without endpoint and health check"
    - "tested without command output"
direction:
  checkpoint_every_rounds: 2
  checkpoint_every_duration: "30m"
  mission:
    outcome: "修复登录失败时错误提示不准确的问题，并通过测试验证"
    current_phase: "implementation"
    non_goals:
      - "不重构整个 auth 模块"
      - "不改动登录流程以外的 UI"
    success_signals:
      - "错误提示符合产品要求"
      - "相关测试通过"
      - "reviewer 无阻塞意见"
  detail_trap:
    max_rounds_without_validation_progress: 2
    max_unplanned_diff_files: 5
approval:
  policy: ".agent-duo/policy.toml"
human_gates:
  - id: "deploy-target"
    trigger: "需要选择部署环境、购买资源或开放网络入口"
    required_before:
      - "provision external infrastructure"
      - "open firewall/security-group rules"
      - "deploy to staging or production"
validation:
  commands:
    - "npm test"
    - "npm run typecheck"
stop:
  success:
    - "tests pass"
    - "reviewer has no blocking findings"
  escalate:
    - "permission not covered by policy"
    - "human decision gate is required"
    - "worker reports done without evidence"
    - "worker is stuck or repeating the same failure"
    - "worker is stuck in details without validation progress"
    - "scope expands beyond mission non-goals"
    - "same failure repeats twice"
    - "diff touches files outside allowed scope"
```

Supervisor 的职责是执行 contract，而不是自由发挥。

## 审计日志

所有自动化动作都应该可追溯。

建议写入 `.agent-duo/logs/approvals.jsonl`：

```json
{"ts":"2026-06-16T12:00:00Z","agent":"worker-impl","action":"approve","mode":"once","cmd":"npm test","cwd":".agent-duo/worktrees/worker-impl","policy":"allow.test","prompt_hash":"abc123","approved_by":"supervisor"}
```

建议写入 `.agent-duo/logs/sessions.jsonl`：

```json
{"ts":"2026-06-16T12:02:00Z","from":"supervisor","to":"worker-impl","type":"tell","summary":"implement login error copy fix"}
{"ts":"2026-06-16T12:08:00Z","from":"worker-impl","to":"supervisor","type":"peek","summary":"tests failing in auth.test.ts"}
```

建议写入 `.agent-duo/logs/decisions.jsonl`：

```json
{"ts":"2026-06-16T12:15:00Z","gate":"deploy-target","status":"opened","summary":"need public staging endpoint for webhook validation","options":["new-vm","existing-dev-vm","generate-runbook-only"]}
{"ts":"2026-06-16T12:20:00Z","gate":"deploy-target","status":"resolved","choice":"existing-dev-vm","decided_by":"human","notes":"use current dev VM, do not open production firewall"}
```

建议写入 `.agent-duo/logs/reports.jsonl`：

```json
{"ts":"2026-06-16T12:25:00Z","agent":"worker-impl","status":"blocked","goal":"deploy demo service","facts":["local tests passed","docker image built locally"],"evidence":["logs/worker-impl/npm-test.log","git diff --stat"],"blocked_on":["deployment target","vm credentials"],"invalidated_claims":[]}
{"ts":"2026-06-16T12:30:00Z","agent":"supervisor","status":"blocked-on-missing-evidence","claim":"deployment complete","reason":"no endpoint, no health check, no deploy command log"}
```

建议写入 `.agent-duo/logs/checkpoints.jsonl`：

```json
{"ts":"2026-06-16T12:35:00Z","agent":"supervisor","mission":"fix login error copy","phase":"implementation","progress":"tests now cover invalid password case","risk":"worker started broad auth refactor","decision":"re-scope to copy handling only"}
```

建议写入 `.agent-duo/logs/budget.jsonl`：

```json
{"ts":"2026-06-16T12:40:00Z","agent":"supervisor","event":"quota_low","action":"handoff_packet_written","path":".agent-duo/state/handoff-20260616-1240.md"}
{"ts":"2026-06-16T12:41:00Z","agent":"supervisor","event":"degraded_mode","mode":"checkpoint-only","reason":"supervisor quota low"}
```

建议写入 `.agent-duo/logs/agents.jsonl`：

```json
{"ts":"2026-06-16T12:00:00Z","event":"agent_added","id":"worker-impl","role":"worker","provider":"codex","pane":"%13","worktree":".agent-duo/worktrees/worker-impl"}
{"ts":"2026-06-16T12:45:00Z","event":"role_reassigned","id":"worker-review","old_role":"reviewer","new_role":"fallback-supervisor","reason":"supervisor quota low"}
```

审计日志的价值：

- 回放 loop 为什么做出某个决定。
- 定位第 N 轮开始跑偏的原因。
- 为团队环境提供治理依据。
- 帮助用户调整 policy。
- 记录外部资源、部署和网络策略的决策依据。
- 防止“文字上完成了，但实际上没有证据”的假进度。
- 防止“局部一直在动，但整体没有前进”的方向漂移。
- 避免 Supervisor 额度耗尽后任务状态丢失、无人能接管。
- 记录 Agent 的加入、退出、角色切换和接管过程。

## MVP 建议

第一阶段不需要一下子做完整多 Agent 平台，可以做一个小而硬的版本：

> **更新（2026-06-17）：MVP 1 / 2 已细化为 hook 方案，见 [Approval Broker 设计](docs/superpowers/specs/2026-06-17-approval-broker-design.md)。** 下面要点中"检查 prompt hash / 抓屏"已被 worker session 的 `PreToolUse` hook 取代（工具执行前进程内 allow/deny/ask，不再抓屏）。

### MVP 1：安全 approve

- 增加 `peer approvals`。
- 增加 `peer approve --once`。
- 只处理当前对方 Agent。
- 仅支持 allowlist 命令。
- ~~检查 prompt hash~~ → 改为 `PreToolUse` hook 决策（见上）。
- 写 `approvals.jsonl`。

目标：解决 80% 的低风险确认打断问题。

### MVP 2：policy.toml

- 支持命令前缀匹配。
- 支持 cwd/path 限制。
- 支持 deny 优先。
- 支持 TTL 租约。

目标：从一次性 approve 变成可配置的授权边界。

### MVP 3：agent registry & dynamic roles

- 增加 `.agent-duo/agents.toml`。
- 增加 `peer ls`。
- 支持 `peer tell <agent-id>`、`peer peek <agent-id>`、`peer wait <agent-id>`。
- 引入 `AGENT_ID`、`AGENT_ROLE`、`AGENT_PROVIDER`。
- 当 Agent 数量超过两个时，要求显式指定目标。

目标：从固定 claude/codex 双人模式升级为动态 Agent 编队。

### MVP 4：worktree worker

- `agent-duo-start --worker worker-impl`
- 自动创建隔离 worktree。
- 为该 worker 注入 `AGENT_ID`、`AGENT_ROLE`、`AGENT_PROVIDER`、`AGENT_WORKTREE`。
- 默认 policy 允许写入自己的 worktree。

目标：让 Worker 可以安全持续执行。

### MVP 5：supervisor loop

- `peer ask`：`tell + wait + peek`，只返回新增输出。
- `agent-duo loop run contract.yaml`
- 支持 max_rounds、validation commands、stop conditions。

目标：让 agent-duo 从“互看互发”升级为“可控 loop harness”。

### MVP 6：human decision gate

- 增加 `peer gate`。
- Supervisor 可创建 Decision Packet。
- 支持 `blocked-on-human-decision` 状态。
- 将用户选择写入 `decisions.jsonl`。
- 将选择结果转成 Worker 的下一步任务。

目标：让 loop 在采购、部署、网络策略等阶段可靠暂停，并给用户足够信息做决定。

### MVP 7：truthful progress protocol

- 增加 `peer report`。
- 规定 Worker 汇报状态：`done`、`partial`、`blocked`、`failed`、`unknown`。
- done 状态必须附 evidence。
- Supervisor 可标记 `blocked-on-missing-evidence`。
- 将结构化汇报写入 `reports.jsonl`。

目标：让 Agent 不能用没有证据的文字总结冒充执行结果。

### MVP 8：direction control

- 增加 `peer checkpoint`。
- 增加 `peer reframe`。
- loop contract 支持 `mission`、`non_goals`、`success_signals`。
- Supervisor 检测 detail trap。
- 将方向检查写入 `checkpoints.jsonl`。

目标：让 Supervisor 定期把 Worker 从局部细节拉回目标和验收条件。

### MVP 9：quota & budget broker

- 增加 `peer budget`。
- loop 状态落盘到 `.agent-duo/state/`。
- 支持 `handoff packet`。
- Supervisor 默认事件驱动，减少无意义轮询。
- 支持 quota low 降级模式。

目标：避免上位 Agent 额度先耗尽导致整个系统停滞。

## 路线图

```text
Phase 0: 当前 agent-duo
  - two-agent peer peek/tell/wait
  - human-in-the-loop

Phase 1: Agent Registry & Dynamic Roles
  - .agent-duo/agents.toml
  - peer tell/peek/wait <agent-id>
  - role/provider/capability separation
  - dynamic team profile

Phase 2: Approval Broker
  - peer approvals
  - peer approve --once
  - prompt hash
  - audit log

Phase 3: Policy & Lease
  - .agent-duo/policy.toml
  - allow/deny rules
  - TTL lease
  - risk classification

Phase 4: Worker Isolation
  - N-agent support
  - worker worktrees
  - role-based prompts
  - scoped write permissions

Phase 5: Supervisor Harness
  - loop contract
  - evaluator role
  - validation commands
  - stop/escalate/rollback decisions

Phase 6: Human Decision Gate
  - decision packet
  - blocked-on-human-decision state
  - deploy/provision/firewall gates
  - decisions audit log

Phase 7: Truthful Progress
  - evidence packet
  - structured worker report
  - stuck detector
  - blocked-on-missing-evidence state

Phase 8: Direction Control
  - mission compass
  - direction checkpoint
  - detail trap detector
  - re-scope/escalate decisions

Phase 9: Quota & Budget Broker
  - event-driven supervisor
  - durable loop state
  - handoff packet
  - degraded supervision mode

Phase 10: Team Mode
  - shared policies
  - reviewable audit logs
  - CI integration
  - organization-level defaults
```

## 产品定位

一句话定位：

 > agent-duo turns visible coding-agent sessions into a dynamic, supervised, auditable multi-agent workbench with explicit approval, decision, evidence, direction, and budget gates.

中文：

> agent-duo 把用户眼前真实运行的编码 Agent 会话，变成可动态编队、可监工、可授权、可决策、可验真、可校准方向、可控预算、可审计的多 Agent 工作台。

它和 MCP bridge 的区别：

- MCP bridge 偏结构化调用、无头子任务、一次性请求响应。
- agent-duo 偏真实 session、可见状态、长期上下文、人工可介入。

它和普通 loop 的区别：

- 普通 loop 容易变成 cron prompt。
- agent-duo 的 supervisor loop 强调观察、验收、授权、决策、证据、方向、预算、停止和审计。

## 核心原则

1. Agent 之间不能无监督闲聊。
2. Agent 身份、角色、provider、能力和预算必须解耦，不能固定死在两个窗口名上。
3. 每个 loop 必须有目标、预算、验收和停止条件。
4. 授权应该是 capability，不是盲按 yes。
5. 决策应该是 gate，不是让 Agent 猜用户偏好。
6. Worker 默认隔离，Supervisor 默认审计。
7. 低风险自动化，高风险升级给人。
8. 采购、部署、网络入口和生产动作必须显式决策。
9. done 必须有证据；没有证据只能是 unknown、partial 或 blocked。
10. 验收信号优先来自测试、日志、截图、CI，而不是 Agent 自我感觉。
11. Worker 的每轮动作必须能映射到 mission outcome 或 success signal。
12. 当局部细节不再推动验收条件时，Supervisor 必须 reframe 或 re-scope。
13. Supervisor 必须轻量化、事件驱动，并能在额度不足前生成 handoff packet。
14. loop 状态必须持久化，不能只存在上位 Agent 的上下文窗口里。
15. 同一错误重复、缺少证据、无法访问外部系统时必须及时上报。
16. 所有 Agent 变更、自动授权、人工决策、关键汇报、方向校准和预算降级必须可回放。

## 结论

agent-duo 的下一步不应只是增加更多 Agent，而是先建立控制平面。

最有价值的演进路径是：

```text
peer -> agent registry -> approval broker -> decision gate -> evidence gate -> direction gate -> budget gate -> worker isolation -> supervisor loop -> team-governed harness
```

这条路径解决的不是“如何让两个 Agent 聊天”，而是“如何让多个 Agent 在人类设定的边界内持续工作，并且在需要时可靠停下来”。
