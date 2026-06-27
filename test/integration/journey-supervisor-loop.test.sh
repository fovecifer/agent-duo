#!/usr/bin/env bash
# test/integration/journey-supervisor-loop.test.sh - playbook-driven supervisor loop journey.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
source "$DIR/../lib/harness.sh"

wait_for_validation_file() {
  local file i
  file="$PROJECT/.agent-duo/state/$1/validation-r$2.json"
  i=0
  while [[ "$i" -lt 200000 ]]; do
    [[ -f "$file" ]] && return 0
    i=$(( i + 1 ))
  done
  return 1
}

integration_setup

# Phase 2: PROVISION. Start from the user-visible add path, then pin the stub
# registry so later routing exercises the real peer lookup used by the playbook.
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%4\tloopd\tdaemon\tbash\n' > "$TMUX_STUB_REGISTRY"
TMUX_STUB_NEW_PANE="%3" assert_ok "journey phase2: add builder" \
  run_peer agent add --provider codex --role builder --id builder
assert_contains "journey phase2: builder approval hint" "$(cat "$OUT")" 'peer approval check builder'
TMUX_STUB_NEW_PANE="%2" assert_ok "journey phase2: add reviewer" \
  run_peer agent add --provider codex --role reviewer --id reviewer
assert_contains "journey phase2: add reviewer id" "$(cat "$OUT")" 'reviewer'

harness_registry \
  $'%1\tsupervisor\tsupervisor\tclaude' \
  $'%2\treviewer\treviewer\tcodex' \
  $'%3\tbuilder\tbuilder\tcodex' \
  $'%4\tloopd\tdaemon\tbash'
harness_broker_ready builder
harness_broker_ready reviewer
assert_ok "journey phase2: approval check builder" run_peer approval check builder --nonce n1
assert_contains "journey phase2: builder broker ready" "$(cat "$OUT")" 'broker READY'
assert_ok "journey phase2: approval check reviewer" run_peer approval check reviewer --nonce n1
assert_contains "journey phase2: reviewer broker ready" "$(cat "$OUT")" 'broker READY'

# Phase 4: BUILD. Freeze verify/judge gates from the playbook and dispatch work.
assert_ok "journey phase4: loop init builder with verify and judge" run_peer loop init builder \
  --mission "ship login copy" \
  --max-rounds 5 \
  --success "tests pass" \
  --verify tests:"true" \
  --verify-satisfies tests:"tests pass" \
  --judge reviewer:request_changes
assert_ok "journey phase4: loop show readable" run_peer loop show builder
assert_contains "journey phase4: loop show verify" "$(cat "$OUT")" $'VERIFY\ttests:true'
assert_contains "journey phase4: loop show judge" "$(cat "$OUT")" $'JUDGE\treviewer:request_changes'

TMUX_STUB_ON_SEND_REPORT_ROOT="$PROJECT" \
  TMUX_STUB_ON_SEND_REPORT_AGENT=builder \
  TMUX_STUB_ON_SEND_REPORT_ROUND=1 \
  TMUX_STUB_ON_SEND_REPORT_DELTA="plan accepted" \
  assert_ok "journey phase4: ask builder and read checkpoint" \
    run_peer ask builder "draft the implementation plan" --timeout 2 --interval 1
assert_contains "journey phase4: ask prints summary" "$(cat "$OUT")" $'SUMMARY\tplan accepted'
assert_contains "journey phase4: ask prints ref" "$(cat "$OUT")" $'REF\t.agent-duo/state/builder/r1.json'

TEST_TMUX_PANE="%3" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "journey phase4: builder reports done with evidence" \
  run_peer_as "%3" report \
    --type result \
    --status done \
    --round 2 \
    --delta "implemented login copy" \
    --evidence-cmd "bash test/run.sh" \
    --evidence-result "ALL TESTS PASSED" \
    --evidence-ref ".agent-duo/logs/builder/r2.log"
assert_contains "journey phase4: builder report sentinel" "$(cat "$OUT")" 'status=done'

# Phase 5: JUDGE. Reviewer vetoes builder@2, proving maker != checker.
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "journey phase5: reviewer vetoes first result" \
  run_peer_as "%2" judge builder@2 \
    --round 1 \
    --verdict request_changes \
    --finding blocking:"copy still mentions legacy auth"
assert_contains "journey phase5: reviewer verdict visible" "$(cat "$OUT")" 'agent_id=reviewer'

# Phase 6: LOOP. Verify passes, judge veto blocks the completion gate and keeps
# builder active; checkpoint exposes user-visible verify/judge state.
assert_ok "journey phase6: loopd starts validation after done" run_loopd_once
assert_ok "journey phase6: validation result arrives" wait_for_validation_file builder 2
assert_ok "journey phase6: loopd exposes reviewer veto" run_loopd_once
assert_eq "journey phase6: veto keeps loop active" "$(jq -r '.status' "$PROJECT/.agent-duo/state/builder/loop.json")" "active"
assert_ok "journey phase6: checkpoint readable after veto" run_peer checkpoint builder
assert_contains "journey phase6: checkpoint header active" "$(cat "$OUT")" $'CHECKPOINT\tbuilder @ r2'
assert_contains "journey phase6: checkpoint verify pass" "$(cat "$OUT")" $'VERIFY\tr2 pass'

# Phase 7: GATE. A red-line decision opens a human gate, then supervisor resolves
# it and sends the decision back to builder.
TEST_TMUX_PANE="%3" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "journey phase7: builder opens decision gate" \
  run_peer_as "%3" report \
    --type request \
    --status blocked \
    --round 3 \
    --needs decision \
    --needs-detail "部署到哪里?" \
    --needs-option staging \
    --needs-option production
assert_ok "journey phase7: gate list is visible" run_peer gate ls
assert_contains "journey phase7: gate list shows detail" "$(cat "$OUT")" '部署到哪里?'
assert_contains "journey phase7: gate list shows option" "$(cat "$OUT")" 'staging'
assert_ok "journey phase7: gate resolve sends decision" run_peer gate resolve --choice staging --note "use staging"
assert_contains "journey phase7: gate decision buffer" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-supervisor2builder-gate")" 'choice=staging'

# Phase 8: DONE. Builder reports final evidence, reviewer approves, loopd stops
# only after verify pass + no veto + evidence are all true.
TEST_TMUX_PANE="%3" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "journey phase8: builder reports final done" \
  run_peer_as "%3" report \
    --type result \
    --status done \
    --round 4 \
    --delta "fixed copy and deployed to staging" \
    --evidence-cmd "bash test/run.sh integration" \
    --evidence-result "ALL TESTS PASSED" \
    --evidence-ref ".agent-duo/logs/builder/r4.log"
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "journey phase8: reviewer approves final result" \
  run_peer_as "%2" judge builder@4 --round 2 --verdict approve

assert_ok "journey phase8: final validation starts" run_loopd_once
assert_ok "journey phase8: final validation arrives" wait_for_validation_file builder 4
assert_ok "journey phase8: loopd stops approved done loop" run_loopd_once
assert_eq "journey phase8: loop stopped" "$(jq -r '.status' "$PROJECT/.agent-duo/state/builder/loop.json")" "stopped"
assert_ok "journey phase8: final checkpoint readable" run_peer checkpoint builder
assert_contains "journey phase8: final checkpoint stopped" "$(cat "$OUT")" 'loop stopped'

teardown
echo "journey-supervisor-loop: ok"
exit "$ADK_FAIL"
