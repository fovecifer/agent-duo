# Broker Dispatch Hard Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `peer tell` to a worker-role target refuse to send (fail-closed) unless that worker's Approval Broker is fresh `ready`, turning the "confirm broker before dispatch" contract into a mechanical gate (backlog ②).

**Architecture:** Add two helpers to `bin/peer` — `role_for_id` (reads the target's `@agent_role`, defaults to `worker` when unreadable) and `broker_is_fresh_ready` (runs the ① `status` subcommand and checks for `"status":"ready"`). Insert a gate in the `tell` arm, after the target is resolved and before any tmux side effect, that refuses when the target is a worker and not fresh-ready. `--force` and `AGENT_DUO_NO_BROKER_GATE=1` bypass; the `broker-check` probe is unaffected because it never goes through `tell`.

**Tech Stack:** Bash (3.2-compatible), `jq` (already a hard dependency, used by the broker `status` subcommand), the `tmux`-stub test harness in `test/peer.test.sh`.

## Global Constraints

- Only `peer tell` is gated, and only when the target's role is `worker`. `broker-check`/`gate resolve`/`esc`/`peek` and sends to non-worker roles are never gated.
- Applies to all workers regardless of provider (`role==worker` is the only check).
- Bypass: `--force` (sets `FORCE_SEND=1`) OR env `AGENT_DUO_NO_BROKER_GATE=1`.
- Hard fail-closed: a non-fresh-`ready` worker target → nonzero exit, no buffer write, no paste, no Enter.
- Target role unreadable → treat as `worker` (fail-closed).
- Reuses ①'s freshness: fresh `ready` is `status` output containing `"status":"ready"`; `stale`/`fail-open`/`unverified` are all not-ready. No change to `lib/approval_broker.sh`.
- Error/notice text is Chinese, matching existing `bin/peer` style.

---

### Task 1: Implement the dispatch gate + tests

**Files:**
- Modify: `bin/peer` — add `role_for_id` and `broker_is_fresh_ready` helpers (after `run_approval_broker`, ~line 156); insert the gate block in the `tell` arm (after `target_id` is set, ~line 607, before `check_safe_to_send_keys`).
- Modify: `test/peer.test.sh` — forward `AGENT_DUO_NO_BROKER_GATE` in `run_peer` (~line 176); add 6 new gate tests; prefix 5 existing worker-targeted `tell` mechanics tests with `AGENT_DUO_NO_BROKER_GATE=1`.

**Interfaces:**
- Consumes (existing): `list_agents` (emits `pane_id<TAB>agent_id<TAB>role<TAB>provider`), `run_approval_broker` (`bash "$APPROVAL_BROKER" "$@"`), `$AGENT_DUO_ROOT`, `FORCE_SEND` (set to `1` by `--force` in the `tell` arm).
- Produces: `role_for_id <id>` → prints role string (or `worker` if unreadable); `broker_is_fresh_ready <id>` → exit 0 if fresh ready, else 1.

- [ ] **Step 1: Forward the bypass env through `run_peer`**

In `test/peer.test.sh`, in the `run_peer` env list (after the `PEER_FORCE="${TEST_PEER_FORCE:-0}" \` line, ~line 176), add:

```bash
    AGENT_DUO_NO_BROKER_GATE="${AGENT_DUO_NO_BROKER_GATE:-0}" \
```

This lets a test prefix `AGENT_DUO_NO_BROKER_GATE=1` reach `bin/peer` (same pattern as `TMUX_STUB_CAPTURE_MODE`).

- [ ] **Step 2: Write the failing gate tests**

In `test/peer.test.sh`, immediately before the final `exit "$ADK_FAIL"` line, add:

```bash
# ② Broker dispatch hard gate: tell to a worker refuses unless broker is fresh ready.

# worker + no marker (unverified) → refuse, nonzero, no buffer written.
setup
assert_exit_code "gate: unverified worker refused" 1 run_peer tell worker "do work"
assert_contains "gate: unverified error mentions fresh ready" "$(cat "$ERR")" 'fresh ready'
assert_contains "gate: unverified error suggests broker-check" "$(cat "$ERR")" 'broker-check'
assert_ok "gate: unverified no buffer written" test ! -e "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker"
teardown

# worker + stale marker (old epoch) → refuse.
setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
printf '{"agent":"worker","status":"ready","updated_epoch":1000000000,"nonce":"old"}\n' > "$PROJECT/.agent-duo/state/worker/broker.json"
assert_exit_code "gate: stale worker refused" 1 run_peer tell worker "do work"
assert_ok "gate: stale no buffer written" test ! -e "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker"
teardown

# worker + fresh ready marker → allowed (sends).
setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
printf '{"agent":"worker","status":"ready","updated_epoch":%s,"nonce":"n1"}\n' "$(date +%s)" > "$PROJECT/.agent-duo/state/worker/broker.json"
assert_ok "gate: fresh ready worker allowed" run_peer tell worker "do work"
assert_eq "gate: fresh ready buffer written" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker")" "do work"
teardown

# worker + unverified + --force → allowed (bypass).
setup
assert_ok "gate: --force bypasses gate" run_peer tell --force worker "do work"
assert_eq "gate: --force buffer written" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker")" "do work"
teardown

# worker + unverified + AGENT_DUO_NO_BROKER_GATE=1 → allowed (bypass).
setup
AGENT_DUO_NO_BROKER_GATE=1 assert_ok "gate: env disable bypasses gate" run_peer tell worker "do work"
assert_eq "gate: env disable buffer written" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker")" "do work"
teardown

# non-worker target (reviewer) + no marker → not gated, sends.
setup
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%2\tworker\tworker\tcodex\n%%3\treviewer\treviewer\tclaude\n' > "$TMUX_STUB_REGISTRY"
assert_ok "gate: non-worker target not gated" run_peer tell reviewer "please review"
assert_eq "gate: non-worker buffer written" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-supervisor2reviewer")" "please review"
teardown
```

- [ ] **Step 3: Run the new tests to verify the refusal tests fail**

Run: `bash test/peer.test.sh 2>&1 | grep -E "gate: (unverified worker refused|stale worker refused)"`
Expected: both `FAIL` (today `tell` to the worker sends regardless, so exit is 0 not 1). The allow/bypass tests (fresh ready, --force, env, non-worker) already pass since nothing blocks them yet.

- [ ] **Step 4: Add the two helpers to `bin/peer`**

In `bin/peer`, directly after the `run_approval_broker` function (ends ~line 156), add:

```bash
# role_for_id <id> → 打印该 id 的 @agent_role;读不到时打印 "worker"(fail-closed)。
role_for_id() {
  local want="$1" role
  role="$(list_agents | awk -F'\t' -v w="$want" '$2==w { print $3; found=1 } END{ exit found?0:1 }')" || role=""
  [[ -n "$role" ]] || role="worker"
  printf '%s' "$role"
}

# broker_is_fresh_ready <id> → 该 worker 的 broker 状态为 fresh `ready` 返回 0,否则 1。
# 复用 approval_broker 的 status 子命令(ready 超 TTL 已自动判 stale)。
broker_is_fresh_ready() {
  local id="$1" out
  out="$(run_approval_broker status --agent-id "$id" --root "$AGENT_DUO_ROOT" 2>/dev/null)"
  case "$out" in
    *'"status":"ready"'*) return 0 ;;
    *) return 1 ;;
  esac
}
```

- [ ] **Step 5: Insert the gate in the `tell` arm**

In `bin/peer`, in the `tell` arm, find this block:

```bash
    if [[ -n "$maybe_id" ]]; then
      target_id="$maybe_id"
    else
      target_id="$(reg_pick_other "$ME" "$(agent_ids)")"
    fi
    check_safe_to_send_keys "$target"
```

and insert the gate between the `fi` and `check_safe_to_send_keys`, so it reads:

```bash
    if [[ -n "$maybe_id" ]]; then
      target_id="$maybe_id"
    else
      target_id="$(reg_pick_other "$ME" "$(agent_ids)")"
    fi
    # Broker 硬门:发给 worker 角色时,broker 必须 fresh ready,否则拒发(fail-closed)。
    # 豁免:--force(FORCE_SEND)或 AGENT_DUO_NO_BROKER_GATE=1。broker-check 探针不经 tell,天然豁免。
    if [[ "${FORCE_SEND:-0}" != "1" && "${AGENT_DUO_NO_BROKER_GATE:-0}" != "1" ]]; then
      if [[ "$(role_for_id "$target_id")" == "worker" ]] && ! broker_is_fresh_ready "$target_id"; then
        bg_status="$(run_approval_broker status --agent-id "$target_id" --root "$AGENT_DUO_ROOT" 2>/dev/null | grep -o '"status":"[^"]*"' | head -1)"
        echo "错误: '$target_id' 的 Approval Broker 非 fresh ready（${bg_status:-未知}），已拒绝派发。" >&2
        echo "      先运行 'peer broker-check $target_id' 验证 broker 生效，或用 'peer tell --force $target_id ...' 强制发送。" >&2
        exit 1
      fi
    fi
    check_safe_to_send_keys "$target"
```

- [ ] **Step 6: Run the new gate tests to verify they pass**

Run: `bash test/peer.test.sh 2>&1 | grep -E "gate:"`
Expected: all 10 `gate:` assertions `ok` (refusals now refuse; allow/bypass paths still send).

- [ ] **Step 7: Fix the 5 existing worker-targeted mechanics tests**

The gate now also fires for the existing `tell` tests that default to / target the worker with no marker. They test `tell` mechanics, not gating, so disable the gate for them. Make these exact edits in `test/peer.test.sh` (prepend `AGENT_DUO_NO_BROKER_GATE=1 `):

1. `assert_ok "tell: arg succeeds" run_peer tell "hello codex"`
   → `AGENT_DUO_NO_BROKER_GATE=1 assert_ok "tell: arg succeeds" run_peer tell "hello codex"`

2. `assert_ok "tell: plain message default other" run_peer tell "hello there"`
   → `AGENT_DUO_NO_BROKER_GATE=1 assert_ok "tell: plain message default other" run_peer tell "hello there"`

3. `TMUX_STUB_CAPTURE_MODE=normal_prompt assert_ok "tell: normal prompt screen succeeds" run_peer tell "ordinary"`
   → `AGENT_DUO_NO_BROKER_GATE=1 TMUX_STUB_CAPTURE_MODE=normal_prompt assert_ok "tell: normal prompt screen succeeds" run_peer tell "ordinary"`

4. `TMUX_STUB_CAPTURE_MODE=prompt assert_exit_code "tell: prompt screen exits 3" 3 run_peer tell "danger"`
   → `AGENT_DUO_NO_BROKER_GATE=1 TMUX_STUB_CAPTURE_MODE=prompt assert_exit_code "tell: prompt screen exits 3" 3 run_peer tell "danger"`

5. `assert_ok "tell: stdin succeeds" run_peer tell <<< $'line 1\n`quoted`'`
   → `AGENT_DUO_NO_BROKER_GATE=1 assert_ok "tell: stdin succeeds" run_peer tell <<< $'line 1\n`quoted`'`

Leave the `reviewer`-targeted tests ("tell: explicit id routes", "tell: stdin with id buffer") and the `--force` test ("tell: force sends despite prompt") unchanged — reviewer is a non-worker role (not gated) and `--force` already bypasses.

- [ ] **Step 8: Run the full peer suite, then the whole suite**

Run: `bash test/peer.test.sh >/dev/null 2>&1 && echo PEER_PASS || echo PEER_FAIL`
Expected: `PEER_PASS`

Run: `bash test/run.sh 2>&1 | tail -1`
Expected: `ALL TESTS PASSED`

- [ ] **Step 9: Commit**

```bash
git add bin/peer test/peer.test.sh
git commit -m "feat(peer): hard-gate tell to workers on fresh broker ready (backlog ②)"
```

---

### Task 2: Update contract / design / decision docs

**Files:**
- Modify: `docs/superpowers/specs/2026-06-17-worker-supervisor-contract.md` — §2.6.
- Modify: `docs/superpowers/specs/2026-06-17-approval-broker-design.md` — §7.1.
- Modify: `docs/superpowers/specs/2026-06-18-codex-hook-delivery-decision.md` — backlog item ②.

**Interfaces:** Documentation only — no code, no tests. One reviewable unit describing the mechanical gate delivered by Task 1.

- [ ] **Step 1: Locate the gating language**

Run: `grep -n "broker-check\|broker-status\|fresh\|ready\|派发\|§2.6\|7.1\|peer tell" docs/superpowers/specs/2026-06-17-worker-supervisor-contract.md docs/superpowers/specs/2026-06-17-approval-broker-design.md`
Read the surrounding paragraphs so edits match wording and section numbering.

- [ ] **Step 2: Upgrade the gate from soft convention to mechanical in both docs**

In the contract (§2.6) and broker design (§7.1), change the gating description so it states: `peer tell` to a **worker-role** target is **mechanically fail-closed** — it refuses to send unless the target's broker is fresh `ready` (per `broker-status`); the supervisor no longer has to remember to check. The probe path (`peer broker-check`) and sends to non-worker roles are exempt. Operators can override with `peer tell --force` or `AGENT_DUO_NO_BROKER_GATE=1`. Keep the existing remediation guidance (run `broker-check` on `stale`/`fail-open`/`unverified`).

- [ ] **Step 3: Mark backlog ② resolved in the decision doc**

In `docs/superpowers/specs/2026-06-18-codex-hook-delivery-decision.md`, in the "A 自身仍存的漏洞与硬化 backlog" list, annotate item ② as resolved:

```markdown
4. ~~**② 门是契约软门，不是机械硬门（安全）**~~ ✅ 已解决：`peer tell` 对 worker 角色机械 fail-closed——目标 broker 非 fresh `ready` 直接拒发（`--force` / `AGENT_DUO_NO_BROKER_GATE=1` 可越过；`broker-check` 探针豁免）。见 [派发硬门设计](./2026-06-19-broker-dispatch-hard-gate-design.md)。
```

(Match the exact list numbering/wording in the file — the item text may be numbered differently; preserve surrounding items ⑦/⑧/③.)

- [ ] **Step 4: Sanity-check the docs**

Run: `grep -n "fail-closed\|机械\|--force\|AGENT_DUO_NO_BROKER_GATE\|fresh" docs/superpowers/specs/2026-06-17-worker-supervisor-contract.md docs/superpowers/specs/2026-06-17-approval-broker-design.md docs/superpowers/specs/2026-06-18-codex-hook-delivery-decision.md`
Expected: each file shows the new mechanical-gate language.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-06-17-worker-supervisor-contract.md docs/superpowers/specs/2026-06-17-approval-broker-design.md docs/superpowers/specs/2026-06-18-codex-hook-delivery-decision.md
git commit -m "docs: peer tell mechanically gates worker dispatch; mark backlog ② resolved"
```

---

## Final verification

- [ ] Run the full suite:

Run: `bash test/run.sh 2>&1 | tail -3`
Expected: `ALL TESTS PASSED`

- [ ] Confirm the e2e tests still skip by default:

Run: `bash test/run.sh 2>&1 | grep -E "skip codex"`
Expected: both `codex-hook-e2e` and `codex-permreq-e2e` show `skip`.
