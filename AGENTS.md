<!-- agent-duo:start -->
## 与另一个编码 Agent 协作

本机的同一个 tmux 会话中还运行着另一个交互式编码 Agent(Claude Code 或 Codex,
环境变量 `AGENT_NAME` 标识了你自己的身份)。你可以通过 `peer` 命令与它交互:

- `peer peek [行数]` — 查看对方终端最近的输出(默认 80 行)
- `peer tell "消息"` — 发送单行消息到对方输入框并回车,效果等同于用户直接对它说话
- 多行/含特殊字符的指令请走 stdin(经 tmux buffer + bracketed paste,无需任何转义):

  ```bash
  peer tell <<'EOF'
  这里是完整的多行指令,可包含 `反引号`、引号和换行
  EOF
  ```
- `peer wait [超时秒]` — 阻塞等待,直到对方屏幕输出稳定(视为它已完成当前任务)
- `peer esc` — 向对方发送 Escape,打断它正在进行的生成
- `peer status` — 查看双方身份与窗口状态
- `peer task init <id> --task "..." --step s1:"..."` / `peer task next <id>`
  — supervisor 初始化/查看 worker 的持久化 `task.json` 步骤账本;worker 解阻后按 next 从 `blocked` 或下一个 `pending` 步续跑
- `peer loop init <id> --mission "..." --max-rounds N [--validation id:"cmd"] [--detail-trap-rounds N]` / `peer loop <id>`
  — supervisor 冻结/查看 worker 的 loop 契约;runtime 会按相对轮次预算截停,并在配置 validation 时用异步客观验收结果门控 `done`
- `peer loop reset <id> [--max-rounds N]`
  — supervisor 在当前最新 report 轮次重新冻结 loop,清空停止状态并给新预算;若最新 report 已是 `done`/`failed`,先用 `peer reframe --force` 推出新非终态 report 再续跑
- `peer ask <id> "消息"` — supervisor 原子下发一条 loop-gated 消息,等待 worker 下一轮结构化 report,再只读取这轮新结果
- `peer checkpoint <id> [--json]` — supervisor 只读汇总 worker 的 loop、最近 report、task 与 validation 状态,用于判断继续/纠偏/停止
- `peer reframe <id> "消息" [--force]` — supervisor 向 worker 下发方向纠偏(`verb=reframe`),并写入 `checkpoints.jsonl` 审计
- `peer report --type request --status blocked --needs decision --needs-detail "..." --needs-option "..."`
  — worker 需要人类做业务/部署/成本/网络等判断时,写结构化阻塞报告并打开 Human Decision Gate
- `peer gate` / `peer gate open ...` / `peer gate resolve --choice ...`
  — supervisor 查看、创建、解决 Human Decision Gate;人类只需对 supervisor 说自然语言,由 supervisor 执行这些命令

### 使用规则

1. **仅在用户明确要求时**才向对方发送指令(`peer tell` / `peer ask` / `peer reframe` / `peer esc`);
   `peer peek` 用于查看状态,可以在用户询问对方进展时主动使用。
2. 典型流程:`peer tell "..."` → `peer wait` → `peer peek 120`,
   然后把对方回复的要点**转述给用户**,不要只说"已发送"。
3. 对方屏幕是 TUI 界面,`peek` 抓到的文本可能含边框、状态栏等噪音,自行过滤。
4. 不要与对方进入无人监督的自动循环对话;每轮交互都应源自用户的指令。
5. 如果对方处于权限确认/弹窗状态(peek 可以看出来),如实告知用户,由用户决定,
   不要替用户按下确认键。

<!-- agent-duo:end -->
