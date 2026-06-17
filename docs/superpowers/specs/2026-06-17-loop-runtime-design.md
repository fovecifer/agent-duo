# agent-duo Loop Runtime 设计

日期：2026-06-17
状态：设计稿，daemon 内部细节待定（见 §10）
关联：[supervisor-loop roadmap](../../../agent-duo-supervisor-loop-roadmap.md)、[worker↔supervisor 契约](./2026-06-17-worker-supervisor-contract.md)、[registry MVP 3 design](./2026-06-16-registry-mvp3-design.md)

## 为什么需要它

worker↔supervisor 契约定义了**消息长什么样**，但没定义**谁来驱动消息流转**。supervisor 是个 LLM，只在"被给一个 turn"时才思考；worker 异步打出 sentinel / 写文件。两者之间缺一个桥：把"发生了一件事"变成"supervisor 得到一个 turn 去反应"。

今天这座桥是**人**——人盯屏看到 worker 卡住，再手动转述给 supervisor。Loop Runtime 的目标就是把人从这根中继线上解放出来，**同时不改变人的使用体验**。

## 第一原则：水线（凌驾于所有机制之上）

> **人这一层 = 原生 Claude Code / Codex 体验。自然语言进、自然语言出。控制平面的一切对人隐形。**

```
══════════════ 人这一层（完全不变的 Claude Code 体验）══════════════
   自然语言进、自然语言出。你不需要知道下面有什么。
─────────────────────────────── 水线 ───────────────────────────────
   控制平面（全部内部、对人隐形）：
   · "supervisor" 只是【你正在说话的这个 session】的内部叫法，
     不是一个你要单独管理的角色——就是你的 Claude Code。
   · 结构化契约（Report / task.json / verb / sentinel）= 它对 worker 的内部语言。
   · runtime（队列 / daemon / 注入）= 把 worker 事件喂给它，好让【你不用当中继】。
   · 这些东西存在的唯一目的：让你能继续只说人话。
═══════════════════════════════════════════════════════════════════
```

**设计纪律**：本文档及后续每个机制都必须回答一句——"它会不会泄漏到人这一层？" 任何要求人去读 JSON、记结构化命令、手动转述 worker 状态的设计，都视为违反第一原则。

## 目标体验（端到端）

```
打开 agent-duo  →  一个 Claude Code tab，跟平常一模一样
人:  帮我把登录失败的错误提示修对，然后跑测试验证
它:  好，我打算用一个 codex worker 实现、一个 claude worker review，
     范围只限错误文案、不动 auth 流程。可以吗?          ← 确认几个点
人:  可以
它:  (peer spawn ×2 → 出现两个新 tab) 开始了
        … workers 在各自 tab 干活，supervisor 替你盯着 …
它:  worker-impl 改完测试过了；worker-review 提了个 blocking 问题:
     401/403 文案写反了。我让它改?                       ← 用人话汇报
人:  改
它:  都过了，要我合并吗?
人:  合
```

人自始至终只做一件事：**对一个 agent 说人话**。tab 是它建的，worker 是它管的，结构化的 report/gate/evidence 人一个字都不用看。

## 目标

- 把契约从"协议"升级为"循环"：事件 → 唤醒 supervisor → 决策 → 下发。
- 在不破坏水线的前提下，让 supervisor 事件驱动、idle 零成本、可持久化、可接管。
- 解决并发仲裁（星型多辐条）、liveness（活着/卡住/死了）。

## 非目标（YAGNI）

- 不把 supervisor 变成无头 daemon——它始终是人能看见、能随时插话的可见 session。
- 不在人面前暴露任何结构化命令——结构化 verb 全是 supervisor 的内部动作。
- daemon 的 idle 判定、注入退避、汇报攒批等内部细节本稿不定死（§10，下一步讨论）。

---

## 1. 驱动模型：注入式（attended）为主

### 核心洞察：人和 worker 事件走同一个通道

LLM 只在"被给一个 turn"时才动。在 Claude Code 里，**给 turn = 往输入框送文字 + 回车**：

- **人**手打 = 给 supervisor 一个 turn。
- **runtime** 把一个 worker 事件 `peer tell` 进 supervisor 的框 = 给它一个 turn。

两者**是同一个机制**（就是 agent-duo 现有的 `peer tell`，只是目标换成 supervisor）。所以 runtime 本质上是**一个自动打字员**：人不用框时，替人把 worker 事件转述给 supervisor；人一开始打字，它就让位。

```
            ┌─────────────── supervisor 输入框（唯一通道）───────────────┐
  人    ─── 自然语言，随时，优先级最高 ───────────────────────────────►│
  runtime ─ 人 idle 时注入 worker 事件("worker-impl 在 s2 blocked…")──►│
            └──────────────────────────────────────────────────────────┘
```

仲裁规则一条：**人永远赢**。runtime 只在框空闲、人没在打字时注入；人一插话，它排队等下次空闲。supervisor 忙时人想打断，就和平常一样——排队消息或 ESC。

这顺带消除了"输入框归属冲突"：框永远是 supervisor 的，人和 runtime 都只是往里送 turn，人优先。

### 预算上不吃亏

一个停在 prompt 上的 Claude Code 本来就**零 token**——只有被给 turn 才花钱。所以"空闲时注入"同样省，且不把人锁在外面。（早期草案曾用阻塞 `peer await` 求"idle 零成本"，那是过度设计且会把人锁在框外，已废弃为下述 unattended 变体。）

### 事件投递与 idle 判定：基于 hook（权威，非抓屏）

Claude Code 与 Codex **都有近乎平行的 hook 系统**，daemon 不靠抓屏猜 turn 状态，而是给 supervisor session 挂 command hook 拿权威信号：

| hook | 触发 | daemon 用途 |
|---|---|---|
| `UserPromptSubmit` | 一个 turn 开始 | 标记 **busy，别注入** |
| `Stop` | 一个 turn 结束、即将 idle | 标记 **idle**，且可借此投递事件（见下） |
| `PreToolUse` / `PermissionRequest` | 工具执行前 / 权限弹窗 | （Approval Broker 用，见契约/roadmap） |

**为什么这招干净**：mid-turn、权限弹窗都发生在"收到 `UserPromptSubmit` 之后、收到 `Stop` 之前"，所以**没 `Stop` 就是 busy**；真收到 `Stop` 时 turn 已彻底结束、不可能有弹窗开着。那个最危险的"误答权限弹窗"被 `Stop` 这一个条件从结构上排除。抓屏只剩"人有没有占着输入框"这一个小检查。

**两种投递路径：**

1. **Stop 便车（首选，零竞态）**：supervisor 一个 turn 结束 → `Stop` hook 触发 → 脚本查 `queue.jsonl`：有待处理事件就返回 `decision:"block"` + 事件文本，**阻止收尾并让 supervisor 接着处理**，根本不碰输入框；队列空则放行 idle。
2. **send-keys 注入（仅 idle-arrival）**：事件在 supervisor **已经 idle**（上次 `Stop` 时队列为空）之后才到 → daemon `peer tell supervisor` 唤醒它，配输入框草稿守卫（框为空 + 静默窗口内无变化 + 非 copy-mode）。

> **先例（已生产验证）**：OpenAI 的 `codex` 插件正是用 `Stop` hook 做"收尾前自动 review"——`hooks/hooks.json` 声明 `Stop`（timeout 900s），`stop-review-gate-hook.mjs` 读 stdin 的 `session_id`/`cwd`、跑 review，发现问题就 `emitDecision({decision:"block", reason})` 逼 Claude 修完再停，并用配置开关 `stopReviewGate` 控制启停。我们的"Stop 便车"与之同构（把 review 换成"查队列"），证明机制可行。可借鉴：hook timeout 给足、按 `session_id` 认准自己、默认惰性靠开关启用、`${CLAUDE_PLUGIN_ROOT}` 保证可移植。

**判错偏向**：一切不确定 → **hold（不注入），绝不误发**。held 事件只是等一会（下个 `Stop`/静默窗口自愈或浮到看板），误发可能毁草稿。Codex 的 hook 较新，且有"非托管 hook 需审核信任"的要求，Codex-as-supervisor 时按此保守处理。

### Unattended 变体

无人值守时（没人看着），supervisor 退回自驱：在自己的 turn 里跑阻塞的 `peer await` 拉取事件、反应、再 await。这是**变体，不是主路径**。

---

## 2. 架构

> **事件队列 + 三个生产者 + 一个消费者（supervisor），外加一个只管时钟和看板的瘦 daemon。**

```
生产者 ────────────────────────►  .agent-duo/events/queue.jsonl  ◄──── 消费者
 ① worker:  peer report  ──────────────►│                          │
 ② 人:      直接对 supervisor 说人话 ───►│ (durable, 带 cursor)      │──► supervisor:
 ③ 时钟:    loopd daemon ──────────────►│                          │     人 idle 时被注入事件 → 反应
            (liveness/stuck/budget tick)                                  → peer <verb> 下发给 worker
```

关键性质：**worker 事件和人事件本就能驱动循环，不需要 daemon**。daemon 只负责"没人动时也要产生的"时间类事件 + 看板。⇒ **MVP 可先不做 daemon**；那时**人就是注入者**（即今天的状态）。daemon 上线后，循环才真正自动。

---

## 3. 事件队列与事件形状

durable、append、带单 owner cursor：`.agent-duo/events/queue.jsonl`。

```jsonc
{"id":"e42","ts":"…","agent":"worker-impl","type":"blocked",
 "round":3,"summary":"s2 撞 db 写权限，needs=approval","ref":".agent-duo/state/worker-impl/r3.json"}
```

- `type` ∈ `plan | blocked | result | checkpoint | stuck | silent | dead | budget_low | tick`
- **极小**：只带 agent / type / 一行摘要 / report 文件 ref。supervisor 自己决定要不要花 token 去读完整 report —— 这是 budget 的杠杆。
- **合并规则**：notify 类（`checkpoint`）按 agent 合并到最新；`blocked`/`result`/gate 类逐条保留，**绝不丢**。
- **优先级**：`blocked`/gate > `result` > `stuck` > `budget_low` > `checkpoint`。阻塞 worker 的事优先解，别让它干等。
- **cursor 落盘**：supervisor 重启 / handoff 能从断点续，未处理的 gate 还在。双 supervisor 抢同队列 → cursor 单 owner 加锁（registry MVP 3 本就是单 supervisor）。

---

## 4. 人作为交互方（不是结构化命令）

人**只对 supervisor 说人话**，在 supervisor 自己的 tab 里，跟今天用 Claude Code 一样：

```
你: 优先让 worker-impl 修 s2，别动 auth 模块
你: 那个部署用 staging，别开生产防火墙
你: 停掉 worker-review
```

- 人**不需要**敲 `peer approve` / `peer gate resolve`——**那是 supervisor 的内部动作**。人说"用 staging"，supervisor 自己翻译成 `peer gate resolve --choice staging`。
- worker 写 `report.json`，supervisor **读了转述成人话**给人；人不读 JSON。
- 需要人拍板时（gate），supervisor 把选项用人话摆出来，人说一句即可。

人坐在哪：
- **主**：supervisor 的 tab——看它思考、决策、下发，在框里说话。可见、可审计。
- **辅**：daemon 渲染的看板 pane，扫一眼谁 blocked、哪些 gate 开着、预算剩多少。要插手就回 supervisor tab 说话。
- 想直接戳某 worker：切到它 pane 自己打字，或让 supervisor 代劳。

---

## 5. 汇报攒批与升级判定（何时打扰人）

worker 事件分三档，决定"立刻打断人 / 喂给 supervisor 自处理 / 攒着批量报"。沿用已定的 coalesce 与防饿死（§3）。

| 档 | 典型事件 | 处理 |
|---|---|---|
| **① 立即打断人** | 需人拍板的 gate（部署/采购/开网络入口）、`failed` 且无 fallback | 浮到看板顶 + 轻提醒；不处理就停在这 |
| **② 喂 supervisor，不打断人** | `blocked`(needs=approval/info)、`result(done)`、reviewer verdict | 走 Stop 便车给 supervisor 自处理；人事后在汇总里看到 |
| **③ 攒着批量报** | `checkpoint` 心跳、`delta`/进度 | 按 agent coalesce，到 tick 或人主动问时一次性汇总 |

最难的是判第①档"需人拍板"。**不要把它当成判断**——判断依赖 supervisor 当下感觉，不可靠。它是一棵基于具体属性的决策树，且"判错也不致命"。

### 换问法：证明"自主做是安全的"，否则升级

默认偏向升级。supervisor 要主动做某事，必须**同时证明**：**可逆 + 命中 policy + 在 mission scope 内**。任一证不出 → 升级。默认值站在安全一边，而非"拿不准就自己上"。

### 主轴：可逆性 = "能不能只用 git 撤销"

> 改动的状态**只活在 worktree / git 里** → 可逆（`git checkout`/`reset` 能回去）→ 倾向自主；
> 碰到 **git 以外的任何东西**（云资源、网络入口、钱、secret、别人能看到的状态）→ 不可逆 → 升级。

| 动作 | 出 git 了吗 | 归档 |
|---|---|---|
| worktree 里 `npm test`、改文件、删生成物 | 否 | 自主（③，常不单独报） |
| `git push` feature 分支 | 边界（可删/force） | policy 粒度：feature 放行、main 升级 |
| 买 VM、`terraform apply` | 是（持续花钱） | **硬升级（①）** |
| 开 `0.0.0.0/0:22` 防火墙 | 是（外网入口） | **硬升级（①）** |
| 部署 staging/prod | 是 | **硬升级**（除非 contract 预授权 staging） |
| drop 一张 DB 表 | 是（外部、不可逆） | **硬升级（①）** |

### 决策树

```
对每个待办动作 / worker request:
  ① 命中 contract 声明的 human_gate?                        → 升级(硬)
  ② 出 git 了 / 命中"永不自动"清单(花钱·外网·secret·prod)?  → 升级(硬)
  ③ 命中 allow policy + 在 scope 内 + 可逆?                 → 自主执行
  ④ 模糊地带:
        可逆          → 执行 + 进汇总(第③档)
        拿不准是否可逆  → 当作不可逆 → 升级
```

模糊情况全部由**可逆性**收口：可逆的错了能撤，容许自主；拿不准就按不可逆、升级。

### 判错也不致命：UX 分档 ≠ 安全闸门（解耦）

危险的不是 supervisor 的分档判断，而是危险动作**真的被执行**。真正执行有**独立机械闸门**——Approval Broker hook（`PreToolUse`/`PermissionRequest`）：

- supervisor 即使第②步判错、真去跑 `terraform apply` → policy hook 执行前**独立拦下** → 这次拦截**本身变成一个强制升级事件**。
- 于是：**分档判断管"何时打扰人"(UX)，policy hook 管"什么能真的执行"(安全)。** 解耦后，分档判错最坏只是 UX 不优，不致不可逆后果。

### 升级有三个独立来源（不押注 supervisor 单点）

- **worker** 自己发现要部署/采购 → `request(needs.kind=decision)`
- **supervisor** 按动作类别匹配 gate
- **policy hook** 拦下危险命令 → 强制升级

### 边界从日志里长出来

每次升级与自主决定都进 `decisions.jsonl` / `approvals.jsonl`。人事后可调："这类以后别问我"（放宽 policy）/"这类永远问我"（加 gate）。"难判断"的部分交给真实历史收敛，不要求第一版划得完美。

## 6. 团队按需生长（启动即普通模式）

- **不预先声明团队**。开 agent-duo = 一个 tab，直接开聊；worker 按需 spawn。对齐 registry MVP 3 的"单 supervisor + 按需生长"。
- **创建 worker 前轻确认**：spawn = 冒出新 tab，是可见副作用，所以"确认几个点（provider、几个 worker、scope）再建"是对的——恰好对应契约的 plan/assign，只是用对话表达。

---

## 7. Liveness：思考 / 阻塞 / 失联 / 死了

纯机械、daemon 计算（LLM 当不了时钟）：

| 现实 | 判据 | 事件 |
|---|---|---|
| 在思考 / 干活 | 有输出在变，未超时 | 无 |
| 真阻塞等你 | 最新 sentinel=blocked + pane 停在 prompt | `blocked`（peer report 已发） |
| 失联 | 无新 sentinel + 输出不再变 + 超 T | `silent`（supervisor 去 peek/poke） |
| 死了 | tmux 里 pane 没了 | `dead`（supervisor 从 task.json 恢复：reassign/handoff） |

`dead` 很重要——tmux-as-truth 让死 pane 消失，但 task.json 还指着幽灵，必须有人捞回来。

---

## 8. 对 codec 第 1 步的约束（接口一次定死）

runtime 给契约 codec 加了硬约束，二者**应合并实现**：

1. report 文件放**固定可 watch 路径**：`.agent-duo/state/<agent_id>/rN.json` + `report.json`（latest）。
2. sentinel **自带入队所需字段**：`agent_id round type status file sha`——不读文件即可入队。
3. `peer report` 一次干三件事：**写文件 + 打 sentinel + 追加 event 到 `queue.jsonl`**。event 是给 runtime 的可靠触发，sentinel 是给人 / `peer wait` 的镜像。
4. 新增 `.agent-duo/events/` 目录与队列格式。
5. **hook 安装**：supervisor session 需挂 `UserPromptSubmit`/`Stop`（busy/idle + Stop 便车），worker session 后续挂 `PreToolUse`/`PermissionRequest`（Approval Broker）。agent-duo 自带这些 hook 脚本，spawn 时注入对应 session 的 settings（Codex 侧注意托管/信任要求）。

---

## 9. 失败 / 恢复

- supervisor 中途挂 → 队列 + cursor 落盘，新 supervisor（或人）从 cursor 续，未处理 gate 还在 → 接 budget MVP 的 handoff packet。
- 队列膨胀 → notify 合并 + 已处理归档。
- daemon 死 → **降级继续**：worker / 人事件仍直接入队，loop 不停，只是暂时没有 liveness / 看板。daemon 是**增强项，非单点**。

---

## 10. 增量落地

```
1. queue.jsonl + peer report 追加 event + sentinel codec（与契约第 1 步合并）
   → worker + 人事件即可驱动一个真 loop，无 daemon（人当注入者）
2. loopd daemon（注入者）：人 idle 时自动把 worker 事件 peer tell 进 supervisor
   → 循环真正自动；人只在被问 gate、或想插手时开口
3. daemon 扩展：liveness（silent/dead）+ tick + 看板 pane
4. stuck / budget_low 派生事件
```

---

## 11. 待定（下一步讨论）

已定：
- ~~**idle 判定**~~ → hook 权威：`UserPromptSubmit`=busy、`Stop`=idle，`Stop` 一招排除 mid-turn 与权限弹窗；抓屏只剩输入框草稿守卫（见 §1）。
- ~~**注入退避**~~ → Stop 便车为首选（零竞态）、send-keys 仅用于 idle-arrival 且带草稿守卫；一切不确定 hold，不误发（见 §1）。
- ~~**汇报攒批 + 升级判定**~~ → 三档 + 可逆性主轴决策树 + UX/安全解耦（见 §5）。

仍待讨论：
- **tick 默认开关**：长超时 tick（如 30min）默认开 → supervisor 主动做 direction checkpoint；默认关 → 纯被动最省。倾向"开、但周期长"。
- **daemon 降级边界**：哪些功能丢了仍算可用。
- **Approval Broker 的 hook 化**：用 `PreToolUse`/`PermissionRequest` 在 worker session 上机械放行/拒绝（替代 roadmap 原"抓屏+回车"方案），细节待 MVP 1/2 设计。
