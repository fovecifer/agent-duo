# 设计:start.sh 在用户授权后自动注入 peer 协作提示词

日期:2026-06-14
状态:已实现

## 背景与问题

目前用户要使用 agent-duo,必须手动把 `docs/AGENT-INSTRUCTIONS.md` 的内容复制粘贴进
项目的 `CLAUDE.md`(给 Claude Code 读)和 `AGENTS.md`(给 Codex 读)两个文件。这一步:

- 繁琐,容易忘记,新用户上手有摩擦;
- 污染用户自己的项目文件,用完还得记得清理。

目标:让用户运行 `agent-duo-start` 后**尽可能零配置**,同时在改动用户文件前**征求授权**。

## 关键约束:两个 CLI 的注入能力不对称(实测)

| 能力 | Claude Code | Codex CLI |
|---|---|---|
| 启动时追加系统提示词 | ✅ `--append-system-prompt "$(cat ...)"` | ❌ 交互模式无此参数 |
| 读取的项目文件 | `CLAUDE.md` | `AGENTS.md` |
| 替换 base 指令 | — | `-c experimental_instructions_file`(替换而非追加,experimental,不采用)|

结论:Claude 可做到"启动时注入、不碰任何文件、会话结束自动消失";Codex **没有**等价
的启动参数,唯一干净的按项目注入途径是写它的 `AGENTS.md`。因此采用**混合(方案 B)**:

- **Claude 侧**:启动时用 `--append-system-prompt`,**完全不碰 `CLAUDE.md`**,临时生效。
- **Codex 侧**:在项目 `AGENTS.md` 追加一个带标记、可撤销的块。

对用户而言两侧体验一致(都是零配置),不对称只存在于 `start.sh` 内部,对用户透明。

## 设计

### 单一数据源

`docs/AGENT-INSTRUCTIONS.md` 的**正文**作为唯一提示词来源,Claude 与 Codex 共用。
删除该文件开头那段"请把本段追加到 CLAUDE.md/AGENTS.md"的 HTML 注释 —— 注入已自动化,
该说明过时。文件正文即纯指令内容。

### 标记块格式(写入 AGENTS.md)

```
<!-- agent-duo:start -->
<docs/AGENT-INSTRUCTIONS.md 的正文>
<!-- agent-duo:end -->
```

标记块的存在同时充当两个角色:Codex 的提示词来源,以及"用户已授权"的凭证。

### start.sh 注入流程(在创建 tmux 会话窗口之前)

```
1. 解析工作目录,定位其中的 AGENTS.md。
2. 检测 AGENTS.md 是否已包含 <!-- agent-duo:start --> 标记块。

   ├─ 已存在 → 视为之前已授权:
   │            打印一句友好提示告知当前状态(非静默),例如:
   │            "✓ peer 协作提示词已就绪(Codex 块在 ./AGENTS.md;Claude 走启动参数)"
   │            然后直接进入步骤 5 启动。
   │
   └─ 不存在 → 进入步骤 3 征求授权。

3. 打印说明并提示用户输入 [y/N]:
     - 说明会注入什么、注入到哪、Claude 临时不写文件、Codex 写带标记可撤销的块、
       CLAUDE.md 不会被改动。

4. 读取用户输入:
   ├─ y / Y / yes → 授权:把标记块追加到 AGENTS.md(文件不存在则创建),
   │                  进入步骤 5,agent 启动时带提示词/能读取 AGENTS.md。
   └─ 其它(含直接回车)→ 拒绝:不写文件、不加参数,
                          进入步骤 5 裸启动,并打印手动配置 fallback 说明。

5. 启动 tmux 会话:
   - Claude provider 窗口:若已授权/已存在块 → 用 claude --append-system-prompt "$(指令正文)" 启动;
                     若拒绝 → 直接 claude 启动。
   - Codex provider 窗口:始终 codex 启动(它从 AGENTS.md 自行读取,已授权则块已就位)。
   - loopd 窗口:不需要协作提示词。
```

### 授权状态的记忆

"第一次问、之后只友好提示"靠 **AGENTS.md 中标记块的存在**来判断,无需额外状态文件。
- 块存在 → 已授权 → 友好提示 + 注入;
- 块不存在 → 询问。用户拒绝时不写块,故下次仍会询问(符合预期)。

### 边界情况

- **无 TTY**(stdin 非交互,如管道/CI):无法询问。默认**不注入**,打印警告 + 手动说明,
  仍启动会话窗口。提供逃生通道 `AGENT_DUO_AUTO_INJECT=1`(或 `-y` 标志):跳过询问、
  直接注入,供自动化使用。
- **AGENTS.md 不存在**:授权后创建该文件并写入块。
- **标记块已存在但仓库内提示词已更新**:v1 **不自动同步**,保持原样(避免误伤用户可能的
  手改)。需要刷新时,用户手动删除标记块后重新启动。(YAGNI)

### 明确不做(划出边界)

- 不修改 `CLAUDE.md`(方案 B 的核心:Claude 走启动参数)。
- 不写全局 `~/.codex/AGENTS.md`(会污染所有 codex 会话,包括无 peer 的场景)。
- 不实现 `peer uninstall` 子命令(标记块手动删即可;后续可加)。
- 不自动同步已存在块的内容。

## 受影响的文件

- `start.sh`:新增注入流程(检测标记 / 询问 / 写块 / 用 --append-system-prompt 启 claude)。
- `docs/AGENT-INSTRUCTIONS.md`:删除开头过时的 HTML 注释,正文成为纯指令。
- `README.md` / `README.zh-CN.md`:更新"Quick start",说明现在自动注入、首次会询问授权;
  保留手动追加作为可选/fallback 说明。

## 验证方式

- 全新项目目录(无 AGENTS.md)运行 `agent-duo-start`:出现授权提示;输入 y 后
  AGENTS.md 被创建且含标记块;claude 窗口命令行含 `--append-system-prompt`。
- 同一目录再次运行:不再询问,打印友好提示,块不重复。
- 输入 n:无文件改动,裸启动,打印手动说明。
- `AGENT_DUO_AUTO_INJECT=1 ./start.sh`:无询问直接注入。
- 无 TTY(如 `echo | ./start.sh`):不注入,打印警告,仍启动。
