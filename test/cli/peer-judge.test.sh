#!/usr/bin/env bash
# test/cli/peer-judge.test.sh - peer judge tests
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
source "$DIR/../lib/harness.sh"

# judge:reviewer verdict 写入自身 report,并路由到目标 worker reviews/。
setup
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%2\treviewer\treviewer\tcodex\n%%3\tworker\tworker\tcodex\n' > "$TMUX_STUB_REGISTRY"
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "judge verdict: succeeds" \
  run_peer judge worker@5 --round 1 --verdict approve --finding blocking:"401/403 反了"
reviewer_report="$(cat "$PROJECT/.agent-duo/state/reviewer/r1.json")"
verdict_record="$(cat "$PROJECT/.agent-duo/state/worker/reviews/reviewer-r5.json")"
assert_contains "judge verdict: report verdict field" "$reviewer_report" '"verdict":"approve"'
assert_contains "judge verdict: report target ref" "$reviewer_report" '"target_ref":"worker@5"'
assert_contains "judge verdict: finding severity" "$reviewer_report" '"severity":"blocking"'
assert_contains "judge verdict: routed verdict" "$verdict_record" '"verdict":"approve"'
assert_contains "judge verdict: routed by" "$verdict_record" '"by":"reviewer"'
assert_contains "judge verdict: routed role" "$verdict_record" '"role":"reviewer"'
assert_contains "judge verdict: routed target round" "$verdict_record" '"target_round":5'
assert_ok "judge ls: succeeds" run_peer judge ls worker
assert_contains "judge ls: shows verdict" "$(cat "$OUT")" $'r5\treviewer\tapprove'
teardown

# report:verdict flags were removed from report and fail-closed toward judge.
setup
TEST_TMUX_PANE="%2" assert_not_ok "report verdict: old report verdict rejected" \
  run_peer report --type result --status done --round 1 --verdict approve --target-ref worker@5
assert_contains "report verdict: old report hints judge" "$(cat "$ERR")" 'peer judge'
assert_ok "report verdict: old report writes no report" test ! -e "$PROJECT/.agent-duo/state/worker/r1.json"
teardown

setup
TEST_TMUX_PANE="%2" assert_not_ok "judge verdict: missing verdict rejected" \
  run_peer judge worker@5 --round 1
assert_contains "judge verdict: missing verdict error" "$(cat "$ERR")" '--verdict'
assert_ok "judge verdict: missing verdict writes no report" test ! -e "$PROJECT/.agent-duo/state/worker/r1.json"
teardown

setup
TEST_TMUX_PANE="%2" assert_not_ok "judge verdict: bad target ref rejected" \
  run_peer judge '..@5' --round 1 --verdict approve
assert_contains "judge verdict: bad target ref error" "$(cat "$ERR")" 'worker'
assert_ok "judge verdict: bad target ref writes no report" test ! -e "$PROJECT/.agent-duo/state/worker/r1.json"
teardown

# judge:判决路由失败时 report/event/latest 保留,但命令非零且不打印 sentinel。
setup
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%2\treviewer\treviewer\tcodex\n%%3\tworker\tworker\tcodex\n' > "$TMUX_STUB_REGISTRY"
mkdir -p "$PROJECT/.agent-duo/state/worker"
printf 'not a directory\n' > "$PROJECT/.agent-duo/state/worker/reviews"
TEST_TMUX_PANE="%2" assert_not_ok "judge verdict: route failure fails visibly" \
  run_peer judge worker@5 --round 1 --verdict approve
assert_contains "judge verdict: route failure error" "$(cat "$ERR")" '路由到 worker/reviews/reviewer-r5.json 失败'
assert_eq "judge verdict: route failure no sentinel" "$(cat "$OUT")" ""
assert_ok "judge verdict: route failure keeps report" test -f "$PROJECT/.agent-duo/state/reviewer/r1.json"
assert_ok "judge verdict: route failure keeps latest" test -L "$PROJECT/.agent-duo/state/reviewer/report.json"
assert_contains "judge verdict: route failure keeps event" "$(cat "$PROJECT/.agent-duo/events/queue.jsonl")" '"agent":"reviewer"'
teardown

exit "$ADK_FAIL"
