# Hook 事件可观测设计（硬化 backlog ⑦）

日期：2026-06-19
状态：设计已批准，待实现。
关联：[Codex hook 投递方案决策](./2026-06-18-codex-hook-delivery-decision.md)（backlog ⑦ 来源）、[Codex hook 交互验证](./2026-06-18-codex-hook-interaction-validation.md)、[Approval Broker 设计](./2026-06-17-approval-broker-design.md)、[marker 新鲜度设计](./2026-06-18-broker-marker-freshness-design.md)

## 要解决的具体问题

**一句话**：Approval Broker 的运行时信号（就绪 marker、审计日志）**不记录是哪种 hook 事件**触发的（PreToolUse 还是 PermissionRequest），而 `peer broker-check` 的探针只触发 PreToolUse——所以即便一个 worker 标了 `ready`，「PermissionRequest 路径在该 worker 上真的被调用过吗」在运行时既看不见也查不到。

**背景与边界**：

- `codex-permreq-e2e.test.sh`（在 ⑥ 中已建）已用**真实 Codex** 端到端验证 PermissionRequest 的 allow/deny 路径（schema 正确、deny 真的拦截）。所以 ⑦ 里「e2e 覆盖一次 PermissionRequest」这半**已完成**。
- 剩下的是**运行时可观测性**：marker 只记 `last_decision`，审计只记 `decision`/`tool`，二者都不含 hook 事件名。PermissionRequest 的调用与 PreToolUse 无从区分。
- Codex 的 hook trust 是**整会话 all-or-nothing**（「Trust all and continue」），所以一个 PreToolUse-green 的 `broker-check` 已蕴含该会话 PermissionRequest 也被信任；真正残留的风险是**接线回归**（如某次改动漏掉 `-c PermissionRequest` 注入），而那由 `start.sh`/`peer` 的配置测试覆盖。
- 一个**运行时主动 PermissionRequest 探针**是脆弱的：它只在 worker 实际启动模式下、某个会触发原生审批的动作上才触发，依赖模式/版本，易误报 fail-open（与 ③ 同源的结构性限制）。因此本 spec **不**做主动探针。

**本 spec 要达到的结果**：把 hook 事件名记入审计与 marker，使 PermissionRequest 的运行时调用**可见、可审计**；并以文档说明 live 验证由 e2e 覆盖、broker-check 主探 PreToolUse 的理由。即决策文档 A 硬化 backlog 的 ⑦。

## 设计决策（已确认）

- **可观测，不主动探针**：审计/marker 记录 hook 事件名；`broker-check` 仍只主动探 PreToolUse（主安全闸、可靠触发）。
- **审计 event 读全局**：`ab_append_audit` 通过读已有全局 `AB_HOOK_EVENT_NAME` 写入 `event` 字段，而非给该函数加第 12 个位置参数（过长）。

## 设计

### 1. 审计记录 hook 事件名（核心）

`ab_run_hook` 顶部已设 `AB_HOOK_EVENT_NAME="$(ab_payload_event_name "$payload")"`（缺省 `PreToolUse`，永不为空）。在 `ab_append_audit` 生成的 JSON 行里加一个 `event` 字段，取自该全局：

- hook 路径的每条审计（auto-allow / hard-deny / escalate / selfcheck / approval.once / approval.denied）都会带 `"event":"PreToolUse"` 或 `"event":"PermissionRequest"`。
- 非 hook 路径（CLI `approve` / `deny` 调用 `ab_append_audit` 时全局未设）→ `"event":null`。
- 实现：在 `ab_append_audit` 的 line 拼接里加 `,"event":` + （`AB_HOOK_EVENT_NAME` 非空则 `ab_json_str "$AB_HOOK_EVENT_NAME"`，否则 `null`）。位置放在 `tool` 字段之后即可。

审计日志（`.agent-duo/logs/approvals.jsonl`）因此成为「该 worker 上 PermissionRequest 是否被调用过」的权威历史。

### 2. marker 记最近事件

`ab_write_broker_marker` 新增第 7 个可选参数 `last_event`：

- 签名：`ab_write_broker_marker <root> <agent> <status> [nonce] [decision] [session_id] [last_event]`。
- 非空时写 `"last_event":"<event>"`（与 `nonce`/`session_id` 同样的「非空才写」模式）。
- `ab_run_hook` 的两处 marker 写入（selfcheck 与 heartbeat）传入 `$AB_HOOK_EVENT_NAME`。
- `ab_cmd_mark`（手动 mark fail-open/unverified，非 hook 路径）不传 → 省略该字段。

`peer broker-status` 已原样转发 marker JSON，`last_event` 自动透出。

### 3. 不改

- `broker-check` 探针形态与轮询逻辑不变（仍探 PreToolUse）。
- 策略评估、①②⑥⑧ 的逻辑、`ab_cmd_selfcheck_cmd`、`peer` 派发门控均不变。

## 测试（`test/approval.test.sh`，无 sleep）

复用现有 `run_hook` / `broker_status`，审计日志在 `$PROJECT/.agent-duo/logs/approvals.jsonl`：

- **审计记 PreToolUse**：`run_hook` 一条普通 Bash 命令（如 `ls -la`，无 `hook_event_name` → 默认 PreToolUse）→ 审计日志含 `"event":"PreToolUse"`。
- **审计记 PermissionRequest**：`run_hook` 一条 `{"hook_event_name":"PermissionRequest",...}` → 审计日志含 `"event":"PermissionRequest"`。
- **marker 记 last_event（PermissionRequest）**：上一条之后 `broker_status` 含 `"last_event":"PermissionRequest"`。
- **marker 记 last_event（PreToolUse heartbeat）**：`run_hook` 一条普通 PreToolUse 命令后 `broker_status` 含 `"last_event":"PreToolUse"`。

## 实现影响面

- `lib/approval_broker.sh`：`ab_append_audit` 加 `event` 字段（读全局 `AB_HOOK_EVENT_NAME`）；`ab_write_broker_marker` 加 `last_event` 参数并在两处 hook 调用点传入。
- `test/approval.test.sh`：新增 4 条断言（审计 PreToolUse/PermissionRequest、marker last_event 两种）。
- 决策文档 backlog ⑦：标记已解决，链接本 spec。
- `bin/peer`：无改动（`broker-status` 已透传 marker）。
