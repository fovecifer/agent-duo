# Broker Marker Freshness + Session Binding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Approval Broker readiness marker expire, so a worker whose Codex session silently restarts untrusted (fail-open) is reported `stale` instead of a permanent green `ready`, closing the stale-ready mis-dispatch hole (backlog ①/④).

**Architecture:** The broker hook writes a per-agent marker (`.agent-duo/state/<agent>/broker.json`) on every real invocation. We add an `updated_epoch` timestamp and the `session_id` (forensic) to that marker. The `status` subcommand becomes freshness-aware: a `ready` marker older than a TTL is reported as `stale`. External gating can't read a worker's live session_id, so freshness (TTL) is the load-bearing signal; session_id is recorded for forensics only.

**Tech Stack:** Bash (3.2-compatible), `jq` (already a hard dependency), the existing custom JSON helpers in `lib/approval_broker.sh`, and the shell test harness in `test/` (`assert.sh`).

## Global Constraints

- Bash 3.2 compatible (`lib/approval_broker.sh` header).
- The hook hot path uses the custom JSON helpers (`ab_json_get_string`/`ab_json_get_int`), not raw `jq` parsing of untrusted input.
- TTL comes from env `AGENT_DUO_BROKER_TTL`, default `60` (seconds).
- Marker status value set: `unverified` | `ready` | `stale` | `fail-open`. Only fresh `ready` means "safe to dispatch protected tasks".
- Fail-closed on ambiguity: a `ready` marker missing/with-unparseable `updated_epoch` is treated as `stale`.
- Only `ready` is subject to freshness downgrade; `fail-open` and `unverified` pass through unchanged.
- All tests must be deterministic without `sleep` (control age via constructed `updated_epoch`, not wall-clock waits).

---

### Task 1: Record `session_id` and `updated_epoch` in the marker

**Files:**
- Modify: `lib/approval_broker.sh` — add `ab_payload_session_id` (near `ab_payload_command`, ~line 226), extend `ab_write_broker_marker` (~line 737), thread `session` through `ab_run_hook` (~line 765-787).
- Test: `test/approval.test.sh` (append after the existing broker-marker block, ~line 292).

**Interfaces:**
- Produces:
  - `ab_payload_session_id <payload>` → echoes the payload's `session_id` string (empty if absent).
  - `ab_write_broker_marker <root> <agent> <status> [nonce] [decision] [session_id]` — now also always writes `"updated_epoch":<int>` and, when `session_id` non-empty, `"session_id":"<id>"`.
- Consumes (existing): `ab_json_escape`, `ab_iso_ts`, `ab_write_file_atomic`, `ab_broker_marker_path`, `ab_json_get_string`.

- [ ] **Step 1: Write the failing test**

Append to `test/approval.test.sh` after the line `assert_contains "broker: selfcheck marker is ready" "$(broker_status)" '"status":"ready"'` block (the marker tests around line 292):

```bash
# ① Marker carries session_id (forensic) and updated_epoch (for freshness).
MARKER_FILE="$PROJECT/.agent-duo/state/worker/broker.json"
run_hook '{"tool_name":"Bash","tool_input":{"command":"ls -la"},"round":30,"session_id":"sess-abc123"}'
assert_contains "broker: marker records session_id" "$(cat "$MARKER_FILE")" '"session_id":"sess-abc123"'
assert_contains "broker: marker records updated_epoch" "$(cat "$MARKER_FILE")" '"updated_epoch":'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/approval.test.sh 2>&1 | grep -E "marker records (session_id|updated_epoch)"`
Expected: both `FAIL` (current marker has neither field).

- [ ] **Step 3: Add the `ab_payload_session_id` accessor**

In `lib/approval_broker.sh`, immediately after the `ab_payload_command` function (ends ~line 228), add:

```bash
ab_payload_session_id() {
  ab_json_get_string "$1" session_id
}
```

- [ ] **Step 4: Extend `ab_write_broker_marker`**

Replace the body of `ab_write_broker_marker` (current lines ~736-747) with:

```bash
ab_write_broker_marker() { # <root> <agent> <status> [nonce] [decision] [session_id]
  local root="$1" agent="$2" status="$3" nonce="${4:-}" decision="${5:-}" session_id="${6:-}" path data
  [[ -n "$agent" ]] || agent="unknown"
  path="$(ab_broker_marker_path "$root" "$agent")"
  data="{\"agent\":\"$(ab_json_escape "$agent")\",\"status\":\"$(ab_json_escape "$status")\""
  data="${data},\"updated_at\":\"$(ab_iso_ts)\",\"updated_epoch\":$(date +%s)"
  if [[ -n "$nonce" ]]; then data="${data},\"nonce\":\"$(ab_json_escape "$nonce")\""; fi
  if [[ -n "$decision" ]]; then data="${data},\"last_decision\":\"$(ab_json_escape "$decision")\""; fi
  if [[ -n "$session_id" ]]; then data="${data},\"session_id\":\"$(ab_json_escape "$session_id")\""; fi
  data="${data}}"
  ab_write_file_atomic "$path" "$data"
}
```

- [ ] **Step 5: Thread `session` through `ab_run_hook`**

In `lib/approval_broker.sh`, in `ab_run_hook`:

1. Add `session` to the `local` declaration line (currently ends `... summary nonce`):

```bash
  local payload root agent tool command raw_path cwd wt_root round fingerprint existing_status summary nonce session
```

2. After the line `cwd="$(ab_payload_cwd "$payload")"`, add:

```bash
  session="$(ab_payload_session_id "$payload")"
```

3. Change the self-check marker write from:

```bash
    ab_write_broker_marker "$root" "$agent" "ready" "$nonce" "selfcheck"
```

to:

```bash
    ab_write_broker_marker "$root" "$agent" "ready" "$nonce" "selfcheck" "$session"
```

4. Change the heartbeat marker write from:

```bash
  ab_write_broker_marker "$root" "$agent" "ready" "" ""
```

to:

```bash
  ab_write_broker_marker "$root" "$agent" "ready" "" "" "$session"
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bash test/approval.test.sh 2>&1 | grep -E "marker records (session_id|updated_epoch)"`
Expected: both `ok`.

Then run the full file to confirm no regressions:
Run: `bash test/approval.test.sh >/dev/null 2>&1 && echo PASS || echo FAIL`
Expected: `PASS`

- [ ] **Step 7: Commit**

```bash
git add lib/approval_broker.sh test/approval.test.sh
git commit -m "feat(broker): record session_id + updated_epoch in readiness marker (backlog ①)"
```

---

### Task 2: Freshness-aware `status` (ready → stale past TTL)

**Files:**
- Modify: `lib/approval_broker.sh` — rewrite `ab_cmd_status` (current lines ~932-940).
- Test: `test/approval.test.sh` (append after Task 1's block).

**Interfaces:**
- Consumes: `ab_read_file`, `ab_broker_marker_path`, `ab_json_get_string`, `ab_json_get_int`, `ab_json_escape`, and the `updated_epoch` field produced by Task 1.
- Produces: `status` subcommand output JSON whose `status` is one of `unverified|ready|stale|fail-open`; `ready`/`stale` outputs include `"age_seconds":<int>`. Honors `AGENT_DUO_BROKER_TTL` (default 60).

- [ ] **Step 1: Write the failing tests**

Append to `test/approval.test.sh` after Task 1's block:

```bash
# ① Freshness: fresh ready stays ready and reports age.
run_hook '{"tool_name":"Bash","tool_input":{"command":"ls -la"},"round":31,"session_id":"sess-abc123"}'
FRESH="$(broker_status)"
assert_contains "broker: fresh ready stays ready" "$FRESH" '"status":"ready"'
assert_contains "broker: fresh ready reports age_seconds" "$FRESH" '"age_seconds":'

# ① Freshness: a ready marker older than TTL is reported stale (constructed old epoch).
mkdir -p "$PROJECT/.agent-duo/state/worker"
printf '{"agent":"worker","status":"ready","updated_at":"2001-09-09T01:46:40Z","updated_epoch":1000000000,"nonce":"old"}' \
  > "$PROJECT/.agent-duo/state/worker/broker.json"
OLD="$(broker_status)"
assert_contains "broker: ready past TTL becomes stale" "$OLD" '"status":"stale"'
assert_not_contains "broker: stale no longer reports ready" "$OLD" '"status":"ready"'

# ① Freshness: TTL is configurable — a huge TTL makes the same old marker fresh again.
WIDE="$(AGENT_DUO_BROKER_TTL=99999999999 bash "$ROOT/lib/approval_broker.sh" status --root "$PROJECT" --agent-id worker)"
assert_contains "broker: TTL env override keeps old marker ready" "$WIDE" '"status":"ready"'

# ① Freshness: legacy marker without updated_epoch → stale (fail-closed).
printf '{"agent":"worker","status":"ready","nonce":"legacy"}' \
  > "$PROJECT/.agent-duo/state/worker/broker.json"
LEGACY="$(broker_status)"
assert_contains "broker: legacy marker (no epoch) is stale" "$LEGACY" '"status":"stale"'

# ① Freshness: fail-open is never rewritten by freshness, even with an old epoch.
printf '{"agent":"worker","status":"fail-open","updated_epoch":1000000000}' \
  > "$PROJECT/.agent-duo/state/worker/broker.json"
FO="$(broker_status)"
assert_contains "broker: fail-open survives freshness" "$FO" '"status":"fail-open"'
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash test/approval.test.sh 2>&1 | grep -E "broker: (fresh ready|ready past TTL|TTL env|legacy marker|fail-open survives)"`
Expected: the `age_seconds`, `stale`, and legacy assertions `FAIL` (current `ab_cmd_status` dumps the marker verbatim). The "fail-open survives" line happens to pass already, but keep it as a guard.

- [ ] **Step 3: Rewrite `ab_cmd_status`**

In `lib/approval_broker.sh`, replace the whole `ab_cmd_status` function (lines ~932-940) with:

```bash
ab_cmd_status() { # <root> <agent>
  local root="$1" agent="$2" data status epoch now ttl age out
  data="$(ab_read_file "$(ab_broker_marker_path "$root" "$agent")")"
  if [[ -z "$data" ]]; then
    printf '{"agent":"%s","status":"unverified"}\n' "$(ab_json_escape "$agent")"
    return 0
  fi
  status="$(ab_json_get_string "$data" status)"
  # Freshness only ever downgrades a "ready" marker; fail-open/unverified pass through.
  if [[ "$status" != "ready" ]]; then
    printf '%s\n' "$data"
    return 0
  fi
  ttl="${AGENT_DUO_BROKER_TTL:-60}"
  [[ "$ttl" =~ ^-?[0-9]+$ ]] || ttl=60
  now="$(date +%s)"
  epoch="$(ab_json_get_int "$data" updated_epoch)"   # missing/invalid → "0" → stale
  age=$(( now - epoch ))
  if (( age > ttl )); then
    out="$(printf '%s' "$data" | sed 's/"status":"ready"/"status":"stale"/')"
  else
    out="$data"
  fi
  printf '%s\n' "${out%\}},\"age_seconds\":${age}}"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash test/approval.test.sh 2>&1 | grep -E "broker: (fresh ready|ready past TTL|stale no longer|TTL env|legacy marker|fail-open survives)"`
Expected: all `ok`.

Confirm the whole file still passes:
Run: `bash test/approval.test.sh >/dev/null 2>&1 && echo PASS || echo FAIL`
Expected: `PASS`

- [ ] **Step 5: Commit**

```bash
git add lib/approval_broker.sh test/approval.test.sh
git commit -m "feat(broker): expire stale ready markers past TTL in status (backlog ①/④)"
```

---

### Task 3: `peer broker-status` surfaces stale + fix existing fixture

**Files:**
- Modify: `bin/peer` — `broker-status` branch (lines ~511-520).
- Modify: `test/peer.test.sh` — update the existing "ready reported" fixture (line ~568) to include a fresh `updated_epoch`; add a new stale-surfacing test after it (~line 570).

**Interfaces:**
- Consumes: `run_approval_broker status ...` (Task 2 output, may now be `stale`).
- Produces: `peer broker-status <id>` prints the broker JSON to stdout unchanged; when status is not `ready`, prints a one-line hint to stderr telling the operator to `broker-check` first.

- [ ] **Step 1: Update the existing fixture and write the new failing test**

In `test/peer.test.sh`, the existing block (around line 565-569) writes a marker with no `updated_epoch`, which Task 2 now treats as stale. Change the fixture line from:

```bash
printf '{"agent":"worker","status":"ready","nonce":"n1"}\n' > "$PROJECT/.agent-duo/state/worker/broker.json"
```

to (fresh epoch so it stays `ready`):

```bash
printf '{"agent":"worker","status":"ready","updated_epoch":%s,"nonce":"n1"}\n' "$(date +%s)" > "$PROJECT/.agent-duo/state/worker/broker.json"
```

Then, immediately after that block's `teardown`, add a new test:

```bash
# broker-status:ready 但过期(老 epoch)→ 报 stale,并给出 broker-check 提示。
setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
printf '{"agent":"worker","status":"ready","updated_epoch":1000000000,"nonce":"n1"}\n' > "$PROJECT/.agent-duo/state/worker/broker.json"
assert_ok "broker-status: stale surfaced" run_peer broker-status worker
assert_contains "broker-status: stale status" "$(cat "$OUT")" '"status":"stale"'
assert_contains "broker-status: stale hint to broker-check" "$(cat "$ERR")" 'broker-check'
teardown
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash test/peer.test.sh 2>&1 | grep -E "broker-status: (stale|ready reported)"`
Expected: `broker-status: stale status` PASS (Task 2 already makes it stale), but `broker-status: stale hint to broker-check` FAILs (peer prints no hint yet). The "ready reported" test passes with the new fresh fixture.

- [ ] **Step 3: Add the stderr hint to `peer broker-status`**

In `bin/peer`, replace the `broker-status)` branch body line:

```bash
    run_approval_broker status --agent-id "$maybe_id" --root "$AGENT_DUO_ROOT"
```

with:

```bash
    bs_json="$(run_approval_broker status --agent-id "$maybe_id" --root "$AGENT_DUO_ROOT")"
    printf '%s\n' "$bs_json"
    case "$bs_json" in
      *'"status":"ready"'*) ;;
      *) echo "提示: '$maybe_id' broker 非 fresh ready,派发需 broker 保护的任务前请先 'peer broker-check $maybe_id'。" >&2 ;;
    esac
```

(Add `bs_json` to the local/var usage — `peer` uses bare assignments in its `case` arms, so no `local` declaration is needed here; follow the surrounding style.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash test/peer.test.sh 2>&1 | grep -E "broker-status:"`
Expected: all `ok` (unverified default, reads marker, ready reported, stale surfaced, stale status, stale hint).

Confirm the whole file still passes:
Run: `bash test/peer.test.sh >/dev/null 2>&1 && echo PASS || echo FAIL`
Expected: `PASS`

- [ ] **Step 5: Commit**

```bash
git add bin/peer test/peer.test.sh
git commit -m "feat(peer): broker-status reports stale + hints broker-check (backlog ①)"
```

---

### Task 4: Update contract / design docs and mark backlog ①④ resolved

**Files:**
- Modify: `docs/superpowers/specs/2026-06-17-worker-supervisor-contract.md` — §2.6 (broker gating).
- Modify: `docs/superpowers/specs/2026-06-17-approval-broker-design.md` — §7.1 (readiness gating).
- Modify: `docs/superpowers/specs/2026-06-18-codex-hook-delivery-decision.md` — backlog list, mark ① and ④ resolved.

**Interfaces:** Documentation only — no code, no test cycle. Reviewable as one unit because all three edits describe the same new `stale` semantics delivered by Tasks 1-3.

- [ ] **Step 1: Locate the gating language**

Run: `grep -n "ready\|broker-check\|broker-status\|fail-open\|§2.6\|7.1" docs/superpowers/specs/2026-06-17-worker-supervisor-contract.md docs/superpowers/specs/2026-06-17-approval-broker-design.md`
Read the surrounding paragraphs in each file so the edit matches the existing wording and section numbering.

- [ ] **Step 2: Tighten the gate from `ready` to fresh `ready`**

In both the contract (§2.6) and the broker design (§7.1), update the gating rule to state: the dispatch gate requires **fresh `ready`**; a `stale` marker (a `ready` whose age exceeds `AGENT_DUO_BROKER_TTL`, default 60s — e.g. after a worker's Codex session restarts untrusted) counts as **not ready**, exactly like `fail-open`/`unverified`. On `stale`/`fail-open`/`unverified`, the supervisor must run `peer broker-check <id>` and only dispatch protected tasks if it returns ready. Add one sentence noting the marker now carries `updated_epoch` (freshness) and `session_id` (forensic).

- [ ] **Step 3: Mark backlog ①④ resolved in the decision doc**

In `docs/superpowers/specs/2026-06-18-codex-hook-delivery-decision.md`, in the "A 自身仍存的漏洞与硬化 backlog" list, strike through / annotate items ① and ④ as resolved, linking the spec and plan:

```markdown
1. ~~**① 验证是时间点的，marker 不绑 session、不过期（安全）**~~ ✅ 已解决：marker 增加 `updated_epoch`，`status` 在 `ready` 超过 `AGENT_DUO_BROKER_TTL`（默认 60s）时报 `stale`；marker 记录 `session_id` 作佐证。见 [marker 新鲜度设计](./2026-06-18-broker-marker-freshness-design.md)。
2. ~~**④ marker 只升不降、无 TTL（①的根）**~~ ✅ 已解决（与 ① 同一改动）。
```

(Keep items ②/⑦/⑧/③ unchanged.)

- [ ] **Step 4: Sanity-check the docs render**

Run: `grep -n "fresh \`ready\`\|stale\|updated_epoch\|AGENT_DUO_BROKER_TTL" docs/superpowers/specs/2026-06-17-worker-supervisor-contract.md docs/superpowers/specs/2026-06-17-approval-broker-design.md docs/superpowers/specs/2026-06-18-codex-hook-delivery-decision.md`
Expected: each file shows the new freshness/stale language.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-06-17-worker-supervisor-contract.md docs/superpowers/specs/2026-06-17-approval-broker-design.md docs/superpowers/specs/2026-06-18-codex-hook-delivery-decision.md
git commit -m "docs: gate on fresh ready (stale=not-ready); mark backlog ①④ resolved"
```

---

## Final verification

- [ ] Run the full suite:

Run: `bash test/run.sh 2>&1 | tail -3`
Expected: `ALL TESTS PASSED`

- [ ] Confirm the e2e tests still skip by default (machine-independent):

Run: `bash test/run.sh 2>&1 | grep -E "skip codex"`
Expected: both `codex-hook-e2e` and `codex-permreq-e2e` show `skip`.
