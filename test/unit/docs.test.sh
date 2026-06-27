#!/usr/bin/env bash
# test/unit/docs.test.sh - 当前用户文档的结构性回归保护。
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
source "$DIR/../lib/assert.sh"

read_file() { # <path>
  cat "$ROOT/$1"
}

mission="$(read_file docs/mission-template.md)"
assert_contains "docs mission: has goal section" "$mission" '## 要做什么 (Goal)'
assert_contains "docs mission: has done section" "$mission" '## 完成条件 (Done means)'
assert_contains "docs mission: has guardrails section" "$mission" '## 不做 / 红线 (Non-goals & guardrails)'
assert_contains "docs mission: requires mechanical gate" "$mission" '可机械验证'
assert_contains "docs mission: mentions human gate red lines" "$mission" '必须升级人类 gate'

playbook="$(read_file docs/SUPERVISOR-LOOP-PLAYBOOK.md)"
assert_contains "docs playbook: has gate set" "$playbook" '## 合门集(唯一停止条件)'
assert_contains "docs playbook: verify in gate set" "$playbook" 'verify 全 pass'
assert_contains "docs playbook: judge in gate set" "$playbook" '无未决 judge veto'
assert_contains "docs playbook: evidence in gate set" "$playbook" 'done report 带 evidence'
assert_contains "docs playbook: agent add current noun" "$playbook" 'peer agent add --provider codex --role builder'
assert_contains "docs playbook: approval current noun" "$playbook" 'peer approval check <id>'
assert_contains "docs playbook: loop verify flag" "$playbook" '--verify smoke:'
assert_contains "docs playbook: loop judge flag" "$playbook" '--judge reviewer:'
assert_contains "docs playbook: judge command" "$playbook" 'peer judge builder@N --verdict'
assert_contains "docs playbook: checkpoint command" "$playbook" 'peer checkpoint builder'

for phase in PARSE PROPOSE PROVISION PLAN BUILD JUDGE LOOP GATE DONE; do
  assert_contains "docs playbook: phase $phase" "$playbook" "$phase"
done

for role in planner builder reviewer evaluator; do
  role_doc="$(read_file "docs/roles/$role.md")"
  assert_contains "docs role $role: responsibilities" "$role_doc" '## 职责'
  assert_contains "docs role $role: verify judge" "$role_doc" '## 默认 verify/judge 取向'
  assert_contains "docs role $role: prompt template" "$role_doc" '## 派发 prompt 模板'
done

reviewer="$(read_file docs/roles/reviewer.md)"
evaluator="$(read_file docs/roles/evaluator.md)"
assert_contains "docs reviewer: uses peer judge" "$reviewer" 'peer judge builder@<ROUND> --verdict request_changes'
assert_contains "docs evaluator: uses peer judge" "$evaluator" 'peer judge builder@<ROUND> --verdict fail'

instructions="$(read_file docs/AGENT-INSTRUCTIONS.md)"
assert_contains "docs instructions: playbook pointer" "$instructions" 'docs/SUPERVISOR-LOOP-PLAYBOOK.md'
assert_contains "docs instructions: current agent noun" "$instructions" 'peer agent add'
assert_contains "docs instructions: current approval noun" "$instructions" 'peer approval check'

root_instructions="$(read_file AGENTS.md)"
assert_contains "docs root instructions: playbook pointer" "$root_instructions" 'docs/SUPERVISOR-LOOP-PLAYBOOK.md'
assert_contains "docs root instructions: current agent noun" "$root_instructions" 'peer agent add'
assert_contains "docs root instructions: current approval noun" "$root_instructions" 'peer approval check'

exit "$ADK_FAIL"
