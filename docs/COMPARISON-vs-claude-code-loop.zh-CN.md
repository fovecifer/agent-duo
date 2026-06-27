# 对标体检：agent-duo vs Claude Code 的 loop engineering 演示

> **定位**：agent-duo 的核心是 **loop engineering**（verify-gated 迭代、verifier 是脊柱）。本文不是「以 Claude Code 为模板」，
> 而是拿 Anthropic 公开的 loop 演示做一次**对标体检**——确认我们在核心 loop 纪律上已对齐，并诚实标出几处值得补的缺口。

## 0. 一个前提：他们没公开命令级实现

Anthropic 的演示视频与工作坊讲的是**架构与原则**，**没有**公开可复制的命令/文件名/脚本（工作坊综述自陈是
"architecture paper, not an implementation guide"）。所以对比只能比到**机制层**——而这恰恰说明：**agent-duo 把他们
抽象描述的 loop 原则，落成了具体的 `peer` 命令实现。**

来源（机制层素材）：

| 来源 | 给什么 | 链接 |
|---|---|---|
| 工作坊《Build Agents That Run for Hours》 | generator-evaluator、契约协商、Playwright 真测、rubric、planner、Ralph loop | <https://www.youtube.com/watch?v=mR-WAvEPRwE> · 综述 <https://www.sean-weldon.com/blog/2026-05-23-build-agents-that-run-for-hours-without-losing-the-plot-ash-prabaker-andrew-wilson-anthropic> |
| 主视频《Reflecting on a year of Claude Code》 | loop engineering 理念、`/goal` 机制 | <https://www.youtube.com/watch?v=Hth_tLaC2j8> |
| `/goal`·`/loop` 文档与解读 | 完成条件、独立模型每轮裁判、Stop 拦截 | <https://www.mindstudio.ai/blog/how-to-build-agentic-loop-claude-code> |
| Addy Osmani《Loop Engineering》 | 五构件、成本/slop/采纳率风险 | <https://addyosmani.com/blog/loop-engineering/> |
| 本仓提炼 | 含时间戳中文逐点 | `docs/agent-loop-三agent循环-提炼.md` |

## 1. 机制对比表

| 维度 | 他们（Claude Code 演示/工作坊） | agent-duo |
|---|---|---|
| 角色 | planner → generator → evaluator，单工具 Claude，子 agent 不可见 | supervisor + planner/builder/reviewer/evaluator，**可见 tmux 标签**，Claude **或 Codex** |
| 制造者/检查者分离 | evaluator 独立、harsh prompt，**有权全盘推翻、命令从头重来** | reviewer+evaluator **两个独立 judge**（`peer judge --verdict`），veto 保持 active + **reframe 增量修** |
| 契约 | generator↔evaluator **协商** ~27 条验收准则，file-based | **planner 写** `acceptance.md`（rubric+evaluator script+done def），三方共读 |
| 机械验证 | evaluator 用 **Playwright / Chrome MCP 真打开点按钮** | `--verify <cmd>` 真跑命令当硬闸门；evaluator「像用户试用」靠 **prose 指示**，无内建浏览器测试工具 ⚠️ |
| 主观质量 | **4 维评分 rubric**（设计/原创/工艺/功能，加权）+ few-shot 校准 | acceptance.md 的 **prose rubric**（功能/状态/可维护/UI），未评分未校准 ⚠️ |
| 状态外置 | filesystem，**时间戳 JSON**（JSON 比 markdown 不易被覆盖） | `.agent-duo/state/**.json`（report/validation/reviews/loop/checkpoints），atomic rename |
| 循环 & 停止 | Ralph loop + `/goal` 用**独立更快模型**每轮裁判 + Stop 拦截 | loopd + **合门集**（verify∧无veto∧done带evidence∧未超预算）+ stop-drain-hook（机械硬门见 nl-mission spec Phase 2）；独立裁判=磁盘上 verify+judge |
| 预算护栏 | `/goal` 硬上限；演示 $200/6h | `--max-rounds` 有界；**token 预算 broker 是 roadmap MVP9，未建** ⚠️ |
| 心跳/自动触发 | `/loop`、`/schedule`、Routines/cron | loopd liveness，**无 cron/schedule 自动触发** ⚠️ |
| connectors | 自动开 PR / 关 ticket / 频道 @ | gate/report，**无原生 connectors** ⚠️ |
| 人类角色 | 偏无人值守自治 | **supervisor 中介、全程可见、红线人类 gate、禁私聊** ✅ |
| 工具范围 | Claude-only | **Claude↔Codex 跨工具桥** ✅ |

## 2. 结论

**核心 loop 纪律——完全对齐**：plan-build-judge、制造者≠检查者、verify 机械闸门、状态外置 JSON、有界预算、
Stop 拦截。agent-duo 把他们抽象讲的，落成了真命令。

**agent-duo 独有（差异化）**：✅ 可见标签 + 人类 gate；✅ 跨工具（Claude↔Codex）；✅ 双独立 judge。

**值得补的缺口（→ 见 roadmap backlog）**：

1. **evaluator 真·浏览器测试**——他们用 Playwright/Chrome MCP 真点；agent-duo 只靠 prose。
2. **rubric 评分化 + 校准**——他们 4 维加权 + few-shot；agent-duo 是 prose。
3. **契约准则强度**——他们经验「~27 条才够 actionable，含糊准则被无视」；acceptance.md 可借此上强度。
4. **预算护栏 + 心跳/connectors**——token 预算（MVP9）、cron/schedule 自动触发、原生 connectors 均未建。

> 取舍提醒：补缺口时**不得削弱 agent-duo 的差异化**（可见 + 人类 gate + 跨工具），也不得动 loop/verifier 脊柱。
