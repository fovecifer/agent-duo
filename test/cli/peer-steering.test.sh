#!/usr/bin/env bash
# test/cli/peer-steering.test.sh - peer ask/reframe/checkpoint tests
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
source "$DIR/../lib/harness.sh"

# ask:stopped loop 发送前 fail-closed,不写 buffer。
setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
jq -cn '{protocol:"1",agent_id:"worker",mission:"m",non_goals:[],success_signals:[],max_rounds:1,frozen_at_round:1,status:"stopped",stop:{on_terminal:true,reason:"max_rounds",stopped_at_round:1,stopped_at:"2026-06-21T00:00:00Z"}}' \
  > "$PROJECT/.agent-duo/state/worker/loop.json"
assert_not_ok "ask: stopped loop rejected" run_peer ask worker "continue"
assert_contains "ask: stopped loop error" "$(cat "$ERR")" 'loop 已到界'
assert_ok "ask: stopped no buffer" test ! -e "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker-ask"
teardown

# ask:active 但 rounds_used>=max 时同样拒发,挡住 loopd 尚未 tick 的竞态。
setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
jq -cn '{protocol:"1",round:1,agent_id:"worker",role:"worker",type:"checkpoint",status:"in_progress",delta:"",next:"",needs:[]}' \
  > "$PROJECT/.agent-duo/state/worker/r1.json"
ln -s "r1.json" "$PROJECT/.agent-duo/state/worker/report.json"
jq -cn '{protocol:"1",agent_id:"worker",mission:"m",non_goals:[],success_signals:[],max_rounds:1,frozen_at_round:1,status:"active",stop:{on_terminal:true,reason:null,stopped_at_round:null,stopped_at:null}}' \
  > "$PROJECT/.agent-duo/state/worker/loop.json"
assert_not_ok "ask: max rounds rejected" run_peer ask worker "continue"
assert_contains "ask: max rounds error" "$(cat "$ERR")" 'reason=max_rounds'
assert_ok "ask: max rounds no buffer" test ! -e "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker-ask"
teardown

# ask:相对预算不因历史 round 误拒;发送后轮询新 report 并打印派生 summary/ref。
setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
mark_broker_ready worker
jq -cn '{protocol:"1",round:12,agent_id:"worker",role:"worker",type:"checkpoint",status:"in_progress",delta:"baseline",next:"",needs:[]}' \
  > "$PROJECT/.agent-duo/state/worker/r12.json"
ln -s "r12.json" "$PROJECT/.agent-duo/state/worker/report.json"
jq -cn '{protocol:"1",agent_id:"worker",mission:"m",non_goals:[],success_signals:[],max_rounds:8,frozen_at_round:12,status:"active",stop:{on_terminal:true,reason:null,stopped_at_round:null,stopped_at:null}}' \
  > "$PROJECT/.agent-duo/state/worker/loop.json"
TMUX_STUB_ON_SEND_REPORT_ROOT="$PROJECT" TMUX_STUB_ON_SEND_REPORT_AGENT=worker TMUX_STUB_ON_SEND_REPORT_ROUND=13 \
  TMUX_STUB_ON_SEND_REPORT_DELTA="answered ask" assert_ok "ask: historical budget sends and reads report" \
  run_peer ask worker "what changed?" --timeout 2 --interval 1
assert_eq "ask: buffer content" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker-ask")" "what changed?"
assert_contains "ask: summary printed" "$(cat "$OUT")" $'SUMMARY\tanswered ask'
assert_contains "ask: ref printed" "$(cat "$OUT")" $'REF\t.agent-duo/state/worker/r13.json'
teardown

# ask:broker 门仍独立生效;loop active 但 broker 非 ready 时拒发。
setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
jq -cn '{protocol:"1",agent_id:"worker",mission:"m",non_goals:[],success_signals:[],max_rounds:8,frozen_at_round:1,status:"active",stop:{on_terminal:true,reason:null,stopped_at_round:null,stopped_at:null}}' \
  > "$PROJECT/.agent-duo/state/worker/loop.json"
assert_not_ok "ask: broker gate still rejects" run_peer ask worker "work"
assert_contains "ask: broker gate error" "$(cat "$ERR")" 'Approval Broker'
assert_ok "ask: broker no buffer" test ! -e "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker-ask"
teardown

# ask:--force 同时越过 loop 边界与 broker 门。
setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
jq -cn '{protocol:"1",agent_id:"worker",mission:"m",non_goals:[],success_signals:[],max_rounds:1,frozen_at_round:1,status:"stopped",stop:{on_terminal:true,reason:"max_rounds",stopped_at_round:1,stopped_at:"2026-06-21T00:00:00Z"}}' \
  > "$PROJECT/.agent-duo/state/worker/loop.json"
TMUX_STUB_ON_SEND_REPORT_ROOT="$PROJECT" TMUX_STUB_ON_SEND_REPORT_AGENT=worker TMUX_STUB_ON_SEND_REPORT_ROUND=1 \
  assert_ok "ask: force sends" run_peer ask --force worker "override" --timeout 2 --interval 1
assert_eq "ask: force buffer content" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker-ask")" "override"
assert_contains "ask: force report printed" "$(cat "$OUT")" $'ROUND\t1'
teardown

# ask:无新 report 时非零退出并打印末屏兜底。
setup
mark_broker_ready worker
assert_not_ok "ask: timeout without new report" run_peer ask worker "status?" --timeout 1 --interval 1
assert_contains "ask: timeout error" "$(cat "$ERR")" '等待'
assert_contains "ask: timeout peek fallback" "$(cat "$ERR")" '目标末屏'

# reframe:发送 verb=reframe 指令,并在发送成功后写 checkpoints.jsonl 审计。
setup
mark_broker_ready worker
mkdir -p "$PROJECT/.agent-duo/state/worker"
jq -cn '{protocol:"1",round:7,agent_id:"worker",role:"worker",type:"checkpoint",status:"in_progress",delta:"",next:"",needs:[]}' \
  > "$PROJECT/.agent-duo/state/worker/r7.json"
ln -s "r7.json" "$PROJECT/.agent-duo/state/worker/report.json"
assert_ok "reframe: sends and logs" run_peer reframe worker "stop lint; finish login first"
printf '«AGENTDUO verb=reframe»\nstop lint; finish login first' > "$SCENARIO_TMP/expected-reframe-buffer"
assert_ok "reframe: buffer content" cmp -s "$SCENARIO_TMP/expected-reframe-buffer" "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker-reframe"
assert_contains "reframe: paste" "$(cat "$TMUX_STUB_LOG")" 'paste-buffer -b peer-supervisor2worker-reframe -t %2 -d -p'
checkpoint_log="$(cat "$PROJECT/.agent-duo/logs/checkpoints.jsonl")"
assert_contains "reframe: log type" "$checkpoint_log" '"type":"reframe"'
assert_contains "reframe: log agent" "$checkpoint_log" '"agent":"worker"'
assert_contains "reframe: log by" "$checkpoint_log" '"by":"supervisor"'
assert_contains "reframe: log round" "$checkpoint_log" '"round":7'
assert_contains "reframe: log message" "$checkpoint_log" '"message":"stop lint; finish login first"'
teardown

# reframe:broker 非 ready 时拒发,且不写审计日志。
setup
assert_not_ok "reframe: broker gate rejects" run_peer reframe worker "continue"
assert_contains "reframe: broker gate error" "$(cat "$ERR")" 'Approval Broker'
assert_ok "reframe: broker no buffer" test ! -e "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker-reframe"
assert_ok "reframe: broker no checkpoint log" test ! -e "$PROJECT/.agent-duo/logs/checkpoints.jsonl"
teardown

# reframe:loop stopped 或到界时窄守卫拒发;near-budget 但 active 时仍允许纠偏。
setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
jq -cn '{protocol:"1",agent_id:"worker",mission:"m",non_goals:[],success_signals:[],max_rounds:1,frozen_at_round:1,status:"stopped",stop:{on_terminal:true,reason:"max_rounds",stopped_at_round:1,stopped_at:"2026-06-21T00:00:00Z"}}' \
  > "$PROJECT/.agent-duo/state/worker/loop.json"
assert_not_ok "reframe: stopped loop rejected" run_peer reframe worker "restart"
assert_contains "reframe: stopped loop error" "$(cat "$ERR")" 'peer reframe --force'
assert_ok "reframe: stopped no buffer" test ! -e "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker-reframe"
teardown

setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
jq -cn '{protocol:"1",round:1,agent_id:"worker",role:"worker",type:"checkpoint",status:"in_progress",delta:"",next:"",needs:[]}' \
  > "$PROJECT/.agent-duo/state/worker/r1.json"
ln -s "r1.json" "$PROJECT/.agent-duo/state/worker/report.json"
jq -cn '{protocol:"1",agent_id:"worker",mission:"m",non_goals:[],success_signals:[],max_rounds:1,frozen_at_round:1,status:"active",stop:{on_terminal:true,reason:null,stopped_at_round:null,stopped_at:null}}' \
  > "$PROJECT/.agent-duo/state/worker/loop.json"
assert_not_ok "reframe: max rounds rejected" run_peer reframe worker "restart"
assert_contains "reframe: max rounds error" "$(cat "$ERR")" 'reason=max_rounds'
assert_ok "reframe: max rounds no buffer" test ! -e "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker-reframe"
teardown

setup
mark_broker_ready worker
mkdir -p "$PROJECT/.agent-duo/state/worker"
jq -cn '{protocol:"1",round:1,agent_id:"worker",role:"worker",type:"checkpoint",status:"in_progress",delta:"",next:"",needs:[]}' \
  > "$PROJECT/.agent-duo/state/worker/r1.json"
ln -s "r1.json" "$PROJECT/.agent-duo/state/worker/report.json"
jq -cn '{protocol:"1",agent_id:"worker",mission:"m",non_goals:[],success_signals:[],max_rounds:2,frozen_at_round:1,status:"active",stop:{on_terminal:true,reason:null,stopped_at_round:null,stopped_at:null}}' \
  > "$PROJECT/.agent-duo/state/worker/loop.json"
assert_ok "reframe: near budget sends" run_peer reframe worker "shrink scope"
assert_contains "reframe: near budget buffer" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker-reframe")" 'shrink scope'
teardown

# reframe:--force 同时越过 loop 窄守卫和 broker 门。
setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
jq -cn '{protocol:"1",agent_id:"worker",mission:"m",non_goals:[],success_signals:[],max_rounds:1,frozen_at_round:1,status:"stopped",stop:{on_terminal:true,reason:"max_rounds",stopped_at_round:1,stopped_at:"2026-06-21T00:00:00Z"}}' \
  > "$PROJECT/.agent-duo/state/worker/loop.json"
assert_ok "reframe: force sends" run_peer reframe --force worker "override stop"
assert_contains "reframe: force buffer" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker-reframe")" 'override stop'
assert_contains "reframe: force log" "$(cat "$PROJECT/.agent-duo/logs/checkpoints.jsonl")" '"message":"override stop"'
teardown

setup
assert_not_ok "reframe: empty message rejected" run_peer reframe worker "   "
assert_contains "reframe: empty message error" "$(cat "$ERR")" '非空消息'

# checkpoint:聚合 loop/report/task/validation,默认文本输出且纯读不写 checkpoints.jsonl。
setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
jq -cn '{protocol:"1",round:5,agent_id:"worker",role:"worker",type:"checkpoint",status:"in_progress",delta:"checked form",drift:null,next:"",needs:[]}' \
  > "$PROJECT/.agent-duo/state/worker/r5.json"
jq -cn '{protocol:"1",round:6,agent_id:"worker",role:"worker",type:"checkpoint",status:"in_progress",delta:"",drift:null,next:"",needs:[]}' \
  > "$PROJECT/.agent-duo/state/worker/r6.json"
jq -cn '{protocol:"1",round:7,agent_id:"worker",role:"worker",type:"checkpoint",status:"in_progress",delta:"",drift:"碰 non_goal: 不改 auth 流程",next:"",needs:[]}' \
  > "$PROJECT/.agent-duo/state/worker/r7.json"
ln -s "r7.json" "$PROJECT/.agent-duo/state/worker/report.json"
jq -cn '{protocol:"1",agent_id:"worker",mission:"fix login copy",non_goals:["不改 auth 流程"],success_signals:["tests pass"],detail_trap_rounds:3,max_rounds:8,frozen_at_round:5,status:"active",stop:{on_terminal:true,reason:null,stopped_at_round:null,stopped_at:null}}' \
  > "$PROJECT/.agent-duo/state/worker/loop.json"
jq -cn '{protocol:"1",agent_id:"worker",task:"login",current_step:"s2",steps:[{id:"s1",status:"done"},{id:"s2",status:"in_progress"},{id:"s3",status:"pending"}]}' \
  > "$PROJECT/.agent-duo/state/worker/task.json"
jq -cn '{protocol:"1",agent_id:"worker",round:7,status:"fail",missing_signals:["tests pass"],failed_validations:["go-test"],results:[]}' \
  > "$PROJECT/.agent-duo/state/worker/validation-r7.json"
assert_ok "checkpoint: text succeeds" run_peer checkpoint worker
checkpoint_out="$(cat "$OUT")"
assert_contains "checkpoint: header" "$checkpoint_out" $'CHECKPOINT\tworker @ r7 (loop active, used 3/8)'
assert_contains "checkpoint: mission" "$checkpoint_out" $'MISSION\tfix login copy'
assert_contains "checkpoint: recent drift" "$checkpoint_out" 'drift="碰 non_goal: 不改 auth 流程"'
assert_contains "checkpoint: steps" "$checkpoint_out" $'STEPS\t1 done, 1 in_progress, 0 blocked, 1 pending, 0 failed (current: s2)'
assert_contains "checkpoint: validation" "$checkpoint_out" $'VERIFY\tr7 fail'
assert_ok "checkpoint: does not write checkpoint log" test ! -e "$PROJECT/.agent-duo/logs/checkpoints.jsonl"
assert_ok "checkpoint: json succeeds" run_peer checkpoint worker --json
assert_eq "checkpoint: json loop detail trap" "$(jq -r '.loop.detail_trap_rounds' "$OUT")" "3"
assert_eq "checkpoint: json recent count" "$(jq -r '.recent | length' "$OUT")" "3"
assert_eq "checkpoint: json current step" "$(jq -r '.steps.current_step' "$OUT")" "s2"
teardown

# checkpoint:仅有 report 也可输出;缺 task/validation 时跳过对应块。
setup
mkdir -p "$PROJECT/.agent-duo/state/worker"
jq -cn '{protocol:"1",round:2,agent_id:"worker",role:"worker",type:"checkpoint",status:"in_progress",delta:"progress",drift:null,next:"",needs:[]}' \
  > "$PROJECT/.agent-duo/state/worker/r2.json"
ln -s "r2.json" "$PROJECT/.agent-duo/state/worker/report.json"
assert_ok "checkpoint: report only succeeds" run_peer checkpoint worker
assert_contains "checkpoint: report only header" "$(cat "$OUT")" $'CHECKPOINT\tworker @ r2 (loop none)'
assert_contains "checkpoint: report only recent" "$(cat "$OUT")" $'RECENT\tr2 in_progress'
assert_not_contains "checkpoint: report only no steps" "$(cat "$OUT")" $'STEPS\t'
assert_not_contains "checkpoint: report only no validation" "$(cat "$OUT")" $'VERIFY\t'
teardown

setup
assert_not_ok "checkpoint: no state rejected" run_peer checkpoint worker
assert_contains "checkpoint: no state error" "$(cat "$ERR")" '无可汇报的方向状态'
assert_ok "checkpoint: no state no log" test ! -e "$PROJECT/.agent-duo/logs/checkpoints.jsonl"

exit "$ADK_FAIL"
