#!/usr/bin/env bash
# lib/registry.sh — agent registry 的纯函数(无副作用,不调用 tmux)。
# source 本文件不产生任何副作用;供 bin/peer、start.sh 与测试调用。
# 兼容 macOS 自带 bash 3.2:不使用关联数组、不使用 ${var,,}。

# reg_validate_provider <provider> → claude|codex 返回 0,否则 1。
reg_validate_provider() {
  case "$1" in
    claude|codex) return 0 ;;
    *) return 1 ;;
  esac
}

# reg_provider_launch_cmd <provider> <instr_path>
# 打印在新 pane 里启动该 provider 的命令字符串。
# claude 走 --append-system-prompt "$(cat <instr>)"(故意不展开 $(...),由目标 shell 启动时替换)。
reg_provider_launch_cmd() {
  local provider="$1" instr="$2"
  case "$provider" in
    claude) printf 'claude --append-system-prompt "$(cat %s)"' "$instr" ;;
    codex)  printf 'codex' ;;
    *)      return 1 ;;
  esac
}

# reg_derive_id <role> <existing_ids_newline_separated>
# role 未被占用 → role;否则 role-2、role-3 ... 直到不冲突。
reg_derive_id() {
  local role="$1" existing="$2" n=1
  local candidate="$role"
  while printf '%s\n' "$existing" | grep -qx "$candidate"; do
    n=$(( n + 1 ))
    candidate="${role}-${n}"
  done
  printf '%s' "$candidate"
}

# reg_pick_other <self_id> <ids_newline_separated>
# 排除 self 后:正好 1 个 → 打印它返回 0;0 个 → 返回 2;>1 个 → 返回 3(歧义)。
reg_pick_other() {
  local self="$1" ids="$2" others count
  others="$(printf '%s\n' "$ids" | grep -vx "$self" | grep -v '^$' || true)"
  count="$(printf '%s\n' "$others" | grep -c . || true)"
  case "$count" in
    1) printf '%s' "$others"; return 0 ;;
    0) return 2 ;;
    *) return 3 ;;
  esac
}
