# agent-duo — 让 Claude Code 和 Codex 在 iTerm2 里互相协作

基于 tmux 的极简方案:两个 agent 跑在同一个 tmux 会话的两个窗口里,
通过 iTerm2 的 tmux 原生集成(`tmux -CC`),它们看起来仍是两个普通的 iTerm2 tab。
每个 agent 通过 `peer` 命令读取对方屏幕(`tmux capture-pane`)、
向对方输入框打字(`tmux send-keys`)——对接的是你眼前那个**真实的交互会话**,
而不是后台另起的子进程。

## 文件

```
agent-duo/
├── start.sh                 # 一键启动两个 agent
├── bin/peer                 # 互看/互发指令的核心命令
└── AGENT-INSTRUCTIONS.md    # 追加到 CLAUDE.md / AGENTS.md 的协作说明
```

## 安装(一次性)

1. `brew install tmux`(如已安装可跳过)
2. 把 `agent-duo/` 放到任意位置,例如 `~/agent-duo`,并 `chmod +x start.sh bin/peer`
3. 把 `AGENT-INSTRUCTIONS.md` 的内容追加到项目的 `CLAUDE.md`(Claude Code 读取)
   和 `AGENTS.md`(Codex 读取)。两个文件用同一段内容即可。

## 日常使用

```bash
cd ~/your-project
~/agent-duo/start.sh          # 创建会话,两个窗口分别启动 claude 和 codex
tmux -CC attach -t agents     # 在 iTerm2 中附加;两个窗口 → 两个原生 tab
```

之后正常在两个 tab 里分别和 Claude Code、Codex 对话。需要它们交互时,
直接用自然语言指挥,例如:

- 对 Claude 说:「看一下 Codex 现在在干什么」 → 它会执行 `peer peek` 并转述
- 对 Claude 说:「让 Codex 审查一下 internal/auth 这个包,等它写完后把结论总结给我」
  → 它会 `peer tell` → `peer wait` → `peer peek`,再向你汇报
- 对 Codex 说:「问问 Claude 它对这个方案的意见」 → 反方向同理

结束:`tmux kill-session -t agents`

## peer 命令参考

| 命令 | 作用 |
|---|---|
| `peer peek [行数]` | 查看对方终端最近输出(默认 80 行) |
| `peer tell "消息"` | 发送单行消息并回车 |
| `... \| peer tell` | 从 stdin 投递多行消息(buffer + bracketed paste,引号/换行安全) |
| `peer wait [秒]` | 等待对方输出稳定(默认最长 300s) |
| `peer esc` | 向对方发 Escape,打断其生成 |
| `peer status` | 查看双方身份与窗口状态 |

身份由 `start.sh` 注入的 `AGENT_NAME` 环境变量决定,`peer` 自动把"对方"
解析为另一个窗口,两个 agent 用的是同一个脚本。

## 原理与注意事项

- **tell 的投递机制**:`tmux load-buffer` + `paste-buffer -p`(bracketed paste),
  TUI 会把内容识别为一次完整粘贴,多行不会被逐行提交,引号反引号无需转义;
  粘贴后 sleep 0.5 再回车,避免 TUI 还没处理完粘贴就把回车吞掉。
- **为什么 peer 是独立脚本而不是 ~/.zshrc 里的函数**:Claude Code / Codex 执行命令
  用的是非交互式 shell,不会 source .zshrc,shell 函数对它们不可见;
  PATH 上的可执行脚本才能被两个 agent 直接调用。
- **peek 输出含 TUI 噪音**(边框、状态栏、spinner),说明文件里已提示 agent 自行过滤。
- **安全**:`peer tell` 等同于在对方终端打字,意味着一个 agent 理论上可以替另一个
  agent 按下权限确认键。说明文件中已明确禁止这样做(由用户决定),但这只是提示词层面的
  约束;如果你担心,可让两个 agent 都跑在各自的非 YOLO 权限模式下,确认弹窗仍需你本人处理。
- **不要让它们无人监督地互相循环对话**:说明文件规定每轮交互都必须源自你的指令,
  避免两个 agent 互相触发、token 烧穿。
- 如果你后来想要"结构化的互相调用"(而不是看屏幕),可以叠加 MCP 方案:
  `npx claude-codex-bridge setup` 双向安装即可,与本方案不冲突。

## 故障排查

- `peer: command not found` → agent 的 shell 没继承 PATH;确认是通过 `start.sh`
  启动的,或在 agent 里用绝对路径调用。
- `会话不存在` → 先运行 `start.sh`;自定义会话名时需同时设置 `AGENT_SESSION`。
- iTerm2 附加后没有变成原生 tab → 必须用 `tmux -CC attach`(注意 `-CC`),
  且 iTerm2 → Settings → General → tmux 中保持默认集成设置。
