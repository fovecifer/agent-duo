# agent-duo Approval Broker 设计（hook 化）

日期：2026-06-17
状态：设计稿，待实现（对应 roadmap MVP 1 / MVP 2）
关联：[supervisor-loop roadmap](../../../agent-duo-supervisor-loop-roadmap.md)、[loop runtime 设计](./2026-06-17-loop-runtime-design.md)、[worker↔supervisor 契约](./2026-06-17-worker-supervisor-contract.md)、[Codex hook 交互验证](./2026-06-18-codex-hook-interaction-validation.md)

## 为什么换方案

roadmap 草案里 `peer approve` 是**抓屏 + 校验 prompt hash + 发 Enter**——脆、只能 approve、是个旁路。Claude Code 与 Codex 都提供能**程序化 allow/deny 工具调用**的 hook（Codex 为 `PreToolUse` / `PermissionRequest`），让我们能在**工具执行前、进程内**做决策。本稿用 hook 重做 Approval Broker。

## 核心洞察：auto-approve 只是副产物，真正要做的是"把权限请求接进 loop"

旧方案只能"替人按 yes"。但真正痛点是 worker **卡在本地权限 prompt 上干等**。hook 化能根治：权限决策发生在工具执行前，我们让"不能自动放行"的请求**不再以 worker 本地 prompt 的形式出现**，而是变成 loop 里的一个 `request` 事件，走已设计好的升级机制（见 runtime 设计「汇报攒批与升级判定」）。

> Approval Broker = **worker session 上的 tool/permission hook + 把决策接进事件队列**，不是一个按键器。

## 目标

- 低风险权限**机械自动放行**，消除 80% 的确认打断。
- 高风险/不确定**升级**为 loop 事件，而非让 worker 在本地 prompt 干等。
- 全程可审计（`approvals.jsonl`），边界可随时间从日志收敛。
- Claude / Codex 通用。

## 非目标（YAGNI）

- 不把 allowlist 当安全护城河（见[诚实定位](#诚实定位allowlistux安全worktreedenylistescalate)）。
- 不做跨机器、跨 session 的集中授权服务。
- MVP 1 不做 lease；lease 属 MVP 2。

---

## 1. Hook 放哪、用哪个

- **主**：worker session 上挂 `PreToolUse` hook，工具执行前触发；一次 policy 评估，内部 deny 优先。
  - `allow` 短路掉权限 prompt（工具直接跑）；`deny` 拦下。
  - Codex 侧不要用 `PreToolUse ask` 表示升级人工确认；2026-06-18 实测表明 Codex 会继续执行工具。Codex 的 `escalate` 应建模为 `deny + 写待批事件/approval record`。
- **Codex 侧补充入口**：同一个 broker hook 同时挂 `PreToolUse` 与 `PermissionRequest`。`PermissionRequest` 只接管 Codex 原生权限 prompt，避免 worker 卡在本地 UI；它不是主安全闸，不能替代 `PreToolUse`。
- **provider adapter**：Claude / Codex 事件名相近，但输出语义不是完全同构；详见 [Codex hook 交互验证](./2026-06-18-codex-hook-interaction-validation.md)。注意 Codex 的"非托管 hook 需审核信任"要求——`peer add` / `agent-duo-start --with` 装 hook 时按 Codex 的 hook trust 机制处理。

---

## 2. 三种 loop 意义上的结局（关键）

hook 的输出不映射成裸的 allow/deny，而是三种**对循环有意义**的结局：

| 结局 | hook 动作 | worker 怎样 | 进 loop |
|---|---|---|---|
| **auto-allow** | `allow` | 工具直接跑 | 第③档，仅记 `approvals.jsonl` |
| **escalate** | `deny` + 写 `approval pending` + 入队 `blocked` 事件 | 不在本地 prompt 干等；看到理由后停下等待 | 走升级；批准后 worker **重跑**该工具 → 命中 approval/lease → auto-allow |
| **hard-deny** | `deny` + 写 `hard-denied` + 入队 `blocked` 事件 | 改走别的路 / 报 `blocked-on-policy` | 让 supervisor 知道，标「不会自动放行」 |

**escalate 这一行是枢纽**：它把"不能自动放行"从"worker 卡死"变成"loop 里一个待批请求"，批准后靠 worker 重跑 + approval/lease 自动通过——彻底消灭本地 prompt 干等。hook 写入的 `blocked` 事件是 canonical 事件源；worker 可再用 `peer report` 镜像自己的停顿状态，但 supervisor 不能依赖模型一定会补报。

`deny` 的两种理由文本（worker 由其契约 prompt 区分）：
- escalate：`BLOCKED-PENDING-APPROVAL: 需 supervisor/人批准；报 blocked 并等待，勿另寻他法。`
- hard-deny：`DENIED-BY-POLICY: 禁止；勿重试；改走他法或报 blocked-on-policy。`

---

## 3. policy 评估（hook 内部算什么）

当前 MVP 先用 broker 内置 deny/allow 规则 + approval 文件状态；`policy.toml`（MVP 2）+ lease 是后续扩展。评估顺序保持 **deny 优先**：

```
1. 命中 deny 规则?                                         → hard-deny
   （sudo / ssh / git push / rm -rf / curl|sh、
     ~/.ssh|~/.aws|.env、worktree 外的写）
2. 命中 allow 规则，或有一次性批准/未来活跃 lease，且可逆(worktree 内 / git 可撤)? → auto-allow
3. 其余                                                     → escalate
```

这就是升级决策树在**执行时刻的机械落地**。可逆性轴很自然：**写 worktree 内 = 可逆 = 可放行；碰 worktree/git 以外 = escalate 或 deny**（与 roadmap"能不能只用 git 撤销"判据一致）。

工具类型差异：
- **Bash**：命令串要**按段拆**（`&& || ; |` 与子shell），任一段命中 deny 即 deny；只有**全段**命中 allow 才 allow。
- **Edit/Write**：目标路径是结构化的——worktree 内放行、外 escalate，比 Bash 干净。
- **MCP 工具**：按 `mcp__<server>__<tool>` 名单。

---

## 诚实定位：allowlist=UX，安全=worktree+denylist+escalate

shell 命令允许名单本质上**防不住恶意**（`npm test && rm -rf ~`、管道、子 shell、脚本里再发网络请求……按段拆也不完美）。因此摆正定位：

> **allowlist = 减少打扰（UX）；真正的安全边界是 worktree 隔离（写不出去）+ deny 清单 + "拿不准就 escalate"。**

一个被搞糊涂 / 被攻陷的 worker 由 **worktree 隔离 + "出 git 必升级"** 兜住，而不是靠 allowlist。安全声明里不得把 allowlist 写成护城河。

---

## 4. 批准状态与后续 Lease

- **当前 MVP**：未知但非 hard-deny 的动作写入 `.agent-duo/approvals/`，状态流转为 `pending → approved → consumed`，实现一次性放行。
- **后续 lease**："某类动作在 T 时间内自动放行"，存 `.agent-duo/leases.jsonl`（`scope` / `agent` / `granted_by` / `expires_at`），hook 读它。
- **谁能批**，复用可逆性轴：
  - **可逆 + 低风险** → supervisor 可**自主**授 lease（不烦人）。
  - **不可逆 / 外部** → 第①档升级到**人**。
- 当前批准 = supervisor/人执行 `peer approve <id>` → worker 重跑 → hook 消费 approved 文件 → auto-allow。后续批准可升级为写 lease + 通知 worker 重跑 → hook 见活跃 lease → auto-allow。

```jsonc
// .agent-duo/leases.jsonl
{"ts":"…","agent":"worker-impl","scope":"allow.test","granted_by":"supervisor","expires_at":"2026-06-17T13:00:00Z"}
```

---

## 5. peer 命令面（水线下，人只说人话）

```sh
peer approvals                              # 列待批请求
peer approve <id> [--lease 30m --scope test]
peer deny <id> [--reason "..."]
```

这些是 **supervisor 的内部动作**。人只说"批了"/"那个别给它权限"，supervisor 翻译成命令。大量情况根本不需要命令——policy 直接 auto-allow。（与 runtime 设计「人作为交互方」一致：人永远只说自然语言。）

---

## 6. 审计与边界自学习

每个 hook 决策写 `.agent-duo/logs/approvals.jsonl`：

```json
{"ts":"2026-06-17T12:00:00Z","agent":"worker-impl","tool":"Bash","cmd":"npm test","cwd":".agent-duo/worktrees/worker-impl","decision":"auto-allow","matched":"allow.test","lease":"l7","granted_by":"policy"}
{"ts":"2026-06-17T12:01:00Z","agent":"worker-impl","tool":"Bash","cmd":"terraform apply","cwd":"…","decision":"hard-deny","matched":"deny.infra","granted_by":null}
```

既是审计，也是"边界从日志里长出来"的数据源——人事后放宽（"这类以后别问我"）/收紧（"这类永远问我"）policy。

---

## 7. 集成约束

- **装 hook**：`peer add` / `agent-duo-start --with` 创建 worker pane 时，把 broker hook 写入该 session 的 settings；Claude 通过 `--settings` 加载，Codex 通过临时 `-c hooks.PreToolUse=...` 与 `-c hooks.PermissionRequest=...` 配置加载并走自身 hook 信任机制。
- **发事件**：escalate / hard-deny 的 hook 除返回 `deny`，还向 `.agent-duo/events/queue.jsonl` 追加 `blocked` 事件（与 runtime 队列同一格式），由 loop 升级机制接手。该事件必须幂等：同一 agent/round/summary 重试不能刷屏。
- **读 policy/lease**：当前 MVP 用 approval 文件状态实现一次性放行（`pending → approved → consumed`）；后续可扩展为 `.agent-duo/policy.toml` 与 `.agent-duo/leases.jsonl`。这些授权状态只允许 supervisor/人写（worker 不能改自己的授权——roadmap 安全原则）。
- **worktree 依赖**：可逆性判据依赖 worker 在隔离 worktree 内工作（MVP 4）。MVP 1/2 先期可用"cwd 前缀"近似 worktree scope。

---

## 7.1 broker 就绪自检（fail-closed，issue #9）

Codex 的非托管 hook **未信任时不生效且 fail-open**——hook 根本不被调用，工具照常执行（实测见 [Codex hook 交互验证](./2026-06-18-codex-hook-interaction-validation.md) 的「Hook trust 首启行为」）。因此「装了 hook」不等于「broker 生效」，必须把生效性变成**可观测、可门控**的状态：

- **就绪 marker**：broker hook 每次被实际调用都会写 `.agent-duo/state/<agent>/broker.json`（`status:ready`）。这是「provider 真的调用了我们」的权威信号——不依赖 Codex 内部 trust 存储（未文档化、版本易变）。marker 现携带 `updated_epoch`（Unix 时间戳，鉴新）和 `session_id`（溯源取证）。
- **自检探针**：命令/路径带 `AGENT_DUO_BROKER_SELFCHECK_<nonce>` 哨兵时，hook **设计性 deny** 并把 marker 写成 `ready` + 该 nonce，但**不**创建 approval、**不**入队 blocked event（无残渣、自证）。
- **`peer broker-check <id>`**：向 worker 投递一条良性探针命令，轮询 marker；命中 `ready`+nonce → broker 生效；超时未命中 → 写 `status:fail-open` 并非零退出。
- **`peer broker-status <id>`**：读 marker，回报 `ready | stale | unverified | fail-open`；当 `ready` marker 的 `updated_epoch` 超过 `AGENT_DUO_BROKER_TTL`（默认 60s）时报 `stale`，含义等同于不就绪。结果以 JSON 输出到 stdout；状态非 fresh `ready` 时向 stderr 写入一行提示，建议先运行 `peer broker-check <id>`。
- **机械硬门**：`peer tell` 对**工作型角色**目标是机械 fail-closed——发送前自动读取目标 broker marker，状态非 fresh `ready` 时直接拒发（非零退出，不触发 tmux 侧效应）；supervisor 无需自行记得检查。工作型 = 除 `supervisor`/`daemon`/`loopd` 外的所有角色（含 `worker`、`reviewer` 及自定义角色，实现按豁免名单取反）。探针路径（`peer broker-check`）及发往豁免名单角色（`supervisor`/`daemon`/`loopd`）的消息豁免此门控；`reviewer`/自定义工作角色不豁免。`--force` 或 `AGENT_DUO_NO_BROKER_GATE=1` 可越过硬门（见 worker↔supervisor 契约 §2.6）。`stale` / `unverified` / `fail-open` 均视为不就绪——应先运行 `peer broker-check <id>` 确认返回 `ready` 后再派。`peer add` 创建 codex worker 时 marker 起始为 `unverified`，并提示先 `peer broker-check`。

---

## 8. MVP 切法

- **MVP 1**：deny 清单 + allow 清单 auto-allow + escalate（发 request 事件），**无 lease**；写 `approvals.jsonl`。解决 80% 低风险打扰。
- **MVP 2**：加 lease（TTL）+ 完整 `policy.toml`（前缀/路径/deny 优先）+ 可逆性/worktree scope。

---

## 9. 相比旧方案（抓屏+回车）

| 维度 | 旧：抓屏+回车 | 新：PreToolUse hook |
|---|---|---|
| 时机 | 权限弹窗出现**之后** | 工具执行**之前** |
| 机制 | 解析屏幕 + prompt_hash + 发 Enter | 进程内 JSON 决策 |
| 能力 | 只能 approve | allow / **deny**（`ask` 需按 provider 实测；Codex 不可用于升级） |
| 鲁棒性 | 依赖 TUI 渲染、有竞态 | 确定性、无抓屏 |
| 与 loop | 旁路 | escalate→request→重跑，**接进 loop** |
| 跨 provider | 各 TUI 不同 | hook 化通用，输出层按 provider 适配 |
