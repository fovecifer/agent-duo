# Broker marker 新鲜度 + session 绑定设计（硬化 backlog ①/④）

日期：2026-06-18
状态：设计已批准，待实现。
关联：[Codex hook 投递方案决策](./2026-06-18-codex-hook-delivery-decision.md)（backlog ①④ 来源）、[Approval Broker 设计](./2026-06-17-approval-broker-design.md)、[worker↔supervisor 契约](./2026-06-17-worker-supervisor-contract.md)、[Codex hook 交互验证](./2026-06-18-codex-hook-interaction-validation.md)

## 要解决的具体问题

**一句话**：Approval Broker 的就绪 marker 是「永不过期的绿灯」——worker 的 Codex session 重启后变回未信任、静默 fail-open，但 marker 仍显示 `ready`，导致 supervisor 把需要 broker 保护的任务误派进一个其实没有保护的 worker。

**具体场景**：

1. worker 启动、用户在该 pane 信任 hook、`broker-check` 通过 → marker = `ready`。supervisor 据此放心派发保护性任务。
2. 该 worker 的 codex 进程重启（崩溃 / 手动重启 / 上下文重置）→ 新 session 回到「未信任」状态 → hook 不再被调用 = 工具调用不经 broker（fail-open）。
3. 但新 session **不触发任何 hook**，所以 marker 既不更新时间戳也不被改写，**仍停在旧的 `ready`**。
4. supervisor 再次读 `broker-status` → 看到 `ready` → 把保护性任务派进这个已经裸奔的 worker。**保护静默失效，且无人察觉。**

**本 spec 要达到的结果**：让「ready」不再是永久绿灯——重启后停发 hook 的 worker 在 TTL 后被判为 `stale`，门控据此拒绝派发并要求重新 `broker-check`。即决策文档 A 硬化 backlog 的 ①（验证是时间点的、marker 不绑 session/不过期）+ ④（marker 只升不降、无 TTL）。

## 关键约束与机制选择

**外部门控无法实时读到 worker 当前的 Codex `session_id`** —— 它只出现在 hook payload 里，活在 codex 进程内部。因此：

- 危险场景是「重启 + 未信任」：新 session 静默 fail-open、**不发任何 hook**，所以 session_id 比对拿不到信号。
- session_id 绑定**只能抓「重启 + 已信任」**（新 session 会发 heartbeat 带新 session_id）—— 而那是安全场景。
- 唯一能抓到静默危险场景的信号是**新鲜度**：未信任的重启 session 停发 heartbeat → `updated_at` 变旧 → 门控把「旧的 ready」当成不可信。

**结论**：新鲜度（TTL）是承重机制；session_id 仅作佐证/排障，**只记不比对**（外部无从比对当前 session）。

## 设计

### 1. Marker schema 扩展

`ab_write_broker_marker` 新增两个字段：

- `session_id`：取自 hook payload（新增 accessor `ab_payload_session_id`，读 `session_id`）。每次 heartbeat / selfcheck 覆盖为当前 session。纯佐证/排障，不参与判定。
- `updated_epoch`：写入时的 `date +%s`（整数秒）。让 status 用纯整数算 age，避免跨平台解析 ISO（`ab_iso_ts` 是 `%Y-%m-%dT%H:%M:%SZ`，回解析在 macOS/GNU `date` 上不一致）。`updated_at`（ISO）保留供人读。

`ab_cmd_mark`（手动标 `fail-open`/`unverified`）不带 session_id，行为不变。

marker 示例（ready）：

```json
{"agent":"worker","status":"ready","updated_at":"2026-06-18T15:00:00Z","updated_epoch":1781880000,"session_id":"019ed8...","nonce":"bc12ab","last_decision":"selfcheck"}
```

### 2. `ab_cmd_status` 变新鲜度感知

读 marker 后：

- marker 不存在 → `{"agent":..,"status":"unverified"}`（不变）。
- `status==ready` 且 `now - updated_epoch > TTL` → 输出 `"status":"stale"`，附 `"age_seconds":N`，并保留 `session_id`/`updated_at`/`nonce`/`last_decision`。
- `status==ready` 且 `now - updated_epoch <= TTL` → 输出 `ready`，附 `"age_seconds":N`。
- `status` 为 `fail-open` / `unverified` → 原样输出（新鲜度只降级 `ready`，不改写已是「非 go」的状态）。
- marker 缺 `updated_epoch`（旧格式遗留）→ 视为过期，按 `stale` 处理（fail-closed）。

TTL 取自环境变量 `AGENT_DUO_BROKER_TTL`，默认 **60**（秒）。

状态值全集：`unverified` | `ready` | `stale` | `fail-open`。其中只有 fresh `ready` 是「可派发保护性任务」。

### 3. 不受影响的部分

- `peer broker-check`：直接用 `jq` 读 marker 原始 `status=="ready"` + nonce（不经 `ab_cmd_status`），且它刚投递过探针、marker 本就新鲜 → 无需改动；并自动获得 session_id 记录。
- `peer broker-status`：继续转发 broker 的 JSON，`stale` 自然透出；额外在 `stale`/`fail-open`/`unverified` 时打一行 stderr 提示「先 broker-check」。
- selfcheck / heartbeat / 审计路径：除多写两字段外逻辑不变。

### 4. 契约 / 文档

- worker↔supervisor 契约 §2.6 与 Approval Broker 设计 §7.1：把门控判据从「`ready`」收紧为「**fresh `ready`**」；遇 `stale` / `fail-open` / `unverified` 一律先 `broker-check` 再决定是否派发保护性任务。
- 决策文档 backlog：①④ 标记已解决，链接本 spec。

### 5. 暴露窗口（已知边界）

TTL=60s ⇒ 静默重启后最坏 60s 内仍可能把 marker 判为 fresh。这是「外部无法实时读 session」约束下 ① 能达到的边界。要彻底关闭需 ②（派发路径机械硬门 + 保护性派发前强制重探），属独立 backlog，不在本 spec 范围。

## 测试（TDD，无 sleep）

`test/approval.test.sh`：

- marker 记录 `session_id`：`run_hook` 的 payload 带 `session_id` → `status` 输出含该 session_id。
- 新鲜度降级：写一次 heartbeat（marker fresh）后，以 `AGENT_DUO_BROKER_TTL=0` 调 `status` → `age_seconds>0` → `status==stale`；以大 TTL（默认 60）调 → 保持 `ready`。
- `fail-open` 不被新鲜度改写：`mark fail-open` 后即使 `AGENT_DUO_BROKER_TTL=0`，`status` 仍为 `fail-open`。
- 旧格式遗留（无 `updated_epoch`）→ `stale`（fail-closed）。

`test/peer.test.sh`：

- `broker-status` 透出 `stale`：构造一个 `updated_epoch` 在过去的 marker → `peer broker-status <id>` 输出 `stale`。

均不依赖 `sleep`：通过环境变量 TTL 与构造的 `updated_epoch` 控制 age。

## 实现影响面

- `lib/approval_broker.sh`：`ab_payload_session_id`（新）、`ab_write_broker_marker`（+2 字段）、`ab_run_hook`（取并传 session_id）、`ab_cmd_status`（新鲜度逻辑 + TTL）。
- `bin/peer`：`broker-status` 分支加 stale/fail-open/unverified 的 stderr 提示。
- `test/approval.test.sh`、`test/peer.test.sh`：新增断言。
- 契约 §2.6、Approval Broker 设计 §7.1、决策文档 backlog：文档更新。
