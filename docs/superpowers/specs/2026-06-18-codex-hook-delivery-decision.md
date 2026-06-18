# Codex hook 投递方案决策记录（A vs B）

日期：2026-06-18
状态：决策已定 —— 采用 A（`-c` 注入 + 可观测自检 + fail-closed 门控），放弃 B（per-role CODEX_HOME）。
关联：[Codex hook 交互验证](./2026-06-18-codex-hook-interaction-validation.md)、[Approval Broker 设计](./2026-06-17-approval-broker-design.md)、[worker↔supervisor 契约](./2026-06-17-worker-supervisor-contract.md)

## 背景

2026-06-17 暂停的 brainstorm 曾「决定」用 **per-role CODEX_HOME**（supervisor / worker 两个 home，各 symlink 镜像 `~/.codex` + 真实 `hooks.json`）来投递 Codex hook，理由是「`-c hooks.*` 加载不了 hook」「worker/supervisor 需要隔离 hook」。

2026-06-18 的实测（见验证文档）把这两个立论都推翻了，且实现已沿 A 路线落地（issue #8/#9）。本文把对比、决策依据、以及 A 自身仍存的漏洞与硬化 backlog 固定下来。

## 决策：采用 A，放弃 B

### B 的两个原始立论都已失效

| CODEX_HOME 的原始立论 | 实测结论 |
|---|---|
| 「`-c hooks.*` 加载不了 hook」 | ❌ `-c` 在交互式 CLI 里生效（deny 拦住、目标文件未创建）。见验证文档 §2。 |
| 「worker/supervisor 须隔离 hook，避免交叉」 | ❌ 已由 per-role `-c` 注入解决：supervisor 进程只注入 `UserPromptSubmit`+`Stop`，worker 进程只注入 `PreToolUse`+`PermissionRequest`，进程级天然隔离，无需 gating（`start.sh` / `bin/peer` / `lib/registry.sh`）。 |

### 真正的痛点 B 也治不了

trust 首启 fail-open（未信任 hook 时 Codex 不调用 hook、工具照跑、supervisor 无从感知）是真正要解决的问题。一个全新 CODEX_HOME 里放真实 `hooks.json`，**首次仍会弹「Hooks need review」**，选「continue without trusting」照样 fail-open。所以无论用哪种投递机制，**「可观测自检 + fail-closed 门控」（A 的核心）都必需**。

### 对比小结

- **A（已落地）**：投递机制已验证；role 隔离免费；自检直接解决真正的缺口；零新增长期组件。代价：命令行里的 `hooks.*=[{...}]` TOML 长、引号转义脆、不可读、不好审计；trust 仍是手动门（靠 `broker-check` 兜）。
- **B（CODEX_HOME）**：hook 配置落到真实文件，干净、可审计、为未来 managed/`requirements.toml` 留路。代价：两个原始立论已失效；symlink 镜像 `~/.codex`（auth/config/sessions/plugins）脆、有漂移风险；新增 `lib/codex_home.sh` + 生命周期/清理；**仍解决不了 fail-open**。

**结论**：A 在两种机制下都必需且充分；B 是正交的「投递/隔离」优化，而那两个问题实测早已不存在 → B 现为 YAGNI。若将来命令行 `-c` 引号脆弱性真的咬人，或需要 managed hooks，再单独评估把投递切到文件（可与 A 并存，不互斥）。

## 实测中发现并已修复的真 bug：PermissionRequest 输出 schema（⑥）

**问题**：`ab_output` 原先对**所有事件**都发 `hookSpecificOutput.permissionDecision`。但 Codex 各事件 schema 不同（已对 developers.openai.com/codex/hooks 核实）：

- `PreToolUse` → `hookSpecificOutput.permissionDecision`（+ `permissionDecisionReason`）。
- `PermissionRequest` → **只认** `hookSpecificOutput.decision.behavior`（+ `message`）；它**不认** `permissionDecision`。

worker 以裸 `codex` 启动（`lib/registry.sh`，无 `-a`/`--sandbox`/bypass），默认模式会对风险动作发原生审批 → **PermissionRequest 实战会触发**。原实现在该事件上发 `permissionDecision`，deny 是 silent no-op → **原生审批路径 fail-open**。与当初 `e7c6a2c` 修的 PreToolUse bug 完全对称（方向相反）。

**修复**：`ab_output` 按事件分 schema —— `PermissionRequest` 输出 `decision.behavior`（deny 带 `message`），其余仍用 `permissionDecision`。

**回归**：`test/approval.test.sh` 新增 PermissionRequest 的 deny/allow schema 断言（deny 用 `decision.behavior`、且不含 `permissionDecision`）。全套绿。

**真机 e2e（已完成）**：`test/codex-permreq-e2e.test.sh` 用真实 Codex（实测 0.141.0）在 `-a untrusted` 下验证：
- **ALLOW 是判别器** —— apply_patch（对 Codex 非 trusted → 触发 PermissionRequest）被 broker `decision.behavior=allow` 放行后**真的执行并建出文件**。旧代码发 `permissionDecision` 会被忽略 → 回落原生审批弹窗 → tmux 无人应答 → 文件建不出，故此断言能区分新旧。
- **DENY** —— apply_patch 写 `.env` 被 broker `deny.secret_path` 硬拒，hook 确实被调用（marker ready + 审计 deny），secret 文件未创建。
默认 skip（`AGENT_DUO_E2E_CODEX=1` 开启；需 codex + tmux + `~/.codex/auth.json`）。

## A 自身仍存的漏洞与硬化 backlog

以下是 A 的已知薄弱点，按优先级排。均为「强化 A」，与 B 无关。

1. **① 验证是时间点的，marker 不绑 session、不过期（安全）**：worker 的 Codex session 重启后回到未信任 → fail-open，但新 session 不触发 hook → heartbeat 不更新 → marker 停在旧 `ready` → supervisor 读到过期绿灯误派。
   - 修法：marker 记录来源 `session_id`（hook payload 里有），`broker-check`/门控要求 marker 的 `session_id` == 当前 worker session；或给 marker 加 TTL，保护性派发前要求「近期 ready」。
2. **④ marker 只升不降、无 TTL（①的根）**：一旦 `ready` 永远 `ready`，session 死掉也不降级。与 ① 同源，TTL/session 绑定一并解决。
3. **⑦ 探针只验 PreToolUse，从不验 PermissionRequest**：`broker-check` 投 shell 命令 → 只触发 PreToolUse。即便 `ready`，PermissionRequest 路径未被验证。叠加 ⑥（已修）后风险下降，但仍应让 `broker-check` 或 e2e 覆盖一次 PermissionRequest。
4. **② 门是契约软门，不是机械硬门（安全）**：gating 写在契约里要求 supervisor「派发前确认 ready」，但 supervisor 是 LLM，忘了就会派进 fail-open worker；`peer send` 不校验 broker-status。
   - 修法：把门做硬 —— 投递路径（`peer` 发任务给 worker）自己读 marker，非 `ready`（或 session 不匹配）直接拒发。
5. **⑧ sentinel 自指风险**：`AGENT_DUO_BROKER_SELFCHECK_` 现存在于本仓库 test/docs。worker 在正常任务里 grep/编辑这些文件、命令里带上形如 `..._<字母数字>` 的 token 会被误判成自检 → 真实命令被 deny、marker 被污染。概率低但是仓库自指地雷。
   - 修法：自检 sentinel 要求更强的封套（如同时带固定前后缀的随机 nonce），或仅在「命令整体即探针」时识别，而非子串命中。

### ③ 探针可靠性是结构性约束（不是可消除的 bug）

Codex hook 只在真实工具调用时触发，工具调用只能由 model 发起 → **没有带外方式让 Codex 跑一次 hook** → 任何「证明 hook 生效」的探针都必须绕经 model。由此：

- 探针无法做成 model-无关；B 对此毫无帮助。
- bootstrap 死锁（ready 才派任务，但 ready 又靠一次 hook 点亮）决定了**主动探针删不掉**。
- 能做的只有：把「pass」当唯一权威信号（现状如此，假阳性不可能）；硬化 paste（探针前检测 TUI 在干净 prompt、失败重试）；别当成持续保证（稳态靠真实工具调用的 heartbeat）；区分「超时=未信任」与「超时=model 没配合」以减少假 fail-open。
