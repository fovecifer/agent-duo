# Self-Check Sentinel Anchor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the broker from misidentifying a real worker command as a self-check probe just because it contains the sentinel substring, by anchoring `ab_selfcheck_nonce` to the full canonical probe command shape (backlog ⑧).

**Architecture:** Replace the substring match in `ab_selfcheck_nonce` with an anchored ERE match against the exact probe command `printf agent-duo-broker-check > AGENT_DUO_BROKER_SELFCHECK_<nonce>.tmp` (whitespace-tolerant around `>`), extracting the nonce via `BASH_REMATCH`. The probe generator (`ab_cmd_selfcheck_cmd`) is unchanged; only the matcher tightens.

**Tech Stack:** Bash (3.2-compatible), the shell test harness in `test/approval.test.sh` (`assert.sh`, `run_hook`, `broker_status`).

## Global Constraints

- Bash 3.2 compatible. For the `=~` match, put the ERE in a variable and use it UNQUOTED on the right side (`re='…'; [[ "$cmd" =~ $re ]]`) — quoting the regex makes it literal in Bash 3.2.
- Recognize a probe ONLY when the trimmed command matches the full canonical shape; whitespace around `>` is tolerant, everything else is exact. `raw_path` is not consulted.
- The matcher's anchored pattern corresponds exactly to `ab_cmd_selfcheck_cmd`'s output (`printf agent-duo-broker-check > <SENTINEL>_<nonce>.tmp`) — keep them in sync.
- No change to `ab_cmd_selfcheck_cmd`, `peer broker-check`, or marker/audit writing. The call site `nonce="$(ab_selfcheck_nonce "$command" "$raw_path")"` and "non-empty ⇒ selfcheck" semantics stay.
- Tests deterministic, no `sleep`.

---

### Task 1: Anchor `ab_selfcheck_nonce` to the canonical probe

**Files:**
- Modify: `lib/approval_broker.sh` — rewrite `ab_selfcheck_nonce` (current lines ~756-766).
- Modify: `test/approval.test.sh` — update the existing self-check probe command (line ~297) to the canonical payload; add anchored-matching tests after the self-check block (after line ~307).

**Interfaces:**
- Consumes (existing): `SELFCHECK_SENTINEL` (= `AGENT_DUO_BROKER_SELFCHECK`), `ab_trim`.
- Produces: `ab_selfcheck_nonce <command> <raw_path>` → prints the probe nonce when (and only when) the trimmed `<command>` is the canonical probe; prints nothing otherwise. (`<raw_path>` is accepted for call-site compatibility but ignored.)

- [ ] **Step 1: Update the existing probe test + add the anchored-matching tests**

In `test/approval.test.sh`:

(a) The existing self-check test (line ~297) uses a non-canonical printf payload (`printf ok`), which the anchored matcher will no longer recognize. Change that one line from:

```bash
run_hook '{"tool_name":"Bash","tool_input":{"command":"printf ok > AGENT_DUO_BROKER_SELFCHECK_probe42.tmp"},"round":21}'
```

to the canonical probe payload:

```bash
run_hook '{"tool_name":"Bash","tool_input":{"command":"printf agent-duo-broker-check > AGENT_DUO_BROKER_SELFCHECK_probe42.tmp"},"round":21}'
```

(The surrounding assertions — denied, `BROKER-SELFCHECK`, `nonce":"probe42"`, no approval/blocked — stay unchanged.)

(b) Immediately after the self-check block (after the `assert_not_contains "hook: selfcheck enqueues no blocked event" ...` lines, ~line 307), insert:

```bash
# ⑧ Self-check is anchored to the canonical probe command shape — a real command that
# merely mentions the sentinel substring is NOT treated as a probe.

# Canonical probe with extra whitespace around `>` is still recognized.
run_hook '{"tool_name":"Bash","tool_input":{"command":"printf agent-duo-broker-check  >   AGENT_DUO_BROKER_SELFCHECK_sp1.tmp"},"round":40}'
assert_contains "selfcheck: whitespace-tolerant probe denied" "$(cat "$OUT")" 'BROKER-SELFCHECK'
assert_contains "selfcheck: whitespace-tolerant probe nonce" "$(broker_status)" '"nonce":"sp1"'

# A grep that merely mentions the sentinel is NOT a probe → normal policy (grep is allowlisted → allow).
run_hook '{"tool_name":"Bash","tool_input":{"command":"grep AGENT_DUO_BROKER_SELFCHECK_zzz test/peer.test.sh"},"round":41}'
assert_not_contains "selfcheck: grep mention not a probe" "$(cat "$OUT")" 'BROKER-SELFCHECK'
assert_contains "selfcheck: grep mention auto-allowed" "$(cat "$OUT")" '"permissionDecision":"allow"'
assert_not_contains "selfcheck: grep mention no fake nonce" "$(broker_status)" '"nonce":"zzz"'

# An echo that mentions the sentinel is NOT a probe.
run_hook '{"tool_name":"Bash","tool_input":{"command":"echo AGENT_DUO_BROKER_SELFCHECK_yyy"},"round":42}'
assert_not_contains "selfcheck: echo mention not a probe" "$(cat "$OUT")" 'BROKER-SELFCHECK'
assert_contains "selfcheck: echo mention auto-allowed" "$(cat "$OUT")" '"permissionDecision":"allow"'

# A cat of a ..._.tmp file (not printf) is NOT a probe.
run_hook '{"tool_name":"Bash","tool_input":{"command":"cat AGENT_DUO_BROKER_SELFCHECK_www.tmp"},"round":43}'
assert_not_contains "selfcheck: cat mention not a probe" "$(cat "$OUT")" 'BROKER-SELFCHECK'
assert_contains "selfcheck: cat mention auto-allowed" "$(cat "$OUT")" '"permissionDecision":"allow"'
```

- [ ] **Step 2: Run the tests to verify the negatives fail**

Run: `bash test/approval.test.sh 2>&1 | grep -E "selfcheck: (grep|echo|cat) mention"`
Expected: the `not a probe` / `auto-allowed` / `no fake nonce` assertions FAIL — today's substring matcher treats `grep …SELFCHECK_zzz…`, `echo …`, and `cat …` as probes (emits `BROKER-SELFCHECK`, denies, and writes `nonce":"zzz"`). The whitespace-tolerant probe test and the updated canonical probe test pass under the current matcher too.

- [ ] **Step 3: Rewrite `ab_selfcheck_nonce`**

In `lib/approval_broker.sh`, replace the whole `ab_selfcheck_nonce` function (current lines ~756-766) with:

```bash
# Return the probe nonce IFF <command> is the canonical self-check probe emitted by
# ab_cmd_selfcheck_cmd: `printf agent-duo-broker-check > AGENT_DUO_BROKER_SELFCHECK_<nonce>.tmp`
# (whitespace around `>` tolerant). Anchored on the whole command so a real command that
# merely contains the sentinel substring is NOT treated as a probe. raw_path is ignored.
ab_selfcheck_nonce() { # <command> <raw_path>
  local cmd re
  cmd="$(ab_trim "$1")"
  # Keep in sync with ab_cmd_selfcheck_cmd's output shape.
  re="^printf agent-duo-broker-check[[:space:]]+>[[:space:]]*${SELFCHECK_SENTINEL}_([A-Za-z0-9]+)\.tmp$"
  if [[ "$cmd" =~ $re ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash test/approval.test.sh 2>&1 | grep -E "selfcheck:|selfcheck probe is denied|selfcheck marker records nonce"`
Expected: all `ok` — canonical and whitespace-tolerant probes still recognized (denied, nonce captured); grep/echo/cat mentions now fall through to normal policy (auto-allowed, no `BROKER-SELFCHECK`, no fake nonce).

Then the whole file:
Run: `bash test/approval.test.sh >/dev/null 2>&1 && echo PASS || echo FAIL`
Expected: `PASS`

- [ ] **Step 5: Commit**

```bash
git add lib/approval_broker.sh test/approval.test.sh
git commit -m "fix(broker): anchor self-check matcher to canonical probe shape (backlog ⑧)"
```

---

### Task 2: Mark backlog ⑧ resolved

**Files:**
- Modify: `docs/superpowers/specs/2026-06-18-codex-hook-delivery-decision.md` — backlog item ⑧.

**Interfaces:** Documentation only — no code, no tests.

- [ ] **Step 1: Locate item ⑧**

Run: `grep -n "⑧\|sentinel\|自指" docs/superpowers/specs/2026-06-18-codex-hook-delivery-decision.md`
Read the backlog list item for ⑧ and the surrounding list formatting (other items may already be struck-through/resolved).

- [ ] **Step 2: Annotate ⑧ resolved**

Mark the ⑧ item resolved, matching the file's existing strike-through/✅ style for resolved items, e.g.:

```markdown
~~**⑧ sentinel 自指风险**~~ ✅ 已解决：自检识别从子串命中改为锚定完整规范探针命令（`printf agent-duo-broker-check > AGENT_DUO_BROKER_SELFCHECK_<nonce>.tmp`，`>` 周围容忍空白），真实命令里偶然出现的 sentinel 不再误触发。见 [自检 sentinel 锚定设计](./2026-06-19-selfcheck-sentinel-anchor-design.md)。
```

Preserve the other backlog items (⑦/③ and the already-resolved ①/②/④) exactly. Match the actual list numbering/wording in the file.

- [ ] **Step 3: Sanity-check**

Run: `grep -n "锚定\|⑧" docs/superpowers/specs/2026-06-18-codex-hook-delivery-decision.md`
Expected: shows the resolved ⑧ annotation with the link.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-06-18-codex-hook-delivery-decision.md
git commit -m "docs: mark backlog ⑧ (sentinel self-reference) resolved"
```

---

## Final verification

- [ ] Run the full suite:

Run: `bash test/run.sh 2>&1 | tail -3`
Expected: `ALL TESTS PASSED`

- [ ] Confirm the e2e tests still skip by default:

Run: `bash test/run.sh 2>&1 | grep -E "skip codex"`
Expected: both `codex-hook-e2e` and `codex-permreq-e2e` show `skip`.
