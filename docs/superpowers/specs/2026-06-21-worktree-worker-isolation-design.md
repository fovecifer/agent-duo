# Worktree Worker 隔离（MVP 4）设计

日期：2026-06-21
状态：设计稿，待实现（交付 Codex 实现，作者 review）
关联：[supervisor-loop roadmap](../../../agent-duo-supervisor-loop-roadmap.md) §MVP 4 / §Worktree 隔离、[Approval Broker 设计](./2026-06-17-approval-broker-design.md)（写域 `path.outside_worktree`）、[registry MVP 3 design](./2026-06-16-registry-mvp3-design.md)

## 1. 架构 + opt-in 面

### 1.1 核心：代码隔离，控制状态共享

把一个 worker 的**代码工作区**和**控制状态**分开：

```
主仓 (AGENT_DUO_ROOT)                         隔离 worktree (AGENT_DUO_WORKTREE = cwd)
  ├─ .agent-duo/         ◄── 共享控制面 ──┐    ├─ <项目代码的独立 checkout>
  │   ├─ events/queue.jsonl               │    └─ 在分支 agent-duo/<id> 上
  │   ├─ state/<id>/(report/loop/task…)   │
  │   ├─ registry / broker markers        └──── worker 的 report/loop/task 仍写这里
  │   └─ gates / logs                            (AGENT_DUO_ROOT 指主仓,不随 cwd)
  └─ <主线代码>
```

- **`AGENT_DUO_ROOT` = 主仓**（不变）：所有 worker 的 report/event/loop.json 仍落主仓的 `.agent-duo/`，**supervisor 和 loopd 照常看得到**。这是隔离能成立的前提——隔离代码，不隔离控制面。
- **`AGENT_DUO_WORKTREE` = cwd = 隔离 worktree**：worker 在自己的 checkout 上编辑/提交；broker 的 `path.outside_worktree` 写域（**已建，不动**）自动把它限制在自己的 worktree 内，写主仓或别的 worker 的 worktree 会被 escalate。

这俩 env 在现有 launch 里**本就解耦**（`peer add` 已显式传 `AGENT_DUO_ROOT` + `new-window -c`），所以改动很小：只把 cwd / `AGENT_DUO_WORKTREE` 从 `$PWD` 指到新 worktree。

### 1.2 opt-in 面（向后兼容）

```
peer add --provider <p> --role <role> [--id <id>] --worktree
agent-duo-start … --with <provider>:<role>:isolated
```

- **不传 `--worktree` / 不带 `:isolated`** → 维持现状（共享 `WORKDIR`），单 worker 简单场景零变化。
- `--worktree` 仅是"创建隔离 worktree 并把 cwd/`AGENT_DUO_WORKTREE` 指过去"的开关；其余（broker install、注册、启动 provider）全走现有路径。

### 1.3 前置校验

- **必须是 git 仓库**：`--worktree` 时若 `AGENT_DUO_ROOT` 不在 git 工作树内 → 报错退出（"隔离需要 git 仓库"）。opt-in，所以直接报错（用户明确要了隔离）。
- 主仓**脏**（有未提交改动）无妨：`git worktree add` 从 `HEAD` 拉干净 checkout，不含主仓未提交内容——这是预期。

## 2. worktree 生命周期（创建 + env 接线）

### 2.1 路径与分支

```
session  = $AGENT_SESSION
wt_base  = ${AGENT_DUO_WORKTREES_DIR:-$(dirname "$git_root")/.agent-duo-worktrees}/$session
wt_path  = $wt_base/<id>
branch   = agent-duo/<id>           # 命名空间化,不撞用户分支
base     = 主仓当前 HEAD
```

### 2.2 创建 helper：`reg_create_worktree <id>`（放 `lib/registry.sh`，**共享**）

`peer add` 与 `start.sh --with` 都要建 worker，**共用一个 helper**（避免两处逻辑漂移——同 `role_is_gated`/`check_target_dispatch_allowed` 的教训）：

```
git_root = git -C "$AGENT_DUO_ROOT" rev-parse --show-toplevel    # 校验 git + 取主仓根
  失败 → 报错 "隔离需要 git 仓库" → 非零退出
mkdir -p "$wt_base"
若 wt_path 已存在 → 报错("worktree 已存在: <path>;先 peer rm 或手动清理")
若 branch 已存在(git show-ref) → git -C git_root worktree add "$wt_path" "$branch"   # 复用分支=续上旧活
否则                            → git -C git_root worktree add -b "$branch" "$wt_path" HEAD
  add 失败(如分支已在别处 checkout)→ 透传 git 错误 + 非零退出
打印 wt_path
```

- **分支已存在 → 复用**：重加同 id（或之前 dirty 保留过）能续上原分支的工作，不丢。
- **base = HEAD**：worker 从 supervisor 当前 commit 起步。

### 2.3 env 接线（`peer add --worktree` / `start --with …:isolated`）

唯一改动是把三处从 `$PWD` 换成 `wt_path`，**`AGENT_DUO_ROOT` 保持主仓不变**：

| 项 | 共享 worker（现状） | 隔离 worker（新） |
|---|---|---|
| tmux `new-window -c` | `$PWD` | `wt_path` |
| `install_approval_session_settings <id> <p> <wt>` 的 worktree 参 | `$PWD` | `wt_path`（broker 写域=此） |
| 启动 export `AGENT_DUO_WORKTREE=` | `$PWD` | `wt_path` |
| 启动 export `AGENT_DUO_ROOT=` | 主仓 | **主仓（不变）** |
| 持久记录 | 无 | **写 `worktree.json`（§3.1）** + 可选 `@agent_worktree` pane option |

- worker 的 cwd 是 worktree，但 `peer`/broker 用 `AGENT_DUO_ROOT`（主仓）读写共享 `.agent-duo`——report/loop/task 仍进主仓状态。
- 从 HEAD 拉的 checkout 不含未跟踪的 `.agent-duo`（它是运行时状态、未 track），即便含也被 `AGENT_DUO_ROOT` 覆盖，无歧义。

## 3. 清理 + 映射记录

### 3.1 映射记录（创建时写，清理时读）

创建隔离 worker 时（§2.3），把 worktree 信息写到**共享 `.agent-duo` 下的持久文件**：

```
.agent-duo/state/<id>/worktree.json   = { "path": "<abs wt_path>", "branch": "agent-duo/<id>" }
```

- 放主仓 `.agent-duo`（不是 worktree 内）→ 与控制面同寿命，**worker 窗口/进程死了也还在**，`peer rm` 照样读得到。
- 另设 tmux pane option `@agent_worktree`（可选，供 `peer ls` 展示）；权威记录是这个文件。

### 3.2 `peer rm <id> [--force]` 清理

```
1. 读 .agent-duo/state/<id>/worktree.json:
     不存在 → 共享 worker,走现有 rm(关窗+注销),无 worktree 清理
2. (隔离 worker) 先关窗+注销 agent(同现有 rm,杀掉占用 cwd 的进程)
3. wt_path = 记录里的 path;git_root = git -C "$AGENT_DUO_ROOT" rev-parse --show-toplevel
4. dirty? = git -C "$wt_path" status --porcelain 非空(未提交/未跟踪改动)
     干净 或 --force → git -C "$git_root" worktree remove [--force] "$wt_path"
                        + git worktree prune;删除 worktree.json
     脏 且 非 --force → 不删 worktree,保留 worktree.json,警告:
        "worker <id> 的 worktree 有未提交改动(<wt_path>),已保留。
         提交/处理后 'peer rm --force <id>' 丢弃,或手动 git worktree remove。"
5. 分支 agent-duo/<id> 始终保留(已提交的活在分支上,worktree 删了也不丢)
```

- **只防"未提交"丢失**：`git status --porcelain` 判脏。已 commit 的工作在分支上，删 worktree 不影响——所以分支永远保留，无需判"未合并 commit"。
- **agent 总是被注销**（关窗/registry），与"peer rm 移除 agent"语义一致；脏时只是把 worktree+分支**留在盘上**给人，agent 没了、活还在。
- `git worktree prune` 清掉 git 的 admin 残留（目录被手动删时也清）。

### 3.3 session 结束的孤儿（说明 + 可选）

`tmux kill-session` 不触发 `peer rm` → worktrees 留盘。`git worktree list` 可见，手动 `git worktree remove` 清。MVP 文档化这条路径；一个批量 `peer worktree prune`（清"agent 已不在 registry 且干净"的 worktree）**列为后续**，本刀不做（YAGNI）。

## 4. 错误处理 + 测试 + 影响面

### 4.1 错误处理（新增/跨切面）

- **创建先于注册（原子性）**：`peer add --worktree` 先 `reg_create_worktree`；失败（非 git / wt_path 已存在 / 分支已在别处 checkout）→ **直接退出，不建窗口、不注册**——不留半个 worker。
- **非 git 仓库** + `--worktree` → 报错"隔离需要 git 仓库"。
- **`wt_path` 已存在** → 报错（残留/id 占用），提示先 `peer rm` 或手动清。
- **`peer rm`：记录在但目录已被手动删** → `git worktree prune` + 删 `worktree.json`，不报错。
- **`worktree remove` 因非脏原因失败** → 警告、保留记录、agent 仍注销。
- broker hook 自动带 `AGENT_DUO_WORKTREE=wt_path`（`install_approval_session_settings` 的 worktree 参已贯穿到 hook command，**无需额外改**）。
- `AGENT_DUO_WORKTREES_DIR` 可覆盖 worktree 基目录（测试隔离用）。

### 4.2 测试矩阵（`peer.test.sh` / `start.test.sh`；真 git + tmux stub）

测试 project 里 `git init` + 一次 commit，用**真 `git worktree`**（tmux 仍 stub）。

**peer add --worktree**

- 建 `wt_path` + 分支 `agent-duo/<id>`；`new-window -c <wt>`；export `AGENT_DUO_WORKTREE=<wt>`、`AGENT_DUO_ROOT=<主仓>`；写 `worktree.json`。
- 非 git root → 报错、**什么都没建**（无窗口/无注册）。
- `wt_path` 已存在 → 报错。
- 分支 `agent-duo/<id>` 已存在 → **复用**（worktree add 到现有分支）。
- **回归**：不带 `--worktree` → 共享（无 `worktree.json`、cwd=PWD、`AGENT_DUO_WORKTREE=PWD`）。

**start --with …:isolated**

- 同样的 worktree 接线（走共享 `reg_create_worktree`）。

**peer rm**

- 干净 worktree → `git worktree remove` 成功、分支保留、`worktree.json` 删、agent 注销。
- 脏（worktree 里 `touch` 个未跟踪文件）→ **不删**、警告、`worktree.json` 保留、agent 仍注销。
- 脏 + `--force` → 删除。
- 无 `worktree.json`（共享 worker）→ 走现有 rm。
- `worktree.json` 在但目录已删 → prune + 删记录、不报错。

### 4.3 实现影响面

- `lib/registry.sh`：新增 `reg_create_worktree <id>`（共享给 add 与 --with）、`reg_worktree_record` 读写 `worktree.json`、`reg_remove_worktree`（安全删 + prune）。
- `bin/peer`：`add` 加 `--worktree`（调 helper、cwd/WORKTREE 指 wt、写记录、`@agent_worktree`）；`rm` 加 `--force` + worktree 清理；`ls`（可选）展示 worktree/branch。
- `start.sh`：`--with <provider>:<role>:isolated` 解析 → 走同一 helper 接线。
- 文档：README（en/zh）、AGENT-INSTRUCTIONS/AGENTS、worker-supervisor 契约（隔离/写域一节）。
- **不动**：broker `path.outside_worktree` 写域（已建）、`AGENT_DUO_ROOT` 语义、loop/validation/direction。

### 4.4 非目标（YAGNI）

- 不做 merge-back（`peer merge`）——worker 在分支提交，并回主线是人/supervisor 的常规 git 活。
- 不做 `peer worktree prune` 批量清孤儿（session-end 留盘，文档化手动清）。
- 不做跨 worktree 的依赖/构建缓存共享。
- 不改默认行为（隔离恒 opt-in）。
