# Loop Runtime 硬化（异步 validation + 进程组 kill + loop reset）设计

日期：2026-06-21
状态：设计稿，待实现（交付 Codex 实现，作者 review）
关联：[Supervisor Loop（MVP 5）设计](./2026-06-21-supervisor-loop-mvp5-design.md)、[Loop Validation + Success Signals 设计](./2026-06-21-loop-validation-success-signals-mvp-design.md)、[worker↔supervisor 契约](./2026-06-17-worker-supervisor-contract.md)（§2.5 acceptance / §4 awaiting_acceptance）

## 1. 架构 + 验收状态机

### 1.1 问题与目标

MVP 5 的 validation 当前在 `eval_contracts` 内**同步 `wait`**，最长阻塞 loopd 到 `timeout_seconds`——期间所有 worker 的注入/liveness/看板停摆（**F2**）。本设计把 validation 改成**非阻塞**：tick 只做"启动/查状态"，真正执行落到分离后台进程。顺带修 **F3**（超时杀进程组）和补 **`peer loop reset`**。

三件事都属于"loop runtime 硬化"，一份 spec。

### 1.2 三态验收状态机（per agent+round，全落文件）

每个 `(agent, round)` 的验收在三态间走，**状态全部由文件表示**，loopd 无状态、每 tick 重算：

```
        (无文件)                    validation-rN.running         validation-rN.json
   ┌─────────────┐   tick 启动     ┌──────────────┐   runner 完成   ┌──────────────┐
   │ not-started │ ─────────────► │   running    │ ─────────────► │     done     │
   └─────────────┘  spawn 分离     │ (pidfile)    │  原子写结果+删   │ (pass/fail)  │
                     runner+写marker└──────────────┘   marker        └──────────────┘
                                          │ 进程已死且无结果(崩溃)
                                          └──► 写 fail 结果 + 删 marker ──► done(fail)
```

- **`validation-rN.json`**：最终结果（已有，MVP 5 schema 不变）。存在 = done。
- **`validation-rN.running/`**：新增**目录**——用 `mkdir`（原子，与现有 `ad_loop_with_cursor_lock` 同 idiom）**认领**该轮验收，内含 `pid` 文件（runner pid + 启动 ts）。目录存在且无结果 = running/已被认领。用目录而非裸文件，是为了让"认领"对并发 tick / 第二个 loopd 也原子（F2 修订 §2）。

### 1.3 tick 内的状态判定（取代现在的同步调用）

`eval_contracts` 里把"同步跑 validation"换成**非阻塞**的 `ad_loop_validation_state <agent> <round>`，返回 `pass | fail | running`：

```
ad_loop_validation_state(root, agent, R):     # 非阻塞,返回 pass|fail|running
  若 validation-rR.json 存在:
      emit 事件(幂等) → 返回 status(pass/fail)                       # done
  若 validation-rR.running/ 存在(已认领):
      pid = 读 validation-rR.running/pid
      若 pid 可解析且 kill -0 pid → 返回 "running"                   # 该轮还在跑,tick 不等
      否则(死/损坏、无结果) → 崩溃:写 status=fail 结果(注 "runner crashed")
                              + emit validation_fail + rmdir 目录 → 返回 "fail"
  # R 尚未启动。限并发:本 agent 已有任一轮在跑,就不再起新 runner(F2 修订 §3)
  若 存在任一 validation-r*.running/(本 agent) → 返回 "running"
  # 原子认领 R 再 spawn
  若 mkdir validation-rR.running 成功:
      写 pid 文件 + spawn 分离 runner(§2.2) → 返回 "running"          # 刚启动
  否则(认领竞争失败) → 返回 "running"
```

**关键：tick 全程不 `wait`**——最多读几个文件、`kill -0` 探一下、`mkdir` 认领、`nohup & disown` 启动，瞬时返回。loopd 再也不会被慢测试冻住。**单 agent 至多一个 runner**：限并发，避免 worker 快速连报多轮时堆叠多个长 `go test`。

### 1.4 与现有组件的关系

- **direction 检测**（MVP 8）已在 validation 之前跑，不受影响。
- **done 停止门**改为"等异步结果"（§2.3）：done 但验收 `running` → 不停、loop 留活（worker 按契约 `awaiting_acceptance` 泊住）；`pass` → stop(done)；`fail` → 不停、continue。
- `failed`/`max_rounds` 停止判定不变。

## 2. F2 异步执行（分离 runner + done 等待门）

### 2.1 分离 runner：`loopd --run-validation <agent> <round>`

`scripts/loopd` 加一个子模式：解析 `--run-validation <agent> <round>` 时，**只**调现有 `ad_loop_run_validation_round`（跑该轮所有 validation、原子写 `validation-rN.json`、含 §3 的 watchdog+进程组 kill），完成后**删 running marker**，然后退出。它是独立进程，**内部照常同步阻塞**——但阻塞的是它自己，不是 loopd。

`ad_loop_run_validation_round` 逻辑基本不变（已是幂等：结果文件在就直接 emit+返回）；只在结尾加"删 marker"。

### 2.2 启动 + marker：`ad_loop_spawn_validation <root> <agent> <round>`

tick 在原子 `mkdir validation-rN.running` 认领成功后调它：

```sh
loopd_bin="${AGENT_DUO_LOOPD_BIN}"        # scripts/loopd 启动时导出自身路径;测试可覆盖为 stub
# 已 mkdir validation-rN.running 认领成功 → 先落 pid 文件
nohup env AGENT_DUO_ROOT="$root" AGENT_SESSION="$session" \
     "$loopd_bin" --run-validation "$agent" "$round" >/dev/null 2>&1 &
pid=$!
printf '{"pid":%s,"started_at":"%s"}\n' "$pid" "$(ad_loop_iso_ts)" > validation-rN.running/pid
disown 2>/dev/null || true
```

- **显式传 root（F2 修订 §1）**：spawn 必须 `env AGENT_DUO_ROOT="$root" AGENT_SESSION="$session" …`——`scripts/loopd` 用 `${AGENT_DUO_ROOT:-$PWD}` 推导，shell 变量默认不 export，手动 `peer loopd`（未 export）时分离 runner 会在错 root 下写结果，父 loopd 看不到 → 误判 crash。显式传环境保证 runner 与父 loopd 同 root。（等价方案：给 `--run-validation` 加 `--root`。）
- **认领即原子，不靠"单 loopd"假设（F2 修订 §2）**：`mkdir validation-rN.running` 是原子的——并发 tick / 第二个 `peer loopd` / "spawn 后写 marker 前崩溃"窗口都被它收口。抢到目录的才 spawn；抢不到 → 视为 running。pid 文件用 `> …/pid`（目录已被自己独占，无并发写）。
- **marker 清理时序**：runner 先原子写结果（tmp+mv）再 `rmdir` 目录。tick 的状态判定**先看结果文件**（§1.3 顺序），所以"结果已写、目录未删"的瞬间也判 done，目录删除是 best-effort。
- **spawn 兜底**：`AGENT_DUO_LOOPD_BIN` 缺失/不可执行 → 回退**同步内联**跑 `ad_loop_run_validation_round`（即现状行为）+ stderr 告警（见 §5.1）。兜底前同样先 `mkdir` 认领，跑完 `rmdir`。

### 2.3 done 等待门（`eval_contracts` 改动）

把现在的"同步 `validation_status=run_validation_round(...)`"换成**非阻塞状态查询**。**对当前（最新）轮查/启动，单 agent 至多一个 runner**（F2 修订 §3）：worker 快速连报多轮时，旧轮验收在跑就不再起新的，中间轮可能被跳过——只有 latest 轮的验收对 done 门要紧，验收串行化，并发上限 1/agent：

```
vstate=""
若 validation_count>0 且 current_round>0:
    vstate = ad_loop_validation_state(agent, current_round)   # 非阻塞:pass|fail|running

reason=""
if on_terminal 且 report_status==done:
    if validation_count==0          → reason=done
    elif vstate==pass               → reason=done
    else                            → (不停) running:等异步结果;fail:loop 留活,worker 继续
elif on_terminal 且 report_status==failed → reason=failed
elif rounds_used>=max_rounds             → reason=max_rounds
```

- **done + running → 不停**：worker 已按契约 `awaiting_acceptance` 泊住不烧 token，loopd 非阻塞地等异步验收；后续某 tick 验收 `pass` 才 stop(done)，`fail` 则发 `validation_fail`、loop 留活等 supervisor 处理。
- **done 优先于 max_rounds**：done+running 时不会被 max_rounds 抢停（worker 泊住未烧轮次，等验收即可；验收有 `timeout_seconds` 上界，不会无限等）。
- `failed`/`max_rounds` 仍是廉价、即时的硬停（不依赖验收）。一个 worker 在验收 running 时撞 `max_rounds`（因为它没报 done、还在 in_progress 推进轮次）→ max_rounds 照常停，后台 runner 跑完写个没人看的结果文件（无害）。

## 3. F3 进程组 kill（超时杀整棵树）

### 3.1 问题

现在 `ad_loop_run_validation_command` 的 watchdog 只 `kill "$pid"`（那个 `( cd; bash -lc )` 子 shell）。`go test` 派生的编译器/测试二进制是子 shell 的**子进程**，超时时只杀子 shell，子进程**成孤儿**继续跑。要杀就得杀**整个进程组**。这段逻辑现在跑在分离 runner 里（§2.1），所以 kill 也发生在 runner 上下文，与 loopd 无关。

### 3.2 机制：bash 作业控制 `set -m` 建独立进程组（macOS 无 setsid）

macOS 不带 `setsid`，用 **bash 作业控制 `set -m`**：开启后，每个 `&` 后台作业被放进**自己的进程组**（组长 PID == 作业 PID）。于是可用 `kill -- -<pid>`（负号 = 进程组）杀整组。

```sh
set -m
( cd "$root"; exec bash -lc "$cmd" ) > "$log" 2>&1 &
pid=$!                       # set -m 下:该作业是进程组组长,PGID == pid
set +m

# …watchdog 超时时(原 flag 机制不变):
kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true   # 先杀组,失败回退杀单 pid
sleep 1
kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
```

- `exec bash -lc` 让 `bash -lc` **就是**组长（exec 不改 pid），`go test` 及其子进程继承该 PGID → `kill -- -$pid` 一锅端。
- **优雅降级**：`kill -- -$pid` 失败（万一某环境 `set -m` 没建独立组）→ 回退 `kill $pid`（即现有行为），不崩。
- **作业控制噪音**：`set -m` 会把 `[1] 12345` 之类通知打到 runner 的 stderr——但 runner 是 `nohup … >/dev/null 2>&1` 分离的，通知被丢弃，无污染。

### 3.3 实现须验证（交付 Codex 时点明）

`set -m` 在 **macOS bash 3.2 非交互脚本**里是否真给 `&` 作业建独立进程组，需在目标机用一条会 fork 子进程的命令实测（如超时 `bash -lc 'sleep 100 & wait'` 后确认子进程也被杀）。**若实测不建独立组**，回退路径（`kill $pid`）保证不回归现状；但要在实现 PR 里记录实测结论。

其余不变：超时仍记 `exit 124`、`VALIDATION_TIMED_OUT=true`；`wait "$pid"`（在 runner 内）照旧——runner 是分离进程，内部阻塞不碍 loopd。

## 4. `peer loop reset`

### 4.1 命令面

```
peer loop reset [<worker>] [--max-rounds N]
```

`<worker>` 解析同 `peer loop init`（省略默认 ME；supervisor 实际传 worker id）。把一个**已停止或快到界**的 loop 在当前轮重新冻结、给全新预算。

### 4.2 行为

```
1. 读 loop.json(loop_file_for_id);不存在 → 报错退出("没有 loop.json,先 peer loop init")
2. new_frozen = 当前最新 report 轮次(report_round_for_id);若为 0(无 report)→ 保留原 frozen_at_round
3. new_max = --max-rounds N(正整数,校验;非正整数 fail-closed) 否则沿用原 max_rounds
4. jq 原子重写(tmp+mv):
     .status = "active"
     .frozen_at_round = new_frozen
     .max_rounds = new_max
     .stop = {on_terminal: 原值, reason: null, stopped_at_round: null, stopped_at: null}
     .updated_at = now
5. echo "已重置 loop: <worker>(frozen_at_round=new_frozen, max_rounds=new_max, active)。"
6. 【终态 report 提醒，F2 修订 §4】若最新 report 的 status ∈ {done, failed}（或 done 且该轮 validation 已 pass）→ 额外 stderr 警告:
     "提醒: '<worker>' 最新 report 是 <status>,下一 tick 会按同一 report 再次停止。
      先 'peer reframe --force <worker> \"...\"' 让它写出新的非终态 report,再续跑。"
```

- **reset 主要用于 `max_rounds`/near-budget**：那时最新 report 通常是 `in_progress`（worker 还在推进、未报终态），reset 后 worker 直接续跑、下轮是新 round，干净。
- **终态 report 的陷阱（F2 修订 §4）**：reset 只重写 loop.json、不改 report。若最新 report 是 `failed`、或 `done` 且该轮验收已 `pass`，下一 tick 会按**同一条** report 立刻再次 stop，与"全新预算"冲突。故 reset 在这种情况**照常重写但发上面的警告**，指引先 `reframe --force` 把 worker 推过终态报告。reset 不阻塞（你可能就是想先 reset 再 reframe）。
- 重置后 `rounds_used = current - new_frozen + 1 = 1` → worker 拿到从现在起的**全新 `max_rounds` 预算**；detail_trap 窗口（`rounds_used>=N`）也随之重新起算。
- **active 或 stopped 都能 reset**（不要求已停）；幂等地把 loop 拉回 active。
- mission/non_goals/success_signals/validation/detail_trap_rounds **不变**——只动预算与停止状态。

### 4.3 不需要清理的陈旧物（说明）

- 历史 `validation-rN.json` / `validation-rN.running`（旧轮）、queue 里的旧 `loop_stop`/`detail_trap` 事件：都是历史，**无害**——停止门只看 `current_round` 的验收，direction 窗口按新 `frozen` 重算。reset **只重写 loop.json**，不碰别的文件。
- 正常情况下重置后 worker 续跑，停止轮号会前移（如 frozen=8,max=8 → 下次停在 round 15），与旧 `loop_stop` 的确定性 id 不撞，不影响再次通知。

### 4.4 顺带：更新守卫提示文案

`loop_guard_command` 里两处 `'…或后续用 peer loop reset(待实现)。'` 去掉"(待实现)"——reset 已落地，直接指引。

## 5. 错误处理 + 测试矩阵 + 影响面

### 5.1 错误处理（新增/跨切面）

- **spawn 退化兜底**：`AGENT_DUO_LOOPD_BIN` 缺失/不可执行 → 无法分离 → **回退到同步内联**跑 `ad_loop_run_validation_round`（即现状行为）+ stderr 告警。保证验收始终能跑（代价是退回阻塞），不因未接好异步入口而让 done 永不通过。
- **marker pid 不可解析/损坏** → 当崩溃处理（写 fail 结果、`rmdir`）。
- **pid 复用（已知边界，接受）**：runner 结束后 `rmdir` 目录；只有"崩溃无结果且 pid 恰被 OS 复用为另一活进程"才会让 `kill -0` 误判 running——窗口极小且需精确 pid 复用，接受不处理（`started_at` 留作日后加超时兜底的钩子）。
- **runner 被 kill 在写结果中途**：结果走 tmp+mv，中途死 → 无结果文件、tmp 孤儿 → 下 tick 判崩溃 → fail。tmp 由下次同名写覆盖或忽略。
- **`peer loop reset`**：无 loop.json → 报错；`--max-rounds` 非正整数 → fail-closed。
- runner 内单条 validation 配置非法（id/cmd 空、timeout 非正）仍按 MVP 5：记 `error`/`exit 127`，该轮 `fail`。

### 5.2 测试矩阵（无 sleep 为主；F3 例外用小真超时）

**异步 validation（loop.test.sh，`AGENT_DUO_LOOPD_BIN` 覆盖为 stub）**

- not-started → tick `mkdir` 认领 + 调 stub spawn + 写 `running/pid`；返回 running；**done report 不停**（等异步）。
- running（`validation-rN.running/` 目录 + 活 pid，如测试自身 `$$`）→ 返回 running、**不重启 stub**、done 不停、**tick 不阻塞**。
- done（预置 `validation-rN.json` status=pass）→ done report → stop(done) + `validation_pass`。
- done + 预置 fail → done **不停**、`validation_fail`、loop active。
- 崩溃（目录 + 死 pid + 无结果）→ 写 fail 结果 + `validation_fail` + `rmdir`；done 不停。
- spawn 兜底：`AGENT_DUO_LOOPD_BIN` 未设 → 同步内联跑、当 tick 出结果 + 告警。
- 幂等：done 再 tick → 不重复 validation 事件。
- **显式 root（F2 修订 §1）**：`cwd != AGENT_DUO_ROOT` 启动 loopd → 断言 spawn 命令含 `AGENT_DUO_ROOT=<root>`（stub 记录其收到的环境），结果写到正确 root。
- **原子认领（F2 修订 §2）**：预置 `validation-rN.running/` 目录 → tick **不**再 spawn（stub 未被调用）、返回 running。
- **单 agent 一 runner（F2 修订 §3）**：预置 `validation-r1.running/`（活 pid）+ 最新 report 为 r2 → tick **不**为 r2 起第二个 runner（stub 未被调用）、返回 running。

**F3 进程组 kill（loop.test.sh，小真超时，可标为集成）**

- cmd 派生一个"延迟后写文件"的子进程，`timeout` < 延迟 → 跑完断言 `exit 124` 且子进程的文件**始终未出现**（整组被杀）。注：依赖 §3.3 的 `set -m` 行为，目标机须实测；回退路径不回归。

**`peer loop reset`（peer.test.sh）**

- stopped loop（max_rounds）+ in_progress r8 → reset → loop.json `active`、`frozen_at_round=8`、`stop.*` 清空、**无终态警告**。
- `--max-rounds 5` → `max_rounds=5`；非正整数 → fail-closed。
- 无 loop.json → 报错；无 report（round 0）→ `frozen_at_round` 不变。
- **终态警告（F2 修订 §4）**：最新 report 为 `failed`（或 `done`）→ reset 仍成功，但 stderr 含"下一 tick 会再次停止…先 reframe --force"提醒。

### 5.3 实现影响面

- `scripts/loopd`：加 `--run-validation <agent> <round>` 子模式；启动时导出 `AGENT_DUO_LOOPD_BIN=自身路径`。
- `lib/loop.sh`：新增 `ad_loop_validation_state`（非阻塞三态 + 原子 `mkdir` 认领 + 单 agent 一 runner）、`ad_loop_spawn_validation`（`env AGENT_DUO_ROOT/AGENT_SESSION` 显式 + nohup+disown + `running/pid`，带同步兜底）；`ad_loop_run_validation_round` 结尾 `rmdir running 目录`；`ad_loop_run_validation_command` 改进程组 kill（`set -m` + `kill -- -$pid` + 回退）；`eval_contracts` 改 done 等待门。
- `bin/peer`：新增 `peer loop reset`；`loop_guard_command` 两处文案去掉"(待实现)"。
- 文档：README（en/zh）、AGENT-INSTRUCTIONS/AGENTS、worker-supervisor 契约（§2.5 验收 / §4 awaiting_acceptance 注明异步）同步。
- 不动：direction 检测、loop_stop、broker 门、reframe/checkpoint。

## 6. 非目标（YAGNI）

- 不做 validation 结果缓存复用跨 round（每 round 独立验收，幂等只在同 round 内）。
- 不做并行多 runner 编排（每 (agent,round) 一个分离 runner；不同 worker 天然各自分离）。
- 不做 validation 优先级/资源配额（留给 quota broker，MVP 9）。
- 不做 reset 的历史事件清理（陈旧事件无害，见 §4.3）。

## 7. 评审修订（2026-06-21，交付前收紧）

1. **spawn 显式传 `AGENT_DUO_ROOT`/`AGENT_SESSION`（§2.2/§5.2）**：`scripts/loopd` 用 `${AGENT_DUO_ROOT:-$PWD}` 且 shell 变量默认不 export，手动 `peer loopd` 时分离 runner 会在错 root 下写结果 → 父 loopd 误判 crash。spawn 必须 `env AGENT_DUO_ROOT="$root" AGENT_SESSION="$session" …`；测试覆盖 `cwd != root`。
2. **原子 `mkdir` 认领，不靠"单 loopd"假设（§1.2/§1.3/§2.2）**：running marker 改为 `mkdir` 认领的**目录**（与现有 cursor lock 同 idiom），收口并发 tick / 第二个 loopd / "spawn 后写 marker 前崩溃"窗口；抢不到目录即视为 running。
3. **单 agent 至多一个 runner（§1.3/§2.3）**：只对当前轮查/启动；本 agent 已有任一 `validation-r*.running/` 在跑就不再起新 runner，避免快速连报多轮时堆叠多个长 `go test`。中间轮可跳过（只 latest 对 done 门要紧）。
4. **reset 终态 report 提醒（§4.2/§5.2）**：reset 只重写 loop.json；最新 report 为 `failed`/`done(pass)` 时下一 tick 会按同一 report 再次停止。reset 照常执行但发警告，指引先 `reframe --force` 推过终态报告。reset 主用于 `max_rounds`/near-budget（那时最新 report 通常 `in_progress`，无此问题）。
