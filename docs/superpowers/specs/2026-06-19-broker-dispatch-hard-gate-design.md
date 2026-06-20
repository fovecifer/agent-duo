# Broker 派发硬门设计（硬化 backlog ②）

日期：2026-06-19
状态：设计已批准，待实现。
关联：[Codex hook 投递方案决策](./2026-06-18-codex-hook-delivery-decision.md)（backlog ② 来源）、[marker 新鲜度设计](./2026-06-18-broker-marker-freshness-design.md)（① 提供 fresh `ready` 判定）、[Approval Broker 设计](./2026-06-17-approval-broker-design.md)、[worker↔supervisor 契约](./2026-06-17-worker-supervisor-contract.md)

## 要解决的具体问题

**一句话**：Approval Broker 的「派发前确认 broker 就绪」目前只是写在契约里的**软约定**——靠 supervisor（一个 LLM）记得先查 `broker-status`。它忘了，就会把需要 broker 保护的任务直接 `peer tell` 给一个 fail-open / 未验证 / 已过期的 worker，保护静默落空。

**具体场景**：

1. 一个 worker 的 broker 处于 `unverified`（刚建、还没 broker-check）、`fail-open`（自检超时）、或 `stale`（① 引入：session 重启后过期）。
2. supervisor 直接 `peer tell <worker> "<保护性任务>"`，没有先看 `broker-status`。
3. `peer tell` 当前不做任何 broker 校验，消息照常投递 → worker 在无 broker 保护下执行任务。

**本 spec 要达到的结果**：把这道门从「软约定」变成**机械硬门**——`peer tell` 发给 worker 角色时，由投递路径自己校验该 worker 的 broker 是否 fresh `ready`；不是就 fail-closed 拒发（非零退出、不粘贴、不回车），并提示先 `broker-check`。即决策文档 A 硬化 backlog 的 ②（门是契约软门，不是机械硬门）。

## 设计决策（已确认）

- **拦截范围**：只拦 `peer tell`，且当目标**角色为工作型**时门控。工作型 = 除 `supervisor`/`daemon`/`loopd` 外的所有角色，含 `worker`、`reviewer` 及自定义角色（见下「实现说明」——最终实现比初版「只拦 `role==worker`」更宽，按豁免名单取反，对所有可能在 broker 保护下执行工具的角色 fail-closed）。`broker-check` 探针走裸 tmux（不经 `tell`），天然豁免；`gate resolve` / `esc` / `peek` / 发给 supervisor 的消息都不拦。
- **Provider 范围**：所有工作型角色（codex 与 claude 一视同仁，防御纵深 + 逻辑简单）。
- **越过机制**：复用 `--force`（语义：强制发送、跳过安全检查，与它现有「跳过权限弹窗检测」一致）；外加 `AGENT_DUO_NO_BROKER_GATE=1` 全局关闭（供测试 / 不想启用的会话）。
- **严格度**：硬 fail-closed——非 fresh `ready` 直接非零退出、完全不发送。
- **role 读不到时**：`role_for_id` fallback 到 `worker` → 落入工作型门控分支，fail-closed，宁可多拦。

> **实现说明（范围比初版宽）**：初版设计写的是「仅 `role==worker` 被门控」。最终实现改为**豁免名单取反**：`case` 命中 `supervisor|daemon|loopd` 才放行，其余一律门控。理由是 `reviewer`/`evaluator`/自定义工作角色同样在 broker 保护下跑工具，应当受同一道硬门保护；白名单（只拦 worker）会漏掉它们。本文档（含下方 §2 代码块）已同步为实现实际行为。

## 设计

### 1. 两个新 helper（`bin/peer`）

```sh
# role_for_id <id> → 打印该 id 的 @agent_role；读不到时打印 "worker"（fail-closed）。
role_for_id() {
  local want="$1" role
  role="$(list_agents | awk -F'\t' -v w="$want" '$2==w { print $3; found=1 } END{ exit found?0:1 }')" || role=""
  [[ -n "$role" ]] || role="worker"
  printf '%s' "$role"
}

# broker_is_fresh_ready <id> → 该 worker 的 broker 状态为 fresh `ready` 返回 0，否则 1。
broker_is_fresh_ready() {
  local id="$1" out
  out="$(run_approval_broker status --agent-id "$id" --root "$AGENT_DUO_ROOT" 2>/dev/null)"
  case "$out" in
    *'"status":"ready"'*) return 0 ;;
    *) return 1 ;;
  esac
}
```

> 实现说明：最终实现把 `broker_is_fresh_ready` 内联进门控块（单次 `run_approval_broker status` 调用，复用其输出同时做就绪判定与错误诊断），不再保留独立 helper；`role_for_id` 保留。

- `list_agents` 已输出 `pane_id<TAB>agent_id<TAB>role<TAB>provider`，role 取第 3 列（与 `pane_for_id` 同模式）。
- `broker_is_fresh_ready` 直接复用 ① 的 `status` 子命令：它在 `ready` 超 `AGENT_DUO_BROKER_TTL` 时已返回 `stale`，所以这里只需判 `"status":"ready"` 子串。`stale`/`fail-open`/`unverified` 均落入 return 1。匹配用紧凑 JSON 子串（broker 由字符串拼接产出，无空格，稳定）。

### 2. `tell` 里插入门控

在 `tell` 分支中、解析出 `target_id` 之后、`check_safe_to_send_keys`/粘贴之前插入：

```sh
    # Broker 硬门:发给工作型角色(非 supervisor/daemon/loopd)时,broker 必须 fresh ready,否则拒发
    # (fail-closed)。worker/reviewer/自定义工作角色都受保护。
    # 豁免:--force(FORCE_SEND)或 AGENT_DUO_NO_BROKER_GATE=1。broker-check 探针不经 tell,天然豁免。
    gate_role="$(role_for_id "$target_id")"
    case "$gate_role" in
      supervisor|daemon|loopd) ;;  # 非工作型角色:不门控
      *)
        if [[ "${FORCE_SEND:-0}" != "1" && "${AGENT_DUO_NO_BROKER_GATE:-0}" != "1" ]]; then
          bg_out="$(run_approval_broker status --agent-id "$target_id" --root "$AGENT_DUO_ROOT" 2>/dev/null)"
          case "$bg_out" in
            *'"status":"ready"'*) ;;  # fresh ready → 放行
            *)
              bg_status="$(printf '%s' "$bg_out" | grep -o '"status":"[^"]*"' | head -1)"
              echo "错误: '$target_id' 的 Approval Broker 非 fresh ready（${bg_status:-未知}），已拒绝派发。" >&2
              echo "      先运行 'peer broker-check $target_id' 验证 broker 生效，或用 'peer tell --force $target_id ...' 强制发送。" >&2
              exit 1
              ;;
          esac
        fi
        ;;
    esac
```

- 位置在粘贴/回车之前，保证拒发时**完全没有副作用**（buffer 未写、未 send-keys）。
- `--force` 已在 `tell` 开头被解析为 `FORCE_SEND=1`，无需新增解析。

### 3. 不受影响 / 天然豁免

- `peer broker-check`：探针用 `tmux load-buffer`/`paste-buffer`/`send-keys`，不经 `tell` → 不被拦。bootstrap 无死锁：`unverified` → `broker-check`（豁免）→ worker 跑探针 → marker `ready` → 之后 `tell` 放行。
- `gate resolve` / `esc` / `peek` / `report`：不经此门。
- 发给豁免名单角色（`supervisor`/`daemon`/`loopd`）的 `tell`：`case` 命中豁免分支 → 不拦。注意 `reviewer` 及自定义工作角色**不在**豁免名单，仍受门控。

### 4. 契约 / 文档

- worker↔supervisor 契约 §2.6 与 Approval Broker 设计 §7.1：把「supervisor 必须先确认 fresh `ready` 再派发」从软约定升级为「`peer tell` 对 worker 角色机械 fail-closed；可用 `--force` 或 `AGENT_DUO_NO_BROKER_GATE=1` 越过」。
- 决策文档 backlog：② 标记已解决，链接本 spec。

### 5. 暴露边界（已知，不在本 spec 范围）

② 把「读 ready」从人肉变成强制，但不改变 ① 的 TTL 窗口：fresh `ready` 在 TTL（默认 60s）内即放行，无法抓 TTL 窗口内的静默重启。这是 ① 的固有边界，由「外部无法实时读 worker 当前 session」决定（见 marker 新鲜度设计）。

## 测试（`test/peer.test.sh`，复用现有 tmux stub）

构造目标 worker 的 marker 文件控制 broker 状态（与 ① 测试同手法，无 `sleep`）。每条 setup/teardown：

- **worker + unverified（无 marker）→ 拒发**：`peer tell worker "x"` 退出 1；stderr 含「非 fresh ready」与 `broker-check`；**未发生粘贴**（断言 stub buffer 文件未创建）。
- **worker + stale（老 `updated_epoch`）→ 拒发**：退出 1、未粘贴。
- **worker + fresh ready（`updated_epoch=$(date +%s)`）→ 放行**：退出 0；stub buffer 写入；发生 send-keys。
- **worker + unverified + `--force` → 放行**：`peer tell --force worker "x"` 退出 0、已粘贴。
- **worker + unverified + `AGENT_DUO_NO_BROKER_GATE=1` → 放行**：退出 0、已粘贴。
- **豁免名单角色（supervisor / daemon / loopd）+ unverified → 放行**：目标 `@agent_role` 命中豁免分支时不拦，退出 0、已粘贴。
- **工作型非 worker 角色（reviewer）+ unverified → 拒发**：目标 `@agent_role=reviewer` 仍受门控，退出 1、未粘贴（验证范围按豁免名单取反，不是只拦字面 `worker`）。

注：测试需保证目标 pane 带 `@agent_role`（stub 注册时设置），并能区分「已粘贴/未粘贴」（依据现有 `TMUX_STUB_BUFFER_DIR` 里 `peer-<me>2<target>` buffer 文件是否存在）。

## 实现影响面

- `bin/peer`：新增 `role_for_id`、`broker_is_fresh_ready`；在 `tell` 分支插入门控块。
- `test/peer.test.sh`：新增 6 条 tell 门控断言。
- 契约 §2.6、Approval Broker 设计 §7.1、决策文档 backlog ②：文档更新。
- `lib/approval_broker.sh`：无改动（复用 ① 的 `status`）。
