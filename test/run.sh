#!/usr/bin/env bash
# test/run.sh — 运行 test/ 下所有 *.test.sh(包括 integration.test.sh),任一失败则整体退出非零。
set -u
shopt -s nullglob   # 无匹配文件时让 glob 展开为空,而不是字面量路径
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
for t in "$DIR"/*.test.sh; do
  echo "=== $t ==="
  bash "$t" || rc=1
done
echo "==============="
[[ "$rc" == "0" ]] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit "$rc"
