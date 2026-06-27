#!/usr/bin/env bash
# test/integration/journey-supervisor-loop.test.sh - user-visible supervisor loop journey.
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

# The journey starts from the user-visible setup path, then fixes the registry to
# the panes created by the stub so later routing exercises the real peer lookup.
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%4\tloopd\tdaemon\tbash\n' > "$TMUX_STUB_REGISTRY"
TMUX_STUB_NEW_PANE="%3" assert_ok "journey: add worker" \
  run_peer agent add --provider codex --role worker --id worker
assert_contains "journey: add worker approval hint" "$(cat "$OUT")" 'peer approval check worker'
TMUX_STUB_NEW_PANE="%2" assert_ok "journey: add reviewer" \
  run_peer agent add --provider codex --role reviewer --id reviewer
assert_contains "journey: add reviewer id" "$(cat "$OUT")" 'reviewer'

harness_registry \
  $'%1\tsupervisor\tsupervisor\tclaude' \
  $'%2\treviewer\treviewer\tcodex' \
  $'%3\tworker\tworker\tcodex' \
  $'%4\tloopd\tdaemon\tbash'
harness_broker_ready worker

assert_ok "journey: loop init with verify and judge" run_peer loop init worker \
  --mission "ship login copy" \
  --max-rounds 5 \
  --success "tests pass" \
  --verify tests:"true" \
  --verify-satisfies tests:"tests pass" \
  --judge reviewer:request_changes
assert_ok "journey: loop show readable" run_peer loop show worker
assert_contains "journey: loop show verify" "$(cat "$OUT")" $'VERIFY\ttests:true'
assert_contains "journey: loop show judge" "$(cat "$OUT")" $'JUDGE\treviewer:request_changes'

TMUX_STUB_ON_SEND_REPORT_ROOT="$PROJECT" \
  TMUX_STUB_ON_SEND_REPORT_AGENT=worker \
  TMUX_STUB_ON_SEND_REPORT_ROUND=1 \
  TMUX_STUB_ON_SEND_REPORT_DELTA="plan accepted" \
  assert_ok "journey: ask worker and read checkpoint" \
    run_peer ask worker "draft the implementation plan" --timeout 2 --interval 1
assert_contains "journey: ask prints summary" "$(cat "$OUT")" $'SUMMARY\tplan accepted'
assert_contains "journey: ask prints ref" "$(cat "$OUT")" $'REF\t.agent-duo/state/worker/r1.json'

TEST_TMUX_PANE="%3" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "journey: worker reports done with evidence" \
  run_peer_as "%3" report \
    --type result \
    --status done \
    --round 2 \
    --delta "implemented login copy" \
    --evidence-cmd "bash test/run.sh" \
    --evidence-result "ALL TESTS PASSED" \
    --evidence-ref ".agent-duo/logs/worker/r2.log"
assert_contains "journey: worker report sentinel" "$(cat "$OUT")" 'status=done'

TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "journey: reviewer vetoes first result" \
  run_peer_as "%2" judge worker@2 \
    --round 1 \
    --verdict request_changes \
    --finding blocking:"copy still mentions legacy auth"
assert_contains "journey: reviewer verdict visible" "$(cat "$OUT")" 'agent_id=reviewer'

assert_ok "journey: loopd starts validation after done" run_loopd_once
assert_ok "journey: validation result arrives" wait_for_validation_file worker 2
assert_ok "journey: loopd exposes reviewer veto" run_loopd_once
assert_eq "journey: veto keeps loop active" "$(jq -r '.status' "$PROJECT/.agent-duo/state/worker/loop.json")" "active"
assert_ok "journey: checkpoint readable after veto" run_peer checkpoint worker
assert_contains "journey: checkpoint header active" "$(cat "$OUT")" $'CHECKPOINT\tworker @ r2'
assert_contains "journey: checkpoint verify pass" "$(cat "$OUT")" $'VERIFY\tr2 pass'

TEST_TMUX_PANE="%3" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "journey: worker opens decision gate" \
  run_peer_as "%3" report \
    --type request \
    --status blocked \
    --round 3 \
    --needs decision \
    --needs-detail "部署到哪里?" \
    --needs-option staging \
    --needs-option production
assert_ok "journey: gate list is visible" run_peer gate ls
assert_contains "journey: gate list shows detail" "$(cat "$OUT")" '部署到哪里?'
assert_contains "journey: gate list shows option" "$(cat "$OUT")" 'staging'
assert_ok "journey: gate resolve sends decision" run_peer gate resolve --choice staging --note "use staging"
assert_contains "journey: gate decision buffer" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker-gate")" 'choice=staging'

TEST_TMUX_PANE="%3" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "journey: worker reports final done" \
  run_peer_as "%3" report \
    --type result \
    --status done \
    --round 4 \
    --delta "fixed copy and deployed to staging" \
    --evidence-cmd "bash test/run.sh integration" \
    --evidence-result "ALL TESTS PASSED" \
    --evidence-ref ".agent-duo/logs/worker/r4.log"
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "journey: reviewer approves final result" \
  run_peer_as "%2" judge worker@4 --round 2 --verdict approve

assert_ok "journey: final validation starts" run_loopd_once
assert_ok "journey: final validation arrives" wait_for_validation_file worker 4
assert_ok "journey: loopd stops approved done loop" run_loopd_once
assert_eq "journey: loop stopped" "$(jq -r '.status' "$PROJECT/.agent-duo/state/worker/loop.json")" "stopped"
assert_ok "journey: final checkpoint readable" run_peer checkpoint worker
assert_contains "journey: final checkpoint stopped" "$(cat "$OUT")" 'loop stopped'

teardown
echo "journey-supervisor-loop: ok"
exit "$ADK_FAIL"
