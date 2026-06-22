#!/usr/bin/env bash
# lib/registry.sh — agent registry / worktree helpers(不调用 tmux)。
# source 本文件不产生任何副作用;供 bin/peer、start.sh 与测试调用。
# 兼容 macOS 自带 bash 3.2:不使用关联数组、不使用 ${var,,}。

# reg_validate_provider <provider> → claude|codex 返回 0,否则 1。
reg_validate_provider() {
  case "$1" in
    claude|codex) return 0 ;;
    *) return 1 ;;
  esac
}

# reg_is_role_token <token> → 路径段安全的 role/id token。
# 允许普通 role/id 里的点号,但首字符必须字母/数字,从而拒绝 "." / ".." / ".foo"。
reg_is_role_token() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

# reg_provider_launch_cmd <provider> <instr_path>
# 打印在新 pane 里启动该 provider 的命令字符串。
# claude 走 --append-system-prompt "$(cat <instr>)"(故意不展开 $(...),由目标 shell 启动时替换)。
reg_provider_launch_cmd() {
  local provider="$1" instr="$2"
  case "$provider" in
    claude) printf 'claude --append-system-prompt "$(cat %q)"' "$instr" ;;
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

reg_worktree_branch() { # <id>
  printf 'agent-duo/%s' "$1"
}

reg_worktree_record_path() { # <root> <id>
  printf '%s/.agent-duo/state/%s/worktree.json' "$1" "$2"
}

reg_git_root() { # <root>
  local root="$1" git_root
  if ! git_root="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)"; then
    echo "错误: 隔离需要 git 仓库。" >&2
    return 1
  fi
  printf '%s' "$git_root"
}

reg_sha8() { # <value>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print substr($1,1,8)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print substr($1,1,8)}'
  else
    printf '%s' "$1" | cksum | awk '{print $1}'
  fi
}

reg_worktree_repo_key() { # <git_root>
  local git_root="$1" base hash
  base="${git_root##*/}"
  hash="$(reg_sha8 "$git_root")"
  printf '%s-%s' "$base" "$hash"
}

reg_worktree_base() { # <git_root> <session>
  local git_root="$1" session="$2" repo_key parent base
  if [[ -n "${AGENT_DUO_WORKTREES_DIR:-}" ]]; then
    base="$AGENT_DUO_WORKTREES_DIR"
  else
    repo_key="$(reg_worktree_repo_key "$git_root")"
    parent="$(dirname "$git_root")"
    base="$parent/.agent-duo-worktrees/$repo_key"
  fi
  printf '%s/%s' "$base" "$session"
}

reg_worktree_path() { # <git_root> <session> <id>
  printf '%s/%s' "$(reg_worktree_base "$1" "$2")" "$3"
}

reg_physical_dir() { # <path>
  local path="$1"
  if [[ -d "$path" ]]; then
    (cd "$path" && pwd -P) 2>/dev/null || printf '%s' "$path"
  else
    printf '%s' "$path"
  fi
}

reg_worktree_list_has_path() { # <git_root> <path>
  local git_root="$1" path="$2" line current_path
  path="$(reg_physical_dir "$path")"
  current_path=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      worktree\ *)
        current_path="${line#worktree }"
        if [[ "$current_path" == "$path" ]]; then
          return 0
        fi
        ;;
    esac
  done < <(git -C "$git_root" worktree list --porcelain 2>/dev/null)
  return 1
}

reg_worktree_is_valid() { # <git_root> <path> <id>
  local git_root="$1" path="$2" id="$3" expected_branch line current_path current_branch
  path="$(reg_physical_dir "$path")"
  expected_branch="refs/heads/$(reg_worktree_branch "$id")"
  current_path=""
  current_branch=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      worktree\ *)
        if [[ -n "$current_path" && "$current_path" == "$path" && "$current_branch" == "$expected_branch" ]]; then
          return 0
        fi
        current_path="${line#worktree }"
        current_branch=""
        ;;
      branch\ *)
        current_branch="${line#branch }"
        ;;
      "")
        if [[ "$current_path" == "$path" && "$current_branch" == "$expected_branch" ]]; then
          return 0
        fi
        current_path=""
        current_branch=""
        ;;
    esac
  done < <(git -C "$git_root" worktree list --porcelain 2>/dev/null)
  [[ "$current_path" == "$path" && "$current_branch" == "$expected_branch" ]]
}

reg_write_worktree_record() { # <root> <id> <path> <branch>
  local root="$1" id="$2" path="$3" branch="$4" record dir tmp
  record="$(reg_worktree_record_path "$root" "$id")"
  dir="${record%/*}"
  mkdir -p "$dir"
  tmp="$record.$$"
  jq -cn --arg path "$path" --arg branch "$branch" '{path:$path,branch:$branch}' > "$tmp"
  mv "$tmp" "$record"
}

reg_create_worktree() { # <id> [root] [session]
  local id="$1" root="${2:-${AGENT_DUO_ROOT:-$PWD}}" session="${3:-${AGENT_SESSION:-agents}}"
  local git_root wt_base wt_path branch
  git_root="$(reg_git_root "$root")" || return 1
  wt_base="$(reg_worktree_base "$git_root" "$session")"
  mkdir -p "$wt_base"
  wt_base="$(reg_physical_dir "$wt_base")"
  wt_path="$wt_base/$id"
  branch="$(reg_worktree_branch "$id")"
  if [[ -e "$wt_path" ]]; then
    if reg_worktree_is_valid "$git_root" "$wt_path" "$id"; then
      printf '%s' "$wt_path"
      return 0
    fi
    echo "错误: wt_path 已存在但不是预期 worktree: $wt_path;请手动清理或换 id。" >&2
    return 1
  fi
  if git -C "$git_root" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$git_root" worktree add "$wt_path" "$branch" >&2 || return 1
  else
    git -C "$git_root" worktree add -b "$branch" "$wt_path" HEAD >&2 || return 1
  fi
  printf '%s' "$wt_path"
}

reg_remove_worktree() { # <root> <id> <force:0|1>
  local root="$1" id="$2" force="${3:-0}" record git_root wt_path dirty
  record="$(reg_worktree_record_path "$root" "$id")"
  [[ -f "$record" ]] || return 2
  wt_path="$(jq -r '.path // empty' "$record" 2>/dev/null || true)"
  if [[ -z "$wt_path" ]]; then
    echo "警告: worker $id 的 worktree 记录无效($record),已保留,请手动清理。" >&2
    return 0
  fi
  wt_path="$(reg_physical_dir "$wt_path")"
  if ! git_root="$(reg_git_root "$root")"; then
    echo "警告: 无法校验 worker $id 的 worktree,已保留记录: $record" >&2
    return 0
  fi
  if ! reg_worktree_is_valid "$git_root" "$wt_path" "$id"; then
    if ! reg_worktree_list_has_path "$git_root" "$wt_path" && [[ ! -e "$wt_path" ]]; then
      git -C "$git_root" worktree prune 2>/dev/null || true
      rm -f "$record"
      return 0
    fi
    echo "警告: worker $id 的 worktree 记录与 git 不符($wt_path),为安全起见不自动删除,请手动清理。" >&2
    return 0
  fi
  dirty="$(git -C "$wt_path" status --porcelain 2>/dev/null || printf 'unknown')"
  if [[ -n "$dirty" && "$force" != "1" ]]; then
    echo "警告: worker $id 的 worktree 有未提交改动($wt_path),已保留。" >&2
    echo "      提交/处理后 'peer rm --force $id' 丢弃,或手动 git worktree remove。" >&2
    return 0
  fi
  if [[ "$force" == "1" ]]; then
    if ! git -C "$git_root" worktree remove --force "$wt_path" >&2; then
      echo "警告: 删除 worker $id 的 worktree 失败($wt_path),已保留记录。" >&2
      return 0
    fi
  else
    if ! git -C "$git_root" worktree remove "$wt_path" >&2; then
      echo "警告: 删除 worker $id 的 worktree 失败($wt_path),已保留记录。" >&2
      return 0
    fi
  fi
  git -C "$git_root" worktree prune 2>/dev/null || true
  rm -f "$record"
}
