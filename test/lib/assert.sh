#!/usr/bin/env bash
# test/lib/assert.sh — 极简断言助手(被各测试文件 source)。失败置 ADK_FAIL=1,不退出。
ADK_FAIL=0

assert_eq() { # <name> <actual> <expected>
  if [[ "$2" == "$3" ]]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: got [%s] want [%s]\n' "$1" "$2" "$3"; ADK_FAIL=1; fi
}

assert_contains() { # <name> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: [%s] missing [%s]\n' "$1" "$2" "$3"; ADK_FAIL=1; fi
}

assert_not_contains() { # <name> <haystack> <needle>
  if [[ "$2" != *"$3"* ]]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: [%s] should not contain [%s]\n' "$1" "$2" "$3"; ADK_FAIL=1; fi
}

assert_ok() { # <name> <cmd...>
  local name="$1"; shift
  if "$@"; then printf 'ok   %s\n' "$name"
  else printf 'FAIL %s (exit %d)\n' "$name" "$?"; ADK_FAIL=1; fi
}

assert_not_ok() { # <name> <cmd...>  (expects non-zero exit)
  local name="$1"; shift
  if "$@"; then printf 'FAIL %s (expected non-zero)\n' "$name"; ADK_FAIL=1
  else printf 'ok   %s\n' "$name"; fi
}
