#!/usr/bin/env bash
# test/cli/peer-report.test.sh - peer report tests
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
source "$DIR/../lib/harness.sh"

# report:写 rN.json、更新 latest 指针、追加极小 event、打印 sentinel。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "report: succeeds" \
  run_peer report --type checkpoint --status in_progress --round 7 --step s1 --delta "tests added" --next "implement codec"
STATE="$PROJECT/.agent-duo/state/worker"
QUEUE="$PROJECT/.agent-duo/events/queue.jsonl"
assert_ok "report: rN exists" test -f "$STATE/r7.json"
assert_eq "report: latest symlink" "$(readlink "$STATE/report.json")" "r7.json"
assert_ok "report: queue exists" test -f "$QUEUE"
report_json="$(cat "$STATE/r7.json")"
event_json="$(cat "$QUEUE")"
sentinel="$(cat "$OUT")"
assert_contains "report: protocol" "$report_json" '"protocol":"1"'
assert_contains "report: agent id" "$report_json" '"agent_id":"worker"'
assert_contains "report: role" "$report_json" '"role":"worker"'
assert_contains "report: type" "$report_json" '"type":"checkpoint"'
assert_contains "report: status" "$report_json" '"status":"in_progress"'
assert_contains "report: step" "$report_json" '"step_ref":"s1"'
assert_contains "report: sentinel delimiter" "$sentinel" '«AGENTDUO:7f3a»'
assert_contains "report: sentinel agent" "$sentinel" 'agent_id=worker'
assert_contains "report: sentinel round" "$sentinel" 'round=7'
assert_contains "report: sentinel file" "$sentinel" 'file=.agent-duo/state/worker/r7.json'
assert_contains "report: event agent" "$event_json" '"agent":"worker"'
assert_contains "report: event type" "$event_json" '"type":"checkpoint"'
assert_contains "report: event ref" "$event_json" '"ref":".agent-duo/state/worker/r7.json"'
teardown

# report:纯 Bash codec 仍要正确 JSON 转义常见特殊字符。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "report: json escaping succeeds" \
  run_peer report --type checkpoint --status in_progress --round 2 \
    --delta $'quote " backslash \\ tab\t' \
    --next $'line 1\nline 2'
escaped_report="$(cat "$PROJECT/.agent-duo/state/worker/r2.json")"
assert_contains "report: escapes quote" "$escaped_report" 'quote \"'
assert_contains "report: escapes backslash" "$escaped_report" 'backslash \\'
assert_contains "report: escapes tab" "$escaped_report" 'tab\t'
assert_contains "report: escapes newline" "$escaped_report" 'line 1\nline 2'
teardown

# report:其余 < 0x20 控制字符转为 \u00XX，且多字节 UTF-8 原样保留(否则下游 jq 会崩)。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "report: control char escaping succeeds" \
  run_peer report --type checkpoint --status in_progress --round 3 \
    --delta $'esc\x1bvt\x0b中文'
ctrl_report="$(cat "$PROJECT/.agent-duo/state/worker/r3.json")"
assert_contains "report: escapes ESC control char" "$ctrl_report" 'esc\u001bvt'
assert_contains "report: escapes vtab control char" "$ctrl_report" 'vt\u000b中文'
assert_contains "report: preserves UTF-8" "$ctrl_report" '中文'
teardown

# report:done/partial 没有 evidence 时按契约降级为 unknown。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "report: done without evidence succeeds" \
  run_peer report --type result --status done --round 1 --delta "claimed done"
assert_contains "report: done without evidence downgraded" "$(cat "$PROJECT/.agent-duo/state/worker/r1.json")" '"status":"unknown"'
assert_contains "report: downgraded sentinel status" "$(cat "$OUT")" 'status=unknown'
teardown

# report:report 文件本身写入失败时不得写 event 或打印 sentinel。
setup
mkdir -p "$PROJECT/.agent-duo/state/worker" "$PROJECT/.agent-duo/events"
chmod -w "$PROJECT/.agent-duo/state/worker"
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_not_ok "report: file write failure fails" \
  run_peer report --type checkpoint --status in_progress --round 4 --delta "cannot write report"
chmod +w "$PROJECT/.agent-duo/state/worker"
assert_eq "report: file write failure no sentinel" "$(cat "$OUT")" ""
assert_contains "report: file write failure error" "$(cat "$ERR")" '写 report 临时文件失败'
assert_ok "report: file write failure no rN" test ! -e "$PROJECT/.agent-duo/state/worker/r4.json"
assert_ok "report: file write failure no latest" test ! -L "$PROJECT/.agent-duo/state/worker/report.json"
assert_ok "report: file write failure no event" test ! -e "$PROJECT/.agent-duo/events/queue.jsonl"
teardown

# report:runtime event 追加失败时不得先打印 sentinel，避免屏幕/队列分裂。
setup
mkdir -p "$PROJECT/.agent-duo/events/queue.jsonl"
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_not_ok "report: queue append failure fails" \
  run_peer report --type checkpoint --status in_progress --round 4 --delta "cannot enqueue"
assert_eq "report: queue append failure no sentinel" "$(cat "$OUT")" ""
assert_contains "report: queue append failure error" "$(cat "$ERR")" 'Is a directory'
assert_ok "report: queue append failure removes rN" test ! -e "$PROJECT/.agent-duo/state/worker/r4.json"
assert_ok "report: queue append failure leaves no latest" test ! -L "$PROJECT/.agent-duo/state/worker/report.json"
teardown

# report:decision gate 的 event 入队失败时,不要留下孤儿 gate 或 opened 审计行。
setup
mkdir -p "$PROJECT/.agent-duo/events/queue.jsonl"
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_not_ok "report: decision queue append failure fails" \
  run_peer report --type request --status blocked --round 4 --needs decision --needs-detail "部署到哪里?" --needs-option staging
assert_eq "report: decision queue append failure no sentinel" "$(cat "$OUT")" ""
assert_ok "report: decision queue append failure removes rN" test ! -e "$PROJECT/.agent-duo/state/worker/r4.json"
assert_ok "report: decision queue append failure removes gate" sh -c '! ls "$1"/*.json >/dev/null 2>&1' sh "$PROJECT/.agent-duo/gates"
assert_ok "report: decision queue append failure no opened log" sh -c '! test -e "$1/.agent-duo/logs/decisions.jsonl" || ! grep -q "\"status\":\"opened\"" "$1/.agent-duo/logs/decisions.jsonl"' sh "$PROJECT"
teardown

# report:无 --needs 时 needs[] 保持为空数组(无阻塞诉求)。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "report: no needs succeeds" \
  run_peer report --type checkpoint --status in_progress --round 1 --delta "still working"
assert_contains "report: empty needs" "$(cat "$PROJECT/.agent-duo/state/worker/r1.json")" '"needs":[]'
teardown

# report:--needs <kind> 把阻塞诉求结构化写入 needs[],供 supervisor 路由(approval|decision|info|scope|discovery)。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "report: needs approval succeeds" \
  run_peer report --type request --status blocked --round 1 --needs approval --needs-detail "迁移需要写权限"
needs_report="$(cat "$PROJECT/.agent-duo/state/worker/r1.json")"
assert_contains "report: needs kind approval" "$needs_report" '"kind":"approval"'
assert_contains "report: needs detail" "$needs_report" '"detail":"迁移需要写权限"'
assert_contains "report: needs empty options" "$needs_report" '"options":[]'
assert_not_contains "report: needs not empty array" "$needs_report" '"needs":[]'
teardown

# report:--needs decision 可带多个 --needs-option 候选,按 contract §2.2 给人类决策门。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "report: needs decision succeeds" \
  run_peer report --type request --status blocked --round 1 \
    --needs decision --needs-detail "用哪个库?" --needs-option new-vm --needs-option existing-dev-vm
decision_report="$(cat "$PROJECT/.agent-duo/state/worker/r1.json")"
assert_contains "report: needs kind decision" "$decision_report" '"kind":"decision"'
assert_contains "report: needs option a" "$decision_report" '"options":["new-vm","existing-dev-vm"]'
teardown

# report:--needs decision 会创建 Human Decision Gate,并让 runtime event 指向 gate packet。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "report: needs decision opens gate" \
  run_peer report --type request --status blocked --round 1 \
    --needs decision --needs-detail "用哪个库?" --needs-option new-vm --needs-option existing-dev-vm
gate_path="$(ls "$PROJECT/.agent-duo/gates"/*.json)"
gate_id="${gate_path##*/}"; gate_id="${gate_id%.json}"
gate_json="$(cat "$gate_path")"
assert_contains "report: gate status pending" "$gate_json" '"status":"pending"'
assert_contains "report: gate agent" "$gate_json" '"agent_id":"worker"'
assert_contains "report: gate detail" "$gate_json" '"detail":"用哪个库?"'
assert_contains "report: gate options" "$gate_json" '"options":["new-vm","existing-dev-vm"]'
assert_contains "report: gate report ref" "$gate_json" '"report_ref":".agent-duo/state/worker/r1.json"'
assert_contains "report: event ref points gate" "$(cat "$PROJECT/.agent-duo/events/queue.jsonl")" "\"ref\":\".agent-duo/gates/$gate_id.json\""
assert_contains "report: decisions log opened" "$(cat "$PROJECT/.agent-duo/logs/decisions.jsonl")" '"status":"opened"'

# report:--needs-detail 仍按 codec 转义,避免下游 jq 崩。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "report: needs detail escaping succeeds" \
  run_peer report --type request --status blocked --round 1 --needs info --needs-detail $'quote " tab\t'
assert_contains "report: needs detail escaped quote" "$(cat "$PROJECT/.agent-duo/state/worker/r1.json")" 'quote \"'
teardown

# report:--needs kind 非法枚举时 fail-closed,不写 report。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_not_ok "report: invalid needs kind fails" \
  run_peer report --type request --status blocked --round 1 --needs bogus
assert_contains "report: invalid needs kind error" "$(cat "$ERR")" 'approval'
assert_ok "report: invalid needs kind writes no rN" test ! -e "$PROJECT/.agent-duo/state/worker/r1.json"
teardown

# report:给了 --needs-detail 却忘了 --needs <kind> → fail-closed,别把阻塞诉求悄悄丢成空 needs[]。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_not_ok "report: detail without kind fails" \
  run_peer report --type request --status blocked --round 1 --needs-detail "迁移需要写权限"
assert_contains "report: detail without kind error" "$(cat "$ERR")" '--needs'
assert_ok "report: detail without kind writes no rN" test ! -e "$PROJECT/.agent-duo/state/worker/r1.json"
teardown

# report:给了 --needs-option 却忘了 --needs <kind> → 同样 fail-closed。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_not_ok "report: option without kind fails" \
  run_peer report --type request --status blocked --round 1 --needs-option new-vm
assert_ok "report: option without kind writes no rN" test ! -e "$PROJECT/.agent-duo/state/worker/r1.json"
teardown

# report:blocked + needs 但无 --delta/--next 时,event summary 用 needs detail,别退化成 request/blocked。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "report: needs summary succeeds" \
  run_peer report --type request --status blocked --round 1 --needs approval --needs-detail "迁移需要写权限"
needs_event="$(cat "$PROJECT/.agent-duo/events/queue.jsonl")"
assert_contains "report: event summary uses needs detail" "$needs_event" '"summary":"迁移需要写权限"'
teardown

# report:有 needs kind 但无 detail/delta/next 时,summary 退化为 needs:<kind> 而非 request/blocked。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "report: needs kind summary succeeds" \
  run_peer report --type request --status blocked --round 1 --needs discovery
assert_contains "report: event summary uses needs kind" "$(cat "$PROJECT/.agent-duo/events/queue.jsonl")" '"summary":"needs:discovery"'

exit "$ADK_FAIL"
