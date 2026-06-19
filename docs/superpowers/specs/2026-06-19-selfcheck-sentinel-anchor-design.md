# 自检 sentinel 锚定设计（硬化 backlog ⑧）

日期：2026-06-19
状态：设计已批准，待实现。
关联：[Codex hook 投递方案决策](./2026-06-18-codex-hook-delivery-decision.md)（backlog ⑧ 来源）、[marker 新鲜度设计](./2026-06-18-broker-marker-freshness-design.md)、[Approval Broker 设计](./2026-06-17-approval-broker-design.md)、[Codex hook 交互验证](./2026-06-18-codex-hook-interaction-validation.md)

## 要解决的具体问题

**一句话**：Approval Broker 的自检探针靠**子串命中**识别——只要工具命令或路径里出现 `AGENT_DUO_BROKER_SELFCHECK_<字母数字>`，就被当成探针、设计性 deny 并改写就绪 marker。但这个串本身就存在于本仓库的测试/文档/spec 里，worker 在正常任务中碰到它就会被误判。

**具体场景**：worker 执行一条真实命令，命令字符串里恰好含该 sentinel，例如：

```sh
grep AGENT_DUO_BROKER_SELFCHECK_ test/peer.test.sh
echo "see AGENT_DUO_BROKER_SELFCHECK_probe42 in the spec"
```

当前 `ab_selfcheck_nonce` 在 `command + " " + raw_path` 里做子串匹配 → 命中 → 该真实命令被 deny（worker 收到「探针被设计性拒绝」），且 broker marker 被写成 `ready` + 一个从该串里截出的伪 nonce。这是一个仓库**自指**的误判地雷：概率低，但一旦命中既阻断真实工作、又污染就绪状态。

**本 spec 要达到的结果**：把识别从「子串命中」收紧为「**锚定到完整规范探针命令**」——只有整条命令精确等于探针形态时才识别为自检，使真实命令里偶然出现的 sentinel 不再触发。即决策文档 A 硬化 backlog 的 ⑧（sentinel 自指风险）。

## 背景：探针的规范形态

`peer broker-check` 通过 `approval_broker.sh selfcheck-cmd --nonce <nonce>` 生成探针命令，格式固定（`ab_cmd_selfcheck_cmd`）：

```sh
printf agent-duo-broker-check > AGENT_DUO_BROKER_SELFCHECK_<nonce>.tmp
```

worker 被要求**原样执行**这条命令。因此实际探针命令就是这个精确形态，可以据此锚定识别。

## 设计

### 锚定匹配（approach A）

把 `ab_selfcheck_nonce` 从「子串命中 + 截取后续字母数字」改为「锚定到完整规范探针命令并提取 nonce」：

- 只检查 `command`（探针是 Bash 命令；`raw_path` 不再参与——探针不写 `raw_path`，且让带 sentinel 的路径不再误判）。
- 对 trim 后的 `command` 做**整体锚定**匹配：

  ```
  ^printf agent-duo-broker-check[空白]+>[空白]*AGENT_DUO_BROKER_SELFCHECK_(<nonce>)\.tmp$
  ```

  其中 `<nonce>` = `[A-Za-z0-9]+`。`>` 两侧容忍任意空白（含零个或多个空格，防 provider 轻微重排版）；其余 token 严格匹配。
- 命中 → 返回捕获的 `<nonce>`；不命中 → 返回空（非自检，走正常 policy）。

锚定后：
- `grep AGENT_DUO_BROKER_SELFCHECK_x …`、`echo "...SELFCHECK..."`、`cat ..._x.tmp`(非 printf)、Edit/Write 到含 sentinel 的路径 —— 都**不再**匹配（命令整体不是探针形态）。
- 真实探针 `printf agent-duo-broker-check > AGENT_DUO_BROKER_SELFCHECK_<nonce>.tmp` 仍匹配。

### 实现要点（Bash 3.2）

- 用 `[[ "$cmd" =~ $re ]]` + `BASH_REMATCH[1]` 提取 nonce（Bash 3.2 支持 `=~` 与 `BASH_REMATCH`）。**Bash 3.2 关键点**：正则必须放进变量并在 `=~` 右侧**不加引号**（`re='...'; [[ "$cmd" =~ $re ]]`）——给正则加引号会被当字面量匹配。正则里对 `.` 转义为 `\.`，`>` 直接量。空白用 `[[:space:]]`。
- 先 trim `command` 两端空白再匹配（复用现有 `ab_trim` 若存在；否则在函数内 trim）。
- `selfcheck-cmd` 的生成格式与该锚定正则是同一形态的两端，必须保持同步——两者都在 `lib/approval_broker.sh`，在锚定正则旁加一行注释指明它对应 `ab_cmd_selfcheck_cmd` 的输出。
- 不改 `selfcheck-cmd` 的输出、不改 `peer broker-check` 的投递、不改 marker/审计写法。`ab_run_hook` 调用点不变（仍 `nonce="$(ab_selfcheck_nonce …)"`，非空即自检）。

### 不在范围

- 不改探针命令本身的形态（保持 `printf … > …_<nonce>.tmp`）。
- 不动 ① 的新鲜度、② 的派发硬门。

## 测试（`test/approval.test.sh`，无 sleep）

复用现有 `run_hook` + `broker_status` 手法：

- **真探针仍识别**：`run_hook` 命令为 `printf agent-duo-broker-check > AGENT_DUO_BROKER_SELFCHECK_probe99.tmp` → 输出含 `BROKER-SELFCHECK`（设计性 deny）、不入队 approval/blocked、marker `status:ready` 且 `nonce:probe99`。（等价于现有自检测试，确保不回归。）
- **`>` 周围多空白仍识别**：命令为 `printf agent-duo-broker-check  >   AGENT_DUO_BROKER_SELFCHECK_sp1.tmp` → 仍判自检，marker `nonce:sp1`。
- **子串误判已消除（grep 形）**：`run_hook` 命令为 `grep AGENT_DUO_BROKER_SELFCHECK_zzz test/peer.test.sh` → **不**判自检：输出不含 `BROKER-SELFCHECK`；按正常 policy 处理（`grep` 在白名单 → auto-allow，输出含 `permissionDecision":"allow"`）；marker 不被写成 `nonce:zzz`（断言 `broker_status` 不含 `"nonce":"zzz"`）。
- **子串误判已消除（echo 形）**：命令为 `echo AGENT_DUO_BROKER_SELFCHECK_yyy` → 不判自检（`echo` 白名单 → allow），不含 `BROKER-SELFCHECK`。
- **非 printf 的 .tmp 不误判**：命令为 `cat AGENT_DUO_BROKER_SELFCHECK_www.tmp` → 不判自检（`cat` 白名单 → allow），不含 `BROKER-SELFCHECK`。

## 实现影响面

- `lib/approval_broker.sh`：仅重写 `ab_selfcheck_nonce`（子串匹配 → 锚定正则 + `BASH_REMATCH` 提取）；在其旁注明与 `ab_cmd_selfcheck_cmd` 同步。其余不变。
- `test/approval.test.sh`：新增 5 条上述断言（真探针、多空白、grep/echo/cat 三种子串误判消除）。
- `bin/peer`：无改动。
- 文档：决策文档 backlog ⑧ 标记已解决，链接本 spec。
