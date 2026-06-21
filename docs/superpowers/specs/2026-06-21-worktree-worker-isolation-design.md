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
repo_key = $(basename "$git_root")-$(printf %s "$git_root" | shasum -a 256 | cut -c1-8)   # 防同名/跨仓撞路径(评审 R1-②)
wt_base  = ${AGENT_DUO_WORKTREES_DIR:-$(dirname "$git_root")/.agent-duo-worktrees/$repo_key}/$session
wt_path  = $wt_base/<id>
branch   = agent-duo/<id>           # 命名空间化,不撞用户分支
base     = 主仓当前 HEAD
```

> `repo_key` 含主仓绝对路径的 8 位 hash：同一父目录下两个仓库、同名 session(`agents`)、同名 worker id 不再共享 `wt_path`。`git_root` 由 §2.2 的 `rev-parse --show-toplevel` 求得。

### 2.2 创建 helper：`reg_create_worktree <id>`（放 `lib/registry.sh`，**共享**）

`peer add` 与 `start.sh --with` 都要建 worker，**共用一个 helper**（避免两处逻辑漂移——同 `role_is_gated`/`check_target_dispatch_allowed` 的教训）：

```
git_root = git -C "$AGENT_DUO_ROOT" rev-parse --show-toplevel    # 校验 git + 取主仓根
  失败 → 报错 "隔离需要 git 仓库" → 非零退出
mkdir -p "$wt_base"
若 wt_path 已存在:                                                # (评审 R1-①)
    若 reg_worktree_is_valid(git_root, wt_path, id)
        → 复用现有 worktree(不 worktree add,直接拿它当 cwd/WORKTREE);续上之前 dirty 保留的活
    否则 → 报错("wt_path 已存在但不是预期 worktree;手动清理或换 id")→ 非零退出
否则若 branch 已存在(git show-ref) → git -C git_root worktree add "$wt_path" "$branch"   # 复用分支=续上已提交的活
否则                                → git -C git_root worktree add -b "$branch" "$wt_path" HEAD
  add 失败(如分支已在别处 checkout)→ 透传 git 错误 + 非零退出
打印 wt_path
```

- **续活的两条路（修复 R1-① 的"已存在即报错 vs 续活"矛盾）**：
  - **clean rm 后**：worktree 已删、分支保留 → 走"branch 已存在 → `worktree add` 到现有分支"，续上**已提交**的活。
  - **dirty rm 后**：worktree 目录还在（§3.2 保留）→ 走"wt_path 已存在且校验通过 → **原地复用**"，续上**未提交**的活。两者都不再撞"已存在即报错"。
- **base = HEAD**：worker 从 supervisor 当前 commit 起步。

### 2.2.1 校验谓词 `reg_worktree_is_valid <git_root> <path> <id>`（共享给创建复用与清理）

以 **git 自己的 worktree 注册表为准**，杜绝误删/误用外部路径：

```
git -C "$git_root" worktree list --porcelain 中存在一条:
    worktree == <path>  且  branch == refs/heads/agent-duo/<id>
→ valid(返回 0);否则 invalid(返回 1)
```

`git worktree list` 只列**本主仓的** linked worktree，故"路径在表里 + 分支正是 `agent-duo/<id>`"足以确认这是我们为该 id 建的 worktree，不会命中同 repo 的别的 worktree 或外部目录。

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

### 3.2 `peer rm [--force] <id>` 清理

`--force` **任意位置可识别**（`peer rm --force <id>` 与 `peer rm <id> --force` 等价，与 `esc`/`tell` 现有的 `--force` 解析一致，评审 R1-④）。用法文案统一写 `peer rm [--force] <id>`。

```
1. 读 .agent-duo/state/<id>/worktree.json:
     不存在 → 共享 worker,走现有 rm(关窗+注销),无 worktree 清理
2. (隔离 worker) 先关窗+注销 agent(同现有 rm,杀掉占用 cwd 的进程)
3. wt_path = 记录里的 path;git_root = git -C "$AGENT_DUO_ROOT" rev-parse --show-toplevel
4. 【校验,评审 R1-③】reg_worktree_is_valid(git_root, wt_path, id)?
     是 → 继续 5
     否,且 wt_path 既不在 git worktree 表、目录也不存在 → **已消失**:`git worktree prune` + 删 worktree.json,幂等收尾、无错
     否,其余(路径在表但分支不符 / 目录在但 git 不认)→ **拒绝自动删除**,保留 worktree.json,警告:
        "worker <id> 的 worktree 记录与 git 不符(<wt_path>),为安全起见不自动删除,请手动清理。"
        (--force 也不跳过此校验——宁可不删,也不误删别的 linked worktree)
5. dirty? = git -C "$wt_path" status --porcelain 非空(未提交/未跟踪改动)
     干净 或 --force → git -C "$git_root" worktree remove [--force] "$wt_path"
                        + git worktree prune;删除 worktree.json
     脏 且 非 --force → 不删 worktree,保留 worktree.json,警告:
        "worker <id> 的 worktree 有未提交改动(<wt_path>),已保留。
         提交/处理后 'peer rm --force <id>' 丢弃,或手动 git worktree remove。"
6. 分支 agent-duo/<id> 始终保留(已提交的活在分支上,worktree 删了也不丢)
```

- **删前必过 `reg_worktree_is_valid`（评审 R1-③）**：只信 git worktree 注册表里"路径匹配 + 分支==agent-duo/<id>"的项；陈旧/手改记录一律拒删（含 `--force`），避免误删同 repo 的别的 linked worktree。
- **只防"未提交"丢失**：`git status --porcelain` 判脏。已 commit 的工作在分支上，删 worktree 不影响——所以分支永远保留，无需判"未合并 commit"。
- **agent 总是被注销**（关窗/registry），与"peer rm 移除 agent"语义一致；脏时只是把 worktree+分支**留在盘上**给人，agent 没了、活还在。
- `git worktree prune` 清掉 git 的 admin 残留（目录被手动删时也清）。

### 3.3 session 结束的孤儿（说明 + 可选）

`tmux kill-session` 不触发 `peer rm` → worktrees 留盘。`git worktree list` 可见，手动 `git worktree remove` 清。MVP 文档化这条路径；一个批量 `peer worktree prune`（清"agent 已不在 registry 且干净"的 worktree）**列为后续**，本刀不做（YAGNI）。

## 4. 错误处理 + 测试 + 影响面

### 4.1 错误处理（新增/跨切面）

- **创建先于注册（原子性）**：`peer add --worktree` 先 `reg_create_worktree`；失败（非 git / wt_path 已存在 / 分支已在别处 checkout）→ **直接退出，不建窗口、不注册**——不留半个 worker。
- **非 git 仓库** + `--worktree` → 报错"隔离需要 git 仓库"。
- **`wt_path` 已存在**（评审 R1-①）→ `reg_worktree_is_valid` 通过则**原地复用续活**，否则报错提示手动清理/换 id。
- **`peer rm` 删前校验**（评审 R1-③）→ 校验不过且**分支不符/外部目录** → 拒绝自动删（`--force` 也不绕过）+ 警告、保留记录；校验不过但**已彻底消失**（git 不认 + 目录不在）→ `prune` + 删记录、幂等无错。
- **`worktree remove` 因非脏原因失败** → 警告、保留记录、agent 仍注销。
- broker hook 自动带 `AGENT_DUO_WORKTREE=wt_path`（`install_approval_session_settings` 的 worktree 参已贯穿到 hook command，**无需额外改**）。
- `AGENT_DUO_WORKTREES_DIR` 可覆盖 worktree 基目录（测试隔离用）。

### 4.2 测试矩阵（`peer.test.sh` / `start.test.sh`；真 git + tmux stub）

测试 project 里 `git init` + 一次 commit，用**真 `git worktree`**（tmux 仍 stub）。

**peer add --worktree**

- 建 `wt_path` + 分支 `agent-duo/<id>`；`new-window -c <wt>`；export `AGENT_DUO_WORKTREE=<wt>`、`AGENT_DUO_ROOT=<主仓>`；写 `worktree.json`。
- 非 git root → 报错、**什么都没建**（无窗口/无注册）。
- 分支 `agent-duo/<id>` 已存在、worktree 已删 → **复用分支** re-add（续已提交活）。
- **wt_path 已存在且校验通过（R1-①）** → **原地复用**（不再 `worktree add`，断言未新建、cwd 指向它）。
- **wt_path 已存在但校验不过（外部目录）** → 报错。
- **repo_key 防撞（R1-②）**：两个同名 basename 的 git_root → 不同 `wt_path`（hash 段不同）。
- **回归**：不带 `--worktree` → 共享（无 `worktree.json`、cwd=PWD、`AGENT_DUO_WORKTREE=PWD`）。

**start --with …:isolated**

- 同样的 worktree 接线（走共享 `reg_create_worktree`）。

**peer rm**

- 干净 worktree → `git worktree remove` 成功、分支保留、`worktree.json` 删、agent 注销。
- 脏（worktree 里 `touch` 个未跟踪文件）→ **不删**、警告、`worktree.json` 保留、agent 仍注销。
- 脏 + `--force` → 删除。
- **校验不过：记录路径换成同 repo 别的 worktree/分支不符（R1-③）** → **拒绝删除**（即便 `--force`）+ 警告、保留记录。
- **`--force` 任意位置（R1-④）**：`peer rm --force <id>` 与 `peer rm <id> --force` 行为一致。
- 无 `worktree.json`（共享 worker）→ 走现有 rm。
- `worktree.json` 在但目录已删且 git 不认 → prune + 删记录、不报错。

### 4.3 实现影响面

- `lib/registry.sh`：新增 `reg_create_worktree <id>`（共享给 add 与 --with，含 `repo_key` 路径与 wt_path-存在复用）、`reg_worktree_is_valid <git_root> <path> <id>`（git worktree list 校验，创建复用与清理共用）、`reg_worktree_record` 读写 `worktree.json`、`reg_remove_worktree`（校验 + 安全删 + prune）。
- `bin/peer`：`add` 加 `--worktree`（调 helper、cwd/WORKTREE 指 wt、写记录、`@agent_worktree`）；`rm` 加 `--force` + worktree 清理；`ls`（可选）展示 worktree/branch。
- `start.sh`：`--with <provider>:<role>:isolated` 解析 → 走同一 helper 接线。
- 文档：README（en/zh）、AGENT-INSTRUCTIONS/AGENTS、worker-supervisor 契约（隔离/写域一节）。
- **不动**：broker `path.outside_worktree` 写域（已建）、`AGENT_DUO_ROOT` 语义、loop/validation/direction。

### 4.4 非目标（YAGNI）

- 不做 merge-back（`peer merge`）——worker 在分支提交，并回主线是人/supervisor 的常规 git 活。
- 不做 `peer worktree prune` 批量清孤儿（session-end 留盘，文档化手动清）。
- 不做跨 worktree 的依赖/构建缓存共享。
- 不改默认行为（隔离恒 opt-in）。

## 5. 评审修订（2026-06-21，交付前收紧）

1. **`wt_path` 已存在与"续活"自洽（§2.2/§4）**：原"已存在即报错"和"dirty 保留后可续活"矛盾。现：`wt_path` 已存在且 `reg_worktree_is_valid` 通过 → **原地复用**（续 dirty 活）；clean rm 后走 branch-reuse re-add（续已提交活）；只有外部目录才报错。
2. **默认路径加 repo key（§2.1）**：`<parent>/.agent-duo-worktrees/<basename>-<hash8(git_root)>/<session>/<id>`，避免同父目录、同名 session、同 id 跨仓撞路径。
3. **`peer rm` 删前校验（§3.2/§4）**：以 `git worktree list` 为准（路径在表 + 分支==`agent-duo/<id>`）才删；陈旧/手改记录拒删（`--force` 也不绕过），杜绝误删同 repo 别的 linked worktree；已彻底消失则幂等清记录。
4. **`--force` 任意位置（§3.2）**：`peer rm [--force] <id>` 与 `peer rm <id> --force` 等价，用法文案统一为 `peer rm [--force] <id>`。
