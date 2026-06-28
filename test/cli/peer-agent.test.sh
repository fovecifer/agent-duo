#!/usr/bin/env bash
# test/cli/peer-agent.test.sh - peer agent tests
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
source "$DIR/../lib/harness.sh"

tmux_new_window="new""-window"

# agent ls:列出 registry 内所有 agent;未注册 pane 显示 (unregistered)。
setup
assert_ok "agent ls: succeeds" run_peer agent ls
assert_contains "ls: shows supervisor" "$(cat "$OUT")" 'supervisor'
assert_contains "ls: shows worker"     "$(cat "$OUT")" 'worker'
assert_contains "ls: shows provider"   "$(cat "$OUT")" 'codex'
assert_contains "ls: marks self"       "$(cat "$OUT")" '*'   # 自己一行带标记
teardown

# ls:未注册 pane(无 @agent_id)显示占位。
setup
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%7\t\t\t\n' > "$TMUX_STUB_REGISTRY"
assert_ok "ls: unregistered succeeds" run_peer agent ls
assert_contains "ls: unregistered marked" "$(cat "$OUT")" '(unregistered)'
teardown

# add:新建 window、写三个 @agent_* 标签、通过 launch.sh 启动 provider、打印 id。
setup
TMUX_STUB_NEW_PANE="%5" assert_ok "add: succeeds" run_peer agent add --provider codex --role worker --id helper
assert_contains "add: new window called" "$(cat "$TMUX_STUB_LOG")" "$tmux_new_window"
assert_contains "add: tags id"       "$(cat "$TMUX_STUB_LOG")" 'set-option -p -t %5 @agent_id helper'
assert_contains "add: tags role"     "$(cat "$TMUX_STUB_LOG")" 'set-option -p -t %5 @agent_role worker'
assert_contains "add: tags provider" "$(cat "$TMUX_STUB_LOG")" 'set-option -p -t %5 @agent_provider codex'
assert_contains "add: default cwd is root" "$(cat "$TMUX_STUB_LOG")" "$tmux_new_window -t agents -n helper -c $PROJECT"
assert_contains "add: new window uses launch script" "$(cat "$TMUX_STUB_LOG")" '.agent-duo/state/helper/launch.sh'
assert_contains "add: launches codex" "$(cat "$PROJECT/.agent-duo/state/helper/launch.sh")" 'codex '
assert_contains "add: codex uses workspace-write sandbox" "$(cat "$PROJECT/.agent-duo/state/helper/launch.sh")" '--sandbox workspace-write'
assert_contains "add: codex allows tmux socket dir" "$(cat "$PROJECT/.agent-duo/state/helper/launch.sh")" '--add-dir'
assert_contains "add: codex allows tmux unix socket" "$(cat "$PROJECT/.agent-duo/state/helper/launch.sh")" 'network.allow_unix_sockets'
assert_contains "add: default worktree is root" "$(cat "$PROJECT/.agent-duo/state/helper/launch.sh")" "AGENT_DUO_WORKTREE=$PROJECT"
assert_not_contains "add: codex hook command is not double-encoded" "$(cat "$PROJECT/.agent-duo/state/helper/launch.sh")" 'command=\"\\\"AGENT_DUO_ROOT'
assert_contains "add: prints id" "$(cat "$OUT")" 'helper'
teardown

# add:省略 --id → 由 role 派生;已存在 worker → worker-2。
setup
TMUX_STUB_NEW_PANE="%5" assert_ok "add: derive id" run_peer agent add --provider codex --role worker
assert_contains "add: derived worker-2" "$(cat "$TMUX_STUB_LOG")" 'set-option -p -t %5 @agent_id worker-2'
teardown

# add:工作型角色(任何 provider)都要提示先 approval check——硬门对 Claude reviewer 同样 fail-closed。
setup
TMUX_STUB_NEW_PANE="%5" assert_ok "add: claude reviewer succeeds" run_peer agent add --provider claude --role reviewer
assert_contains "add: claude reviewer approval check hint" "$(cat "$OUT")" 'peer approval check reviewer'
teardown

# add:豁免名单角色(supervisor/daemon/loopd)不受硬门保护,不应误导用户去 approval check。
setup
TMUX_STUB_NEW_PANE="%5" assert_ok "add: claude supervisor succeeds" run_peer agent add --provider claude --role supervisor --id sup2
assert_not_contains "add: exempt role no approval check hint" "$(cat "$OUT")" 'approval check'
teardown

# add:Codex 工作型角色既给 approval check 提示,也给 /hooks 信任提示。
setup
TMUX_STUB_NEW_PANE="%5" assert_ok "add: codex worker succeeds" run_peer agent add --provider codex --role worker --id helper2
add_out="$(cat "$OUT")"
assert_contains "add: codex worker approval check hint" "$add_out" 'peer approval check helper2'
assert_contains "add: codex worker hooks hint" "$add_out" '/hooks'
teardown

# add:非法 provider 报错。
setup
assert_not_ok "add: bad provider" run_peer agent add --provider gpt --role worker
assert_contains "add: bad provider error" "$(cat "$ERR")" 'provider 必须是 claude 或 codex'
teardown

setup
assert_not_ok "add: bad role token rejected" run_peer agent add --provider codex --role 'bad/role'
assert_contains "add: bad role token error" "$(cat "$ERR")" '--role'
teardown

setup
assert_not_ok "add: dot role rejected" run_peer agent add --provider codex --role '..'
assert_contains "add: dot role error" "$(cat "$ERR")" '--role'
teardown

setup
assert_not_ok "add: bad id token rejected" run_peer agent add --provider codex --role worker --id 'bad/id'
assert_contains "add: bad id token error" "$(cat "$ERR")" '--id'
teardown

setup
assert_not_ok "add: dot id rejected" run_peer agent add --provider codex --role worker --id '..'
assert_contains "add: dot id error" "$(cat "$ERR")" '--id'
teardown

# add --worktree:创建隔离 worktree,worker cwd/写域指向 worktree,控制面仍指主仓。
setup
init_git_project
TEST_AGENT_DUO_WORKTREES_DIR="$SCENARIO_TMP/worktrees"
TMUX_STUB_NEW_PANE="%5" assert_ok "add worktree: succeeds" run_peer agent add --provider codex --role worker --id helper --worktree
record="$PROJECT/.agent-duo/state/helper/worktree.json"
assert_ok "add worktree: record exists" test -f "$record"
wt_path="$(jq -r '.path' "$record")"
assert_ok "add worktree: path exists" test -d "$wt_path"
assert_contains "add worktree: branch recorded" "$(cat "$record")" '"branch":"agent-duo/helper"'
assert_contains "add worktree: git registered path" "$(git -C "$PROJECT" worktree list --porcelain)" "worktree $wt_path"
assert_contains "add worktree: git registered branch" "$(git -C "$PROJECT" worktree list --porcelain)" 'branch refs/heads/agent-duo/helper'
assert_contains "add worktree: window cwd" "$(cat "$TMUX_STUB_LOG")" "$tmux_new_window -t agents -n helper -c $wt_path"
assert_contains "add worktree: pane option" "$(cat "$TMUX_STUB_LOG")" "@agent_worktree $wt_path"
assert_contains "add worktree: root stays main" "$(cat "$PROJECT/.agent-duo/state/helper/launch.sh")" "AGENT_DUO_ROOT=$PROJECT"
assert_contains "add worktree: worker worktree env" "$(cat "$PROJECT/.agent-duo/state/helper/launch.sh")" "AGENT_DUO_WORKTREE=$wt_path"
assert_contains "add worktree: broker scoped to worktree" "$(cat "$PROJECT/.agent-duo/state/helper/session-settings.json")" "\"worktree\":\"$wt_path\""
teardown

# add --worktree:非 git root fail-closed,不建窗口/记录。
setup
TEST_AGENT_DUO_WORKTREES_DIR="$SCENARIO_TMP/worktrees"
assert_not_ok "add worktree: non git rejected" run_peer agent add --provider codex --role worker --id helper --worktree
assert_contains "add worktree: non git error" "$(cat "$ERR")" '隔离需要 git 仓库'
assert_not_contains "add worktree: non git no window" "$(cat "$TMUX_STUB_LOG")" "$tmux_new_window"
assert_ok "add worktree: non git no record" test ! -e "$PROJECT/.agent-duo/state/helper/worktree.json"
teardown

# add --worktree:分支已存在但 worktree 已删时,复用分支重新 checkout。
setup
init_git_project
TEST_AGENT_DUO_WORKTREES_DIR="$SCENARIO_TMP/worktrees"
git -C "$PROJECT" branch agent-duo/helper
TMUX_STUB_NEW_PANE="%5" assert_ok "add worktree: reuses existing branch" run_peer agent add --provider codex --role worker --id helper --worktree
wt_path="$(jq -r '.path' "$PROJECT/.agent-duo/state/helper/worktree.json")"
assert_eq "add worktree: branch checkout" "$(git -C "$wt_path" branch --show-current)" "agent-duo/helper"
teardown

# add --worktree:dirty rm 保留过的有效 wt_path 可原地复用。
setup
init_git_project
TEST_AGENT_DUO_WORKTREES_DIR="$SCENARIO_TMP/worktrees"
TMUX_STUB_NEW_PANE="%5" assert_ok "add worktree reuse: first succeeds" run_peer agent add --provider codex --role worker --id helper --worktree
wt_path="$(jq -r '.path' "$PROJECT/.agent-duo/state/helper/worktree.json")"
printf 'dirty\n' > "$wt_path/dirty.txt"
TMUX_STUB_NEW_PANE="%6" assert_ok "add worktree reuse: second succeeds" run_peer agent add --provider codex --role worker --id helper --worktree
assert_ok "add worktree reuse: dirty file preserved" test -f "$wt_path/dirty.txt"
assert_contains "add worktree reuse: window cwd" "$(cat "$TMUX_STUB_LOG")" "$tmux_new_window -t agents -n helper -c $wt_path"
teardown

# add --worktree:目标路径存在但不是 git worktree 时拒绝,避免覆盖外部目录。
setup
init_git_project
TEST_AGENT_DUO_WORKTREES_DIR="$SCENARIO_TMP/worktrees"
mkdir -p "$TEST_AGENT_DUO_WORKTREES_DIR/agents/helper"
assert_not_ok "add worktree: external dir rejected" run_peer agent add --provider codex --role worker --id helper --worktree
assert_contains "add worktree: external dir error" "$(cat "$ERR")" '不是预期 worktree'
assert_not_contains "add worktree: external dir no window" "$(cat "$TMUX_STUB_LOG")" "$tmux_new_window"
teardown

# rm:按 id 找到 pane 并 kill-window。
setup
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%2\tworker\tworker\tcodex\n' > "$TMUX_STUB_REGISTRY"
assert_ok "rm: succeeds" run_peer agent rm worker
assert_contains "rm: kills window" "$(cat "$TMUX_STUB_LOG")" 'kill-window -t %2'
teardown

# rm:干净隔离 worktree 会被删除,分支保留,记录清掉。
setup
init_git_project
TEST_AGENT_DUO_WORKTREES_DIR="$SCENARIO_TMP/worktrees"
TMUX_STUB_NEW_PANE="%5" assert_ok "rm worktree clean setup" run_peer agent add --provider codex --role worker --id helper --worktree
wt_path="$(jq -r '.path' "$PROJECT/.agent-duo/state/helper/worktree.json")"
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%5\thelper\tworker\tcodex\n' > "$TMUX_STUB_REGISTRY"
assert_ok "rm worktree clean: succeeds" run_peer agent rm helper
assert_contains "rm worktree clean: kills window" "$(cat "$TMUX_STUB_LOG")" 'kill-window -t %5'
assert_ok "rm worktree clean: dir removed" test ! -e "$wt_path"
assert_ok "rm worktree clean: record removed" test ! -e "$PROJECT/.agent-duo/state/helper/worktree.json"
assert_ok "rm worktree clean: branch kept" git -C "$PROJECT" show-ref --verify --quiet refs/heads/agent-duo/helper
teardown

# rm:脏隔离 worktree 非 force 时保留 worktree 与记录,但 agent 仍被移除。
setup
init_git_project
TEST_AGENT_DUO_WORKTREES_DIR="$SCENARIO_TMP/worktrees"
TMUX_STUB_NEW_PANE="%5" assert_ok "rm worktree dirty setup" run_peer agent add --provider codex --role worker --id helper --worktree
wt_path="$(jq -r '.path' "$PROJECT/.agent-duo/state/helper/worktree.json")"
printf 'dirty\n' > "$wt_path/dirty.txt"
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%5\thelper\tworker\tcodex\n' > "$TMUX_STUB_REGISTRY"
assert_ok "rm worktree dirty: succeeds" run_peer agent rm helper
assert_contains "rm worktree dirty: warning" "$(cat "$ERR")" '有未提交改动'
assert_ok "rm worktree dirty: dir kept" test -d "$wt_path"
assert_ok "rm worktree dirty: record kept" test -f "$PROJECT/.agent-duo/state/helper/worktree.json"
teardown

# rm:--force 可在 id 前,脏 worktree 会被丢弃。
setup
init_git_project
TEST_AGENT_DUO_WORKTREES_DIR="$SCENARIO_TMP/worktrees"
TMUX_STUB_NEW_PANE="%5" assert_ok "rm worktree force before setup" run_peer agent add --provider codex --role worker --id helper --worktree
wt_path="$(jq -r '.path' "$PROJECT/.agent-duo/state/helper/worktree.json")"
printf 'dirty\n' > "$wt_path/dirty.txt"
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%5\thelper\tworker\tcodex\n' > "$TMUX_STUB_REGISTRY"
assert_ok "rm worktree force before: succeeds" run_peer agent rm --force helper
assert_ok "rm worktree force before: dir removed" test ! -e "$wt_path"
teardown

# rm:--force 可在 id 后。
setup
init_git_project
TEST_AGENT_DUO_WORKTREES_DIR="$SCENARIO_TMP/worktrees"
TMUX_STUB_NEW_PANE="%5" assert_ok "rm worktree force after setup" run_peer agent add --provider codex --role worker --id helper --worktree
wt_path="$(jq -r '.path' "$PROJECT/.agent-duo/state/helper/worktree.json")"
printf 'dirty\n' > "$wt_path/dirty.txt"
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%5\thelper\tworker\tcodex\n' > "$TMUX_STUB_REGISTRY"
assert_ok "rm worktree force after: succeeds" run_peer agent rm helper --force
assert_ok "rm worktree force after: dir removed" test ! -e "$wt_path"
teardown

# rm:记录路径指向同 repo 其他 branch 的 worktree 时,即便 --force 也拒绝自动删除。
setup
init_git_project
git -C "$PROJECT" worktree add -b agent-duo/other "$SCENARIO_TMP/other-wt" HEAD >/dev/null 2>&1
mkdir -p "$PROJECT/.agent-duo/state/helper"
jq -cn --arg path "$SCENARIO_TMP/other-wt" --arg branch "agent-duo/helper" '{path:$path,branch:$branch}' \
  > "$PROJECT/.agent-duo/state/helper/worktree.json"
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%5\thelper\tworker\tcodex\n' > "$TMUX_STUB_REGISTRY"
assert_ok "rm worktree invalid: succeeds" run_peer agent rm --force helper
assert_contains "rm worktree invalid: warning" "$(cat "$ERR")" '记录与 git 不符'
assert_ok "rm worktree invalid: other kept" test -d "$SCENARIO_TMP/other-wt"
assert_ok "rm worktree invalid: record kept" test -f "$PROJECT/.agent-duo/state/helper/worktree.json"
teardown

# rm:记录存在但目录和 git worktree 均已消失时,幂等清理记录。
setup
init_git_project
mkdir -p "$PROJECT/.agent-duo/state/helper"
jq -cn --arg path "$SCENARIO_TMP/missing-wt" --arg branch "agent-duo/helper" '{path:$path,branch:$branch}' \
  > "$PROJECT/.agent-duo/state/helper/worktree.json"
printf '%%1\tsupervisor\tsupervisor\tclaude\n%%5\thelper\tworker\tcodex\n' > "$TMUX_STUB_REGISTRY"
assert_ok "rm worktree missing: succeeds" run_peer agent rm helper
assert_ok "rm worktree missing: record removed" test ! -e "$PROJECT/.agent-duo/state/helper/worktree.json"
teardown

# rm:未知 id 报错。
setup
assert_not_ok "rm: unknown id" run_peer agent rm ghost
assert_contains "rm: unknown error" "$(cat "$ERR")" "找不到 agent 'ghost'"
teardown

# rm:拒绝移除自己。
setup
assert_not_ok "rm: refuse self" run_peer agent rm supervisor
assert_contains "rm: refuse self error" "$(cat "$ERR")" '不能移除自己'
teardown

exit "$ADK_FAIL"
