# agent-duo 演示脚本

这个脚本面向第一次接触 `agent-duo` 的普通用户。目标不是讲完 tmux 的所有概念,
而是让对方在 3 分钟内看懂:两个 agent 是真实 tab,不是后台临时进程。

## 演示前准备

1. 在 iTerm2 中打开 `Settings > General > tmux`。
2. 确认 `When attaching, restore windows as...` 选中 `Tabs in the attaching window`。
3. 准备一个可安全演示的小项目目录。
4. 确认 `claude`、`codex`、`tmux`、`agent-duo-start` 都在 PATH 上。

## 1. 先讲一句话

可以这样开场:

> 这个工具不是让 Claude 和 Codex 在后台开新进程互相调用,而是让它们看到你眼前正在操作的
> 两个真实终端 tab。你仍然掌控两个 agent,它们只在你要求时互相传话。

## 2. 启动两个真实 tab

在演示项目目录里运行:

```bash
agent-duo-start
tmux -CC attach -t agents
```

此时 iTerm2 应该显示两个 tab:

- `claude`
- `codex`

如果出现两个 macOS 窗口,回到 iTerm2 设置,把 tmux 选项改为
`Tabs in the attaching window`,然后重新 attach。

## 3. 展示它们互相看屏幕

在 Claude tab 中对 Claude 说:

```text
看一下 Codex 现在在干什么,然后用一句话告诉我。
```

预期效果:

- Claude 会运行 `peer peek`
- Claude 会读取 Codex tab 的近期屏幕内容
- Claude 会把结果转述给你

这里要强调:Claude 看到的是当前 Codex tab 的真实屏幕,不是另起了一个隐藏的 Codex。

## 4. 展示一次委托

在 Claude tab 中对 Claude 说:

```text
请让 Codex 审查这个项目的 README 是否容易理解,等它完成后总结它的建议。
```

预期流程:

```text
Claude -> peer tell -> Codex
Claude -> peer wait
Claude -> peer peek
Claude -> 你
```

可以一边演示一边解释:

- `peer tell` 像是 Claude 帮你把一句话粘贴到 Codex 的输入框
- `peer wait` 是等 Codex 屏幕稳定
- `peer peek` 是再看一眼 Codex 的输出

## 5. 讲清楚安全边界

结束前建议明确说明:

- `peer tell` 等同于往对方终端输入文字,所以它有真实操作能力。
- 说明文件要求 agent 不要替你确认权限弹窗。
- 真正需要安全约束时,Claude 和 Codex 都应该保持非 YOLO 权限模式。
- 不建议让两个 agent 无人监督地互相循环对话。

## 6. 收尾命令

结束演示:

```bash
tmux kill-session -t agents
```

如果只是暂时离开,可以从 iTerm2 的 tmux 模式 detach,之后再运行:

```bash
tmux -CC attach -t agents
```
