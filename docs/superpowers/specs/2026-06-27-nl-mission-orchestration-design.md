---
title: "NL Mission 入口与 supervisor 自动编排（对齐 Agent Teams 设计）"
date: 2026-06-27
status: design
tags: [natural-language, orchestration, loop-engineering, agent-teams, mission, agent-duo]
related:
  - 2026-06-27-loop-engineering-restructure-design.md
  - LOOP-ENGINEERING-PRODUCT-CASE.zh-CN.md
---

# NL Mission 入口与 supervisor 自动编排

## 0. 最高约束（凌驾本 spec 所有设计决策）

> 借 Claude Code **Agent Teams** 的入口人体工学，但**全在 agent-duo 自有、工具无关的底座上原生实现，
> 不依赖原生 Agent Teams**；**loop / verifier 永远是脊柱**——任何简化不得削弱 verify / judge / stop 闸门，
> 不得削弱跨工具桥（Claude ↔ Codex）。

依据：Agent Teams 是「空间轴」并行底座，没有内建 loop（跑完即关、无心跳、无「验证通过才停」），且只
Claude↔Claude、session resumption 弱。agent-duo 的不可替代价值＝跨工具桥 + loop 纪律层，二者都留在自己手里。

## 1. 背景与动机

现状（`docs/LOOP-ENGINEERING-PRODUCT-CASE.zh-CN.md`）要人手敲十几条 `peer task init / loop init / ask /
reframe`，对照 Claude Code `/goal`「一个提示词文件就把 loop 跑起来」UX 落差太大。**自然语言与框架交互是
agent-duo 的核心设计原则**：`peer` 命令面应退为 supervisor 的内部实现细节，人类接口收敛到自然语言。

本 spec 是「底座对齐 Agent Teams」系列的**第一个子项目**：**NL mission 入口 + supervisor 自动组队编排
（含可复用角色定义 #6）**。后续子项目（共享 task list / mailbox 自动投递 / hook 质量门 / plan approval）
各自再 brainstorm。

学 Agent Teams 的：①NL-first 入口 + ②supervisor 主动提议组队 + ⑥可复用角色定义。
坚持 agent-duo 差异：supervisor 中介、全程可见、人类 gate（不学 AT 的无人值守自取互聊）。

## 2. 目标体验与架构

**目标体验**：

```
你：把这份 mission.md 跑起来。            ← 唯一人类输入（NL + 一个文件，或直接说这几段）
supervisor（自动）：
  1. 读 mission → 提议编队（planner/builder/reviewer/evaluator）→ 回显待确认
  2. peer agent add ×N + approval check                      ← 命令对人隐身
  3. 把「完成条件」物化成 verify gate + judge 契约
  4. planner 出契约 → builder 实现 → reviewer/evaluator 独立 judge
  5. Ralph 循环：未合门则 reframe 重试、拦假完成
  6. 只在【人类 gate】和【最终合门】回来找你
```

**四件套**：

| 件 | 角色 | 状态 |
|---|---|---|
| **mission 文件**（NL，§3） | 人类唯一要写：goal + done-criteria + 非目标/红线 | 🆕 |
| **supervisor 编排 playbook**（§4） | 「运行时」：把 mission 翻成完整 plan-build-judge 流程 | 🆕 |
| **可复用角色定义**（#6，§4） | planner/builder/reviewer/evaluator 的标准职责+派发模板 | 🆕 |
| **peer 机件**（task/loop/verify/judge/gate/stop-hook） | 被 playbook 调用的内部实现 | ♻️ 已有 |

**三条不变量（对 Agent Teams 的刻意偏离，守差异化）**：每轮交互源自人/supervisor、**不许 teammate 私下互聊**；
全程在可见 tab；高层决策仍升级人类 gate。

## 3. mission 文件的 NL 模板

**原则**：人只写**意图**（prose），supervisor **物化机件**，中间一道**回显确认**把抽象「完成」变成具体闸门。

人要写的——三段 prose：

```markdown
# Mission: <一句话目标>

## 要做什么 (Goal)          ← 必填
<2–4 句自然语言：是什么、给谁、核心场景>

## 完成条件 (Done means)    ← 必填，这是 loop 的停止条件
- <可机械验证>：如「smoke 测试通过」「npm run build 无错」
- <主观质量>：如「首屏即可用工具、不是 landing page」「移动端可用」
- <独立验收>：如「reviewer、evaluator 都不 veto」

## 不做 / 红线 (Non-goals & guardrails)   ← 推荐
- 不做：<范围外>
- 红线（必须升级人类 gate）：部署、花钱、碰生产、删数据
```

**supervisor 自动推断 + 回显确认（对齐 AT plan-approval）**：读完 mission 把 prose 翻成具体机件，回显一屏等确认：

```
supervisor 拟定（待确认）：
  编队：planner · builder(isolated) · reviewer · evaluator(isolated)   ← 实例化角色定义
  verify 闸门：smoke = `bash test/run.sh`        ← 从「smoke 测试通过」推断
  judge 契约：reviewer veto=request_changes,reject；evaluator veto=fail,request_changes
  预算：builder max-rounds 6 · detail-trap 3
  红线 gate：deploy / purchase → 人类决策门
确认？(y / 改哪条 / 让我补一个 smoke test)
```

确认后才执行 `peer agent add … / loop init … / ask …`（命令对人隐身）。

**职责切分**：

| 人写（intent，NL） | supervisor 推断（mechanics，回显确认） |
|---|---|
| 目标、完成条件、非目标/红线 | 编队、verify 命令、judge 契约、max-rounds/detail-trap、task 拆解、派发 prompt |

**两条 NL-first 细节**：

1. **文件 = 内联等价**：也可不写文件、直接对 supervisor 说这三段；文件只是可复用/可版本化形式。
2. **守 verifier 脊柱（诚实兜底）**：若完成条件**无任何可机械验证项**，supervisor 必须**主动提议补一个硬闸门**
   （「我加个 smoke test 当 verify gate？」）或**明确告警**「只靠 judge 主观验收、有 slop 风险」——
   绝不默默跑一个没有硬闸门的循环。

## 4. supervisor 编排 playbook + 可复用角色定义

### 4.1 住哪（context 极简 + 工具无关）

- 全文住独立 doc `docs/SUPERVISOR-LOOP-PLAYBOOK.md`，**按需加载**，不塞进每个会话系统提示。
- 注入块（现有 AGENTS.md/CLAUDE.md 注入机制）只放**一行触发指针**：
  > 「当用户给你一份 mission、或要你把一个目标『跑成 loop』时，先读 `docs/SUPERVISOR-LOOP-PLAYBOOK.md` 并严格按它执行。」
- **纯 markdown，不做成 Claude-only skill**——supervisor 可能是 Claude 也可能是 Codex，doc 两边都能读，守工具无关。

### 4.2 怎么跑（相位状态机，每相位点名隐身的 peer 命令）

playbook 写成**确定性 checklist**（非泛泛 prose），每步点名要敲的 peer 命令：

```
0. PARSE      读 mission → goal / done-criteria / 红线
1. PROPOSE    实例化角色定义 → 回显 编队+verify+judge+预算+红线gate → 等人确认(§3)
2. PROVISION  peer agent add ×N  →  peer approval check ×N
3. PLAN       peer task/loop init planner → peer ask planner(出 brief+acceptance 契约)
              → peer verify show planner(契约文件存在才算过)
4. BUILD      peer task/loop init builder(--verify <硬闸门> --judge <角色:veto>)
              → peer ask builder(实现，done 必带 evidence)
5. JUDGE      builder done → peer ask reviewer + evaluator(独立 judge builder@N)
              → 各自 peer judge builder@N --verdict ...
6. LOOP       每轮检查【合门集】：verify 全 pass ∧ 无 judge veto ∧ done 带 evidence ∧ 轮次未超预算
              未达 → peer reframe builder(只修具体阻塞项) [+ peer loop reset 给小预算] → 回 4
              detail-trap/stuck 信号 → reframe 收敛，不扩范围
7. GATE       命中红线 或 需人类判断 → peer gate open → 找人
8. DONE       仅当【合门集】全真 → 带证据向人汇报；否则绝不宣布完成
```

### 4.3 三条写进 playbook 的纪律（loop 脊柱）

1. **合门集 = 唯一停止条件**（第 6 步）——对标 `/goal` 完成判定；builder 不能自评 done 就停，supervisor
   每轮按合门集拦截（§5 把这层升级成 stop-hook 机械硬门）。
2. **制造者 ≠ 检查者**：reviewer/evaluator 独立 judge，veto 命中保持 builder active、发 review_required。
3. **红线升级人类**：明确「这些情况只开 gate、不自作主张」。

### 4.4 可复用角色定义（#6）

planner/builder/reviewer/evaluator 各做成**可复用角色定义文件** `docs/roles/<role>.md`（版本化、可提交；
**不**放 `.agent-duo/`——那是运行时态），含：标准职责、默认 verify/judge 取向、默认派发 prompt 模板。对齐 AT 的
subagent-definitions-as-teammates。supervisor 自动组队时**实例化**这些定义（填入 mission 具体参数），
而不是每次现编 prompt——这是「全自动组队可靠」的关键。

### 4.5 收尾

- **playbook 是 journey 测试的来源**：测试架构 spec 的 `journey-supervisor-loop.test.sh` 照这张相位机断言
  用户可见输出——playbook 变了 journey 跟着红，强制「文档=现实」。
- **可靠性靠确定性**：用「相位 + 精确 peer 命令 + 合门集」写死，把 supervisor 自由度收窄到「填参数、读结果、
  做 reframe 判断」。

## 5. 机械完成门（Ralph 硬拦截，Phase 2 加固）

Section 4 的合门集是契约但靠 supervisor 自觉。本段升级成 **stop-hook 机械硬门**，对标 `/goal` 的 Stop 拦截、
AT 的 `TeammateIdle`/`TaskCompleted` exit 2。

### 5.1 机制

```
worker/supervisor 想停（report done / 交还控制）
  → Stop/idle hook 触发 → 读磁盘 loop runtime 状态算【合门集】
     verify 全 pass ∧ 无未决 judge veto ∧ done 带 evidence ∧ 轮次未超预算
  ├─ 全真          → 放行，真停（带证据汇报）
  ├─ 未达 且 预算未尽 → 拦截：不准停 + 注入定向指令（"verify smoke fail / reviewer veto 未决，继续修"）
  └─ 预算已尽 且 未达 → 停下来，开人类 gate（"预算耗尽、未合门，请人类决策"）
```

- **独立检查器 = 磁盘上的 verify + judge 状态**：不另起 Haiku 裁判——「独立于制造者」已由 verify gate +
  reviewer/evaluator verdict 落盘实现，hook 机械读取强制执行。loopd 已算这些 event，hook 复用其结论。
- **复用现有 hook 投递**：supervisor 是 Claude（原生 Stop hook）或 Codex（agent-duo 已有 `-c` 注入 +
  self-check 门控，见 `2026-06-18-codex-hook-delivery-decision.md`）——两 provider 都能用，不另造轮子。
- 落点是现有 `scripts/supervisor-stop-drain-hook`：加「读合门集 → 放行/拦截/升级」三分支。

### 5.2 防跑飞（两条出口纪律）

1. **成功**：合门集全真 → 放行。
2. **硬上限**：预算耗尽仍未达 → **停下来开人类 gate**，绝不无限拦截空转烧 token。
   （没有这条，机械硬门会退化成能烧一整夜的烧钱机器。）

### 5.3 与 prose 层优雅降级

- §4 prose 合门集是**契约与回退**：hook 没装/被绕过时 supervisor 仍按 prose 自觉执行。
- §5 hook 是**硬保证**：装上后「不达合门不准停」从自觉变结构。
- 对应提炼文档：偏好类→prose/memory，硬保证→hook。两层不互斥。

## 6. 「全自动」下的人类掌控与可见性

「全自动」= **机械编排自动化**（人不再手敲 peer），**不是**无人值守/无 gate。人类掌控**上移一层**：
从「敲每条命令」变成「批准 mission + 物化闸门，只在关键点被拉进来」。

### 6.1 自治阶梯（对齐 roadmap 既有「安全边界」三档）

| 层 | 内容 | 谁拍板 |
|---|---|---|
| 自治（无需人） | 机械编排：provision、派发、judge、命中阻塞 reframe、预算内重试、读 checkpoint | supervisor |
| 拦截找人（gate） | ①初始物化确认（§3 回显）②红线 deploy/购买/碰生产/删数据 ③真业务/设计判断 ④预算耗尽未合门（§5）⑤最终合门→带证据汇报 | 人类 |
| 永远可见 | 每步在可见 tab；loopd 看板实时显 `verify=/judge=`；人可随时围观 | — |

### 6.2 三条不变量

1. **人可随时插话（NL）**：循环跑着时照样能说「停一下」「换方向」「先别碰 X」。全自动 ≠ 锁死。
2. **无监督互聊禁令仍在**：每次 agent↔agent 交换源自 supervisor 编排，而编排源自**你批准过的 mission**。
3. **红线永不自动跨越**：复用 roadmap「安全边界」三档（可自动批准 / 默认需人工 / 永不自动），不另立标准。

### 6.3 完成时带证据汇报，不静默 done

```
Release Desk MVP 已合门。证据：
  verify smoke: pass (.agent-duo/state/builder/validation-r4.json)
  reviewer: approve · evaluator: pass (reviews/*.json)
  final report 带 evidence (state/builder/r4.json)
```

「完成」永远 = 可核验证据，而非「agent 说完成了」。

## 7. 分期落地

- **Phase 1（先做、快、验证体验）**：§2–§4、§6——mission 模板 + 编排 playbook + 角色定义 + 回显确认 +
  注入触发指针。纯 doc/markdown，不动 `bin/peer`/`lib/*` 逻辑（playbook 调用的都是现有命令）。合门靠 prose 自觉。
- **Phase 2（验证后加固）**：§5——给 `scripts/supervisor-stop-drain-hook` 接合门集读取 + 三分支 +
  预算升级，做成机械硬门。

## 8. 明确不在范围（YAGNI / 后续子项目）

- 共享 claimable task list、mailbox 自动投递、plan approval 流程——**底座对齐系列的后续子项目**，各自 spec。
- 不依赖/不集成原生 Agent Teams（见 §0）。
- 不改 loop/verify/judge 的落盘 schema 与 `bin/peer` 命令面（本系列上一 spec 已重构，这里只调用）。
- 不引入新的人类命令——人类接口是 NL + mission 文件。

## 9. 开放问题

无（设计已逐段确认）。实现细节（角色定义文件的确切字段、playbook 相位与现有 peer 命令的逐条绑定、
回显确认的具体渲染）在实现计划阶段细化。
