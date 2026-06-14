#!/usr/bin/env bash
# lib/inject.sh — peer 协作提示词的注入逻辑(纯函数 + 常量)。
# source 本文件不产生任何副作用;仅供 start.sh 与测试调用。
# 兼容 macOS 自带 bash 3.2:不使用关联数组、不使用 ${var,,}。

AGENT_DUO_MARK_START='<!-- agent-duo:start -->'
AGENT_DUO_MARK_END='<!-- agent-duo:end -->'

# adk_has_block <agents_md_path>
# 文件存在且包含起始标记 → 0;否则 → 1。
adk_has_block() {
  local f="$1"
  [[ -f "$f" ]] && grep -qF "$AGENT_DUO_MARK_START" "$f"
}

# adk_block <instructions_file>
# 打印带标记的完整块:起始标记 + 指令正文 + 结束标记。
adk_block() {
  local instr="$1"
  printf '%s\n' "$AGENT_DUO_MARK_START"
  cat "$instr"
  printf '%s\n' "$AGENT_DUO_MARK_END"
}

# adk_inject_codex <agents_md_path> <instructions_file>
# 幂等:块已存在 → 不动,返回 1;否则把块追加到文件(不存在则创建),返回 0。
# 文件已存在且非空时,先空一行再追加,保持可读。
adk_inject_codex() {
  local f="$1" instr="$2"
  if adk_has_block "$f"; then
    return 1
  fi
  if [[ -s "$f" ]]; then
    printf '\n' >> "$f"
  fi
  adk_block "$instr" >> "$f"
  return 0
}

# adk_claude_cmd <do_inject:0|1> <instructions_file>
# do_inject=1 → 打印 claude --append-system-prompt "$(cat <path>)"($(...) 故意不展开,
#               由 claude 窗口自己的 shell 在启动时替换);否则打印纯 claude。
adk_claude_cmd() {
  local inject="$1" instr="$2"
  if [[ "$inject" == "1" ]]; then
    printf 'claude --append-system-prompt "$(cat %q)"' "$instr"
  else
    printf 'claude'
  fi
}
