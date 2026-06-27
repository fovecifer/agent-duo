#!/usr/bin/env bash
# test/cli/peer-aliases.test.sh - peer aliases/help fail-closed tests
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
source "$DIR/../lib/harness.sh"

# 运行时和安装路径不应再依赖额外 Python 运行时。
PY_RUNTIME="python""3"
assert_not_contains "dependency: no Python runtime in peer/install docs" \
  "$(cat "$ROOT/bin/peer" "$ROOT/install.sh" "$ROOT/README.md" "$ROOT/README.zh-CN.md")" "$PY_RUNTIME"

# 新名词 help 可直接发现。
setup
assert_ok "help: loop noun" run_peer loop --help
assert_ok "help: agent noun" run_peer agent --help
assert_ok "help: approval noun" run_peer approval --help
assert_ok "help: verify noun" run_peer verify --help
assert_ok "help: judge noun" run_peer judge --help
assert_ok "help: gate noun" run_peer gate --help
assert_ok "help: budget noun" run_peer budget --help
assert_ok "help: task noun" run_peer task --help
assert_ok "help: report noun" run_peer report --help
teardown

# 旧命令面 fail-closed,并提示新命令。
setup
assert_not_ok "old command: peer ls removed" run_peer ls
assert_contains "old command: ls hints agent" "$(cat "$ERR")" 'peer agent ls'
assert_not_ok "old command: peer --force ls removed" run_peer --force ls
assert_contains "old command: --force ls hints agent" "$(cat "$ERR")" 'peer agent ls'
assert_not_ok "old command: peer loop <id> removed" run_peer loop worker
assert_contains "old command: loop hints show" "$(cat "$ERR")" 'peer loop show'
assert_not_ok "old command: peer task <id> removed" run_peer task worker
assert_contains "old command: task hints show" "$(cat "$ERR")" 'peer task show'
assert_not_ok "old command: peer approvals removed" run_peer approvals
assert_contains "old command: approvals hints approval" "$(cat "$ERR")" 'peer approval ls'
assert_not_ok "old command: peer approve removed" run_peer approve abc
assert_contains "old command: approve hints approval" "$(cat "$ERR")" 'peer approval approve'
assert_not_ok "old command: peer deny removed" run_peer deny abc
assert_contains "old command: deny hints approval" "$(cat "$ERR")" 'peer approval deny'
assert_not_ok "old command: peer broker-check removed" run_peer broker-check worker
assert_contains "old command: broker-check hints approval" "$(cat "$ERR")" 'peer approval check'
assert_not_ok "old command: peer broker-status removed" run_peer broker-status worker
assert_contains "old command: broker-status hints approval" "$(cat "$ERR")" 'peer approval status'
TEST_TMUX_PANE="%2" assert_not_ok "old command: report verdict removed" \
  run_peer report --type result --status done --round 1 --verdict approve --target-ref worker@3
assert_contains "old command: report verdict hints judge" "$(cat "$ERR")" 'peer judge'
assert_ok "old command: report verdict writes no file" test ! -e "$PROJECT/.agent-duo/state/worker/r1.json"
TEST_TMUX_PANE="%2" assert_not_ok "old command: --force report verdict removed" \
  run_peer --force report --type result --status done --round 1 --verdict approve --target-ref worker@3
assert_contains "old command: --force report verdict hints judge" "$(cat "$ERR")" 'peer judge'
assert_ok "old command: --force report verdict writes no file" test ! -e "$PROJECT/.agent-duo/state/worker/r1.json"
teardown

exit "$ADK_FAIL"
