#!/usr/bin/env bash
# test/integration.test.sh - end-to-end supervisor loop integration with peer + loopd stubs.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
source "$DIR/lib/harness.sh"
source "$ROOT/lib/loop.sh"
setup() { integration_setup; }

wait_for_validation_file() { # <agent> <round>
  local file i
  file="$PROJECT/.agent-duo/state/$1/validation-r$2.json"
  i=0
  while [[ "$i" -lt 200000 ]]; do
    [[ -f "$file" ]] && return 0
    i=$(( i + 1 ))
  done
  return 1
}

event_by_id() { # <id>
  jq -c -s --arg id "$1" '[.[] | select(.id == $id)][0] // empty' "$QUEUE"
}

event_by_type() { # <type>
  jq -c -s --arg type "$1" '[.[] | select(.type == $type)][0] // empty' "$QUEUE"
}

event_count_by_id() { # <id>
  jq -r -s --arg id "$1" '[.[] | select(.id == $id)] | length' "$QUEUE"
}

event_count_by_type_agent() { # <type> <agent>
  jq -r -s --arg type "$1" --arg agent "$2" '[.[] | select(.type == $type and .agent == $agent)] | length' "$QUEUE"
}

event_line_for_id() { # <id>
  jq -r -s --arg id "$1" 'to_entries[] | select(.value.id == $id) | (.key + 1)' "$QUEUE"
}

assert_event_priority() { # <name> <event_json> <expected>
  local name="$1" event="$2" expected="$3" actual
  if [[ -z "$event" ]]; then
    printf 'FAIL %s: missing event\n' "$name"
    ADK_FAIL=1
    return 0
  fi
  actual="$(ad_loop_event_priority "$event")"
  assert_eq "$name" "$actual" "$expected"
}

assert_line_before() { # <name> <id_a> <id_b>
  local name="$1" a="$2" b="$3" line_a line_b
  line_a="$(event_line_for_id "$a")"
  line_b="$(event_line_for_id "$b")"
  if [[ -n "$line_a" && -n "$line_b" && "$line_a" -lt "$line_b" ]]; then
    printf 'ok   %s\n' "$name"
  else
    printf 'FAIL %s: got lines [%s] before [%s]\n' "$name" "$line_a" "$line_b"
    ADK_FAIL=1
  fi
}

queue_ids_are_unique() {
  [[ "$(jq -r -s '[.[] | .id] as $ids | (($ids | length) == ($ids | unique | length))' "$QUEUE")" == "true" ]]
}

setup
printf 'busy\n' > "$PROJECT/.agent-duo/state/supervisor.turn"

assert_ok "integration: worker loop init with all gates" run_peer_as "%1" loop init worker \
  --mission "ship integrated loop" \
  --max-rounds 5 \
  --round 1 \
  --success "tests pass" \
  --verify validate:"stub validation" \
  --verify-satisfies validate:"tests pass" \
  --verify-timeout validate:5 \
  --judge reviewer:request_changes,reject \
  --detail-trap-rounds 2
worker_contract="$(cat "$PROJECT/.agent-duo/state/worker/loop.json")"
assert_eq "integration: worker max_rounds active" "$(jq -r '.max_rounds' "$PROJECT/.agent-duo/state/worker/loop.json")" "5"
assert_eq "integration: worker validation active" "$(jq -r '(.validation // []) | length' "$PROJECT/.agent-duo/state/worker/loop.json")" "1"
assert_eq "integration: worker detail trap active" "$(jq -r '.detail_trap_rounds' "$PROJECT/.agent-duo/state/worker/loop.json")" "2"
assert_eq "integration: worker acceptance active" "$(jq -r '(.acceptance.reviews // []) | length' "$PROJECT/.agent-duo/state/worker/loop.json")" "1"
assert_contains "integration: worker contract status" "$worker_contract" '"status":"active"'

assert_ok "integration: helper loop init isolated" run_peer_as "%1" loop init helper \
  --mission "helper independent contract" \
  --max-rounds 4 \
  --round 1 \
  --success "tests pass" \
  --verify validate:"stub validation" \
  --verify-satisfies validate:"tests pass" \
  --verify-timeout validate:5 \
  --judge evaluator:fail,request_changes \
  --detail-trap-rounds 2

assert_ok "integration: worker r1 empty progress" run_peer_as "%3" report \
  --type checkpoint --status in_progress --round 1 --delta "" --next "continue"
assert_ok "integration: helper blocked report" run_peer_as "%4" report \
  --type request --status blocked --round 1 --needs decision --needs-detail "need human scope"
assert_ok "integration: r1 loopd spawns async validation" run_loopd_once
assert_ok "integration: worker r1 validation finishes" wait_for_validation_file worker 1
assert_ok "integration: helper validation finishes" wait_for_validation_file helper 1
assert_ok "integration: r1 loopd observes validation results" run_loopd_once
assert_eq "integration: worker r1 validation pass" "$(jq -r '.status' "$PROJECT/.agent-duo/state/worker/validation-r1.json")" "pass"
assert_eq "integration: helper validation fail" "$(jq -r '.status' "$PROJECT/.agent-duo/state/helper/validation-r1.json")" "fail"
assert_contains "integration: helper loop remains active after fail" "$(cat "$PROJECT/.agent-duo/state/helper/loop.json")" '"status":"active"'

assert_ok "integration: worker r2 empty drift" run_peer_as "%3" report \
  --type checkpoint --status in_progress --round 2 --delta "" --drift "left mission scope" --next "correct"
assert_ok "integration: r2 loopd emits direction events" run_loopd_once
assert_ok "integration: worker r2 validation finishes" wait_for_validation_file worker 2
assert_ok "integration: r2 loopd observes validation pass" run_loopd_once
assert_eq "integration: worker r2 validation pass" "$(jq -r '.status' "$PROJECT/.agent-duo/state/worker/validation-r2.json")" "pass"
assert_eq "integration: drift deterministic once" "$(event_count_by_id drift-worker-2)" "1"
assert_eq "integration: detail trap deterministic once" "$(event_count_by_id detailtrap-worker-2)" "1"

assert_ok "integration: reviewer request_changes routed" run_peer_as "%5" judge \
  worker@3 --round 1 --verdict request_changes --finding blocking:"needs revision"
assert_ok "integration: worker r3 done with evidence" run_peer_as "%3" report \
  --type result --status done --round 3 --delta "done" --evidence-result "validated locally"
assert_ok "integration: done first pass starts validation only" run_loopd_once
assert_not_contains "integration: no premature stop while validation running" "$(cat "$QUEUE")" '"id":"loopstop-worker-3"'
assert_ok "integration: worker r3 validation finishes" wait_for_validation_file worker 3
assert_ok "integration: validation pass exposes veto" run_loopd_once
assert_eq "integration: worker r3 validation pass" "$(jq -r '.status' "$PROJECT/.agent-duo/state/worker/validation-r3.json")" "pass"
assert_eq "integration: veto event deterministic once" "$(event_count_by_id reviewreq-worker-3-vetoed)" "1"
assert_not_contains "integration: no stop while reviewer vetoes" "$(cat "$QUEUE")" '"id":"loopstop-worker-3"'
assert_contains "integration: dashboard combines active pass veto" "$(cat "$OUT")" 'worker pane=%3 round=3 status=done   loop=3/5 active verify=pass judge=reviewer:vetoed(request_changes)'

assert_ok "integration: reviewer approve routed" run_peer_as "%5" judge \
  worker@3 --round 2 --verdict approve
assert_ok "integration: approve lets done stop" run_loopd_once
assert_eq "integration: worker stopped done" "$(jq -r '.stop.reason' "$PROJECT/.agent-duo/state/worker/loop.json")" "done"
assert_eq "integration: loop stop deterministic once" "$(event_count_by_id loopstop-worker-3)" "1"
assert_contains "integration: dashboard combines stopped pass ok" "$(cat "$OUT")" 'worker pane=%3 round=3 status=done   loop=3/5 stopped:done verify=pass judge=reviewer:ok'

assert_eq "integration: helper has no loop stop" "$(event_count_by_type_agent loop_stop helper)" "0"
assert_eq "integration: helper has no review_required" "$(event_count_by_type_agent review_required helper)" "0"
assert_contains "integration: helper dashboard isolated" "$(cat "$OUT")" 'helper pane=%4 round=1 status=blocked   loop=1/4 active verify=fail judge=evaluator:pending'
assert_eq "integration: worker review approval isolated" "$(jq -r '.verdict' "$PROJECT/.agent-duo/state/worker/reviews/reviewer-r3.json")" "approve"
assert_ok "integration: helper has no reviewer state" test ! -e "$PROJECT/.agent-duo/state/helper/reviews/reviewer-r3.json"

assert_event_priority "integration: loop_stop priority" "$(event_by_id loopstop-worker-3)" "10"
assert_event_priority "integration: blocked priority" "$(event_by_type blocked)" "10"
assert_event_priority "integration: review_required priority" "$(event_by_id reviewreq-worker-3-vetoed)" "11"
assert_event_priority "integration: direction_drift priority" "$(event_by_id drift-worker-2)" "12"
assert_event_priority "integration: validation_fail priority" "$(event_by_id validation-helper-1)" "15"
assert_event_priority "integration: detail_trap priority" "$(event_by_id detailtrap-worker-2)" "20"
assert_ok "integration: event ids do not collide" queue_ids_are_unique

assert_line_before "integration: direction before validation in eval order" detailtrap-worker-2 validation-worker-2
assert_line_before "integration: validation before veto gate" validation-worker-3 reviewreq-worker-3-vetoed
assert_line_before "integration: veto before final stop" reviewreq-worker-3-vetoed loopstop-worker-3
assert_eq "integration: no worker validation fail collision" "$(event_count_by_id validation-worker-3)" "1"
assert_contains "integration: validation runner was async child" "$(cat "$VERIFY_STUB_LOG")" $'worker\t3'
assert_contains "integration: validation runner kept helper separate" "$(cat "$VERIFY_STUB_LOG")" $'helper\t1'

teardown

exit "$ADK_FAIL"
