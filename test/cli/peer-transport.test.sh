#!/usr/bin/env bash
# test/cli/peer-transport.test.sh - peer transport/status/peek/tell/wait/esc tests
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
source "$DIR/../lib/harness.sh"

tmux_capture_pane="capture""-pane"

# 身份:从 $TMUX_PANE 的 @agent_id 自识别(而非 AGENT_NAME)。
setup
TEST_TMUX_PANE="%1" assert_ok "identity: self from tmux pane" run_peer status
assert_contains "identity: prints self id" "$(cat "$OUT")" 'supervisor'
teardown

# 身份:Codex/Claude 工具子进程可能丢失 TMUX_PANE,此时回退启动注入的 AGENT_DUO_AGENT_ID。
setup
assert_ok "identity: self from agent id env fallback" run_peer_with_agent_id_without_pane status
assert_contains "identity: env fallback prints self id" "$(cat "$OUT")" '我是: supervisor'
teardown

setup
assert_ok "identity: env fallback marks self in agent ls" run_peer_with_agent_id_without_pane agent ls
assert_contains "identity: env fallback self mark" "$(cat "$OUT")" '*   supervisor'
teardown

# status:命令分发与默认目标展示。
setup
assert_ok "status: succeeds" run_peer status
assert_contains "status: prints identity" "$(cat "$OUT")" '我是: supervisor'
teardown

# status:打印自身与目标。
setup
assert_contains "status: prints target pane" "$(run_peer status; cat "$OUT")" '%2'
teardown

# 寻址:peek 无 id,正好两人 → 默认另一个(worker=%2)。
setup
assert_ok "addr: peek default other" run_peer peek 7
assert_contains "addr: peek default captures %2" "$(cat "$TMUX_STUB_LOG")" "$tmux_capture_pane -p -J -t %2 -S -7"
teardown

# 寻址:peek 显式 id → 路由到该 pane。
setup
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%2\tworker\tworker\tcodex\n%%3\treviewer\treviewer\tclaude\n' > "$TMUX_STUB_REGISTRY"
assert_ok "addr: peek explicit id" run_peer peek reviewer 9
assert_contains "addr: peek explicit captures %3" "$(cat "$TMUX_STUB_LOG")" "$tmux_capture_pane -p -J -t %3 -S -9"
teardown

# 寻址:≥3 人且省略 id → 报错要求指名。
setup
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%2\tworker\tworker\tcodex\n%%3\treviewer\treviewer\tclaude\n' > "$TMUX_STUB_REGISTRY"
assert_not_ok "addr: ambiguous rejected" run_peer peek
assert_contains "addr: ambiguous error" "$(cat "$ERR")" '请指定目标'
teardown

# 寻址:未知 id → 报错。
setup
assert_not_ok "addr: unknown id rejected" run_peer peek nobody
assert_contains "addr: unknown id error" "$(cat "$ERR")" "找不到 agent 'nobody'"
teardown

# tell:单行参数走 tmux buffer + bracketed paste + Enter。
setup
AGENT_DUO_NO_BROKER_GATE=1 assert_ok "tell: arg succeeds" run_peer tell "hello codex"
assert_eq "tell: arg buffer content" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker")" "hello codex"
assert_contains "tell: load-buffer called" "$(cat "$TMUX_STUB_LOG")" 'load-buffer -b peer-supervisor2worker -'
assert_contains "tell: paste-buffer called" "$(cat "$TMUX_STUB_LOG")" 'paste-buffer -b peer-supervisor2worker -t %2 -d -p'
assert_contains "tell: enter sent" "$(cat "$TMUX_STUB_LOG")" 'send-keys -t %2 Enter'
teardown

# tell:显式 id 首参(已注册)→ 路由该 pane,其余为消息。
setup
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%2\tworker\tworker\tcodex\n%%3\treviewer\treviewer\tclaude\n' > "$TMUX_STUB_REGISTRY"
AGENT_DUO_NO_BROKER_GATE=1 assert_ok "tell: explicit id routes" run_peer tell reviewer "please review"
assert_eq "tell: explicit id buffer" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-supervisor2reviewer")" "please review"
assert_contains "tell: explicit id paste" "$(cat "$TMUX_STUB_LOG")" 'paste-buffer -b peer-supervisor2reviewer -t %3 -d -p'
teardown

# tell:首参不是已注册 id → 整句当消息,两人默认发给另一个。
setup
AGENT_DUO_NO_BROKER_GATE=1 assert_ok "tell: plain message default other" run_peer tell "hello there"
assert_eq "tell: plain buffer" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker")" "hello there"
teardown

# tell:stdin + 显式 id(stdin 形式下唯一位置参数即目标 id)。
setup
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%2\tworker\tworker\tcodex\n%%3\treviewer\treviewer\tclaude\n' > "$TMUX_STUB_REGISTRY"
AGENT_DUO_NO_BROKER_GATE=1 run_peer tell reviewer <<< $'multi\nline'
printf 'multi\nline\n' > "$SCENARIO_TMP/expected"
assert_ok "tell: stdin with id buffer" cmp -s "$SCENARIO_TMP/expected" "$TMUX_STUB_BUFFER_DIR/peer-supervisor2reviewer"
teardown

# tell:普通 TUI 输入提示符和普通 no/yes 文本不应被误判为权限弹窗。
setup
AGENT_DUO_NO_BROKER_GATE=1 TMUX_STUB_CAPTURE_MODE=normal_prompt assert_ok "tell: normal prompt screen succeeds" run_peer tell "ordinary"
assert_eq "tell: normal prompt buffer content" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker")" "ordinary"
assert_contains "tell: normal prompt enter" "$(cat "$TMUX_STUB_LOG")" 'send-keys -t %2 Enter'
teardown

# tell:旧 scrollback 里的权限提示不应阻塞当前可见的正常输入提示。
setup
AGENT_DUO_NO_BROKER_GATE=1 TMUX_STUB_CAPTURE_MODE=stale_prompt assert_ok "tell: stale prompt history ignored" run_peer tell "after trust"
assert_eq "tell: stale prompt buffer content" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker")" "after trust"
assert_contains "tell: stale prompt uses visible capture" "$(cat "$TMUX_STUB_LOG")" 'capture-pane -p -J -t %2'
assert_contains "tell: stale prompt enter" "$(cat "$TMUX_STUB_LOG")" 'send-keys -t %2 Enter'
teardown

# tell:对方疑似权限弹窗时拒绝发送,不写 buffer、不粘贴、不回车。
setup
AGENT_DUO_NO_BROKER_GATE=1 TMUX_STUB_CAPTURE_MODE=prompt assert_exit_code "tell: prompt screen exits 3" 3 run_peer tell "danger"
assert_contains "tell: prompt error" "$(cat "$ERR")" '疑似正在等待权限确认'
assert_ok "tell: prompt no buffer" test ! -e "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker"
assert_not_contains "tell: prompt no paste" "$(cat "$TMUX_STUB_LOG")" 'paste-buffer'
assert_not_contains "tell: prompt no enter" "$(cat "$TMUX_STUB_LOG")" 'send-keys -t %2 Enter'
teardown

# tell:--force 跳过弹窗检测并按原流程发送。
setup
TMUX_STUB_CAPTURE_MODE=prompt assert_ok "tell: force sends despite prompt" run_peer tell --force "forced"
assert_eq "tell: force buffer content" "$(cat "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker")" "forced"
assert_contains "tell: force notice" "$(cat "$ERR")" '已跳过对方权限弹窗检测'
assert_contains "tell: force paste" "$(cat "$TMUX_STUB_LOG")" 'paste-buffer -b peer-supervisor2worker -t %2 -d -p'
assert_contains "tell: force enter" "$(cat "$TMUX_STUB_LOG")" 'send-keys -t %2 Enter'
teardown

# tell:stdin 多行保持原文进入 buffer。
setup
AGENT_DUO_NO_BROKER_GATE=1 assert_ok "tell: stdin succeeds" run_peer tell <<< $'line 1\n`quoted`'
printf 'line 1\n`quoted`\n' > "$SCENARIO_TMP/expected-stdin-buffer"
assert_ok "tell: stdin buffer content" cmp -s "$SCENARIO_TMP/expected-stdin-buffer" "$TMUX_STUB_BUFFER_DIR/peer-supervisor2worker"
teardown

# esc:向目标 pane 发送 Escape。
setup
assert_ok "esc: succeeds" run_peer esc
assert_contains "esc: escape sent" "$(cat "$TMUX_STUB_LOG")" 'send-keys -t %2 Escape'
teardown

# esc:对方疑似权限弹窗时拒绝发送 Escape。
setup
TMUX_STUB_CAPTURE_MODE=prompt assert_exit_code "esc: prompt screen exits 3" 3 run_peer esc
assert_contains "esc: prompt error" "$(cat "$ERR")" '疑似正在等待权限确认'
assert_not_contains "esc: prompt no escape" "$(cat "$TMUX_STUB_LOG")" 'send-keys -t %2 Escape'
teardown

# esc:PEER_FORCE=1 跳过检测并发送 Escape。
setup
TMUX_STUB_CAPTURE_MODE=prompt TEST_PEER_FORCE=1 assert_ok "esc: force env sends despite prompt" run_peer esc
assert_contains "esc: force notice" "$(cat "$ERR")" '已跳过对方权限弹窗检测'
assert_contains "esc: force escape" "$(cat "$TMUX_STUB_LOG")" 'send-keys -t %2 Escape'
teardown

# esc:--force(作为参数)跳过弹窗检测并发送 Escape。
setup
TMUX_STUB_CAPTURE_MODE=prompt assert_ok "esc: force arg sends despite prompt" run_peer esc --force
assert_contains "esc: force arg notice" "$(cat "$ERR")" '已跳过对方权限弹窗检测'
assert_contains "esc: force arg escape" "$(cat "$TMUX_STUB_LOG")" 'send-keys -t %2 Escape'
teardown

# wait:连续两次稳定采样才成功。
setup
assert_ok "wait: stable after repeated samples" run_peer wait 3 1 2
assert_eq "wait: sampled initial plus two stable checks" "$(cat "$TMUX_STUB_CAPTURE_COUNT")" "3"
assert_contains "wait: success message" "$(cat "$OUT")" '连续 2 次采样一致'
teardown

# wait:输出一直变化时超时。
setup
TMUX_STUB_CAPTURE_MODE=changing assert_not_ok "wait: times out on changing output" run_peer wait 1 1 2
assert_contains "wait: timeout message" "$(cat "$ERR")" '等待超时(1s)'

# wait --round:等待指定 round 的 sentinel,不再靠屏幕稳定猜测回合边界。
setup
TMUX_STUB_SENTINEL='«AGENTDUO:7f3a» agent_id=worker round=7 type=checkpoint status=in_progress file=.agent-duo/state/worker/r7.json sha=abc ts=2026-06-17T00:00:00Z'
TMUX_STUB_CAPTURE_MODE=sentinel assert_ok "wait round: sentinel found" run_peer wait worker --round 7
assert_contains "wait round: success message" "$(cat "$OUT")" '已看到 round=7 的 sentinel'
teardown

# wait --round:指定回合一直没出现时超时。
setup
TMUX_STUB_SENTINEL='«AGENTDUO:7f3a» agent_id=worker round=6 type=checkpoint status=in_progress file=.agent-duo/state/worker/r6.json sha=abc ts=2026-06-17T00:00:00Z'
TMUX_STUB_CAPTURE_MODE=sentinel assert_not_ok "wait round: timeout" run_peer wait worker --round 7 --timeout 1 --interval 1
assert_contains "wait round: timeout message" "$(cat "$ERR")" '等待 round=7 的 sentinel 超时(1s)'
teardown

# wait --round:同 round 但 agent_id 不同不能误判成功。
setup
TMUX_STUB_SENTINEL='«AGENTDUO:7f3a» agent_id=reviewer round=7 type=checkpoint status=in_progress file=.agent-duo/state/reviewer/r7.json sha=abc ts=2026-06-17T00:00:00Z'
TMUX_STUB_CAPTURE_MODE=sentinel assert_not_ok "wait round: wrong agent ignored" run_peer wait worker --round 7 --timeout 1 --interval 1
assert_contains "wait round: wrong agent timeout" "$(cat "$ERR")" '等待 round=7 的 sentinel 超时(1s)'
teardown

# wait --round:字段必须精确匹配,不能把 round=70/worker2 当成目标。
setup
TMUX_STUB_SENTINEL='«AGENTDUO:7f3a» agent_id=worker round=70 type=checkpoint status=in_progress file=.agent-duo/state/worker/r70.json sha=abc ts=2026-06-17T00:00:00Z'
TMUX_STUB_CAPTURE_MODE=sentinel assert_not_ok "wait round: round boundary ignored" run_peer wait worker --round 7 --timeout 1 --interval 1
assert_contains "wait round: round boundary timeout" "$(cat "$ERR")" '等待 round=7 的 sentinel 超时(1s)'
teardown

setup
TMUX_STUB_SENTINEL='«AGENTDUO:7f3a» agent_id=worker2 round=7 type=checkpoint status=in_progress file=.agent-duo/state/worker2/r7.json sha=abc ts=2026-06-17T00:00:00Z'
TMUX_STUB_CAPTURE_MODE=sentinel assert_not_ok "wait round: agent boundary ignored" run_peer wait worker --round 7 --timeout 1 --interval 1
assert_contains "wait round: agent boundary timeout" "$(cat "$ERR")" '等待 round=7 的 sentinel 超时(1s)'
teardown

setup
TMUX_STUB_CODEC_TAG=expected
TMUX_STUB_SENTINEL='«AGENTDUO:other» agent_id=worker round=7 type=checkpoint status=in_progress file=.agent-duo/state/worker/r7.json sha=abc ts=2026-06-17T00:00:00Z'
TMUX_STUB_CAPTURE_MODE=sentinel assert_not_ok "wait round: tag mismatch ignored" run_peer wait worker --round 7 --timeout 1 --interval 1
assert_contains "wait round: tag mismatch timeout" "$(cat "$ERR")" '等待 round=7 的 sentinel 超时(1s)'
teardown

# 非法输入。
setup
assert_not_ok "invalid: missing identity" run_peer_without_agent status
assert_contains "invalid: missing identity error" "$(cat "$ERR")" '无法确定自身身份'
teardown

setup
assert_not_ok "invalid: bad peek lines" run_peer peek worker nope
assert_contains "invalid: bad peek error" "$(cat "$ERR")" '行数必须是正整数'
teardown

setup
assert_not_ok "invalid: bad wait timeout" run_peer wait worker nope
assert_contains "invalid: bad wait error" "$(cat "$ERR")" '超时秒数必须是正整数'

# 缺失 session:peek/status 都报错。
setup
TMUX_STUB_HAS_SESSION=0 assert_not_ok "missing session: peek fails" run_peer peek
assert_contains "missing session: peek error" "$(cat "$ERR")" "tmux 会话 'agents' 不存在"
teardown

setup
TMUX_STUB_HAS_SESSION=0 assert_not_ok "missing session: status fails" run_peer status
assert_contains "missing session: status error" "$(cat "$ERR")" "tmux 会话 'agents' 不存在"

exit "$ADK_FAIL"
