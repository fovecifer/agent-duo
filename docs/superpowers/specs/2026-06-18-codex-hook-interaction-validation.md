# Codex hook 交互验证记录

日期：2026-06-18
状态：实测记录，用于修正 Approval Broker 设计
关联：[Approval Broker 设计](./2026-06-17-approval-broker-design.md)、[loop runtime 设计](./2026-06-17-loop-runtime-design.md)、[worker↔supervisor 契约](./2026-06-17-worker-supervisor-contract.md)

## 背景

Approval Broker 原设计假设 Codex 与 Claude Code 的 `PreToolUse` 都能表达三态：`allow` / `deny` / `ask`。2026-06-17 的验证发现 Codex hook 交互与该假设不一致，因此 2026-06-18 对 Codex CLI 做了独立验证。

本记录只描述 Codex CLI 实测行为，不代表 Claude Code 行为。

## 环境

- Codex CLI：`codex-cli 0.140.0`
- 验证方式：本机交互式 Codex CLI + 临时 hook lab
- 临时目录：`/private/tmp/agent-duo-codex-hook-lab/`
- hook 脚本：`/private/tmp/agent-duo-codex-hook-lab/hook.sh`
- 事件日志：`/private/tmp/agent-duo-codex-hook-lab/events.log`
- 官方参考：[Codex Hooks 文档](https://developers.openai.com/codex/hooks)

## 要验证的问题

1. `codex exec` 与交互式 Codex CLI 的 hook 行为是否一致。
2. 当前项目使用的 `codex -c hooks...` 注入方式是否真的生效。
3. `PreToolUse` 的 `deny` / `ask` 在 Codex 上分别是什么语义。
4. `PermissionRequest` 是否能接管 Codex 原生权限请求。
5. hook 输入里 Codex 对 shell 工具的 `tool_name` / `tool_input` 长什么样。

## 验证矩阵

| 场景 | 配置方式 | Codex 启动形态 | 结果 |
|---|---|---|---|
| `UserPromptSubmit` | 项目 `.codex/config.toml` | 交互式 CLI | 生效，hook 收到 prompt |
| `PreToolUse deny` | 项目 `.codex/config.toml` | 交互式 CLI | 生效，命令被阻止，目标文件未创建 |
| `PreToolUse ask` | 项目 `.codex/config.toml` | 交互式 CLI | hook 被调用，但命令继续执行，目标文件被创建 |
| `UserPromptSubmit` | `-c hooks.UserPromptSubmit=...` | 交互式 CLI | 生效，证明当前 `start.sh`/`peer add` 的 `-c` 注入路线可用 |
| `PreToolUse deny` | `-c hooks.PreToolUse=...` | 交互式 CLI | 生效，命令被阻止，目标文件未创建 |
| `PermissionRequest allow` | `-c hooks.PermissionRequest=...` + `-a untrusted` | 交互式 CLI | 生效，原生审批被 hook allow，命令执行 |
| `PermissionRequest deny` | `-c hooks.PermissionRequest=...` + `-a untrusted` | 交互式 CLI | 生效，原生审批被 hook deny，目标文件未创建 |
| `PreToolUse apply_patch` | `-c hooks.PreToolUse=...` + `--dangerously-bypass-hook-trust` | 交互式 CLI | 生效，broker 收到 `tool=apply_patch`，worktree 内新增文件 |
| `PreToolUse deny`（automated smoke） | `-c hooks.PreToolUse=...` + `--dangerously-bypass-hook-trust` | 交互式 CLI（tmux 驱动） | 生效，TUI 显示 `PreToolUse hook (blocked)`，`blocked.txt` 未创建；已固化为 `test/codex-hook-e2e.test.sh` |
| **hook trust 首启（不带 bypass）** | `-c hooks.PreToolUse=...`，未信任 | 交互式 CLI | 先弹「目录信任」，再弹「Hooks need review」；选「Continue without trusting」后 **hook 不运行，命令照常执行，文件被创建** |
| `PreToolUse` / `UserPromptSubmit` | 项目配置或 `-c` | `codex exec` | 未观察到 hook 触发；命令直接执行 |

## 关键实测

### 1. 交互式 Codex 能加载项目 hook

项目 `.codex/config.toml` 中配置：

```toml
[[hooks.PreToolUse]]
matcher = "*"

[[hooks.PreToolUse.hooks]]
type = "command"
command = "/private/tmp/agent-duo-codex-hook-lab/hook.sh pretool-deny"
```

交互式 CLI 中要求 Codex 执行：

```sh
printf INTERACTIVE_PRETOOL_DENY_RAN > interactive-pretool-deny.txt
```

结果：

- TUI 显示 `PreToolUse hook (blocked)`。
- 模型收到拒绝原因 `LAB-DENY pretool`。
- `interactive-pretool-deny.txt` 未创建。
- `events.log` 记录了 `hook_event_name: "PreToolUse"`。

### 2. `-c hooks...` 注入方式可用

当前 `start.sh` / `peer add` 不是写项目 `.codex/config.toml`，而是拼：

```sh
codex -c 'hooks.PreToolUse=[{matcher="*",hooks=[{type="command",command="/path/to/hook"}]}]'
```

单独验证该方式：

```sh
codex -a never --no-alt-screen --dangerously-bypass-hook-trust \
  -C /private/tmp/agent-duo-codex-hook-lab/work \
  -s workspace-write \
  -c 'hooks.PreToolUse=[{matcher="*",hooks=[{type="command",command="/private/tmp/agent-duo-codex-hook-lab/hook.sh pretool-deny"}]}]'
```

结果：

- `UserPromptSubmit` 通过 `-c` 注入可触发。
- `PreToolUse` 通过 `-c` 注入可触发。
- `dash-c-pretool-deny.txt` 未创建。

结论：当前项目的 Codex hook 注入通道本身可用，问题不在 `-c` 注入。

### 3. `PreToolUse ask` 不能用于升级人工确认

hook 返回：

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "ask",
    "permissionDecisionReason": "LAB-ASK pretool"
  }
}
```

交互式 CLI 中要求 Codex 执行：

```sh
printf INTERACTIVE_PRETOOL_ASK_RAN > interactive-pretool-ask.txt
```

结果：

- hook 被调用。
- 没有出现人工确认。
- 命令继续执行。
- `interactive-pretool-ask.txt` 被创建。

这与官方文档一致：Codex `PreToolUse` 会解析 `permissionDecision: "ask"`，但当前不支持；hook run 被标记失败后工具调用继续执行。

## 观察到的 hook 输入

### `UserPromptSubmit`

```json
{
  "session_id": "019ed834-eca6-7052-9610-b71012db45f8",
  "turn_id": "019ed834-ee1c-7703-8b3d-84d66bbde9c5",
  "transcript_path": "/Users/david/.codex/sessions/2026/06/18/rollout-2026-06-18T08-50-07-019ed834-eca6-7052-9610-b71012db45f8.jsonl",
  "cwd": "/private/tmp/agent-duo-codex-hook-lab/work",
  "hook_event_name": "UserPromptSubmit",
  "model": "gpt-5.5",
  "permission_mode": "bypassPermissions",
  "prompt": "Reply with exactly INTERACTIVE_USERPROMPT_HOOK_TEST and do not use tools."
}
```

### `PreToolUse` for shell

```json
{
  "session_id": "019ed83a-48ee-7e92-8b56-0470cfab598e",
  "turn_id": "019ed83a-4a5b-71b2-ac4c-dcce3615f1e6",
  "transcript_path": "/Users/david/.codex/sessions/2026/06/18/rollout-2026-06-18T08-55-58-019ed83a-48ee-7e92-8b56-0470cfab598e.jsonl",
  "cwd": "/private/tmp/agent-duo-codex-hook-lab/work",
  "hook_event_name": "PreToolUse",
  "model": "gpt-5.5",
  "permission_mode": "bypassPermissions",
  "tool_name": "Bash",
  "tool_input": {
    "command": "printf DASH_C_PRETOOL_DENY_RAN > dash-c-pretool-deny.txt"
  },
  "tool_use_id": "call_f0YeCB5xPFso5xZXN29OgQ4h"
}
```

### `PermissionRequest` for shell

```json
{
  "session_id": "019ed83b-6a40-77e3-aa7f-32958c8f9ed4",
  "turn_id": "019ed83b-6c23-7ac2-8bbb-d8a76fb2115c",
  "transcript_path": "/Users/david/.codex/sessions/2026/06/18/rollout-2026-06-18T08-57-13-019ed83b-6a40-77e3-aa7f-32958c8f9ed4.jsonl",
  "cwd": "/private/tmp/agent-duo-codex-hook-lab/work",
  "hook_event_name": "PermissionRequest",
  "model": "gpt-5.5",
  "permission_mode": "default",
  "tool_name": "Bash",
  "tool_input": {
    "command": "python3 -c \"open(\\\"permission-allow.txt\\\",\\\"w\\\").write(\\\"ok\\\")\""
  }
}
```

关键字段：

- shell 工具在交互式 Codex hook 中报告为 `tool_name: "Bash"`。
- shell 命令在 `tool_input.command`。
- `PreToolUse` 有 `tool_use_id`。
- `PermissionRequest` 本次未见 `tool_use_id`。
- `permission_mode` 会随启动策略变化：`-a never --dangerously-bypass-hook-trust` 下观察到 `bypassPermissions`；`-a untrusted` 下观察到 `default`。

### `PreToolUse` for `apply_patch`

2026-06-18 追加验证：

```sh
codex -a never --no-alt-screen --dangerously-bypass-hook-trust \
  -C /private/tmp/agent-duo-codex-apply-patch.* \
  -c 'hooks.PreToolUse=[{matcher="*",hooks=[{type="command",command="AGENT_DUO_ROOT=... AGENT_DUO_AGENT_ID=probe AGENT_DUO_WORKTREE=... /Users/david/workspace/agent-duo/bin/agent-duo-approval-hook"}]}]' \
  'Use the apply_patch tool to create ...'
```

观察结果：

- Codex 创建了 `codex-apply-patch-probe.txt`，内容为 `PROBE_OK`。
- broker 审计日志记录：`"tool":"apply_patch"`、`"decision":"auto-allow"`、`"matched":"allow.worktree_patch"`。
- 因此 `apply_patch` 的交互式工具名与 matcher 至少在 worktree 内新增文件路径上已验证。

未覆盖：交互式验证尚未覆盖 `apply_patch` 写 worktree 外路径、secret 路径 hard-deny；这些当前只由 broker 单元测试覆盖。

## `PermissionRequest` 行为

在 `-a untrusted` 下，要求 Codex 执行需要原生审批的 shell 命令。

hook allow 返回：

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "allow"
    }
  }
}
```

结果：没有人工 prompt，命令执行，`permission-allow.txt` 写入 `ok`。

hook deny 返回：

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "deny",
      "message": "LAB-DENY permission"
    }
  }
}
```

结果：没有人工 prompt，命令未执行，`permission-deny.txt` 未创建，模型收到 `LAB-DENY permission`。

## Hook trust 首启行为（2026-06-18 追加实测，关键缺口）

之前的 deny/allow 实测都带 `--dangerously-bypass-hook-trust`，但**产品启动路径（`peer add` / `start.sh`）并不带这个 flag**（见 `bin/peer` / `start.sh` 的 codex 分支，只注入 `-c hooks...`，不 bypass）。因此单独验证「未信任时 hook 是否生效」。

用全新未信任目录 + 同一个 deny-all hook，**不带** bypass flag 启动交互式 Codex：

```sh
codex -a never --no-alt-screen -C <fresh-untrusted-dir> -s workspace-write \
  -c 'hooks.PreToolUse=[{matcher="*",hooks=[{type="command",command="/abs/hook.sh"}]}]'
```

观察到**两道串行关卡**：

1. `Do you trust the contents of this directory?`（目录信任；`--dangerously-bypass-hook-trust` 只跳过下一道，不跳过这道）。
2. 选「Yes, continue」后弹 `Hooks need review / 1 hook is new or changed / Hooks can run outside the sandbox after you trust them`，选项：
   - `1. Review hooks`
   - `2. Trust all and continue`
   - `3. Continue without trusting (hooks won't run)`

选 `3. Continue without trusting` 后让 Codex 执行 `printf NOTRUST_RAN > notrust.txt`：

- TUI 显示 `• Ran printf NOTRUST_RAN > notrust.txt`（命令执行，**没有** `blocked`）。
- hook 的 `events.log` **为空**——hook 根本没被调用。
- `notrust.txt` **被创建**。

**结论（安全语义）**：未信任 hook 时，Approval Broker 完全缺席——不是 fail-closed，而是 fail-open（工具照常跑）。也就是说，从 worker pane 首次启动到用户在该 pane 内信任 hook 之间，存在一个 broker 不生效的窗口；当前实现只用一条 echo 提醒兜底（`peer add` / `start.sh` 的「Codex hook 提示」），不是强制。

对应设计要求：

- worker 契约 / 文档必须把「未信任 = broker 未生效」当作显式状态，而不是假设 hook 一定在跑。
- 后续应让 supervisor/runtime 能**探测** broker 是否真的生效（例如启动后做一次 deny 自检），未生效时不要把保护性任务派给该 worker，而不仅是打印提醒。

## `codex exec` 的验证结果

同样尝试过：

- 通过 `-c hooks.PreToolUse=...` 注入。
- 通过项目 `.codex/config.toml` 配置。
- 使用 `UserPromptSubmit` 和 `PreToolUse`。

观察：

- 未写入 `events.log`。
- 目标命令直接执行。
- TUI/输出显示走的是非交互执行路径。

结论：本项目的可见协作窗口应以交互式 Codex CLI 为准，不能用 `codex exec` 代表 worker tab 的行为。`codex exec` 可作为无头子任务能力，但 Approval Broker hook 方案不能依赖本次观察到的 `codex exec` hook 行为。

## 对 agent-duo 设计的影响

### 1. Codex `PreToolUse` 不存在可用三态

对 Codex 来说，`PreToolUse` 在当前可用设计里只能安全使用：

- `allow`：放行或改写工具输入。
- `deny`：阻止工具。

不要使用：

- `ask` 表示升级人工确认。
- `continue: false` / `stopReason` 表示阻止工具。

这些都会导致工具继续执行或 hook run 失败，不符合安全闸门语义。

### 2. Codex 的 escalate 必须建模为 `deny + 事件`

Approval Broker 中的 `escalate` 对 Codex 应实现为：

1. hook 写入 `.agent-duo/events/queue.jsonl` 或 `.agent-duo/approvals/` 待批记录。
2. hook 返回 `PreToolUse deny`。
3. hook 入队的 `blocked` 事件触发 supervisor 审批；模型看到理由后按契约停下等待，可用 `peer report` 镜像状态，但这不是审批触发的唯一来源。
4. supervisor/人批准后，worker 重跑同一动作。
5. hook 消费批准状态或 lease，再返回 `allow`。

也就是说，Codex 的 `escalate` 不是 `ask`，而是一个带语义的 `deny`。

### 3. `PermissionRequest` 是补充入口，不是主安全闸

`PermissionRequest` 只在 Codex 准备发起原生审批时触发。它适合接管 Codex 的 native approval prompt，避免 worker 卡在本地 UI，但不覆盖所有工具调用。

因此建议：

- 主安全闸仍放在 `PreToolUse`。
- `PermissionRequest` 作为 native approval prompt 的二级兜底。
- 两者共用同一套 policy/lease/approval 状态，避免决策分叉。

### 4. `-c` 注入路线可以保留

本次验证确认 `codex -c hooks...` 在交互式 CLI 中可用。因此 `start.sh` / `peer add` 暂时不必改成写项目 `.codex/config.toml`。

但仍要注意：

- hook 命令应使用绝对路径。
- 自动化启动需要处理 Codex hook trust；验证时使用了 `--dangerously-bypass-hook-trust`，产品化时不能无说明地默认开启。
- 如果未来使用 managed hooks，需要单独验证 `requirements.toml` / managed config 行为。

## 设计修正建议

1. 把 Approval Broker 设计里的 Codex `ask` 语义改为 provider-specific：Claude 可保留原语义时再验证；Codex 明确不支持。
2. `approval_broker` 的 Codex 输出层只生成 `allow` / `deny`，不要输出 `permissionDecision: "ask"`。
3. 对 unknown / unmanaged / 需要人工判断的请求，Codex 一律 `deny + pending approval record`。
4. worker 契约里要求：看到 `BLOCKED-PENDING-APPROVAL` 时停下等待，不要换命令绕过；hook 写入的 `blocked` 事件是 supervisor 审批的 canonical 触发。
5. ~~后续补一个自动化 smoke：启动真实交互式 Codex session，验证 `-c PreToolUse deny` 能阻止写文件。~~ ✅ 已固化为 `test/codex-hook-e2e.test.sh`（默认 skip，`AGENT_DUO_E2E_CODEX=1` 开启；需 codex + tmux + `~/.codex/auth.json`）。
6. **hook trust fail-open 缺口**：产品启动路径未信任 hook 时 broker 不生效（见上节）。需把它当显式状态处理，并加 broker 生效自检，而非仅靠 echo 提醒。

## 待补验证

- `apply_patch` 的 worktree 外路径、secret 路径交互式阻断实测（逻辑已由 `test/approval.test.sh` 单测覆盖，缺交互式实证）。
- MCP 工具名 matcher：需要用一个低风险 MCP 工具做一次实测。
- ~~不使用 `--dangerously-bypass-hook-trust` 时，Codex hook trust 的真实首次确认体验。~~ ✅ 已实测：两道关卡（目录信任 + Hooks need review），未信任时 fail-open（见「Hook trust 首启行为」一节）。
- Stop hook continuation 行为对 supervisor loop 的可用性。
