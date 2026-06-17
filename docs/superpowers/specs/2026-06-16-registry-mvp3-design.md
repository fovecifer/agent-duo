# agent-duo Registry (MVP 3) 设计

日期：2026-06-16
状态：已实现（命令名落地为 `peer add` / `peer rm`）

## 目标

把 agent-duo 从"claude / codex 双人固定"升级为"单 supervisor + 按需生长"的动态多 agent 工作台，作为 supervisor-loop roadmap 的第一步（风险最低、无安全面）。

对应 roadmap 的 MVP 3，但根据讨论做了三处收敛：

1. **不引入人工维护的配置文件**（放弃 roadmap 草案里的 `.agent-duo/agents.toml`）。
2. **tmux 自身是唯一真相源**，消除任何"配置 vs 现实"的同步问题。
3. **单一入口**：会话内的所有团队操作都走 `peer`，不新增二进制。

## 非目标（YAGNI）

- 不做 budget / capabilities / policy 等元数据（属于后续 MVP）。
- 不做角色再分配 `reassign`（add 时定角色即可，先不支持运行中改角色）。
- 不做跨 session、跨机器的 registry。
- 不做 worktree 隔离（MVP 4）。

## 核心原则：tmux-as-truth

每个 agent 的身份 = 它所在 pane 上的 tmux 用户选项（per-pane user options）：

| 选项 | 含义 | 示例 |
|---|---|---|
| `@agent_id` | 会话内唯一地址 | `supervisor`、`worker`、`reviewer` |
| `@agent_role` | 语义角色（自由字符串） | `supervisor`、`worker`、`reviewer` |
| `@agent_provider` | 工具来源 | `claude`、`codex` |

- **没有第二份数据**，因此没有同步问题。pane 没了，标签随之消失；session 在，标签就在——生命周期天然正确。
- 写入只发生在创建 pane 的同一时刻，原子绑定，永不出现"有 pane 没身份"的中间态。
- `peer ls` = 一次 `tmux list-panes` 现场读取，永远等于现实。
- 凡是 `list-panes` 能列出的都是活的 ⇒ 不存在"声明了但已死"的条目（这正是放弃混合方案 C 的收益）。

读写机制：

```sh
# 写（创建时打标签）
tmux set-option -p -t "$pane" @agent_id worker
tmux set-option -p -t "$pane" @agent_role worker
tmux set-option -p -t "$pane" @agent_provider codex

# 读（一次拿全）
tmux list-panes -s -t agents \
  -F '#{pane_id} #{@agent_id} #{@agent_role} #{@agent_provider}'
```

## 启动模型

开局只拉起**一个** agent，打成 supervisor，provider 可配、默认 claude。`tmux -CC` 集成把它渲染为那唯一的 iTerm2 tab。

```sh
start.sh                      # 默认 claude 当 supervisor，单 tab
start.sh --supervisor codex   # 改用 codex 当 supervisor
start.sh --with codex:worker  # 便捷：同时再 add 一个 codex worker（demo 平价）
```

- 这**替换**掉现在"claude+codex 双人固定"的启动逻辑，只保留一条代码路径。
- `--with <provider>:<role>` 是便捷糖：起完 supervisor 后立即执行一次等价于 `peer add` 的动作，保住 README demo"开箱即有 worker"的体验，但走的是新模型（supervisor / worker / loopd 都正确打上标签或角色）。
- `start.sh` 是唯一能**创建 session** 的入口（因为 `peer` 运行在已存在的 session 内部）。

## 命令面（单一入口 `peer`）

会话内一律走 `peer`。新增/改造：

### 团队生命周期

```sh
peer add --provider codex --role worker [--id NAME]
peer rm <id>
peer ls
```

- `peer add` 干三件原子事：
  1. `tmux new-window -P -F '#{pane_id}' -n <id> -t <session> '<provider 启动命令>'` 捕获新 pane id；
  2. 在该 pane 上 `set-option -p` 写三个 `@agent_*` 标签；
  3. 打印分配的 id。
  省略 `--id` 时由 `--role` 派生（`worker`），撞名追加 `-2`、`-3`。
- `<provider 启动命令>` 复用 `start.sh` 已有的 claude / codex 启动片段，抽成 `provider_launch_cmd <provider>` 辅助函数共享。
- `peer rm <id>` = `tmux kill-window`（按 `@agent_id` 定位其 pane 所在 window）。
- 执行者是 supervisor（Claude Code）用 Bash 跑这些命令——它现在已经在跑 `peer`，无新机制。

### Agent 间通信（泛化为 N-agent 寻址）

```sh
peer peek   [<id>] [行数]
peer tell   [<id>] "消息"
peer wait   [<id>] [超时] [间隔] [稳定次数]
peer status [<id>]
peer esc    [<id>]
```

寻址解析规则：

1. **显式 `<id>`** → 在本 session 的 panes 里按 `@agent_id` 查找目标 pane。找不到则报错并列出候选。
2. **省略 `<id>` 且会话正好 2 个 agent** → 默认"另一个"，保留今天的双人手感（supervisor + 单 worker 场景）。
3. **省略 `<id>` 且 ≥3 个 agent** → 报错，列出候选 id，要求显式指定（避免误发）。
4. **永不默认发给自己**：解析"另一个"时排除自身。

## 自我身份发现（`peer` 改造要点）

- 旧实现里 `peer` 靠注入的 `AGENT_NAME` 环境变量推导 `OTHER`（原 `bin/peer:32-38`）。
- 当前方式：`peer` 用 `$TMUX_PANE` 定位自己的 pane，读自己的 `@agent_id`——**移除一类注入脆弱性**，agent 不必再被注入身份环境变量。
- 过渡兼容：若 `@agent_id` 未设置但 `AGENT_NAME` 存在，回退到旧推导，保证迁移期老路径仍可用。
- 未打标签的 pane（用户手动开的窗口）在 `peer ls` 中显示为 `(unregistered)`，使其可见而非隐形。

## 数据流（目标场景）

```
开 iTerm2 → start.sh → tab1: claude(supervisor), tab2: loopd
人: "起一个 codex worker"
supervisor: peer add --provider codex --role worker
            → 新 window 跑 codex + 打 @agent_* 标签 → worker tab 出现
supervisor: peer tell "review internal/auth"   # 两人局，默认发给 worker
            peer wait
            peer peek
```

人决定团队构成（自然语言指示 supervisor），supervisor（AI）执行 add。决定权在人，执行在 AI。

## 代码影响面

- `bin/peer`
  - 已将 `AGENT_NAME → OTHER` 推导替换为：`$TMUX_PANE` 自我发现 + N-agent 目标解析（含 2-agent 默认、≥3 强制指名、self 守卫）。
  - `capture` / `ensure_target` 改为按解析出的目标 pane 工作，不再假设只有"对方"一个。
  - 新增子命令：`add`、`rm`、`ls`。
  - `peek/tell/wait/status/esc` 接受可选前置 `<id>` 参数。
- `start.sh`
  - 改为单 supervisor bootstrap；新增 `--supervisor <provider>` 与 `--with <provider>:<role>`。
  - 抽出 `provider_launch_cmd <provider>` 供 `peer add` 复用（消除重复的启动知识）。
- `lib/inject.sh`：若仍负责注入环境，调整为给 supervisor pane 打 `@agent_*` 标签（或由 start.sh 直接 set-option）。

## 测试（沿用现有约定：bash + tmux stub + `test/run.sh`）

新增/扩展用例，stub `tmux` 记录 `set-option` / `new-window` / `send-keys` 调用并断言：

- `peer add`：调用 `new-window`，并对返回 pane 写齐三个 `@agent_*` 标签；省略 `--id` 时 id 由 role 派生、撞名加后缀。
- `peer ls`：枚举 session 内 panes，正确解析 id/role/provider；未打标签的 pane 显示 `(unregistered)`。
- 寻址：2-agent 省略 `<id>` 默认"另一个"；≥3 省略时报错并列候选；显式 `<id>` 不存在时报错；解析"另一个"排除自身。
- `peer rm <id>`：按 id 定位并 `kill-window`。
- `start.sh --with codex:worker`：起 supervisor 后执行一次 add 等价动作，worker pane 标签正确。
- 兼容回退：`@agent_id` 缺失但 `AGENT_NAME` 存在时仍能路由。

## 开放风险 / 后续

- `provider 启动命令`耦合各 provider 的 CLI 细节（参数、cwd）；MVP 仅支持 claude / codex，新 provider 后续扩展 `provider_launch_cmd`。
- 暂不持久化任何状态到磁盘——session 关闭即团队消失，符合"live workbench"定位；durable state 是 MVP 9（Budget Broker）的事。
