#!/usr/bin/env bash
# Approval Broker MVP1 policy and persistence helpers.
# Bash 3.2 compatible; allowlists are UX only, not a security boundary.
set -euo pipefail

ESCALATE_REASON="BLOCKED-PENDING-APPROVAL: 需 supervisor/人批准；报 blocked 并等待，勿另寻他法。"
HARD_DENY_REASON="DENIED-BY-POLICY: 禁止；勿重试；改走他法或报 blocked-on-policy。"

ab_root() {
  local root="${AGENT_DUO_ROOT:-$PWD}"
  ab_abs_path "$root" "$PWD"
}

ab_duo_dir() { printf '%s/.agent-duo' "$1"; }
ab_approvals_dir() { printf '%s/approvals' "$(ab_duo_dir "$1")"; }
ab_logs_dir() { printf '%s/logs' "$(ab_duo_dir "$1")"; }
ab_events_dir() { printf '%s/events' "$(ab_duo_dir "$1")"; }
ab_state_dir() { printf '%s/state' "$(ab_duo_dir "$1")"; }

ab_iso_ts() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

ab_oneline() {
  printf '%s' "${1:-}" | tr '\r\n' '  ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

ab_json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

ab_json_str() {
  printf '"%s"' "$(ab_json_escape "${1:-}")"
}

ab_json_field() { # <name> <value>
  printf '"%s":' "$1"
  ab_json_str "${2:-}"
}

ab_json_null_field() { # <name> <value>
  printf '"%s":' "$1"
  if [[ -z "${2:-}" ]]; then
    printf 'null'
  else
    ab_json_str "$2"
  fi
}

ab_json_unescape() {
  local s="${1:-}"
  s="${s//\\\"/\"}"
  s="${s//\\\\/\\}"
  s="${s//\\n/$'\n'}"
  s="${s//\\r/$'\r'}"
  s="${s//\\t/$'\t'}"
  printf '%s' "$s"
}

ab_require_jq() {
  if command -v jq >/dev/null 2>&1; then
    return 0
  fi
  printf '{"decision":"deny","reason":"DENIED-BY-POLICY: approval broker requires jq for safe JSON parsing."}\n'
  exit 0
}

ab_json_get_string() { # <json> <key>
  local json="$1" key="$2" value
  ab_require_jq
  value="$(printf '%s' "$json" | jq -er --arg key "$key" '[.. | objects | .[$key]? | select(type == "string")][0] // empty' 2>/dev/null || true)"
  printf '%s' "$value"
}

ab_json_get_int() { # <json> <key>
  local json="$1" key="$2" value
  ab_require_jq
  value="$(printf '%s' "$json" | jq -er --arg key "$key" '[.. | objects | .[$key]? | select(type == "number" or type == "string")][0] // empty' 2>/dev/null || true)"
  [[ "$value" =~ ^[0-9]+$ ]] || value="0"
  printf '%s' "$value"
}

ab_parent_dir() {
  local path="$1"
  printf '%s' "${path%/*}"
}

ab_write_file_atomic() { # <path> <content>
  local path="$1" content="$2" dir tmp
  dir="$(ab_parent_dir "$path")"
  mkdir -p "$dir"
  tmp="${path}.$$"
  printf '%s\n' "$content" > "$tmp"
  mv -f "$tmp" "$path"
}

ab_append_jsonl() { # <path> <line>
  local path="$1" line="$2" dir
  dir="$(ab_parent_dir "$path")"
  mkdir -p "$dir"
  printf '%s\n' "$line" >> "$path"
}

ab_sha256_string() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    echo "错误: approval broker 需要 shasum 或 sha256sum。" >&2
    exit 1
  fi
}

ab_normalize_abs_path() { # <absolute_path>
  local path="$1" part out idx
  local -a parts stack
  IFS='/' read -r -a parts <<< "$path"
  for part in "${parts[@]}"; do
    case "$part" in
      ""|.)
        ;;
      ..)
        if (( ${#stack[@]} > 0 )); then
          idx=$(( ${#stack[@]} - 1 ))
          unset "stack[$idx]"
        fi
        ;;
      *)
        stack[${#stack[@]}]="$part"
        ;;
    esac
  done
  out=""
  for part in "${stack[@]}"; do
    out="$out/$part"
  done
  [[ -n "$out" ]] || out="/"
  printf '%s' "$out"
}

ab_abs_path() { # <raw> <cwd>
  local raw="$1" cwd="$2" path dir base canon_dir search suffix parent
  case "$raw" in
    "") path="$cwd" ;;
    /*) path="$raw" ;;
    ~*) path="$raw" ;;
    *) path="$cwd/$raw" ;;
  esac
  dir="${path%/*}"
  base="${path##*/}"
  if [[ -z "$dir" || "$dir" == "$path" ]]; then
    ab_normalize_abs_path "$path"
    return 0
  fi
  canon_dir="$(cd -P "$dir" 2>/dev/null && pwd -P || true)"
  if [[ -n "$canon_dir" ]]; then
    ab_normalize_abs_path "$canon_dir/$base"
  else
    search="$dir"
    suffix="/$base"
    while [[ -n "$search" && "$search" != "/" && ! -d "$search" ]]; do
      suffix="/${search##*/}${suffix}"
      parent="${search%/*}"
      [[ "$parent" == "$search" ]] && break
      search="$parent"
    done
    canon_dir="$(cd -P "$search" 2>/dev/null && pwd -P || true)"
    if [[ -n "$canon_dir" ]]; then
      ab_normalize_abs_path "$canon_dir$suffix"
    else
      while [[ "$path" == *'//'* ]]; do path="${path//\/\//\/}"; done
      path="${path//\/.\//\/}"
      ab_normalize_abs_path "$path"
    fi
  fi
}

ab_is_inside() { # <path> <root>
  local path="$1" root="$2"
  [[ "$path" == "$root" || "$path" == "$root"/* ]]
}

ab_path_mentions_secret() {
  local path="$1"
  case "$path" in
    .env|*/.env|*/.env/*|.ssh|*/.ssh|*/.ssh/*|~/.ssh|~/.ssh/*|.aws|*/.aws|*/.aws/*|~/.aws|~/.aws/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

ab_payload_tool() {
  local payload="$1" value
  for key in tool_name tool name toolName; do
    value="$(ab_json_get_string "$payload" "$key")"
    if [[ -n "$value" ]]; then printf '%s' "$value"; return 0; fi
  done
  printf ''
}

ab_payload_path() {
  local payload="$1" value key
  for key in file_path path target_path filename; do
    value="$(ab_json_get_string "$payload" "$key")"
    if [[ -n "$value" ]]; then printf '%s' "$value"; return 0; fi
  done
  printf ''
}

ab_payload_command() {
  ab_json_get_string "$1" command
}

ab_payload_cwd() {
  local payload="$1" cwd
  cwd="$(ab_json_get_string "$payload" cwd)"
  if [[ -z "$cwd" ]]; then cwd="$PWD"; fi
  ab_abs_path "$cwd" "$PWD"
}

ab_agent_id() {
  local payload="$1" agent
  agent="${AGENT_DUO_AGENT_ID:-}"
  if [[ -z "$agent" ]]; then agent="$(ab_json_get_string "$payload" agent)"; fi
  if [[ -z "$agent" ]]; then agent="$(ab_json_get_string "$payload" agent_id)"; fi
  if [[ -z "$agent" ]]; then agent="${AGENT_NAME:-unknown}"; fi
  printf '%s' "$agent"
}

ab_round() {
  local payload="$1" round
  round="$(ab_json_get_int "$payload" round)"
  if [[ "$round" == "0" && -n "${AGENT_DUO_ROUND:-}" && "$AGENT_DUO_ROUND" =~ ^[0-9]+$ ]]; then
    round="$AGENT_DUO_ROUND"
  fi
  printf '%s' "$round"
}

ab_worktree_root() {
  local payload="$1" cwd="$2" raw
  raw="${AGENT_DUO_WORKTREE:-}"
  if [[ -z "$raw" ]]; then raw="$(ab_json_get_string "$payload" worktree)"; fi
  if [[ -z "$raw" ]]; then raw="$cwd"; fi
  ab_abs_path "$raw" "$cwd"
}

ab_split_segments() { # <command>
  local s="$1" i ch next current len
  current=""
  len="${#s}"
  i=0
  while (( i < len )); do
    ch="${s:$i:1}"
    next=""
    if (( i + 1 < len )); then next="${s:$(( i + 1 )):1}"; fi
    if [[ "$ch$next" == "&&" || "$ch$next" == "||" ]]; then
      printf '%s\n' "$current"
      current=""
      i="$(( i + 2 ))"
      continue
    fi
    case "$ch" in
      ';'|'|'|'('|')'|$'\n')
        printf '%s\n' "$current"
        current=""
        ;;
      *)
        current="${current}${ch}"
        ;;
    esac
    i="$(( i + 1 ))"
  done
  printf '%s\n' "$current"
}

ab_trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

ab_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

ab_match() { # <text> <extended-regex>
  printf '%s\n' "$1" | grep -Eq "$2"
}

ab_bash_hits_deny() { # <segment> <whole>
  local segment whole word
  segment="$(ab_lower "$1")"
  whole="$(ab_lower "$2")"
  if ab_match "$segment" '(^|[;&|()[:space:]])sudo([;&|()[:space:]]|$)'; then printf 'deny.sudo'; return 0; fi
  if ab_match "$segment" '(^|[;&|()[:space:]])su([;&|()[:space:]]|$)'; then printf 'deny.su'; return 0; fi
  if ab_match "$segment" '(^|[;&|()[:space:]])ssh([;&|()[:space:]]|$)'; then printf 'deny.ssh'; return 0; fi
  if ab_match "$segment" '(^|[;&|()[:space:]])scp([;&|()[:space:]]|$)'; then printf 'deny.scp'; return 0; fi
  if ab_match "$segment" '(^|[;&|()[:space:]])rsync([;&|()[:space:]]|$)'; then printf 'deny.rsync'; return 0; fi
  if ab_match "$segment" '(^|[;&|()[:space:]])git[[:space:]]+push([;&|()[:space:]]|$)'; then printf 'deny.git_push'; return 0; fi
  if ab_match "$segment" '(^|[;&|()[:space:]])terraform[[:space:]]+(apply|destroy)([;&|()[:space:]]|$)'; then printf 'deny.infra'; return 0; fi
  if ab_match "$segment" '(^|[;&|()[:space:]])kubectl[[:space:]]+(apply|delete|create|patch|scale)([;&|()[:space:]]|$)'; then printf 'deny.kubectl'; return 0; fi
  if ab_match "$segment" '(^|[;&|()[:space:]])(aws|gcloud|az)[[:space:]]+'; then printf 'deny.cloud'; return 0; fi
  if ab_match "$segment" '(^|[;&|()[:space:]])docker[[:space:]]+push([;&|()[:space:]]|$)'; then printf 'deny.publish'; return 0; fi
  if ab_match "$segment" '(^|[;&|()[:space:]])npm[[:space:]]+publish([;&|()[:space:]]|$)'; then printf 'deny.publish'; return 0; fi
  if ab_match "$segment" '(^|[;&|()[:space:]])gh[[:space:]]+(pr[[:space:]]+merge|release[[:space:]]+create)([;&|()[:space:]]|$)'; then printf 'deny.github_mutation'; return 0; fi
  if ab_match "$segment" '(^|[;&|()[:space:]])sed([[:space:]]|$)'; then
    for word in $segment; do
      case "$word" in
        -i|-i*|--in-place|--in-place=*) printf 'deny.in_place_edit'; return 0 ;;
      esac
    done
  fi
  if ab_match "$segment" '(^|[;&|()[:space:]])find[[:space:]][^;&|()]*(-delete|-exec)([;&|()[:space:]]|$)'; then printf 'deny.find_mutation'; return 0; fi
  if ab_match "$segment" '(^|[;&|()[:space:]])rm([[:space:]]|$)' &&
     { ab_match "$segment" '(^|[[:space:]])-[^[:space:]]*r[^[:space:]]*([[:space:]]|$)' || ab_match "$segment" '(^|[[:space:]])--recursive([=[:space:]]|$)'; } &&
     { ab_match "$segment" '(^|[[:space:]])-[^[:space:]]*f[^[:space:]]*([[:space:]]|$)' || ab_match "$segment" '(^|[[:space:]])--force([=[:space:]]|$)'; }; then
    printf 'deny.rm_rf'
    return 0
  fi
  if ab_match "$whole" '(curl|wget|fetch)[^|;]*\|[[:space:]]*(sh|bash|zsh)([[:space:]]|$)'; then printf 'deny.curl_pipe_shell'; return 0; fi
  if ab_match "$whole" '(^|[/[:space:]"'"'"'])\.(ssh|aws)([/[:space:]"'"'"']|$)'; then printf 'deny.secret_path'; return 0; fi
  if ab_match "$whole" '(^|[/[:space:]"'"'"'])\.env([/[:space:]"'"'"']|$)'; then printf 'deny.secret_path'; return 0; fi
  return 1
}

ab_bash_requires_escalation() { # <segment>
  local text="$1"
  case "$text" in
    *'>'*|*'<'*|*'`'*|*'$('*)
      printf 'bash.shell_syntax'
      return 0
      ;;
  esac
  return 1
}

ab_bash_segment_allowed() {
  local text="$1" target
  text="$(ab_trim "$text")"
  [[ -z "$text" ]] && { printf 'allow.empty'; return 0; }
  if ab_match "$text" '^pwd([[:space:]]|$)'; then printf 'allow.inspect'; return 0; fi
  if ab_match "$text" '^ls([[:space:]]|$)'; then printf 'allow.inspect'; return 0; fi
  if ab_match "$text" '^(cat|head|tail|wc|rg|grep|awk)([[:space:]]|$)'; then printf 'allow.inspect'; return 0; fi
  if ab_match "$text" '^sed[[:space:]]' &&
     ! ab_match "$text" '(^|[[:space:]])(-i[^[:space:]]*|--in-place(=[^[:space:]]*)?)([[:space:]]|$)'; then
    printf 'allow.inspect'
    return 0
  fi
  if ab_match "$text" '^find[[:space:]]' && ! ab_match "$text" '(-delete|-exec)'; then printf 'allow.inspect'; return 0; fi
  if ab_match "$text" '^git[[:space:]]+(status|diff|show|log|branch|rev-parse|ls-files|grep)([[:space:]]|$)'; then printf 'allow.git_read'; return 0; fi
  if ab_match "$text" '^(bash|sh)[[:space:]]+test/run\.sh([[:space:]]|$)'; then printf 'allow.test'; return 0; fi
  if ab_match "$text" '^\./test/run\.sh([[:space:]]|$)'; then printf 'allow.test'; return 0; fi
  if ab_match "$text" '^(npm|pnpm|yarn|bun)[[:space:]]+(test|run[[:space:]]+test)([[:space:]]|$)'; then printf 'allow.test'; return 0; fi
  if ab_match "$text" '^pytest([[:space:]]|$)'; then printf 'allow.test'; return 0; fi
  if ab_match "$text" '^python[0-9.]*[[:space:]]+-m[[:space:]]+pytest([[:space:]]|$)'; then printf 'allow.test'; return 0; fi
  if ab_match "$text" '^go[[:space:]]+test([[:space:]]|$)'; then printf 'allow.test'; return 0; fi
  if ab_match "$text" '^cargo[[:space:]]+test([[:space:]]|$)'; then printf 'allow.test'; return 0; fi
  if ab_match "$text" '^make[[:space:]]+test([[:space:]]|$)'; then printf 'allow.test'; return 0; fi
  if ab_match "$text" '^bundle[[:space:]]+exec[[:space:]]+rspec([[:space:]]|$)'; then printf 'allow.test'; return 0; fi
  if ab_match "$text" '^mvn[[:space:]]+test([[:space:]]|$)'; then printf 'allow.test'; return 0; fi
  if ab_match "$text" '^(gradle|./gradlew)[[:space:]]+test([[:space:]]|$)'; then printf 'allow.test'; return 0; fi
  if ab_match "$text" '^(date|true|false)([[:space:]]|$)'; then printf 'allow.basic'; return 0; fi
  if ab_match "$text" '^(printf|echo)([[:space:]]|$)'; then printf 'allow.basic'; return 0; fi
  if ab_match "$text" '^cd([[:space:]]|$)'; then
    target="$(printf '%s' "$text" | sed 's/^cd[[:space:]]*//')"
    if [[ -z "$target" || "$target" == "." ]]; then printf 'allow.cd'; return 0; fi
    case "$target" in
      /*|~*|*..*) return 1 ;;
      *) printf 'allow.cd'; return 0 ;;
    esac
  fi
  return 1
}

ab_mcp_policy() { # <tool>; sets AB_OUTCOME AB_MATCHED AB_REASON
  local tool="$1" action stripped prefix
  action="${tool##*__}"
  stripped="${action#_}"
  for prefix in add approve convert create delete dismiss enable label lock mark merge remove reply request rerun resolve unresolve unlock update; do
    if [[ "$stripped" == "$prefix" || "$stripped" == "$prefix"_* ]]; then
      AB_OUTCOME="hard-deny"; AB_MATCHED="deny.mcp.$prefix"; AB_REASON="$HARD_DENY_REASON"; return 0
    fi
  done
  for prefix in fetch get list search; do
    if [[ "$stripped" == "$prefix" || "$stripped" == "$prefix"_* ]]; then
      AB_OUTCOME="auto-allow"; AB_MATCHED="allow.mcp.$prefix"; AB_REASON="allow"; return 0
    fi
  done
  if [[ "$tool" == mcp__github__download* || "$tool" == mcp__codex_apps__github__download* ]]; then
    AB_OUTCOME="auto-allow"; AB_MATCHED="allow.mcp.download"; AB_REASON="allow"; return 0
  fi
  AB_OUTCOME="escalate"; AB_MATCHED="mcp.unknown"; AB_REASON="$ESCALATE_REASON"
}

ab_request_summary() {
  local tool="$1" command="$2" path="$3"
  if [[ "$tool" == "Bash" ]]; then
    printf 'Bash: %s' "$(ab_oneline "$command")"
  elif [[ -n "$path" ]]; then
    printf '%s: %s' "$tool" "$(ab_oneline "$path")"
  else
    ab_oneline "$tool"
  fi
}

ab_fingerprint() {
  local agent="$1" tool="$2" cwd="$3" command="$4" raw_path="$5" mcp="$6" resolved
  if [[ "$tool" == "Bash" ]]; then
    ab_sha256_string "agent=$agent|tool=$tool|cwd=$cwd|command=$command"
  elif [[ -n "$raw_path" ]]; then
    resolved="$(ab_abs_path "$raw_path" "$cwd")"
    ab_sha256_string "agent=$agent|tool=$tool|cwd=$cwd|path=$resolved"
  elif [[ "$tool" == mcp__* ]]; then
    ab_sha256_string "agent=$agent|tool=$tool|cwd=$cwd|mcp=$mcp"
  else
    ab_sha256_string "agent=$agent|tool=$tool|cwd=$cwd"
  fi
}

ab_approval_path() { # <root> <id>
  printf '%s/%s.json' "$(ab_approvals_dir "$1")" "$2"
}

ab_read_file() {
  [[ -f "$1" ]] && sed -n '1p' "$1" || true
}

ab_find_existing_approval() { # <root> <fingerprint>; sets AB_EXISTING_*
  local root="$1" fingerprint="$2" file data fp
  AB_EXISTING_PATH=""
  AB_EXISTING_DATA=""
  AB_EXISTING_ID=""
  for file in "$(ab_approvals_dir "$root")"/*.json; do
    [[ -f "$file" ]] || continue
    data="$(ab_read_file "$file")"
    fp="$(ab_json_get_string "$data" fingerprint)"
    if [[ "$fp" == "$fingerprint" ]]; then
      AB_EXISTING_PATH="$file"
      AB_EXISTING_DATA="$data"
      AB_EXISTING_ID="$(ab_json_get_string "$data" id)"
    fi
  done
}

ab_approval_id() {
  printf 'a%s-%s-%s' "$(date -u '+%Y%m%dT%H%M%SZ')" "$$" "$RANDOM"
}

ab_tool_input_json() { # <tool> <command> <cwd> <raw_path>
  local tool="$1" command="$2" cwd="$3" raw_path="$4" resolved
  if [[ "$tool" == "Bash" ]]; then
    printf '{'
    ab_json_field command "$command"
    printf ','
    ab_json_field cwd "$cwd"
    printf '}'
  elif [[ -n "$raw_path" ]]; then
    resolved="$(ab_abs_path "$raw_path" "$cwd")"
    printf '{'
    ab_json_field path "$raw_path"
    printf ','
    ab_json_field resolved_path "$resolved"
    printf ','
    ab_json_field cwd "$cwd"
    printf '}'
  elif [[ "$tool" == mcp__* ]]; then
    printf '{}'
  else
    printf '{}'
  fi
}

ab_create_or_reuse_approval() {
  local root="$1" agent="$2" round="$3" status="$4" decision="$5" matched="$6" reason="$7"
  local tool="$8" command="$9" cwd="${10}" raw_path="${11}" fingerprint="${12}" summary="${13}"
  local existing_status aid ts ref path tool_input data
  ab_find_existing_approval "$root" "$fingerprint"
  if [[ -n "$AB_EXISTING_DATA" ]]; then
    existing_status="$(ab_json_get_string "$AB_EXISTING_DATA" status)"
    if [[ "$existing_status" == "pending" || "$status" == "pending" ]]; then
      AB_APPROVAL_DATA="$AB_EXISTING_DATA"
      AB_APPROVAL_ID="$AB_EXISTING_ID"
      return 0
    fi
  fi

  aid="$(ab_approval_id)"
  ts="$(ab_iso_ts)"
  ref=".agent-duo/approvals/$aid.json"
  path="$(ab_approval_path "$root" "$aid")"
  tool_input="$(ab_tool_input_json "$tool" "$command" "$cwd" "$raw_path")"
  data="{"
  data="${data}\"protocol\":\"1\",\"id\":\"$(ab_json_escape "$aid")\",\"ts\":\"$ts\",\"updated_at\":\"$ts\","
  data="${data}\"agent\":\"$(ab_json_escape "$agent")\",\"round\":$round,\"status\":\"$status\",\"decision\":\"$decision\","
  data="${data}\"tool\":\"$(ab_json_escape "$tool")\",\"tool_input\":$tool_input,\"cwd\":\"$(ab_json_escape "$cwd")\","
  data="${data}\"summary\":\"$(ab_json_escape "$summary")\",\"matched\":\"$(ab_json_escape "$matched")\","
  data="${data}\"reason\":\"$(ab_json_escape "$reason")\",\"fingerprint\":\"$fingerprint\",\"ref\":\"$(ab_json_escape "$ref")\"}"
  ab_write_file_atomic "$path" "$data"
  AB_APPROVAL_DATA="$data"
  AB_APPROVAL_ID="$aid"
}

ab_append_audit() {
  local root="$1" agent="$2" tool="$3" command="$4" raw_path="$5" cwd="$6" decision="$7" matched="$8" reason="$9" approval_id="${10}" granted_by="${11}"
  local line
  line="{\"ts\":\"$(ab_iso_ts)\",\"agent\":\"$(ab_json_escape "$agent")\",\"tool\":\"$(ab_json_escape "$tool")\","
  line="${line}\"cmd\":"
  if [[ "$tool" == "Bash" ]]; then line="${line}$(ab_json_str "$command")"; else line="${line}null"; fi
  line="${line},\"path\":"
  if [[ -n "$raw_path" ]]; then line="${line}$(ab_json_str "$raw_path")"; else line="${line}null"; fi
  line="${line},\"cwd\":\"$(ab_json_escape "$cwd")\",\"decision\":\"$(ab_json_escape "$decision")\","
  line="${line}\"matched\":\"$(ab_json_escape "$matched")\",\"approval_id\":"
  if [[ -n "$approval_id" ]]; then line="${line}$(ab_json_str "$approval_id")"; else line="${line}null"; fi
  line="${line},\"granted_by\":"
  if [[ -n "$granted_by" ]]; then line="${line}$(ab_json_str "$granted_by")"; else line="${line}null"; fi
  line="${line},\"reason\":"
  if [[ -n "$reason" ]]; then line="${line}$(ab_json_str "$reason")"; else line="${line}null"; fi
  line="${line}}"
  ab_append_jsonl "$(ab_logs_dir "$root")/approvals.jsonl" "$line"
}

ab_append_blocked_event() {
  local root="$1" approval="$2" id agent round summary ref line
  id="$(ab_json_get_string "$approval" id)"
  agent="$(ab_json_get_string "$approval" agent)"
  round="$(ab_json_get_int "$approval" round)"
  summary="$(ab_json_get_string "$approval" summary)"
  ref="$(ab_json_get_string "$approval" ref)"
  line="{\"id\":\"e$(date -u '+%Y%m%dT%H%M%SZ')-$(ab_json_escape "$id")\","
  line="${line}\"ts\":\"$(ab_iso_ts)\",\"agent\":\"$(ab_json_escape "$agent")\",\"type\":\"blocked\","
  line="${line}\"round\":$round,\"summary\":\"$(ab_json_escape "$summary")\",\"ref\":\"$(ab_json_escape "$ref")\"}"
  ab_append_jsonl "$(ab_events_dir "$root")/queue.jsonl" "$line"
}

ab_output() { # <decision> [reason] [approval_id]
  local decision="$1" reason="${2:-}" approval_id="${3:-}" out
  out="{\"decision\":\"$(ab_json_escape "$decision")\""
  if [[ -n "$reason" ]]; then out="${out},\"reason\":\"$(ab_json_escape "$reason")\""; fi
  if [[ -n "$approval_id" ]]; then out="${out},\"approval_id\":\"$(ab_json_escape "$approval_id")\""; fi
  out="${out}}"
  printf '%s\n' "$out"
}

ab_evaluate_policy() {
  local payload="$1" root="$2" agent="$3" tool="$4" command="$5" raw_path="$6" cwd="$7" wt_root="$8"
  local segment trimmed matched allow_list resolved
  AB_OUTCOME=""
  AB_MATCHED=""
  AB_REASON=""
  if [[ -z "$tool" ]]; then AB_OUTCOME="ask"; AB_MATCHED="tool.unknown"; AB_REASON="ask"; return 0; fi
  if [[ "$tool" == "Bash" ]]; then
    while IFS= read -r segment; do
      trimmed="$(ab_trim "$segment")"
      [[ -n "$trimmed" ]] || continue
      if matched="$(ab_bash_hits_deny "$trimmed" "$command")"; then
        AB_OUTCOME="hard-deny"; AB_MATCHED="$matched"; AB_REASON="$HARD_DENY_REASON"; return 0
      fi
    done <<EOF
$(ab_split_segments "$command")
EOF
    while IFS= read -r segment; do
      trimmed="$(ab_trim "$segment")"
      [[ -n "$trimmed" ]] || continue
      if matched="$(ab_bash_requires_escalation "$trimmed")"; then
        AB_OUTCOME="escalate"; AB_MATCHED="$matched"; AB_REASON="$ESCALATE_REASON"; return 0
      fi
    done <<EOF
$(ab_split_segments "$command")
EOF
    allow_list=""
    while IFS= read -r segment; do
      trimmed="$(ab_trim "$segment")"
      [[ -n "$trimmed" ]] || continue
      if matched="$(ab_bash_segment_allowed "$trimmed")"; then
        if [[ -n "$allow_list" ]]; then allow_list="${allow_list},$matched"; else allow_list="$matched"; fi
      else
        AB_OUTCOME="escalate"; AB_MATCHED="bash.unmatched"; AB_REASON="$ESCALATE_REASON"; return 0
      fi
    done <<EOF
$(ab_split_segments "$command")
EOF
    if [[ -n "$allow_list" ]]; then
      AB_OUTCOME="auto-allow"; AB_MATCHED="$allow_list"; AB_REASON="allow"
    else
      AB_OUTCOME="escalate"; AB_MATCHED="bash.empty"; AB_REASON="$ESCALATE_REASON"
    fi
    return 0
  fi

  case "$tool" in
    Edit|Write|MultiEdit)
      if [[ -z "$raw_path" ]]; then AB_OUTCOME="escalate"; AB_MATCHED="path.missing"; AB_REASON="$ESCALATE_REASON"; return 0; fi
      if ab_path_mentions_secret "$raw_path"; then AB_OUTCOME="hard-deny"; AB_MATCHED="deny.secret_path"; AB_REASON="$HARD_DENY_REASON"; return 0; fi
      resolved="$(ab_abs_path "$raw_path" "$cwd")"
      if ab_path_mentions_secret "$resolved"; then AB_OUTCOME="hard-deny"; AB_MATCHED="deny.secret_path"; AB_REASON="$HARD_DENY_REASON"; return 0; fi
      if ab_is_inside "$resolved" "$wt_root"; then
        AB_OUTCOME="auto-allow"; AB_MATCHED="allow.worktree_write"; AB_REASON="allow"
      else
        AB_OUTCOME="escalate"; AB_MATCHED="path.outside_worktree"; AB_REASON="$ESCALATE_REASON"
      fi
      return 0
      ;;
  esac

  if [[ "$tool" == mcp__* ]]; then
    ab_mcp_policy "$tool"
    return 0
  fi
  AB_OUTCOME="ask"; AB_MATCHED="tool.unmanaged"; AB_REASON="ask"
}

ab_set_approval_fields() { # <root> <id> <status> [extra-json-fragment-with-leading-comma]
  local root="$1" id="$2" status="$3" extra="${4:-}" path data
  path="$(ab_approval_path "$root" "$id")"
  data="$(ab_read_file "$path")"
  [[ -n "$data" ]] || { echo "错误: 找不到 approval '$id'。" >&2; exit 1; }
  data="$(printf '%s' "$data" | sed 's/"status":"[^"]*"/"status":"'"$status"'"/')"
  data="$(printf '%s' "$data" | sed 's/"updated_at":"[^"]*"/"updated_at":"'"$(ab_iso_ts)"'"/')"
  if [[ -n "$extra" ]]; then
    data="${data%\}}${extra}}"
  fi
  ab_write_file_atomic "$path" "$data"
  AB_APPROVAL_DATA="$data"
}

ab_run_hook() {
  local payload root agent tool command raw_path cwd wt_root round fingerprint existing_status summary
  payload="$(cat)"
  root="$(ab_root)"
  agent="$(ab_agent_id "$payload")"
  tool="$(ab_payload_tool "$payload")"
  command="$(ab_payload_command "$payload")"
  raw_path="$(ab_payload_path "$payload")"
  cwd="$(ab_payload_cwd "$payload")"
  wt_root="$(ab_worktree_root "$payload" "$cwd")"
  round="$(ab_round "$payload")"
  fingerprint="$(ab_fingerprint "$agent" "$tool" "$cwd" "$command" "$raw_path" "$tool")"

  ab_find_existing_approval "$root" "$fingerprint"
  ab_evaluate_policy "$payload" "$root" "$agent" "$tool" "$command" "$raw_path" "$cwd" "$wt_root"

  if [[ "$AB_OUTCOME" != "hard-deny" && -n "$AB_EXISTING_DATA" ]]; then
    existing_status="$(ab_json_get_string "$AB_EXISTING_DATA" status)"
    if [[ "$existing_status" == "approved" ]]; then
      ab_set_approval_fields "$root" "$AB_EXISTING_ID" "consumed" ",\"consumed_at\":\"$(ab_iso_ts)\""
      ab_append_audit "$root" "$agent" "$tool" "$command" "$raw_path" "$cwd" "auto-allow" "approval.once" "" "$AB_EXISTING_ID" "supervisor"
      ab_output allow "" "$AB_EXISTING_ID"
      return 0
    fi
    if [[ "$existing_status" == "denied" ]]; then
      AB_REASON="DENIED-BY-POLICY: supervisor denied approval $AB_EXISTING_ID."
      ab_append_audit "$root" "$agent" "$tool" "$command" "$raw_path" "$cwd" "hard-deny" "approval.denied" "$AB_REASON" "$AB_EXISTING_ID" ""
      ab_output deny "$AB_REASON" "$AB_EXISTING_ID"
      return 0
    fi
  fi

  if [[ "$AB_OUTCOME" == "auto-allow" ]]; then
    ab_append_audit "$root" "$agent" "$tool" "$command" "$raw_path" "$cwd" "auto-allow" "$AB_MATCHED" "" "" "policy"
    ab_output allow
    return 0
  fi

  if [[ "$AB_OUTCOME" == "hard-deny" ]]; then
    summary="$(ab_request_summary "$tool" "$command" "$raw_path")"
    ab_create_or_reuse_approval "$root" "$agent" "$round" "hard-denied" "hard-deny" "$AB_MATCHED" "$AB_REASON" "$tool" "$command" "$cwd" "$raw_path" "$fingerprint" "$summary"
    ab_append_blocked_event "$root" "$AB_APPROVAL_DATA"
    ab_append_audit "$root" "$agent" "$tool" "$command" "$raw_path" "$cwd" "hard-deny" "$AB_MATCHED" "$AB_REASON" "$AB_APPROVAL_ID" ""
    ab_output deny "$AB_REASON" "$AB_APPROVAL_ID"
    return 0
  fi

  if [[ "$AB_OUTCOME" == "escalate" ]]; then
    summary="$(ab_request_summary "$tool" "$command" "$raw_path")"
    ab_create_or_reuse_approval "$root" "$agent" "$round" "pending" "escalate" "$AB_MATCHED" "$AB_REASON" "$tool" "$command" "$cwd" "$raw_path" "$fingerprint" "$summary"
    ab_append_blocked_event "$root" "$AB_APPROVAL_DATA"
    ab_append_audit "$root" "$agent" "$tool" "$command" "$raw_path" "$cwd" "escalate" "$AB_MATCHED" "$AB_REASON" "$AB_APPROVAL_ID" ""
    ab_output deny "$AB_REASON" "$AB_APPROVAL_ID"
    return 0
  fi

  ab_append_audit "$root" "$agent" "$tool" "$command" "$raw_path" "$cwd" "ask" "$AB_MATCHED" "" "" ""
  ab_output ask
}

ab_cmd_list() {
  local root="$1" show_all="$2" file data status id agent round summary any
  any=0
  for file in "$(ab_approvals_dir "$root")"/*.json; do
    [[ -f "$file" ]] || continue
    data="$(ab_read_file "$file")"
    status="$(ab_json_get_string "$data" status)"
    if [[ "$show_all" == "1" || "$status" == "pending" ]]; then
      if [[ "$any" == "0" ]]; then
        printf '%-24s %-12s %-10s %-8s %s\n' "ID" "STATUS" "AGENT" "ROUND" "SUMMARY"
      fi
      any=1
      id="$(ab_json_get_string "$data" id)"
      agent="$(ab_json_get_string "$data" agent)"
      round="$(ab_json_get_int "$data" round)"
      summary="$(ab_json_get_string "$data" summary)"
      printf '%-24s %-12s %-10s %-8s %s\n' "$id" "$status" "$agent" "$round" "$(ab_oneline "$summary" | cut -c1-100)"
    fi
  done
  if [[ "$any" == "0" ]]; then
    printf '没有待审批请求。\n'
  fi
}

ab_load_approval_or_die() { # <root> <id>
  local path
  path="$(ab_approval_path "$1" "$2")"
  AB_APPROVAL_DATA="$(ab_read_file "$path")"
  if [[ -z "$AB_APPROVAL_DATA" ]]; then
    echo "错误: 找不到 approval '$2'。" >&2
    exit 1
  fi
}

ab_cmd_approve() {
  local root="$1" id="$2" status by extra agent tool command raw_path cwd
  ab_load_approval_or_die "$root" "$id"
  status="$(ab_json_get_string "$AB_APPROVAL_DATA" status)"
  if [[ "$status" == "hard-denied" ]]; then
    echo "错误: approval '$id' 是 hard-deny，不能 approve。" >&2
    exit 1
  fi
  by="${AGENT_DUO_SUPERVISOR_ID:-${AGENT_NAME:-supervisor}}"
  extra=",\"approved_at\":\"$(ab_iso_ts)\",\"approved_by\":\"$(ab_json_escape "$by")\""
  ab_set_approval_fields "$root" "$id" "approved" "$extra"
  agent="$(ab_json_get_string "$AB_APPROVAL_DATA" agent)"
  tool="$(ab_json_get_string "$AB_APPROVAL_DATA" tool)"
  command="$(ab_json_get_string "$AB_APPROVAL_DATA" command)"
  raw_path="$(ab_json_get_string "$AB_APPROVAL_DATA" path)"
  cwd="$(ab_json_get_string "$AB_APPROVAL_DATA" cwd)"
  ab_append_audit "$root" "$agent" "$tool" "$command" "$raw_path" "$cwd" "approved" "approval.once" "" "$id" "$by"
  printf '已批准 approval %s；worker 重跑同一工具调用时将一次性放行。\n' "$id"
}

ab_cmd_deny() {
  local root="$1" id="$2" reason="$3" by extra agent tool command raw_path cwd
  ab_load_approval_or_die "$root" "$id"
  by="${AGENT_DUO_SUPERVISOR_ID:-${AGENT_NAME:-supervisor}}"
  extra=",\"denied_at\":\"$(ab_iso_ts)\",\"denied_by\":\"$(ab_json_escape "$by")\",\"deny_reason\":\"$(ab_json_escape "$reason")\""
  ab_set_approval_fields "$root" "$id" "denied" "$extra"
  agent="$(ab_json_get_string "$AB_APPROVAL_DATA" agent)"
  tool="$(ab_json_get_string "$AB_APPROVAL_DATA" tool)"
  command="$(ab_json_get_string "$AB_APPROVAL_DATA" command)"
  raw_path="$(ab_json_get_string "$AB_APPROVAL_DATA" path)"
  cwd="$(ab_json_get_string "$AB_APPROVAL_DATA" cwd)"
  ab_append_audit "$root" "$agent" "$tool" "$command" "$raw_path" "$cwd" "denied" "approval.supervisor_deny" "$reason" "$id" "$by"
  printf '已拒绝 approval %s。\n' "$id"
}

ab_shell_quote() {
  local s="$1"
  printf "'%s'" "$(printf '%s' "$s" | sed "s/'/'\\\\''/g")"
}

ab_cmd_install() {
  local root="$1" agent="$2" provider="$3" hook="$4" worktree="$5" output="$6" command settings_path settings
  settings_path="$output"
  if [[ -z "$settings_path" ]]; then settings_path="$(ab_state_dir "$root")/$agent/session-settings.json"; fi
  command="AGENT_DUO_ROOT=$(ab_shell_quote "$root") AGENT_DUO_AGENT_ID=$(ab_shell_quote "$agent") AGENT_DUO_WORKTREE=$(ab_shell_quote "$worktree") $(ab_shell_quote "$hook")"
  settings="{\"agent_duo_approval_broker\":{\"version\":1,\"agent_id\":\"$(ab_json_escape "$agent")\","
  settings="${settings}\"provider\":\"$(ab_json_escape "$provider")\",\"hook\":\"$(ab_json_escape "$hook")\","
  settings="${settings}\"worktree\":\"$(ab_json_escape "$worktree")\","
  settings="${settings}\"positioning\":\"allowlist=UX; safety=worktree+denylist+escalate\"},"
  settings="${settings}\"hooks\":{\"PreToolUse\":[{\"matcher\":\"*\",\"hooks\":[{\"type\":\"command\",\"command\":\"$(ab_json_escape "$command")\"}]}]},"
  settings="${settings}\"codex\":{\"managed_hook_command\":\"$(ab_json_escape "$command")\","
  settings="${settings}\"trust_note\":\"Project-local testable hook metadata; actual Codex trust is handled by the host CLI.\"}}"
  ab_write_file_atomic "$settings_path" "$settings"
  printf '%s\n' "$settings_path"
}

ab_usage() {
  echo "用法: approval_broker.sh <hook|list|approve|deny|install>" >&2
  exit 2
}

main() {
  local cmd="${1:-}" root="" show_all=0 id="" reason="" agent="" provider="" hook="" worktree="" output=""
  [[ -n "$cmd" ]] || ab_usage
  shift || true
  case "$cmd" in
    hook)
      ab_run_hook
      ;;
    list)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --root) root="${2:-}"; shift 2 ;;
          --all) show_all=1; shift ;;
          *) ab_usage ;;
        esac
      done
      [[ -n "$root" ]] || root="$(ab_root)"
      ab_cmd_list "$(ab_abs_path "$root" "$PWD")" "$show_all"
      ;;
    approve)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --root) root="${2:-}"; shift 2 ;;
          *) id="$1"; shift ;;
        esac
      done
      [[ -n "$id" ]] || ab_usage
      [[ -n "$root" ]] || root="$(ab_root)"
      ab_cmd_approve "$(ab_abs_path "$root" "$PWD")" "$id"
      ;;
    deny)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --root) root="${2:-}"; shift 2 ;;
          --reason) reason="${2:-}"; shift 2 ;;
          *) id="$1"; shift ;;
        esac
      done
      [[ -n "$id" ]] || ab_usage
      [[ -n "$root" ]] || root="$(ab_root)"
      ab_cmd_deny "$(ab_abs_path "$root" "$PWD")" "$id" "$reason"
      ;;
    install)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --agent-id) agent="${2:-}"; shift 2 ;;
          --provider) provider="${2:-}"; shift 2 ;;
          --hook) hook="${2:-}"; shift 2 ;;
          --root) root="${2:-}"; shift 2 ;;
          --worktree) worktree="${2:-}"; shift 2 ;;
          --output) output="${2:-}"; shift 2 ;;
          *) ab_usage ;;
        esac
      done
      [[ -n "$agent" && -n "$provider" && -n "$hook" ]] || ab_usage
      [[ -n "$root" ]] || root="$(ab_root)"
      root="$(ab_abs_path "$root" "$PWD")"
      hook="$(ab_abs_path "$hook" "$PWD")"
      [[ -n "$worktree" ]] || worktree="$root"
      worktree="$(ab_abs_path "$worktree" "$PWD")"
      ab_cmd_install "$root" "$agent" "$provider" "$hook" "$worktree" "$output"
      ;;
    *)
      ab_usage
      ;;
  esac
}

main "$@"
