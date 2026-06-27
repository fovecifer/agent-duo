# Supervisor Loop Playbook

当用户给你一份 mission(见 `docs/mission-template.md`),或要你把一个目标「跑成 loop」时,严格按下列相位执行。
全程 `peer` 命令对用户隐身;只在【人类 gate】与【最终合门】回来找人。

## 合门集(唯一停止条件)

verify 全 pass ∧ 无未决 judge veto ∧ builder done report 带 evidence ∧ 轮次未超 max-rounds

任一不满足 -> 不算完成。builder 说 done 只是一条输入,不是停止条件。

## 相位

0. PARSE
   - 读 mission 或用户自然语言,提取 goal / done-criteria / non-goals / 红线。
   - 若完成条件没有任何可机械验证项,先提议补 smoke test,或明确告警只靠 judge 有 slop 风险。

1. PROPOSE
   - 按 `docs/roles/*.md` 实例化 planner / builder / reviewer / evaluator。
   - 把 done-criteria 物化为 verify gate、judge 契约、max-rounds/detail-trap、红线 gate。
   - 向用户回显一屏 proposal 并等确认;确认前不执行 `peer agent add`。

2. PROVISION
   - `peer agent add --provider codex --role planner --id planner`
   - `peer agent add --provider codex --role builder --id builder --worktree`
   - `peer agent add --provider claude --role reviewer --id reviewer`
   - `peer agent add --provider codex --role evaluator --id evaluator --worktree`
   - 对每个工作型 agent 执行 `peer approval check <id>`;未 ready 不派发工作。

3. PLAN
   - `peer task init planner --task "<plan task>" --step brief:"write brief" --step acceptance:"write acceptance"`
   - `peer loop init planner --mission "<planning mission>" --max-rounds 3 --verify contract:"test -s docs/product/brief.md && test -s docs/product/acceptance.md"`
   - `peer ask planner "<planner prompt from docs/roles/planner.md>"`
   - `peer verify show planner`
   - planner 未产出契约或 verify 未 pass,先 `peer reframe planner "<具体缺口>"`,不要进入 BUILD。

4. BUILD
   - `peer task init builder --task "<build task>" --step implement:"build" --step test:"smoke test" --step report:"final evidence"`
   - `peer loop init builder --mission "<build mission>" --max-rounds 6 --detail-trap-rounds 3 --verify smoke:"<mechanical command>" --judge reviewer:request_changes,reject --judge evaluator:fail,request_changes`
   - `peer ask builder "<builder prompt from docs/roles/builder.md>"`
   - builder 的 done 必须是 `peer report --type result --status done ... --evidence-cmd ... --evidence-result ...`。

5. JUDGE
   - builder done 后,分别 `peer ask reviewer "<review builder@N>"` 与 `peer ask evaluator "<evaluate builder@N>"`。
   - reviewer/evaluator 必须独立写 `peer judge builder@N --verdict <...> [--finding ...] [--evidence-result ...]`。
   - veto 命中时不得宣布完成。

6. LOOP
   - 每轮检查【合门集】: `peer verify show builder`, `peer judge ls builder`, `peer checkpoint builder`。
   - 未达合门 -> `peer reframe builder "<只修阻塞项>"`;需要小预算时 `peer loop reset builder --max-rounds N`;然后回到 BUILD/JUDGE。
   - detail-trap/stuck 时只收敛问题,不扩范围,不换目标。

7. GATE
   - 命中红线(部署、花钱、碰生产、删数据)或需要人类业务判断时,执行 `peer gate open builder --title "<决策>" --detail "<上下文>" --option "<选项>"`。
   - 找人处理,等待 `peer gate resolve --choice <choice>` 后再继续。
   - 不自作主张跨越红线。

8. DONE
   - 仅当【合门集】全真,才带证据汇报:verify 路径、judge verdict、final report ref、关键 evidence。
   - 可用 `peer checkpoint builder` 作为最终摘要输入。
   - 任一条件不满足,绝不宣布完成。

## 纪律

- 合门集是唯一停止条件;builder 不能自评 done 就停。
- 制造者 != 检查者:reviewer/evaluator 独立 judge。
- 红线只开 gate,不自作主张。
- 用户可随时用自然语言插话改向。
- 不许 teammate 私下互聊;每轮 agent 交互都由 supervisor 编排,且源自用户确认过的 mission。
- `peer` 命令是 supervisor 内部实现细节,不要把命令清单甩给用户执行。
