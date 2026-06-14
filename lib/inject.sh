#!/usr/bin/env bash
# lib/inject.sh — peer 协作提示词的注入逻辑(纯函数 + 常量)。
# source 本文件不产生任何副作用;仅供 start.sh 与测试调用。
# 兼容 macOS 自带 bash 3.2:不使用关联数组、不使用 ${var,,}。

AGENT_DUO_MARK_START='<!-- agent-duo:start -->'
AGENT_DUO_MARK_END='<!-- agent-duo:end -->'

# adk_has_block <agents_md_path>
# 文件存在且包含成对有序标记 → 0;否则 → 1。
adk_has_block() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  awk -v start="$AGENT_DUO_MARK_START" -v end="$AGENT_DUO_MARK_END" '
    $0 == start { seen_start = 1; next }
    seen_start && $0 == end { found = 1; exit }
    END { exit found ? 0 : 1 }
  ' "$f"
}

# adk_block <instructions_file>
# 打印带标记的完整块:起始标记 + 指令正文 + 结束标记。
adk_block() {
  local instr="$1"
  printf '%s\n' "$AGENT_DUO_MARK_START"
  cat "$instr"
  # 前置 \n:即使指令文件结尾缺少换行,结束标记也单独成行。
  printf '\n%s\n' "$AGENT_DUO_MARK_END"
}

# adk_inject_codex <agents_md_path> <instructions_file>
# 幂等:块已存在 → 不动,返回 1;成功写入 → 返回 0;I/O 错误 → 返回非零(来自 cat/重定向)。
# 调用方应只在返回 0 时认为注入成功(块已存在的场景由 adk_plan 提前判掉,不会走到这里)。
# 文件已存在且非空时,先空一行再追加,保持可读。
adk_inject_codex() {
  local f="$1" instr="$2"
  if adk_has_block "$f"; then
    return 1
  fi
  if [[ -s "$f" ]]; then
    printf '\n' >> "$f"
  fi
  # 不显式 return 0:让 adk_block(实为 cat 的退出码)与重定向失败如实传播。
  adk_block "$instr" >> "$f"
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

# adk_plan <has_block:0|1> <auto_inject:0|1> <is_tty:0|1>
# 打印计划: reminder | auto | prompt | skip
#   块已存在            → reminder(不重写文件,但 claude 仍加参数)
#   无块 & auto         → auto    (直接写块 + claude 加参数)
#   无块 & 交互终端     → prompt  (询问用户)
#   无块 & 非交互       → skip    (不注入,打印手动说明)
adk_plan() {
  local hb="$1" ai="$2" tty="$3"
  if [[ "$hb" == "1" ]]; then echo reminder; return; fi
  if [[ "$ai" == "1" ]]; then echo auto; return; fi
  if [[ "$tty" == "1" ]]; then echo prompt; return; fi
  echo skip
}

# adk_answer_yes <answer> → 同意(y/Y/yes/YES/Yes) 返回 0,否则 1。
adk_answer_yes() {
  case "$1" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}
