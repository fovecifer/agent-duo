# Hook Event Observability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record which hook event (PreToolUse vs PermissionRequest) fired in both the audit log and the readiness marker, so PermissionRequest activity is observable/auditable at runtime (backlog ⑦).

**Architecture:** `ab_append_audit` gains an `event` field read from the existing global `AB_HOOK_EVENT_NAME` (null for non-hook CLI paths). `ab_write_broker_marker` gains an optional `last_event` parameter, passed from the two hook call sites in `ab_run_hook`. No active runtime probe is added — live PermissionRequest verification stays with the existing `codex-permreq-e2e` test, and `broker-check` continues to probe PreToolUse.

**Tech Stack:** Bash (3.2-compatible), the shell test harness in `test/approval.test.sh` (`assert.sh`, `run_hook`, `broker_status`).

## Global Constraints

- Bash 3.2 compatible.
- `event` in the audit log is read from the global `AB_HOOK_EVENT_NAME` (NOT a new positional parameter); empty global ⇒ JSON `null`.
- `AB_HOOK_EVENT_NAME` is set at the top of `ab_run_hook` (`ab_payload_event_name`, default `PreToolUse`); each hook/CLI invocation is a fresh process, so there is no stale-global risk.
- Marker `last_event` follows the existing "non-empty ⇒ write the field" pattern (like `nonce`/`session_id`); manual `ab_cmd_mark` does not pass it.
- No change to policy evaluation, `broker-check`, `ab_cmd_selfcheck_cmd`, or the `peer` dispatch gate. `peer broker-status` already forwards the marker JSON, so `last_event` surfaces automatically.
- Tests deterministic, no `sleep`.

---

### Task 1: Record hook event in audit log and marker

**Files:**
- Modify: `lib/approval_broker.sh` — `ab_append_audit` (add `event` field, ~lines 544-562); `ab_write_broker_marker` (add `last_event` param, ~lines 741-753); the two marker calls in `ab_run_hook` (~lines 786 and 793).
- Test: `test/approval.test.sh` — add 4 assertions after the self-check anchor (⑧) test block.

**Interfaces:**
- Consumes (existing): global `AB_HOOK_EVENT_NAME`, `ab_json_str`, `ab_json_escape`.
- Produces:
  - Audit JSON lines now contain `"event":"<PreToolUse|PermissionRequest>"` (or `null`).
  - `ab_write_broker_marker <root> <agent> <status> [nonce] [decision] [session_id] [last_event]` — writes `"last_event":"<event>"` when the 7th arg is non-empty.

- [ ] **Step 1: Write the failing tests**

In `test/approval.test.sh`, find the end of the ⑧ self-check anchor block — the last assertion is:

```bash
assert_contains "selfcheck: cat mention auto-allowed" "$(cat "$OUT")" '"permissionDecision":"allow"'
```

Immediately after that line, add:

```bash
# ⑦ Hook event name is recorded in the audit log and the marker (observability).
AUDIT_LOG="$PROJECT/.agent-duo/logs/approvals.jsonl"

# A PreToolUse invocation records event=PreToolUse in the audit line and marker last_event.
run_hook '{"tool_name":"Bash","tool_input":{"command":"ls -la"},"round":50}'
assert_contains "audit: PreToolUse event recorded" "$(tail -n1 "$AUDIT_LOG")" '"event":"PreToolUse"'
assert_contains "marker: last_event PreToolUse" "$(broker_status)" '"last_event":"PreToolUse"'

# A PermissionRequest invocation records event=PermissionRequest in the audit line and marker.
run_hook '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls -la"},"round":51}'
assert_contains "audit: PermissionRequest event recorded" "$(tail -n1 "$AUDIT_LOG")" '"event":"PermissionRequest"'
assert_contains "marker: last_event PermissionRequest" "$(broker_status)" '"last_event":"PermissionRequest"'
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash test/approval.test.sh 2>&1 | grep -E "audit: (PreToolUse|PermissionRequest) event|marker: last_event"`
Expected: all four `FAIL` — today's audit line has no `event` field and the marker has no `last_event`.

- [ ] **Step 3: Add the `event` field to `ab_append_audit`**

In `lib/approval_broker.sh`, in `ab_append_audit`, find:

```bash
  line="{\"ts\":\"$(ab_iso_ts)\",\"agent\":\"$(ab_json_escape "$agent")\",\"tool\":\"$(ab_json_escape "$tool")\","
  line="${line}\"cmd\":"
```

and insert the `event` field between them so it becomes:

```bash
  line="{\"ts\":\"$(ab_iso_ts)\",\"agent\":\"$(ab_json_escape "$agent")\",\"tool\":\"$(ab_json_escape "$tool")\","
  line="${line}\"event\":"
  if [[ -n "${AB_HOOK_EVENT_NAME:-}" ]]; then line="${line}$(ab_json_str "$AB_HOOK_EVENT_NAME")"; else line="${line}null"; fi
  line="${line},\"cmd\":"
```

- [ ] **Step 4: Add the `last_event` parameter to `ab_write_broker_marker`**

In `lib/approval_broker.sh`, update `ab_write_broker_marker`. Change the signature comment and `local` line, and add the field write. The function becomes:

```bash
ab_write_broker_marker() { # <root> <agent> <status> [nonce] [decision] [session_id] [last_event]
  local root="$1" agent="$2" status="$3" nonce="${4:-}" decision="${5:-}" session_id="${6:-}" last_event="${7:-}" path data
  [[ -n "$agent" ]] || agent="unknown"
  path="$(ab_broker_marker_path "$root" "$agent")"
  data="{\"agent\":\"$(ab_json_escape "$agent")\",\"status\":\"$(ab_json_escape "$status")\""
  data="${data},\"updated_at\":\"$(ab_iso_ts)\",\"updated_epoch\":$(date +%s)"
  if [[ -n "$nonce" ]]; then data="${data},\"nonce\":\"$(ab_json_escape "$nonce")\""; fi
  if [[ -n "$decision" ]]; then data="${data},\"last_decision\":\"$(ab_json_escape "$decision")\""; fi
  if [[ -n "$session_id" ]]; then data="${data},\"session_id\":\"$(ab_json_escape "$session_id")\""; fi
  if [[ -n "$last_event" ]]; then data="${data},\"last_event\":\"$(ab_json_escape "$last_event")\""; fi
  data="${data}}"
  ab_write_file_atomic "$path" "$data"
}
```

- [ ] **Step 5: Pass `AB_HOOK_EVENT_NAME` from the two hook marker calls**

In `lib/approval_broker.sh`, in `ab_run_hook`:

Change the self-check marker write from:

```bash
    ab_write_broker_marker "$root" "$agent" "ready" "$nonce" "selfcheck" "$session"
```

to:

```bash
    ab_write_broker_marker "$root" "$agent" "ready" "$nonce" "selfcheck" "$session" "$AB_HOOK_EVENT_NAME"
```

Change the heartbeat marker write from:

```bash
  ab_write_broker_marker "$root" "$agent" "ready" "" "" "$session"
```

to:

```bash
  ab_write_broker_marker "$root" "$agent" "ready" "" "" "$session" "$AB_HOOK_EVENT_NAME"
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bash test/approval.test.sh 2>&1 | grep -E "audit: (PreToolUse|PermissionRequest) event|marker: last_event"`
Expected: all four `ok`.

Confirm no regressions in the file:
Run: `bash test/approval.test.sh >/dev/null 2>&1 && echo PASS || echo FAIL`
Expected: `PASS`

- [ ] **Step 7: Commit**

```bash
git add lib/approval_broker.sh test/approval.test.sh
git commit -m "feat(broker): record hook event in audit log and marker (backlog ⑦)"
```

---

### Task 2: Mark backlog ⑦ resolved

**Files:**
- Modify: `docs/superpowers/specs/2026-06-18-codex-hook-delivery-decision.md` — backlog item ⑦.

**Interfaces:** Documentation only — no code, no tests.

- [ ] **Step 1: Locate item ⑦**

Run: `grep -n "⑦\|PermissionRequest" docs/superpowers/specs/2026-06-18-codex-hook-delivery-decision.md`
Read the ⑦ backlog item and the surrounding list formatting (other items are already struck-through/resolved or open).

- [ ] **Step 2: Annotate ⑦ resolved**

Mark the ⑦ item resolved, matching the file's existing strike-through/✅ style, e.g.:

```markdown
~~**⑦ 探针只验 PreToolUse，从不验 PermissionRequest**~~ ✅ 已解决：live PermissionRequest 路径由 `test/codex-permreq-e2e.test.sh` 真机覆盖（⑥）；运行时 hook 事件名现入审计日志（`event` 字段）与 marker（`last_event`），PermissionRequest 调用可见可审计。broker-check 仍主探 PreToolUse（主安全闸、可靠触发）；Codex hook trust 为整会话 all-or-nothing，故 PreToolUse-green 已蕴含 PermissionRequest trust。见 [hook 事件可观测设计](./2026-06-19-hook-event-observability-design.md)。
```

Preserve the other backlog items (the already-resolved ①/②/④/⑥/⑧ and the structural ③). Match the actual list numbering/wording in the file.

- [ ] **Step 3: Sanity-check**

Run: `grep -n "可观测\|⑦" docs/superpowers/specs/2026-06-18-codex-hook-delivery-decision.md`
Expected: shows the resolved ⑦ annotation with the link.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-06-18-codex-hook-delivery-decision.md
git commit -m "docs: mark backlog ⑦ (PermissionRequest observability) resolved"
```

---

## Final verification

- [ ] Run the full suite:

Run: `bash test/run.sh 2>&1 | tail -3`
Expected: `ALL TESTS PASSED`

- [ ] Confirm the e2e tests still skip by default:

Run: `bash test/run.sh 2>&1 | grep -E "skip codex"`
Expected: both `codex-hook-e2e` and `codex-permreq-e2e` show `skip`.
