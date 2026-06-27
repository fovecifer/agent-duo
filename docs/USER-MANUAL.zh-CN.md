# agent-duo 使用手册

本文面向日常使用者。它把 `README.zh-CN.md`、`docs/AGENT-INSTRUCTIONS.md`、`docs/glossary.md` 以及当前源码里的实际命令行为整理成一份完整操作手册。

## 1. agent-duo 是什么

`agent-duo` 把同一个 tmux 会话中的多个可见编码 agent 组织起来。每个 agent 都是真实的 Claude Code 或 Codex CLI 交互式 tab，不是一次性无头子进程。你通常会看到：

- `supervisor`：你主要对话的上位 agent，负责拆任务、派发、检查、纠偏、处理 gate。
- `worker` / `reviewer` / `evaluator`：可见的工作 agent，由 supervisor 用 `peer` 管理。
- `loopd`：可见的 runtime 看板，轮询 `.agent-duo/` 状态、投递事件、运行 verify gate。

核心心智模型：

```text
Human
  -> supervisor
      -> worker / reviewer / evaluator
      -> verify gates
      -> judge verdicts
      -> human gates
      -> approval broker
```

`agent-duo` 的目标不是让 agent 私下聊天，而是让你用可审计、可暂停、可验证的方式驱动一个 supervised loop。

## 2. 关键术语

| 术语 | 含义 |
| --- | --- |
| peer | 同一个 tmux session 里的另一个可见 agent。 |
| supervisor | 负责调度、验收、纠偏、处理 gate 的 agent。 |
| worker | 负责实现、调查、测试、汇报的 agent。 |
| loop | 写在 `.agent-duo/state/<agent>/loop.json` 里的有界迭代契约。 |
| task | 写在 `.agent-duo/state/<agent>/task.json` 里的步骤账本。 |
| report | worker 用 `peer report` 写出的结构化进度文件。 |
| verify | `peer loop init --verify` 声明的机械验收命令，由 loop runtime 执行。 |
| judge | reviewer/evaluator 用 `peer judge` 写入的独立验收 verdict。 |
| gate | 需要人类做业务、部署、成本、网络、范围等判断的 Human Decision Gate。 |
| approval | Approval Broker 捕获的工具权限请求。 |
| reframe | supervisor 对 worker 的方向纠偏。 |
| checkpoint | supervisor 读取 worker loop/report/task/verify 的只读状态摘要。 |

注意两个容易混淆的概念：

- `peer` 是眼前长期存活的可见队友 tab，用 `peer tell` / `peer peek` 交互。
- “spawn 一个 Codex 子 agent”是临时无头进程，不经过 `peer`，也不受 agent-duo 的 worker pane broker 保护。

## 3. 环境要求

必需：

- macOS 或其他可运行 tmux 的 Unix 环境。
- `tmux`。
- `jq`。
- 已安装并登录 `claude` 和 `codex` CLI。
- `peer` 与 `agent-duo-start` 在 PATH 中。

推荐：

- iTerm2，并使用 `tmux -CC attach -t agents`。这样 tmux window 会变成原生 tab。
- 对需要隔离的 worker 使用 git 仓库，因为 `--worktree` 依赖 `git worktree`。

安装方式：

```bash
brew install fovecifer/agent-duo/agent-duo
```

源码安装：

```bash
git clone https://github.com/<you>/agent-duo
cd agent-duo
./install.sh
```

## 4. 第一次启动

在目标项目目录中运行：

```bash
agent-duo-start
tmux -CC attach -t agents
```

默认会创建：

- `supervisor` tab：默认 provider 是 Claude Code。
- `loopd` tab：可见看板。

如果你想启动时直接带一个 worker：

```bash
agent-duo-start --with codex:worker
```

如果 worker 需要在隔离 worktree 里编辑：

```bash
agent-duo-start --with codex:worker:isolated
```

如果你想让 Codex 当 supervisor：

```bash
agent-duo-start --supervisor codex
```

### 4.1 指令注入

`agent-duo-start` 会让 agent 知道 `peer` 协作协议：

- Claude：通过启动参数 `--append-system-prompt` 注入，不写项目文件。
- Codex：写入项目 `AGENTS.md` 中带标记的可撤销块，因为 Codex 使用 `AGENTS.md` 读取项目指令。

第一次交互运行时会询问是否注入。非交互场景默认跳过；加 `-y` 或设置 `AGENT_DUO_AUTO_INJECT=1` 可自动注入。

## 5. iTerm2 设置

如果 `tmux -CC attach -t agents` 后打开的是独立 macOS 窗口，而不是 tab：

```text
iTerm2 Settings > General > tmux >
When attaching, restore windows as... = Tabs in the attaching window
```

这由 iTerm2 控制，`agent-duo` 只负责创建 tmux window。

## 6. 会话生命周期

查看当前 agent：

```bash
peer agent ls
```

查看整体状态：

```bash
peer status
```

结束会话：

```bash
tmux kill-session -t agents
```

重新附加已有会话：

```bash
tmux -CC attach -t agents
```

自定义 tmux 会话名：

```bash
AGENT_SESSION=my-agents agent-duo-start
AGENT_SESSION=my-agents tmux -CC attach -t my-agents
```

## 7. 自然语言 mission：推荐入口

日常最推荐的入口不是让用户手动敲完整 `peer` 命令串，而是把目标写成一份三段 mission，或直接对
supervisor 说清这三段：

- `要做什么 (Goal)`：目标、用户、核心场景。
- `完成条件 (Done means)`：至少包含一个可机械验证项，以及 reviewer/evaluator 不 veto。
- `不做 / 红线 (Non-goals & guardrails)`：范围外事项，以及部署、花钱、碰生产、删数据等必须升级人类 gate 的动作。

模板在 [docs/mission-template.md](mission-template.md)。例如：

```text
请把这个目标跑成 loop：做一个本地优先的 Release Desk 发布检查清单工具。
完成条件：smoke test 通过，reviewer/evaluator 不 veto，最终 report 带 evidence。
不做：不部署、不购买资源、不碰生产。
```

注入给 supervisor 的说明会指向 [docs/SUPERVISOR-LOOP-PLAYBOOK.md](SUPERVISOR-LOOP-PLAYBOOK.md)。
supervisor 收到 mission 后应按 playbook 自动完成：

1. 解析 mission，回显编队、verify、judge、预算、红线 gate，等待用户确认。
2. 创建或复用 `planner`、`builder`、`reviewer`、`evaluator` 可见 teammate。
3. 对工作型 teammate 执行 `peer approval check <id>`。
4. 用 `peer loop init` 冻结 verify/judge 合门。
5. 用 `peer ask` 派发，用 `peer checkpoint` 读状态，用 `peer reframe` 收敛阻塞项。
6. 只在人类 gate 与最终合门时回来找用户。

所以 `peer` 仍是可审计、可调试的控制面，但它是 supervisor 的内部工具，不是普通用户的主要界面。

## 8. Transport：基础互看互发

### 7.1 查看对方屏幕

两人会话里可以省略目标 id：

```bash
peer peek
peer peek 120
```

多人会话必须指定目标：

```bash
peer peek worker 120
```

`peek` 输出是 TUI 屏幕文本，可能含边框、状态栏、spinner，需要自行过滤。

### 7.2 给对方发消息

单行：

```bash
peer tell worker "请审查 README 是否容易理解，完成后汇报主要问题。"
```

多行：

```bash
peer tell worker <<'EOF'
请执行以下任务：
1. 读取 README.zh-CN.md
2. 找出新用户最可能卡住的地方
3. 用 peer report 写结构化结论
EOF
```

实现上，`peer tell` 使用 `tmux load-buffer` + `paste-buffer -p`，也就是 bracketed paste。多行文本会作为一次粘贴进入对方 TUI，不会被逐行提交。

### 7.3 等待对方稳定

```bash
peer wait worker
peer wait worker 300 5 2
```

参数依次是超时秒、采样间隔秒、连续稳定次数。默认通常是 300 秒、5 秒、连续 2 次。

等待某个 report round 的 sentinel：

```bash
peer wait worker --round 3 --timeout 120
```

### 7.4 打断对方

```bash
peer esc worker
```

如果目标屏幕疑似权限确认或弹窗，`peer esc` 和 `peer tell` 默认会拒绝发送按键。确认确实需要强制发送时：

```bash
peer esc worker --force
peer tell --force worker "..."
```

强制发送等同于替对方按键，谨慎使用。

## 9. 管理可见 agent

新增 worker：

```bash
peer agent add --provider codex --role worker
```

指定 id：

```bash
peer agent add --provider claude --role reviewer --id review-1
```

隔离 worktree：

```bash
peer agent add --provider codex --role worker --id impl-1 --worktree
```

移除：

```bash
peer agent rm impl-1
```

如果隔离 worktree 有未提交改动，默认会保留。确认丢弃时：

```bash
peer agent rm --force impl-1
```

身份来自 tmux pane option：

- `@agent_id`
- `@agent_role`
- `@agent_provider`
- 可选 `@agent_worktree`

正好两个 agent 时，`peer` 可以自动解析“另一个”。三个及以上必须显式指定 id，避免误发。

## 10. Approval Broker

新 worker 的 Approval Broker 初始是 `unverified`。发给工作型角色的 `peer tell` / `peer ask` 会检查 broker 是否 fresh ready；不 ready 时默认 fail-closed 拒发。

正确流程：

```bash
peer approval check worker
```

如果成功，会看到 broker READY。之后再派任务：

```bash
peer tell worker "请实现..."
```

查看 broker 状态：

```bash
peer approval status worker
```

列出待审批请求：

```bash
peer approval ls
peer approval ls --all
```

批准一次性请求：

```bash
peer approval approve <approval-id>
```

拒绝：

```bash
peer approval deny <approval-id> --reason "不允许发布或推送远端。"
```

### 9.1 它保护什么

Approval Broker 是工具权限请求接入 loop 的机制，不是完整安全沙箱。当前策略：

- 自动允许常见只读命令、测试命令、worktree 内编辑。
- 对明显危险操作 hard-deny，例如 `sudo`、`ssh`、`git push`、`terraform apply`、`kubectl delete`、`npm publish`、`rm -rf`、`curl | sh`、访问 `.env` / `.ssh` / `.aws`。
- 对不确定操作 escalate，生成 pending approval 并把 blocked event 放进 queue。

真正安全边界仍然依赖：

- provider 自身的非 YOLO 权限模式。
- worktree 隔离。
- deny / escalate 策略。
- 人类 gate。
- 审计日志。

## 11. 结构化 report

worker 应该用 `peer report` 写结构化进度，而不是只把结论留在屏幕上。

进行中：

```bash
peer report --type checkpoint --status in_progress \
  --delta "已读完核心入口，正在梳理 loopd 状态流。" \
  --next "补验证路径和失败恢复。"
```

完成并带证据：

```bash
peer report --type result --status done \
  --delta "实现完成，补了测试。" \
  --evidence-cmd "bash test/run.sh" \
  --evidence-result "pass" \
  --next "等待 reviewer 验收。"
```

如果 `done` 或 `partial` 没有任何 evidence，当前实现会把状态降为 `unknown`。这是为了避免“无证据完成”。

阻塞并请求人类决策：

```bash
peer report --type request --status blocked \
  --needs decision \
  --needs-detail "是否允许部署到 staging？" \
  --needs-option "deploy_staging" \
  --needs-option "skip_deploy"
```

这会自动创建 Human Decision Gate。

阻塞并请求 scope / info / discovery：

```bash
peer report --type request --status blocked \
  --needs scope \
  --needs-detail "目标是否包含 README 英文版？"
```

`--needs` 可用值：

- `approval`
- `decision`
- `info`
- `scope`
- `discovery`

## 12. task.json：步骤账本

初始化任务：

```bash
peer task init worker \
  --task "补齐项目三类文档" \
  --step s1:"阅读本地文档和源码" \
  --step s2:"检索外部资料" \
  --step s3:"新增文档" \
  --step s4:"检查一致性"
```

查看：

```bash
peer task show worker
```

取下一步：

```bash
peer task next worker
```

worker 的 report 如果带 `--step s1`，会更新对应 step：

- `done` 且有 evidence：step 变 `done`。
- `blocked` 或 request：step 变 `blocked`。
- `in_progress`：step 变 `in_progress`。
- `failed`：step 变 `failed`。

如果所有 step 未完成，worker 报 `done` 会被降为 `partial`。

## 13. loop.json：有界迭代契约

初始化 loop：

```bash
peer loop init worker \
  --mission "完成三份中文文档并确保命令与实现一致" \
  --max-rounds 5 \
  --non-goal "不改动运行时代码" \
  --success "三份 docs/*.zh-CN.md 存在" \
  --success "文档中的命令在 peer --help 中存在" \
  --verify docs:"test -f docs/USER-MANUAL.zh-CN.md && test -f docs/IMPLEMENTATION.zh-CN.md" \
  --verify-satisfies docs:"docs-exist" \
  --judge reviewer:request_changes,reject \
  --detail-trap-rounds 3
```

查看：

```bash
peer loop show worker
```

重置预算：

```bash
peer loop reset worker --max-rounds 3
```

如果最新 report 是 `done` 或 `failed`，重置后下一次 tick 仍可能再次停止。先纠偏：

```bash
peer reframe --force worker "继续处理 reviewer 指出的遗漏，完成后写新的非终态 report。"
peer loop reset worker --max-rounds 3
```

## 14. peer ask：受 loop 边界保护的派发

`peer ask` 是 `tell + 等待新 report + 打印摘要` 的热路径：

```bash
peer ask worker "请按 task next 继续，完成本轮后 peer report。"
```

如果 worker 的 loop 已到 `max_rounds` 或 `stopped`，`peer ask` 默认拒发。人工确认后可以越界：

```bash
peer ask --force worker "这是人工确认后的额外一轮，请只修 reviewer 指出的阻塞项。"
```

`peer ask` 依赖 worker 写出新的 report。如果 worker 只在屏幕上回复但没有 `peer report`，`peer ask` 会超时。

## 15. checkpoint 与 reframe

读取方向状态：

```bash
peer checkpoint worker
peer checkpoint worker --json
```

输出会聚合：

- loop mission、预算、剩余轮次。
- 最近几轮 report。
- task step 计数。
- 当前 round 的 verify 状态。

纠偏：

```bash
peer reframe worker "不要继续扩写背景材料，优先补命令参考和 troubleshooting。"
```

`reframe` 会发送一个带 `verb=reframe` 的消息，并写入 `.agent-duo/logs/checkpoints.jsonl`。

## 16. verify gate

查看 verify gate 列表：

```bash
peer verify ls worker
```

查看详情：

```bash
peer verify show worker
peer verify show worker --round 3
peer verify show worker --json
```

verify 命令由 loopd 执行，结果写入：

```text
.agent-duo/state/<agent>/validation-r<round>.json
.agent-duo/logs/<agent>/validation-r<round>-<id>.log
```

当 worker report 为 `done` 时，如果 loop 声明了 verify，只有 verify pass 后才允许 loop 因 `done` 停止。
如果还声明了 `--judge`，对应 reviewer/evaluator verdict 也必须全部不 veto。
supervisor Stop hook 还会在 supervisor 试图停下时机械复核这组条件：verify pass、无 judge veto、
done report 带 evidence、轮次未超预算。未达合门且预算未尽时会拦截并要求继续修；预算耗尽时会打开
Human Decision Gate，而不是无限拦截。

## 17. judge verdict

reviewer/evaluator 不再通过 `peer report --verdict` 写验收，而是使用 `peer judge`：

```bash
peer judge worker@3 --verdict approve \
  --finding note:"文档覆盖完整。" \
  --evidence-cmd "review" \
  --evidence-result "no blocking findings"
```

要求修改：

```bash
peer judge worker@3 --verdict request_changes \
  --finding major:"缺少 Approval Broker fail-closed 说明。"
```

查看 verdict：

```bash
peer judge ls worker
peer judge ls worker --json
```

如果 loop 中有：

```bash
--judge reviewer:request_changes,reject
```

那么 reviewer 的 `request_changes` 或 `reject` 会阻止 `done` 合门，并产生 `review_required` event。

## 18. Human Decision Gate

列出待处理 gate：

```bash
peer gate ls
peer gate ls --all
```

手动打开 gate：

```bash
peer gate open worker \
  --title "选择部署目标" \
  --detail "worker 已构建完成，需要决定是否部署。" \
  --option staging \
  --option skip
```

解决 gate 并把 decision 发回 worker：

```bash
peer gate resolve worker --choice staging --note "只部署 staging，不碰 production。"
```

如果只有一个 pending gate，也可以省略目标：

```bash
peer gate resolve --choice skip
```

`choice` 只能使用字母、数字、点、下划线、冒号、连字符；长说明放 `--note`。

## 19. loopd 看板

`loopd` tab 会显示：

```text
agent-duo loopd
heartbeat: ...
supervisor: idle|busy
pending: N
workers:
  worker pane=%13 round=2 status=in_progress loop=2/5 active verify=pass judge=reviewer:pending
```

它负责：

- 写 heartbeat。
- 发现静默或缺失 pane。
- 投递 queue 里的高优先级事件。
- 周期 tick。
- 运行 verify gate。
- 评估 loop stop 条件。
- 渲染看板。

同时，supervisor 的 Stop hook 会读取同一份 `.agent-duo/` 状态做合门硬门。它不是隐藏 daemon；
它只在 supervisor 准备交还控制时兜底，防止“builder 说 done 但证据/verify/judge 不满足”的假完成。

默认轮询间隔是 2 秒，可用环境变量调整：

```bash
LOOPD_INTERVAL=1 peer loopd
```

常用 runtime 阈值：

- `LOOPD_SILENT_T`：worker 多久没有 report 且 pane quiet 时产生 silent event，默认 180 秒。
- `LOOPD_TICK_T`：tick 间隔，默认 1800 秒。
- `LOOPD_HEARTBEAT_TTL`：supervisor hook 判断 loopd 离线的 TTL，默认 10 秒。

## 20. 常见工作流

### 19.1 让 worker 审查一个文件

```bash
peer approval check worker
peer tell worker "请审查 README.zh-CN.md，完成后用 peer report 汇报主要问题。"
peer wait worker
peer peek worker 120
```

把 worker 结论转述给用户，不要只说“已发送”。

### 19.2 supervisor 派实现任务

```bash
peer task init worker \
  --task "修复 README 中安装说明缺口" \
  --step s1:"确认现状" \
  --step s2:"编辑 README" \
  --step s3:"运行文档检查"

peer loop init worker \
  --mission "README 安装说明准确完整" \
  --max-rounds 4 \
  --verify docs:"rg 'agent-duo-start' README.zh-CN.md" \
  --judge reviewer:request_changes,reject

peer ask worker "请从 task next 开始，完成每步后 peer report。"
```

### 19.3 reviewer 验收 worker

```bash
peer agent add --provider claude --role reviewer --id reviewer
peer approval check reviewer
peer ask reviewer "请审查 worker@latest 的 diff 和 report，最后用 peer judge worker@<round> --verdict ... 写 verdict。"
```

如果 reviewer 要求修改：

```bash
peer reframe worker "reviewer 要求补安装失败场景，请只处理该问题。"
peer loop reset worker --max-rounds 2
peer ask worker "请处理 reviewer feedback，完成后写新 report。"
```

### 19.4 处理权限请求

worker 卡住并产生 pending approval：

```bash
peer approval ls
peer approval approve a20260627T123456Z-12345-6789
peer ask worker "权限已批准，请重试同一工具调用并继续。"
```

如果不允许：

```bash
peer approval deny a20260627T123456Z-12345-6789 --reason "不允许访问外部网络。"
peer reframe worker "该权限已拒绝，请改用本地资料或报告 blocked。"
```

## 21. 状态文件速查

所有控制状态默认在项目根目录：

```text
.agent-duo/
  approvals/                     # Approval Broker 请求
  events/
    queue.jsonl                  # runtime event queue
    cursor                       # 已投递 cursor
    delivered                    # 已投递行号集合
  gates/                         # Human Decision Gate
    stop-drain-*.json             # Stop hook 预算耗尽升级 gate
  logs/
    approvals.jsonl              # approval 审计
    decisions.jsonl              # gate 审计
    checkpoints.jsonl            # reframe 审计
    <agent>/validation-*.log     # verify 日志
  state/
    supervisor/session-settings.json
    daemon.heartbeat
    daemon.expected
    <agent>/
      broker.json
      task.json
      loop.json
      report.json -> rN.json
      r1.json
      validation-rN.json
      reviews/<role>-rN.json
      worktree.json
```

这些文件是调试事实来源。屏幕输出只是用户界面。

## 22. 安全规则

1. 不要让两个 agent 进入无人监督的自动互聊。
2. 不要替用户按权限确认弹窗；发现弹窗就报告给用户。
3. `peer tell` 等同于往对方终端打字，具备真实副作用。
4. 对 worker 派发前先 `peer approval check`，确保 broker 不是 `unverified` / `stale` / `fail-open`。
5. 对会写代码的 worker 优先使用 `--worktree`。
6. 对部署、购买资源、开网络、删数据、推送、发布等动作使用 Human Decision Gate。
7. loop 必须有 `max_rounds`，重要 loop 应有 `--verify` 或 `--judge`。
8. Stop hook 会对已建 loop 做合门硬门；预算耗尽仍未合门时升级 Human Decision Gate，不会无限拦截。
9. `peer budget status` 目前只是预留面，不要假设已有成本硬限制。

## 23. 故障排查

`peer: command not found`

- 确认 agent 是通过 `agent-duo-start` 或 `peer agent add` 启动。
- 确认 `peer` 所在目录在 PATH。

`错误: tmux 会话 'agents' 不存在`

- 先运行 `agent-duo-start`。
- 如果用了自定义 session，执行命令时带同一个 `AGENT_SESSION`。

`会话 'agents' 已存在`

- 直接附加：`tmux -CC attach -t agents`。
- 或结束旧会话：`tmux kill-session -t agents`。

`会话内有多个 agent,请指定目标`

- 三人及以上不能省略目标，使用 `peer tell worker ...`。

`Approval Broker 非 fresh ready`

- 运行 `peer approval check <id>`。
- 如果 Codex 提示 hook need review，在该 Codex pane 里运行 `/hooks` 并信任 agent-duo hook。
- 如果仍失败，不要派需要 broker 保护的任务。

`peer ask 等待新 report 超时`

- worker 可能只在屏幕回复，没有运行 `peer report`。
- 用 `peer peek worker 120` 查看末屏。
- 必要时 `peer reframe worker "请用 peer report 写出当前状态"`。

`loop 已到界`

- 先读 `peer checkpoint worker`。
- 人工确认后可 `peer ask --force` 或 `peer reframe --force`。
- 后续用 `peer loop reset worker --max-rounds N` 给新预算。

`verify 一直 running`

- 查看 `.agent-duo/state/<agent>/validation-rN.running/pid`。
- 查看 `.agent-duo/logs/<agent>/validation-rN-<id>.log`。
- loopd 可能离线，重启或重新 attach 后检查看板。

`worktree 没有自动删除`

- `peer agent rm` 遇到脏 worktree 会保留。
- 处理改动后重试，或确认丢弃：`peer agent rm --force <id>`。

## 24. 命令迁移

旧命令已移除：

| 旧命令 | 新命令 |
| --- | --- |
| `peer ls` | `peer agent ls` |
| `peer add ...` | `peer agent add ...` |
| `peer rm ...` | `peer agent rm ...` |
| `peer loop <id>` | `peer loop show <id>` |
| `peer task <id>` | `peer task show <id>` |
| `--validation*` | `--verify*` |
| `--review` | `--judge` |
| `peer report --verdict ...` | `peer judge <target-ref> --verdict ...` |
| `peer gate` | `peer gate ls` |
| `peer approvals` | `peer approval ls` |
| `peer approve <id>` | `peer approval approve <id>` |
| `peer deny <id>` | `peer approval deny <id>` |
| `peer broker-status <id>` | `peer approval status <id>` |
| `peer broker-check <id>` | `peer approval check <id>` |

## 25. 参考

- [README.zh-CN.md](../README.zh-CN.md)
- [docs/AGENT-INSTRUCTIONS.md](AGENT-INSTRUCTIONS.md)
- [docs/glossary.md](glossary.md)
- [docs/DEMO.zh-CN.md](DEMO.zh-CN.md)
- [bin/peer](../bin/peer)
- [start.sh](../start.sh)
- [lib/loop.sh](../lib/loop.sh)
- [lib/approval_broker.sh](../lib/approval_broker.sh)
