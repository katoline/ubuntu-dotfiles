#!/usr/bin/env bash
# OpenCode plugin と既存の共通フック（Claude Code / Grok / Codex と共有）の薄い adapter。
#
# 呼び出し: bash harness.sh <op>  （JSON は stdin）
#   guard        … guard-destructive.sh に PreToolUse(Bash) を渡す
#   pr-pre       … pr-mode.sh に PreToolUse(Bash) を渡す
#   pr-request   … pr-mode.sh に PermissionRequest を渡す（コマンドは単一の Bash 入力）
#   verify-post  … verify-gate.sh に PostToolUse を渡す
#   verify-stop  … verify-gate.sh に Stop を渡す
#   complete-prompt … completion-gate.sh に UserPromptSubmit を渡す（新しい実 user のターン）
#   complete-post   … completion-gate.sh に PostToolUse を渡す
#   complete-stop   … completion-gate.sh に Stop を渡す
#
# Git の許可判定は /pr の起動状態に依存しない（既定ブランチ保護方式）。pr-mode.sh の
# PreToolUse は既定ブランチ宛の commit / push・force / 削除・宛先不明 push を deny し、
# 確認が必要な PR のマージは ask する。PermissionRequest は PR_MODE_REQUEST_SCOPE=git で呼ぶので、
# 既定ブランチ以外の commit / push / PR 作成・更新（単一コマンド）だけを allow する。
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

run_pr() { # $1=event
  local event="$1" h="$ROOT/.claude/hooks/pr-mode.sh" payload
  [ -f "$h" ] || exit 1
  case "$event" in
    pr-pre | pr-request)
      local cmd cwd agent name
      cmd=$(field command); cwd=$(field cwd); agent=$(field agent_id)
      [ -n "$cmd" ] || exit 1
      if [ "$event" = "pr-pre" ]; then name=PreToolUse; else name=PermissionRequest; fi
      payload=$(hook_json --arg e "$name" --arg s "$session" --arg c "$cmd" --arg d "$cwd" --arg a "$agent" \
        '{hook_event_name:$e,session_id:$s,tool_name:"Bash",tool_input:{command:$c},cwd:$d}
         + (if $a == "" then {} else {agent_id:$a} end)') || exit 1 ;;
    *) exit 1 ;;
  esac
  if [ "$event" = "pr-request" ]; then
    # OpenCode は main 時点の自動承認範囲（git の単一コマンドだけ）に戻す
    printf '%s' "$payload" | PR_MODE_REQUEST_SCOPE=git bash "$h"
  else
    printf '%s' "$payload" | bash "$h"
  fi
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

run_complete() {
  local event="$1" h="$ROOT/.claude/hooks/completion-gate.sh" payload tool path cmd cwd
  [ -f "$h" ] || exit 1
  cwd=$(field cwd)
  case "$event" in
    complete-prompt)
      payload=$(hook_json --arg s "$session" --arg d "$cwd" \
        '{hook_event_name:"UserPromptSubmit",session_id:$s,cwd:$d}') || exit 1 ;;
    complete-post)
      tool=$(field tool_name); path=$(field file_path); cmd=$(field command)
      [ -n "$tool" ] || exit 1
      payload=$(hook_json --arg t "$tool" --arg s "$session" --arg f "$path" --arg c "$cmd" --arg d "$cwd" \
        '{hook_event_name:"PostToolUse",session_id:$s,tool_name:$t,
          tool_input:(if $t == "Bash" then {command:$c} else {file_path:$f} end),cwd:$d}') || exit 1 ;;
    complete-stop)
      payload=$(hook_json --arg s "$session" --arg d "$cwd" \
        '{hook_event_name:"Stop",session_id:$s,stop_hook_active:false,cwd:$d}') || exit 1 ;;
    *) exit 1 ;;
  esac
  printf '%s' "$payload" | bash "$h"
}

case "$op" in
  guard) run_guard ;;
  pr-pre | pr-request) run_pr "$op" ;;
  verify-post | verify-stop) run_verify "$op" ;;
  complete-prompt | complete-post | complete-stop) run_complete "$op" ;;
  *) exit 1 ;;
esac
