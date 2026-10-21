#!/usr/bin/env bash
# OpenCode plugin と既存の共通フック（Claude Code / Grok / Codex と共有）の薄い adapter。
#
# 呼び出し: bash harness.sh <op>  （JSON は stdin）
#   guard        … guard-destructive.sh に PreToolUse(Bash) を渡す
#   pr-start     … pr-mode.sh に UserPromptExpansion(command_name=pr) を渡す
#   pr-pre       … pr-mode.sh に PreToolUse(Bash) を渡す
#   pr-request   … pr-mode.sh に PermissionRequest(Bash) を渡す
#   pr-stop      … pr-mode.sh に Stop を渡す（フラグ解除）
#   verify-post  … verify-gate.sh に PostToolUse を渡す
#   verify-stop  … verify-gate.sh に Stop を渡す
#
# 実体パスからリポジトリルートを解決するので、home-manager のリンク経由でも worktree でも同じ実体を使う。
# 入力 JSON の解釈に失敗したとき・jq や共通スクリプトが無いときは exit 1（呼び出し側は拒否に倒す）。
set -u
export LC_ALL=C

SELF="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
ROOT="$(cd "$(dirname "$SELF")/../.." 2>/dev/null && pwd -P)" || exit 1
op=${1:-}

command -v jq >/dev/null 2>&1 || exit 1
input=$(cat) || exit 1
[ -n "$input" ] || exit 1
printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 1

field() { printf '%s' "$input" | jq -r --arg k "$1" '.[$k] // ""'; }
session=$(field session_id)
case "$session" in *[!A-Za-z0-9._-]* | '') exit 1 ;; esac

hook_json() { # jq のフィルタと --arg 群を受け取り、JSON を 1 つ出力する
  jq -cn "$@"
}

run_guard() {
  local cmd cwd
  cmd=$(field command)
  cwd=$(field cwd)
  [ -n "$cmd" ] || exit 1
  local h="$ROOT/.claude/hooks/guard-destructive.sh"
  [ -f "$h" ] || exit 1
  hook_json --arg s "$session" --arg c "$cmd" --arg d "$cwd" \
    '{hook_event_name:"PreToolUse",session_id:$s,tool_name:"Bash",tool_input:{command:$c},cwd:$d}' \
    | bash "$h"
}

run_pr() { # $1=event $2=extra jq filter（引数なし）
  local event="$1" h="$ROOT/.claude/hooks/pr-mode.sh" payload
  [ -f "$h" ] || exit 1
  case "$event" in
    pr-start)
      payload=$(hook_json --arg s "$session" \
        '{hook_event_name:"UserPromptExpansion",session_id:$s,command_name:"pr"}') || exit 1 ;;
    pr-pre | pr-request)
      local cmd cwd agent name
      cmd=$(field command); cwd=$(field cwd); agent=$(field agent_id)
      [ -n "$cmd" ] || exit 1
      if [ "$event" = "pr-pre" ]; then name=PreToolUse; else name=PermissionRequest; fi
      payload=$(hook_json --arg e "$name" --arg s "$session" --arg c "$cmd" --arg d "$cwd" --arg a "$agent" \
        '{hook_event_name:$e,session_id:$s,tool_name:"Bash",tool_input:{command:$c},cwd:$d}
         + (if $a == "" then {} else {agent_id:$a} end)') || exit 1 ;;
    pr-stop)
      payload=$(hook_json --arg s "$session" '{hook_event_name:"Stop",session_id:$s}') || exit 1 ;;
    *) exit 1 ;;
  esac
  printf '%s' "$payload" | bash "$h"
}

run_verify() {
  local event="$1" h="$ROOT/.claude/hooks/verify-gate.sh" payload tool path cmd out cwd active
  [ -f "$h" ] || exit 1
  case "$event" in
    verify-post)
      tool=$(field tool_name); path=$(field file_path); cmd=$(field command)
      out=$(field stdout); cwd=$(field cwd)
      payload=$(hook_json --arg t "$tool" --arg s "$session" --arg f "$path" --arg c "$cmd" --arg o "$out" --arg d "$cwd" \
        '{hook_event_name:"PostToolUse",session_id:$s,tool_name:$t,
          tool_input:(if $t == "Bash" then {command:$c} else {file_path:$f} end),
          tool_response:{stdout:$o},cwd:$d}') || exit 1 ;;
    verify-stop)
      active=$(field stop_hook_active)
      [ "$active" = "true" ] || active=false
      payload=$(hook_json --arg s "$session" --argjson a "$active" \
        '{hook_event_name:"Stop",session_id:$s,stop_hook_active:$a}') || exit 1 ;;
    *) exit 1 ;;
  esac
  printf '%s' "$payload" | bash "$h"
}

case "$op" in
  guard) run_guard ;;
  pr-start | pr-pre | pr-request | pr-stop) run_pr "$op" ;;
  verify-post | verify-stop) run_verify "$op" ;;
  *) exit 1 ;;
esac
