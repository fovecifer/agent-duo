# Loop Validation + Success Signals（MVP 5 验收补丁）设计

日期：2026-06-21
状态：已实现
关联：[Supervisor Loop（MVP 5）设计](./2026-06-21-supervisor-loop-mvp5-design.md)、[worker↔supervisor 契约](./2026-06-17-worker-supervisor-contract.md)

## 1. 目标

补齐 MVP 5 的验收侧：worker 写出 report 后，runtime 自动执行 loop contract 里的 validation 命令，把结果作为 evidence 落盘并追加 runtime event；当 worker 声明 `done` 时，只有 validation 全通过且 `success_signals` 被机械满足，loop 才能真正停为 `done`。

这把完成判定从“信任 worker 自述”推进到“worker 自述 + runtime 客观验收”。

## 2. loop.json 扩展

`peer loop init` 写入：

```json
{
  "success_signals": ["tests pass"],
  "validation": [
    {
      "id": "go-test",
      "cmd": "go test ./...",
      "timeout_seconds": 120,
      "satisfies": ["tests pass"]
    }
  ]
}
```

字段规则：

- `validation[].id`：`[A-Za-z0-9._-]+`，用于日志文件名与结果定位。
- `validation[].cmd`：在 project root 下用 `bash -lc` 执行。
- `validation[].timeout_seconds`：正整数，默认 120；超时按 exit code 124 记 fail。
- `validation[].satisfies`：该 validation 通过时满足的 success signal。未显式配置时默认 `[id]`。
- `success_signals`：有 validation 时变为机械匹配目标；没有 validation 时保持 MVP 5 的软护栏语义。

## 3. CLI

```bash
peer loop init worker --mission "..." --max-rounds 4 \
  --success "tests pass" \
  --validation go-test:"go test ./..." \
  --validation-satisfies go-test:"tests pass" \
  --validation-timeout go-test:120
```

行为：

- `--validation id:cmd` 可重复。
- `--validation-satisfies id:signal` 可重复；引用未知 id 时 fail-closed。
- `--validation-timeout id:N` 可重复；引用未知 id 或非正整数时 fail-closed。
- 旧用法保持兼容，写入 `"validation":[]`。

## 4. Runtime 执行

`loopd` 在 `ad_loop_eval_contracts` 中处理 active contract：

1. 读取最新 `report.json` 的 `round` 与 `status`。
2. 若 contract 配了 validation，且当前 report round 在冻结轮次之后，则按 `(agent, round)` 幂等执行 validation。
3. 结果写入 `.agent-duo/state/<agent>/validation-r<round>.json`。
4. stdout/stderr 写入 `.agent-duo/logs/<agent>/validation-r<round>-<id>.log`。
5. 追加确定性事件 `validation-<agent>-<round>`：
   - `validation_pass`：所有 validation exit 0 且 success signals 全满足。
   - `validation_fail`：任一 validation 失败、超时、配置错误，或存在 missing signal。

validation 结果 schema：

```json
{
  "protocol": "1",
  "agent_id": "worker",
  "round": 3,
  "status": "pass",
  "satisfied_signals": ["tests pass"],
  "missing_signals": [],
  "failed_validations": [],
  "results": [
    {
      "id": "go-test",
      "cmd": "go test ./...",
      "status": "pass",
      "exit_code": 0,
      "timed_out": false,
      "duration_seconds": 2,
      "log_ref": ".agent-duo/logs/worker/validation-r3-go-test.log",
      "satisfies": ["tests pass"]
    }
  ],
  "created_at": "2026-06-21T...Z"
}
```

## 5. done 判定

停止优先级保持 MVP 5 的形状，但 `done` 多一道验收门：

```text
if report_status == done and no validation configured:
  stop(done)
if report_status == done and validation_status == pass:
  stop(done)
elif report_status == failed:
  stop(failed)
elif rounds_used >= max_rounds:
  stop(max_rounds)
```

因此 validation fail 不会把 contract 翻成 `done`；worker 下次仍可继续报告，supervisor 会先收到 `validation_fail` evidence。

## 6. MVP 限制：同步执行

当前实现把 validation 放在 `loopd` tick 内同步执行：`loopd` 会等待当前 round 的 validation 命令退出或超时后，才继续后续 worker 评估、事件注入和看板刷新。单 worker MVP 场景可接受，但多 worker 场景里一个慢 validation 最长会阻塞整个 runtime 到 `timeout_seconds`。

因此 MVP 使用建议：

- validation 命令应保持短小、确定，并设置合理 `--validation-timeout`。
- 需要长时间验收时，先把 timeout 配低，让 `validation_fail` 触发 supervisor 介入。
- 后续迭代应把 validation 改成异步执行：tick 启动 job、后续 tick 收割结果并写 `validation-rN.json`。

## 7. 非目标

- 不做 reviewer/evaluator acceptance veto 组合规则。
- 不做 shell 命令 sandbox；contract 被视为 supervisor 写入的可信项目状态。
- 不解析 worker 文本报告里的自然语言 evidence，只机械使用 validation exit code 和 `satisfies` 映射。
