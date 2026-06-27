#!/usr/bin/env bash
# test/cli/peer-loop.test.sh - peer loop tests
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
source "$DIR/../lib/harness.sh"

# loop:init 创建 loop.json,默认 frozen_at_round 取当前最新 report 轮次。
setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
jq -cn '{protocol:"1",round:12,agent_id:"worker",role:"worker",type:"checkpoint",status:"in_progress",delta:"",next:"",needs:[]}' \
  > "$PROJECT/.agent-duo/state/worker/r12.json"
ln -s "r12.json" "$PROJECT/.agent-duo/state/worker/report.json"
assert_ok "loop init: succeeds" run_peer loop init worker --mission "finish login copy" --max-rounds 8 \
  --non-goal "no auth refactor" --success "tests pass"
loop_json="$(cat "$PROJECT/.agent-duo/state/worker/loop.json")"
assert_contains "loop init: mission" "$loop_json" '"mission":"finish login copy"'
assert_contains "loop init: max rounds" "$loop_json" '"max_rounds":8'
assert_contains "loop init: frozen from report" "$loop_json" '"frozen_at_round":12'
assert_contains "loop init: non goal" "$loop_json" '"non_goals":["no auth refactor"]'
assert_contains "loop init: success" "$loop_json" '"success_signals":["tests pass"]'
assert_contains "loop init: default validation empty" "$loop_json" '"validation":[]'
assert_contains "loop init: default detail trap" "$loop_json" '"detail_trap_rounds":3'
assert_ok "loop print: succeeds" run_peer loop show worker
assert_contains "loop print: rounds used" "$(cat "$OUT")" $'ROUNDS_USED\t1'
assert_contains "loop print: remaining" "$(cat "$OUT")" $'REMAINING\t7'
assert_contains "loop print: detail trap rounds" "$(cat "$OUT")" $'DETAIL_TRAP_ROUNDS\t3'
teardown

# loop:init detail-trap 阈值可配置,非法值 fail-closed。
setup
assert_ok "loop init detail trap: succeeds" run_peer loop init worker --mission "avoid drift" --max-rounds 5 --detail-trap-rounds 4
assert_contains "loop init detail trap: value" "$(cat "$PROJECT/.agent-duo/state/worker/loop.json")" '"detail_trap_rounds":4'
teardown

setup
assert_not_ok "loop init detail trap: bad value rejected" run_peer loop init worker --mission "avoid drift" --max-rounds 5 --detail-trap-rounds 0
assert_contains "loop init detail trap: bad value error" "$(cat "$ERR")" '--detail-trap-rounds'
assert_ok "loop init detail trap: no file on bad value" test ! -e "$PROJECT/.agent-duo/state/worker/loop.json"
teardown

# loop:init validation 命令写入 contract,并把 validation id 映射到 success_signals。
setup
assert_ok "loop init validation: succeeds" run_peer loop init worker --mission "ship with tests" --max-rounds 4 \
  --success "tests pass" --verify go-test:"printf ok" \
  --verify-satisfies go-test:"tests pass" --verify-timeout go-test:5
loop_json="$(cat "$PROJECT/.agent-duo/state/worker/loop.json")"
assert_contains "loop init validation: id" "$loop_json" '"id":"go-test"'
assert_contains "loop init validation: cmd" "$loop_json" '"cmd":"printf ok"'
assert_contains "loop init validation: timeout" "$loop_json" '"timeout_seconds":5'
assert_contains "loop init validation: satisfies" "$loop_json" '"satisfies":["tests pass"]'
assert_ok "loop init validation: print succeeds" run_peer loop show worker
assert_contains "loop init validation: print" "$(cat "$OUT")" $'VERIFY\tgo-test:printf ok'
teardown

# loop:init validation 省略 satisfies/timeout 时,bash 3.2 空数组分支不崩溃,并使用默认值。
setup
assert_ok "loop init validation default: succeeds" run_peer loop init worker --mission "ship with default validation" --max-rounds 4 \
  --verify go-test:"echo hi"
loop_json="$(cat "$PROJECT/.agent-duo/state/worker/loop.json")"
assert_contains "loop init validation default: timeout" "$loop_json" '"timeout_seconds":120'
assert_contains "loop init validation default: satisfies id" "$loop_json" '"satisfies":["go-test"]'
teardown

# loop:init review 写入 acceptance.reviews,role 允许点号,坏格式 fail-closed。
setup
assert_ok "loop init review: succeeds" run_peer loop init worker --mission "ship with review" --max-rounds 4 \
  --judge reviewer.v2:request_changes,reject --judge evaluator:fail
loop_json="$(cat "$PROJECT/.agent-duo/state/worker/loop.json")"
assert_contains "loop init review: role with dot" "$loop_json" '"role":"reviewer.v2"'
assert_contains "loop init review: veto list" "$loop_json" '"veto_on":["request_changes","reject"]'
assert_ok "loop init review: print succeeds" run_peer loop show worker
assert_contains "loop init review: print" "$(cat "$OUT")" $'JUDGE\treviewer.v2:request_changes,reject; evaluator:fail'
teardown

setup
assert_not_ok "loop init review: bad role rejected" run_peer loop init worker --mission "ship" --max-rounds 4 --judge '../reviewer:reject'
assert_contains "loop init review: bad role error" "$(cat "$ERR")" '--judge'
assert_ok "loop init review: bad role no file" test ! -e "$PROJECT/.agent-duo/state/worker/loop.json"
teardown

setup
assert_not_ok "loop init review: empty veto rejected" run_peer loop init worker --mission "ship" --max-rounds 4 --judge reviewer:reject,
assert_contains "loop init review: empty veto error" "$(cat "$ERR")" '空 verdict'
assert_ok "loop init review: empty veto no file" test ! -e "$PROJECT/.agent-duo/state/worker/loop.json"
teardown

# loop:init 无 report 时 frozen_at_round 默认 1,且已存在/非法输入 fail-closed。
setup
assert_ok "loop init default no report: succeeds" run_peer loop init worker --mission "do work" --max-rounds 3
assert_contains "loop init default no report: frozen one" "$(cat "$PROJECT/.agent-duo/state/worker/loop.json")" '"frozen_at_round":1'
assert_not_ok "loop init: existing rejected" run_peer loop init worker --mission "again" --max-rounds 3
assert_contains "loop init: existing error" "$(cat "$ERR")" 'loop.json 已存在'
teardown

setup
assert_not_ok "loop init: missing mission rejected" run_peer loop init worker --max-rounds 3
assert_contains "loop init: missing mission error" "$(cat "$ERR")" '--mission'
assert_not_ok "loop init: bad max rejected" run_peer loop init worker --mission "do work" --max-rounds nope
assert_contains "loop init: bad max error" "$(cat "$ERR")" '--max-rounds'
assert_not_ok "loop init: bad validation rejected" run_peer loop init worker --mission "do work" --max-rounds 3 --verify bad
assert_contains "loop init: bad validation error" "$(cat "$ERR")" 'id:value'
assert_not_ok "loop init: unknown validation signal rejected" run_peer loop init worker --mission "do work" --max-rounds 3 --verify go-test:"true" --verify-satisfies lint:"tests pass"
assert_contains "loop init: unknown validation signal error" "$(cat "$ERR")" '不存在的 verify id'
teardown

# loop:reset 在当前 report 轮次重新冻结预算,只重写 loop.json 的边界/stop 状态。
setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
jq -cn '{protocol:"1",round:8,agent_id:"worker",role:"worker",type:"checkpoint",status:"in_progress",delta:"",next:"",needs:[]}' \
  > "$PROJECT/.agent-duo/state/worker/r8.json"
ln -s "r8.json" "$PROJECT/.agent-duo/state/worker/report.json"
jq -cn '{protocol:"1",agent_id:"worker",mission:"m",non_goals:["n"],success_signals:["s"],validation:[{id:"go-test",cmd:"true",timeout_seconds:5,satisfies:["s"]}],detail_trap_rounds:4,max_rounds:3,frozen_at_round:1,status:"stopped",stop:{on_terminal:true,reason:"max_rounds",stopped_at_round:3,stopped_at:"2026-06-21T00:00:00Z"}}' \
  > "$PROJECT/.agent-duo/state/worker/loop.json"
assert_ok "loop reset: succeeds" run_peer loop reset worker --max-rounds 5
loop_json="$(cat "$PROJECT/.agent-duo/state/worker/loop.json")"
assert_contains "loop reset: active" "$loop_json" '"status":"active"'
assert_contains "loop reset: frozen current round" "$loop_json" '"frozen_at_round":8'
assert_contains "loop reset: max override" "$loop_json" '"max_rounds":5'
assert_contains "loop reset: stop cleared" "$loop_json" '"reason":null'
assert_contains "loop reset: validation preserved" "$loop_json" '"validation":[{"id":"go-test"'
assert_contains "loop reset: detail preserved" "$loop_json" '"detail_trap_rounds":4'
assert_not_contains "loop reset: no terminal warning" "$(cat "$ERR")" '下一 tick'
teardown

setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
jq -cn '{protocol:"1",agent_id:"worker",mission:"m",non_goals:[],success_signals:[],validation:[],max_rounds:3,frozen_at_round:4,status:"stopped",stop:{on_terminal:true,reason:"max_rounds",stopped_at_round:6,stopped_at:"2026-06-21T00:00:00Z"}}' \
  > "$PROJECT/.agent-duo/state/worker/loop.json"
assert_ok "loop reset: no report keeps frozen" run_peer loop reset worker
loop_json="$(cat "$PROJECT/.agent-duo/state/worker/loop.json")"
assert_contains "loop reset: no report frozen old" "$loop_json" '"frozen_at_round":4'
assert_contains "loop reset: no max override keeps old" "$loop_json" '"max_rounds":3'
teardown

setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
jq -cn '{protocol:"1",agent_id:"worker",mission:"m",non_goals:[],success_signals:[],validation:[],max_rounds:3,frozen_at_round:1,status:"active",stop:{on_terminal:true,reason:null,stopped_at_round:null,stopped_at:null}}' \
  > "$PROJECT/.agent-duo/state/worker/loop.json"
assert_not_ok "loop reset: bad max rejected" run_peer loop reset worker --max-rounds 0
assert_contains "loop reset: bad max error" "$(cat "$ERR")" '--max-rounds'
teardown

setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
jq -cn '{protocol:"1",agent_id:"worker",mission:"m",non_goals:[],success_signals:[],validation:[],max_rounds:3,frozen_at_round:1,status:"active",stop:{on_terminal:true,reason:null,stopped_at_round:null,stopped_at:null}}' \
  > "$PROJECT/.agent-duo/state/worker/loop.json"
assert_not_ok "loop reset: missing max rejected" run_peer loop reset worker --max-rounds
assert_contains "loop reset: missing max usage" "$(cat "$ERR")" '用法: peer loop reset'
teardown

setup
assert_not_ok "loop reset: missing loop rejected" run_peer loop reset worker
assert_contains "loop reset: missing loop error" "$(cat "$ERR")" '没有 loop.json'
teardown

setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
jq -cn '{protocol:"1",round:9,agent_id:"worker",role:"worker",type:"checkpoint",status:"failed",delta:"",next:"",needs:[]}' \
  > "$PROJECT/.agent-duo/state/worker/r9.json"
ln -s "r9.json" "$PROJECT/.agent-duo/state/worker/report.json"
jq -cn '{protocol:"1",agent_id:"worker",mission:"m",non_goals:[],success_signals:[],validation:[],max_rounds:3,frozen_at_round:1,status:"stopped",stop:{on_terminal:true,reason:"failed",stopped_at_round:9,stopped_at:"2026-06-21T00:00:00Z"}}' \
  > "$PROJECT/.agent-duo/state/worker/loop.json"
assert_ok "loop reset: terminal report warns" run_peer loop reset worker
assert_contains "loop reset: terminal warning" "$(cat "$ERR")" '下一 tick 会按同一 report 再次停止'
assert_contains "loop reset: terminal reframe hint" "$(cat "$ERR")" 'peer reframe --force worker'

exit "$ADK_FAIL"
