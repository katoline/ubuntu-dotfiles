#!/bin/bash
# Codex の Git 操作ガード。PreToolUse は拒否だけを返し、承認は Codex の UI に任せる。
# 通常の CLI 操作の事故防止が対象。難読化による回避は対象外。
#
# 既定ブランチ（main / master / origin/HEAD の指すブランチ）への commit / push は、
# /pr の有無や承認モードに関係なく常に deny する。それ以外のブランチでの
# commit / push / PR の作成と更新は何も返さない（Codex の承認ポリシーに任せる）。
# PR のマージ・push の宛先を判定できない形・--amend / --no-verify / -n は、
# Codex の PreToolUse が ask を返せないため deny する。
# force push・リモートブランチ削除・--all / --mirror・sudo・サブエージェントからの
# git 書き込みも deny する。
#
# /pr のフラグ（codex-pr-mode-*）は廃止した。判定は毎回コマンドとその対象リポジトリの
# 状態から行い、共有関数（.claude/hooks/lib/git-write.sh）に委譲する。
# PreToolUse に agent_id が届かない環境ではサブエージェントを判別できないため、
# 委譲禁止は ai/codex.md の指示でも守る。
exec 2>/dev/null
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
fields=$(printf '%s' "$input" | jq -r '
  (.tool_input | if type == "object" then . else {} end) as $ti
  | [(.hook_event_name // ""), (.cwd // ""),
     ($ti.command // $ti.cmd // "" | if type == "array" then (if length >= 3 and (.[0] | test("(^|/)(bash|sh|zsh)$")) and (.[1] | test("^-[A-Za-z]*c[A-Za-z]*$")) then .[2] else join(" ") end) elif type == "string" then . else "" end),
     (.agent_id // "")]
  | map(tostring) | @sh') || exit 0
eval "set -- $fields" || exit 0
event="$1" cwd="$2" cmd="$3" agent="$4"
[ "$event" = PreToolUse ] || exit 0
[ -n "$cmd" ] || exit 0
[ -n "$cwd" ] || cwd="$PWD"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "$SELF")/../.." && pwd -P)" || exit 0
STRIP_AWK="$ROOT/.claude/hooks/lib/strip-shell.awk"
source "$ROOT/.claude/hooks/lib/git-write.sh" || exit 0

deny() {
  jq -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

s=$(stripped_or_raw "$cmd")
s=${s//\\$'\n'/ }
s=${s//$'\n'/;}

# サブエージェントからの git 書き込みは常に拒否する
if [ -n "$agent" ] && is_git_write "$cmd" "$s"; then
  deny 'コミット・push・PR の作成と更新はメインセッションが直接実行してください（サブエージェントからは実行できません）。'
fi

printf '%s\n' "$s" | grep -Eq '(^|[[:space:];&|(])sudo([[:space:];&|)]|$)' && deny 'sudo は使えません。必要なコマンドをユーザーに示してください。'

# PR のマージは Codex が ask を返せないため拒否する
if is_pr_merge "$cmd"; then
  deny 'PR のマージは、ユーザーが明示的に指示したときに、ユーザー自身が実行するか Claude Code 等の確認付きの環境で行ってください（Codex は確認ダイアログを出せないため拒否します）。'
fi

# force push は常に拒否
if is_force_push "$cmd"; then
  deny 'force push は禁止です。'
fi

# 既定ブランチへの commit は常に拒否。--amend / --no-verify / -n も拒否
case "$(commit_verdict "$cmd" "$cwd")" in
  protected) deny '既定ブランチ（main / master / origin/HEAD が指すブランチ）への commit は禁止されています。作業ブランチを作成してください。' ;;
  ask) deny '--amend / --no-verify / -n を含むコミットは拒否します。内容を確認し、必要な場合はユーザーが手動で実行してください。' ;;
esac

# push は宛先で判定する。宛先を判定できない形も拒否（Codex は ask を返せない）
case "$(push_destination_verdict "$cmd" "$cwd")" in
  all | delete) deny '--all / --mirror での push とリモートブランチの削除は禁止です。' ;;
  force) deny 'force push は禁止です。' ;;
  no-verify) deny '--no-verify は使いません。' ;;
  protected) deny '既定ブランチ（main / master / origin/HEAD が指すブランチ）への push は禁止されています。PR 用ブランチを使ってください。' ;;
  indeterminate) deny 'push の宛先を判定できません（変数・ワイルドカード等）。宛先を確認し、ユーザーに手動実行を依頼してください。' ;;
esac

exit 0
