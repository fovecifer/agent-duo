#!/usr/bin/env bash
# test/cli/peer-gate.test.sh - peer gate tests
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
source "$DIR/../lib/harness.sh"

# gate resolve:把 human gate 决策格式化为下行 decision verb。
setup
assert_ok "gate resolve: sends decision" run_peer gate resolve --choice staging-db --note "use staging"
printf '«AGENTDUO verb=decision choice=staging-db»\nuse staging' > "$SCENARIO_TMP/expected-gate-buffer"
assert_ok "gate resolve: buffer content" cmp -s "$SCENARIO_TMP/expected-gate-buffer" "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker-gate"
assert_contains "gate resolve: paste" "$(cat "$TMUX_STUB_LOG")" 'paste-buffer -b peer-supervisor2worker-gate -t %2 -d -p'
assert_contains "gate resolve: enter" "$(cat "$TMUX_STUB_LOG")" 'send-keys -t %2 Enter'
teardown

# gate resolve:存在唯一 pending gate 时,省略 id 会解析该 gate、更新 packet 与 decisions log,再发给原 worker。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "gate resolve pending setup report" \
  run_peer report --type request --status blocked --round 1 \
    --needs decision --needs-detail "用哪个库?" --needs-option new-vm --needs-option existing-dev-vm
gate_path="$(ls "$PROJECT/.agent-duo/gates"/*.json)"
assert_ok "gate resolve: resolves pending gate" run_peer gate resolve --choice existing-dev-vm --note "use dev"
gate_json="$(cat "$gate_path")"
assert_contains "gate resolve: packet resolved" "$gate_json" '"status":"resolved"'
assert_contains "gate resolve: choice recorded" "$gate_json" '"choice":"existing-dev-vm"'
assert_contains "gate resolve: note recorded" "$gate_json" '"note":"use dev"'
assert_contains "gate resolve: log resolved" "$(cat "$PROJECT/.agent-duo/logs/decisions.jsonl")" '"status":"resolved"'
printf '«AGENTDUO verb=decision choice=existing-dev-vm»\nuse dev' > "$SCENARIO_TMP/expected-resolved-gate-buffer"
assert_ok "gate resolve: pending buffer content" cmp -s "$SCENARIO_TMP/expected-resolved-gate-buffer" "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker-gate"
teardown

# gate resolve <target-id>:target 恰有唯一 pending gate 时,也要 resolve 记录,不能只裸发 decision。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "gate resolve target setup report" \
  run_peer report --type request --status blocked --round 1 \
    --needs decision --needs-detail "部署到哪里?" --needs-option staging --needs-option prod
gate_path="$(ls "$PROJECT/.agent-duo/gates"/*.json)"
assert_ok "gate resolve: target id resolves pending gate" run_peer gate resolve worker --choice staging --note "staging only"
gate_json="$(cat "$gate_path")"
assert_contains "gate resolve: target packet resolved" "$gate_json" '"status":"resolved"'
assert_contains "gate resolve: target choice recorded" "$gate_json" '"choice":"staging"'
assert_contains "gate resolve: target log resolved" "$(cat "$PROJECT/.agent-duo/logs/decisions.jsonl")" '"status":"resolved"'
printf '«AGENTDUO verb=decision choice=staging»\nstaging only' > "$SCENARIO_TMP/expected-target-gate-buffer"
assert_ok "gate resolve: target buffer content" cmp -s "$SCENARIO_TMP/expected-target-gate-buffer" "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker-gate"
teardown

# gate resolve:多个 pending gate 时省略 id 会 fail-closed,避免把人的选择发错 gate。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "gate resolve multi setup r1" \
  run_peer report --type request --status blocked --round 1 --needs decision --needs-detail "部署到哪里?"
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "gate resolve multi setup r2" \
  run_peer report --type request --status blocked --round 2 --needs decision --needs-detail "买哪种机器?"
assert_not_ok "gate resolve: ambiguous pending rejected" run_peer gate resolve --choice staging
assert_contains "gate resolve: ambiguous pending error" "$(cat "$ERR")" '多个 pending gate'
assert_not_contains "gate resolve: ambiguous no paste" "$(cat "$TMUX_STUB_LOG")" 'paste-buffer'
teardown

# gate open:Supervisor 可手动创建 Decision Packet,落 gates/ 与 decisions.jsonl。
setup
assert_ok "gate open: succeeds" run_peer gate open worker --title "选择部署目标" --detail "需要公网回调地址" --option new-vm --option existing-dev-vm
gate_path="$(ls "$PROJECT/.agent-duo/gates"/*.json)"
gate_json="$(cat "$gate_path")"
assert_contains "gate open: status pending" "$gate_json" '"status":"pending"'
assert_contains "gate open: target worker" "$gate_json" '"agent_id":"worker"'
assert_contains "gate open: title" "$gate_json" '"title":"选择部署目标"'
assert_contains "gate open: detail" "$gate_json" '"detail":"需要公网回调地址"'
assert_contains "gate open: options" "$gate_json" '"options":["new-vm","existing-dev-vm"]'
assert_contains "gate open: decisions log opened" "$(cat "$PROJECT/.agent-duo/logs/decisions.jsonl")" '"status":"opened"'
teardown

# gate resolve:choice 是结构化字段，含空白的解释放到 --note。
setup
assert_not_ok "gate resolve: rejects spaced choice" run_peer gate resolve --choice "staging db"
assert_contains "gate resolve: rejects spaced choice error" "$(cat "$ERR")" '--choice 只能包含'
teardown

# gate:默认列出 pending Human Decision Gate。
setup
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "gate list setup report" \
  run_peer report --type request --status blocked --round 1 --needs decision --needs-detail "部署到哪里?" --needs-option staging
assert_ok "gate list: succeeds" run_peer gate ls
assert_contains "gate list: has header" "$(cat "$OUT")" 'ID'
assert_contains "gate list: shows pending" "$(cat "$OUT")" 'pending'
assert_contains "gate list: shows title" "$(cat "$OUT")" '部署到哪里?'
assert_contains "gate list: shows options" "$(cat "$OUT")" 'staging'
teardown

exit "$ADK_FAIL"
