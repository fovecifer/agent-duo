# Loop Engineering 实际用例：一条 Prompt 做出一个产品

这个文档展示 `agent-duo` 应该提供的用户体验：像 Claude Code 的 agent teams 一样，用户不需要手动敲一串 `peer task init` / `peer loop init` / `peer ask` 命令。用户只在一个 agent CLI 窗口，也就是 `supervisor` 窗口里，输入一条产品目标 prompt。之后由 supervisor 负责创建 worker、冻结 loop、派发任务、收集 verify/judge 结果，并把最终可验收产品交还给用户。

命令仍然存在，但它们是 supervisor 的内部工具，不应该成为普通用户的主要界面。

## 1. 参考 Claude Code 的交互模型

Claude Code 的 Agent Teams 文档把入口设计成自然语言：用户告诉 lead session 想要什么 teammates 和任务，lead 负责 spawn、协调、维护任务列表和汇总结果。它还明确区分 lead 与 teammates：lead 是主会话，teammates 是独立上下文中的工作会话；质量门可以通过 hooks 阻止不合格的任务完成。相关资料：

- [Claude Code: Agent teams](https://code.claude.com/docs/en/agent-teams)
- [Claude Code: Subagents](https://code.claude.com/docs/en/sub-agents)
- [Claude Code: Hooks](https://code.claude.com/docs/en/hooks)
- [Claude Code: Worktrees](https://code.claude.com/docs/en/worktrees)

`agent-duo` 的等价心智模型：

```text
用户只对 supervisor 说一句完整目标
  -> supervisor 自己使用 peer agent/task/loop/ask/reframe/gate/approval
  -> planner/builder/reviewer/evaluator 在可见 tab 中工作
  -> loopd 跑 verify、投递事件、展示看板
  -> supervisor 汇总最终产品、证据和剩余风险
```

## 2. 用户只需要做什么

第一次在项目里启动：

```bash
agent-duo-start
tmux -CC attach -t agents
```

然后在 `supervisor` 的 Claude Code 或 Codex CLI 输入框里粘贴下面这一条 prompt。

## 3. 一条 Prompt

```text
请用 agent-duo 的 loop engineering 流程，从 0 做出一个本地优先的小产品。

产品名：Release Desk

产品目标：
做一个发布检查清单工具，帮助独立开发者在发布前整理任务、风险和验收状态。它应该能在浏览器里直接使用，数据保存在本地，首屏就是可用工具，不要做 landing page。

MVP 功能：
- 创建、重命名、删除多个 release checklist。
- 每个 checklist 包含三类条目：Tasks、Risks、Checks。
- 每个条目可以新增、编辑、删除、切换状态。
- 状态至少包含 todo、doing、done、blocked。
- 使用 localStorage 持久化，刷新后数据仍在。
- 首页显示 readiness 汇总：完成项、阻塞项、风险项、是否 ready。
- 移动端宽度下可读、可操作。
- 有最小自动测试或 smoke test。

非目标：
- 不做登录。
- 不接后端。
- 不接第三方 API。
- 不部署生产。
- 不购买任何资源。

请你作为 supervisor 完成整个流程，不要把 peer 命令交给我手动执行。你需要自己：

1. 查看当前 agent 编队；缺少角色时创建可见 teammates。
   - planner：负责产品 brief 和验收契约，不写代码。
   - builder：负责实现产品和测试，建议用隔离 worktree。
   - reviewer：负责代码和产品契约审查。
   - evaluator：负责像真实用户一样运行和试用产品。

2. 对所有工作型 teammate 先做 Approval Broker 自检。
   - 如果 broker 没 ready，告诉我需要在对应 pane 信任 hook 或处理权限，不要绕过安全门。

3. 让 planner 先产出：
   - docs/product/brief.md
   - docs/product/acceptance.md
   acceptance 必须写清 reviewer 和 evaluator 的验收标准。

4. 给 builder 建立有界 loop：
   - mission：实现 Release Desk MVP。
   - max rounds：6。
   - non-goals：不接后端、不部署、不买资源。
   - verify gate：必须能运行 smoke test，例如 bash test/run.sh，或项目实际测试命令。
   - judge gates：reviewer 的 request_changes/reject 必须 veto；evaluator 的 fail/request_changes 必须 veto。

5. 派 builder 实现，但要求 builder 每轮写结构化 peer report。
   - done 必须带 evidence-cmd/evidence-result/evidence-ref。
   - 如果没有证据，不要接受 done。

6. 让 reviewer 审查 builder 的最终 round。
   - reviewer 不改代码，只写 peer judge。
   - finding 必须具体、可执行。

7. 让 evaluator 按 docs/product/acceptance.md 里的用户脚本实际试用。
   - evaluator 不改代码，只写 peer judge。
   - 必须检查创建、编辑、状态切换、刷新持久化、readiness 汇总和移动端布局。

8. 如果 verify 或 judge 失败：
   - 你负责读 checkpoint / verify / judge。
   - 你负责 reframe builder，只修阻塞项，不扩范围。
   - 必要时 reset 小预算继续。

9. 如果遇到部署、购买资源、访问外网、发布、删除数据、改变范围等高层判断：
   - 打开 Human Decision Gate。
   - 给我选项和建议。
   - 未经我明确选择，不要继续。

10. 最终汇报必须包含：
   - 产品入口文件或运行方式。
   - smoke test / build / verify 证据。
   - reviewer verdict。
   - evaluator verdict。
   - 最终 report ref。
   - 剩余风险。

你可以使用 peer 命令、loopd、worktree、verify、judge、gate 和 approval broker，但这些都是你的内部执行细节。请现在开始，先检查当前 agent 编队并补齐需要的 teammates。
```

这就是用户层面的完整接口。

## 4. 用户期望看到的过程

用户不需要盯着每个命令，但应该能在 tabs 中看到真实进展：

```text
supervisor tab
  解释计划、创建 teammates、派发任务、汇总结果

planner tab
  产出产品 brief 和 acceptance contract

builder tab
  实现 Release Desk、写测试、修 verify/judge 反馈

reviewer tab
  审查代码和产品契约，写 judge verdict

evaluator tab
  运行产品，按用户脚本试用，写 judge verdict

loopd tab
  展示 pending events、worker round、verify、judge、loop stop
```

如果 supervisor 需要用户处理权限或业务判断，它应该停下来说明：

```text
我需要你处理 builder 的 Codex hook trust。
请在 builder pane 运行 /hooks 并信任 agent-duo hook，然后告诉我继续。
```

或：

```text
需要 Human Decision Gate：
是否允许启动本地 dev server 做浏览器 smoke test？
选项：
1. allow_local_server
2. skip_browser_smoke
建议：allow_local_server，仅限 localhost，不部署。
```

## 5. Supervisor 内部应该做什么

下面不是给用户手动执行的命令，而是 supervisor 收到一条 prompt 后应该自动完成的内部步骤。

### 5.1 编队

检查：

```bash
peer agent ls
```

缺少角色时创建：

```bash
peer agent add --provider codex --role planner --id planner
peer agent add --provider codex --role builder --id builder --worktree
peer agent add --provider claude --role reviewer --id reviewer
peer agent add --provider codex --role evaluator --id evaluator --worktree
```

对工作型 agent 验证 broker：

```bash
peer approval check planner
peer approval check builder
peer approval check reviewer
peer approval check evaluator
```

如果 broker 不 ready，supervisor 应该向用户请求处理，不应该强制绕过。

### 5.2 Planner loop

supervisor 应该给 planner 一个小 loop，让它只产出契约：

```bash
peer task init planner \
  --task "Release Desk 产品契约" \
  --step p1:"目标、场景、非目标" \
  --step p2:"MVP 功能和信息架构" \
  --step p3:"验收标准和用户试用脚本"

peer loop init planner \
  --mission "产出 Release Desk 产品 brief 和验收契约" \
  --max-rounds 3 \
  --non-goal "不写实现代码" \
  --success "docs/product/brief.md 存在" \
  --success "docs/product/acceptance.md 存在" \
  --verify contract:"test -f docs/product/brief.md && test -f docs/product/acceptance.md" \
  --verify-satisfies contract:"product-contract-exists"
```

然后用 `peer ask planner "..."` 派发。planner 完成后，supervisor 读取 `peer verify show planner` 和 `peer checkpoint planner`。

### 5.3 Builder loop

builder 的 loop 必须有机械 verify 和独立 judge：

```bash
peer task init builder \
  --task "实现 Release Desk MVP" \
  --step b1:"读取产品契约并选择最小技术栈" \
  --step b2:"实现 UI、状态模型和 localStorage 持久化" \
  --step b3:"补 smoke test" \
  --step b4:"运行验证并写完成 report"

peer loop init builder \
  --mission "实现 Release Desk MVP，并满足 docs/product/acceptance.md" \
  --max-rounds 6 \
  --non-goal "不接后端、不部署、不购买资源" \
  --success "产品可在本地浏览器运行" \
  --success "localStorage 持久化可验证" \
  --success "自动测试或 smoke test 通过" \
  --verify smoke:"bash test/run.sh" \
  --verify-satisfies smoke:"smoke-pass" \
  --judge reviewer:request_changes,reject \
  --judge evaluator:fail,request_changes \
  --detail-trap-rounds 3
```

如果当前仓库已有测试命令，supervisor 应替换 `bash test/run.sh` 为项目实际命令，例如 `npm test`、`npm run build`、`go test ./...`。

### 5.4 Review / Evaluate

builder 写出 final report 后，supervisor 让 reviewer 和 evaluator 分别 judge 同一个 target round：

```bash
peer ask reviewer "请审查 builder@<round>，不要改代码，最后 peer judge builder@<round> --verdict approve|request_changes|reject。"

peer ask evaluator "请按 docs/product/acceptance.md 试用 builder@<round>，不要改代码，最后 peer judge builder@<round> --verdict pass|request_changes|fail。"
```

supervisor 再查看：

```bash
peer verify show builder --round <round>
peer judge ls builder
peer loop show builder
```

### 5.5 修复循环

如果 verify 或 judge 不通过，supervisor 不应该把问题丢给用户，而应该：

```bash
peer checkpoint builder
peer reframe builder "只修复当前 verify/judge 阻塞项，不扩展新功能。"
peer loop reset builder --max-rounds 2
peer ask builder "请处理 reframe 中列出的阻塞项，完成后写新 report。"
```

继续直到：

- verify pass。
- reviewer verdict 没有 veto。
- evaluator verdict 没有 veto。
- builder loop 因 done 停止。

## 6. 最终汇报格式

用户只需要看到类似这样的结果：

```text
Release Desk MVP 已完成。

运行方式：
- 打开 index.html
或
- npm install
- npm run dev

验收证据：
- builder final report: .agent-duo/state/builder/r4.json
- verify: .agent-duo/state/builder/validation-r4.json, status=pass
- reviewer: approve, .agent-duo/state/builder/reviews/reviewer-r4.json
- evaluator: pass, .agent-duo/state/builder/reviews/evaluator-r4.json

已实现：
- 多 checklist 创建/重命名/删除
- Tasks/Risks/Checks 三类条目
- todo/doing/done/blocked 状态
- localStorage 刷新持久化
- readiness 汇总
- 移动端布局
- smoke test

剩余风险：
- 当前是 localStorage 单机数据，没有同步和备份。
- evaluator 只做了本地 smoke，不包含多浏览器矩阵。
```

## 7. 为什么文档不再把命令放在第一层

旧版案例把每一步 `peer task init`、`peer loop init`、`peer ask` 都暴露给用户。那更像内部 API 教程，不像产品体验。

参考 Claude Code 的 lead/team 模式，用户界面应该是：

```text
给 lead 一个目标 + 约束 + 验收标准
lead 自己完成编队、计划、执行、验收和汇报
```

`agent-duo` 保留命令面的原因是可调试、可审计、可恢复；但理想使用方式应该是一条高质量 prompt 驱动整个 loop。

## 8. 这个案例体现的设计原则

| 原则 | 用户看到什么 | supervisor 内部做什么 |
| --- | --- | --- |
| 单 prompt 入口 | 用户只描述产品目标 | supervisor 拆 task/loop |
| Lead 负责协调 | 用户只和 supervisor 对话 | supervisor 创建 planner/builder/reviewer/evaluator |
| 分离 plan/build/judge | 用户看到角色分工 | planner 写契约、builder 实现、reviewer/evaluator judge |
| 有界 loop | 用户不担心无限跑 | `--max-rounds` 和 `loop reset` |
| 机械验证 | 用户看到 verify 证据 | `--verify smoke:"..."` |
| 独立验收 | 用户看到 reviewer/evaluator verdict | `peer judge` 和 veto gate |
| 人类 gate | 高风险问题暂停问用户 | `peer gate open/resolve` |
| 可见性 | 用户能看每个 tab | tmux pane + loopd dashboard |
| 可审计 | 最终汇报有 ref | `.agent-duo/state` 和 `.agent-duo/logs` |

## 9. 给 supervisor 的简短版本

如果用户不想贴长 prompt，也可以只贴这个压缩版：

```text
请用 agent-duo 从 0 做一个本地优先的小产品 Release Desk：发布前 checklist 工具，浏览器可用，localStorage 持久化，首屏是工具不是 landing page。你作为 supervisor 自己创建 planner/builder/reviewer/evaluator，验证 broker，建立有 max-rounds、verify、reviewer/evaluator judge 的 loop。planner 先写 docs/product/brief.md 和 docs/product/acceptance.md；builder 按契约实现并写 smoke test；reviewer 审查；evaluator 按用户脚本试用。verify/judge 失败就 reframe builder 只修阻塞项。遇到部署、购买资源、外网、发布、删数据、范围变化就开 human gate。最终只向我汇报运行方式、验收证据、verdict、final report ref 和剩余风险。不要把 peer 命令交给我手动执行。
```
