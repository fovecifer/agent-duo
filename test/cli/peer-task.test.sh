#!/usr/bin/env bash
# test/cli/peer-task.test.sh - peer task tests
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
source "$DIR/../lib/harness.sh"

# task:init 创建 task.json 步骤账本,默认所有步骤 pending。
setup
assert_ok "task init: succeeds" run_peer task init worker --task "add tenant_id" --round 1 \
  --step s1:"schema 加 tenant_id" --step s2:"写迁移" --step s3:"更新文档"
task_json="$(cat "$PROJECT/.agent-duo/state/worker/task.json")"
assert_contains "task init: task title" "$task_json" '"task":"add tenant_id"'
assert_contains "task init: frozen round" "$task_json" '"frozen_at_round":1'
assert_contains "task init: step s1" "$task_json" '"id":"s1"'
assert_contains "task init: pending status" "$task_json" '"status":"pending"'
assert_ok "task list: succeeds" run_peer task show worker
assert_contains "task list: shows task" "$(cat "$OUT")" 'add tenant_id'
assert_ok "task next: succeeds" run_peer task next worker
assert_contains "task next: first pending" "$(cat "$OUT")" $'s1\tpending'
teardown

# task:report --step 会驱动 step 状态,并保留 done evidence 供幂等 resume 使用。
setup
assert_ok "task update setup: init succeeds" run_peer task init worker --task "add tenant_id" --round 1 \
  --step s1:"schema 加 tenant_id" --step s2:"写迁移"
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "task update: s1 in progress report" \
  run_peer report --type checkpoint --status in_progress --round 1 --step s1 --delta "started schema"
assert_contains "task update: s1 in progress" "$(cat "$PROJECT/.agent-duo/state/worker/task.json")" '"status":"in_progress"'
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "task update: s1 done report" \
  run_peer report --type checkpoint --status done --round 2 --step s1 \
    --evidence-cmd "go test ./..." --evidence-result "ok" --evidence-ref ".agent-duo/logs/worker/r2.log"
task_json="$(cat "$PROJECT/.agent-duo/state/worker/task.json")"
assert_contains "task update: s1 done" "$task_json" '"status":"done"'
assert_contains "task update: evidence kept" "$task_json" '"cmd":"go test ./..."'
assert_ok "task update: next skips done" run_peer task next worker
assert_contains "task update: next is s2" "$(cat "$OUT")" $'s2\tpending'
teardown

# task:blocked report 把当前 step 持久化为 blocked,解阻后 next 从该 step 继续。
setup
assert_ok "task blocked setup: init succeeds" run_peer task init worker --task "deploy demo" --round 1 \
  --step s1:"构建" --step s2:"部署"
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "task blocked: report succeeds" \
  run_peer report --type request --status blocked --round 1 --step s2 --needs decision --needs-detail "部署到哪里?"
assert_contains "task blocked: s2 blocked" "$(cat "$PROJECT/.agent-duo/state/worker/task.json")" '"status":"blocked"'
assert_ok "task blocked: next succeeds" run_peer task next worker
assert_contains "task blocked: next is blocked s2" "$(cat "$OUT")" $'s2\tblocked'
teardown

# task:有账本时,未知 step_ref fail-closed,避免 report 与 task.json 分裂。
setup
assert_ok "task unknown setup: init succeeds" run_peer task init worker --task "add tenant_id" --round 1 --step s1:"schema"
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_not_ok "task unknown: report rejected" \
  run_peer report --type checkpoint --status in_progress --round 1 --step s9 --delta "bad step"
assert_contains "task unknown: error" "$(cat "$ERR")" 'task.json 中不存在 step'
assert_ok "task unknown: no report written" test ! -e "$PROJECT/.agent-duo/state/worker/r1.json"
teardown

# task:ledger 未全 done/kept 时,result(done) 降级为 partial,不能静默完成整任务。
setup
assert_ok "task result setup: init succeeds" run_peer task init worker --task "add tenant_id" --round 1 \
  --step s1:"schema" --step s2:"docs"
TEST_TMUX_PANE="%2" TMUX_STUB_CODEC_TAG="7f3a" assert_ok "task result: partial downgrade succeeds" \
  run_peer report --type result --status done --round 1 --step s1 \
    --evidence-cmd "go test ./..." --evidence-result "ok" --evidence-ref ".agent-duo/logs/worker/r1.log"
assert_contains "task result: report downgraded partial" "$(cat "$PROJECT/.agent-duo/state/worker/r1.json")" '"status":"partial"'
assert_contains "task result: sentinel partial" "$(cat "$OUT")" 'status=partial'
assert_contains "task result: s1 still done" "$(cat "$PROJECT/.agent-duo/state/worker/task.json")" '"status":"done"'

exit "$ADK_FAIL"
