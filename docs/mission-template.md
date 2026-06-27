# Mission: <一句话目标>

## 要做什么 (Goal)
<2-4 句自然语言:是什么、给谁、核心场景>

## 完成条件 (Done means)
- <可机械验证>:如「smoke 测试通过」「npm run build 无错」
- <主观质量>:如「首屏即可用工具、不是 landing page」「移动端可用」
- <独立验收>:如「reviewer、evaluator 都不 veto」

## 不做 / 红线 (Non-goals & guardrails)
- 不做:<范围外>
- 红线(必须升级人类 gate):部署、花钱、碰生产、删数据

也可不写文件,直接对 supervisor 说这三段。若完成条件无任何可机械验证项,supervisor 会主动提议补一个 smoke test,
或明确告警 slop 风险;绝不默默跑没有硬闸门的循环。
