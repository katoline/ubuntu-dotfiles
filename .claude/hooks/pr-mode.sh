#!/bin/bash

# 既定ブランチ保護フック（Claude Code / Grok CLI。OpenCode / Codex は adapter 経由で共有）
#
# 目標:
# - 既定ブランチ（main / master / origin/HEAD の指すブランチ）への commit / push は
#   常に deny する（/pr の有無・bypass / always-approve・allow ルールに関係なく、
#   PreToolUse の deny を最終防衛層にする）。
# - それ以外のブランチでの git commit / git push / gh pr create（別名 new）/ gh pr edit /
#   gh api の /pulls 書き込み（マージ以外）は、単一コマンドで秘密情報の検査を満たす
#   ときに自動承認する（Claude は PermissionRequest の allow、Grok は PreToolUse の
#   no-decision = 設定側の ask を PermissionRequest で昇格できないため Grok は
#   PreToolUse で何も返さず設定の ask に委ねる。Grok は PermissionRequest を持たない）。
# - PR のマージ（gh pr merge / gh api の /pulls/N/merge への PUT / GraphQL の
#   mergePullRequest）は常に ask（Claude / Grok）。Codex は PreToolUse が ask を
#   返せないため guard.sh 側で deny する（このフックは Claude/Grok 用）。
# - force push・リモートブランチ削除・--all / --mirror・--no-verify は従来どおり deny。
# - サブエージェント（入力に agent_id がある）からの git 書き込みは deny。
#
# /pr のフラグ（claude-pr-mode-* / codex-pr-mode-*）は廃止した。判定は毎回
# コマンドとその対象リポジトリの状態から行う。
#
# 対象リポジトリの解決:
# - `git -C <dir>` があればその dir
# - コマンド先頭が `cd <dir> &&` / `cd <dir> ;` ならその dir（フック入力の cwd 基準）
# - それ以外はフック入力の cwd。変数・コマンド置換で解決できないときも cwd
# - 判定は lib/git-write.sh に集約し、Codex / OpenCode の adapter と共有する
#
# 自動承認の条件（満たさなければ何も出力せず通常の確認ダイアログに落とす。拒否はしない）:
# - コマンド文字列が git commit / git push / gh pr create / gh pr new / gh pr edit で始まるか、
#   gh api の /pulls への書き込み（POST / PUT / PATCH / -f / --input。マージ以外）
# - 引用符の中身と HEREDOC 本文を除いた上で、複合コマンド・コマンド置換・
#   リダイレクトを含まない（&& || ; | & $( ` <( >( > <。2>&1 は許容）。
#   "$(cat <<'EOF' … EOF\n)" の定型 HEREDOC 本文だけは許す
# - git push: 宛先が既定ブランチでない・force / 削除 / --all / --mirror / --no-verify でない・
#   変数などで宛先を判定できない形でない
# - git commit: 既定ブランチでない・--amend / --no-verify / -n でない・
#   コミットされる差分に既知のトークン形式（lib/scan-secrets.sh）が無い
# - gh pr create / new / edit: 別リポジトリ宛（-R / --repo）でない
# - 引用符で割ったオプション（"--force" / -"f" / "--amend" 等）は、git push / git commit の
#   引数区間ごとに判定して自動承認しない（-m "- x" のような値や push 区間の外の引用は対象外）。
#   gh pr create / new / edit の引用符で割った -R / --repo も自動承認しない
# - 除去処理が失敗した・引用符や HEREDOC が閉じていない場合は自動承認しない
#   （拒否判定側は逆に、除去に失敗したら生文字列で判定する = fail-closed）
#
# 制約:
# - jq が無い・入力 JSON が壊れている場合は何もせず exit 0（~/.claude/pr-mode.log に記録）。
#   どのイベントでも exit 0 固定
# - 判定 JSON は Claude 形式（hookSpecificOutput.permissionDecision / decision.behavior）。
#   Grok も同じキーを読む
# - git alias 経由（git -c alias.x=commit x）は捕捉しない（CLAUDE.md の指示で抑止）

LOG="$HOME/.claude/pr-mode.log"
SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
STRIP_AWK="$(dirname "$SELF")/lib/strip-shell.awk"

logmsg() { printf '%s %s\n' "$(date +%FT%T)" "$*" >>"$LOG" 2>/dev/null; }

if ! command -v jq >/dev/null 2>&1; then
  logmsg "jq が見つからないため pr-mode は無効です（PATH=${PATH}）"
  exit 0
fi

input=$(cat)
if ! event=$(printf '%s' "$input" | jq -r '.hook_event_name // .hookEventName // empty' 2>/dev/null); then
  logmsg "入力 JSON を解釈できません"
  exit 0
fi
if [ -z "$event" ] && [ -n "${GROK_HOOK_EVENT:-}" ]; then
  event="$GROK_HOOK_EVENT"
fi
case "$event" in
  permission_request) event=PermissionRequest ;;
  pre_tool_use) event=PreToolUse ;;
esac
case "$event" in
  PreToolUse | PermissionRequest) ;;
  *) exit 0 ;;
esac

# Git 書き込みの判定は Codex / OpenCode と同じ関数を使う。
source "$(dirname "$SELF")/lib/git-write.sh"

cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')
[ -n "$cwd" ] || cwd="$PWD"

# コミットされる差分に既知のトークン形式があるか調べ、「ファイル名（形式名）」の一覧を返す
# （lib/scan-secrets.sh に委譲。一致が無ければ空）。-a / -am のときは git diff HEAD を見る。
secret_hits() {
  local raw="$1" scan mode=staged
  scan="$(dirname "$SELF")/lib/scan-secrets.sh"
  [ -f "$scan" ] || return 0
  [ -n "$cwd" ] || return 0
  printf '%s\n' "$raw" | grep -Eq -- '(^|[[:space:]])(-[A-Za-z]*a[A-Za-z]*|--all)([[:space:]]|$)' && mode=all
  # 複数件は「、」で連結する（paste -d は区切りをバイト単位で扱い、全角文字では壊れる）
  bash "$scan" "$cwd" "$mode" 2>/dev/null | awk 'NR > 1 { printf "、" } { printf "%s", $0 } END { if (NR) print "" }'
}

# 自動承認の対象か（引数: 生コマンド）。対象なら 0
is_auto_approvable() {
  local raw="$1" s rest flat kq tok nq is_api=0 rawh
  is_pr_api_write "$raw" && is_api=1
  if [ "$is_api" -eq 0 ]; then
    rawh=$(raw_no_heredoc "$raw")
    case "$rawh" in
      *gh*api* | *graphql*) case "$rawh" in *createPullRequest*) is_api=1 ;; esac ;;
    esac
  fi
  if [ "$is_api" -eq 0 ]; then
    case "$raw" in
      "git push" | "git push "* | "git commit "* \
      | "gh pr create" | "gh pr create "* | "gh pr new" | "gh pr new "* | "gh pr edit "*) ;;
      *) return 1 ;;
    esac
  fi

  s=$(strip_cmd "$raw")
  # 許容する定型だけ判定前に取り除く: "$(cat <<'EOF'" と 2>&1 系
  s=$(printf '%s\n' "$s" | sed -E "s/\\\$\\(cat[[:space:]]+<<-?[[:space:]]*['\"]?[A-Za-z_][A-Za-z0-9_-]*['\"]?//; s/[0-9]*>&[0-9]+//g; s/<<-?[[:space:]]*['\"]?[A-Za-z_][A-Za-z0-9_-]*['\"]?//")
  # 2 行目以降は ")" で始まる行だけ許す（"$(cat <<'EOF' … EOF\n)" の閉じ行）
  rest=$(printf '%s\n' "$s" | sed -E '1d; /^[[:space:]]*(\).*)?$/d' | grep -c .)
  [ "$rest" -gt 0 ] && return 1
  case "$s" in
    *'&&'* | *'||'* | *';'* | *'|'* | *'&'* | *'$('* | *'`'* | *'<('* | *'>('* | *'>'* | *'<'*) return 1 ;;
  esac
  flat=$(printf '%s' "$s" | tr '\n' ' ')

  # 引用符で割ったオプション（"--force" / -"f" / "--amend"）の扱いは各 verdict に任せる。
  # git commit の -m "- add x" のような値や、git push 区間の外の引用トークンは対象外。
  case "$raw" in
    "git push"*)
      [ "$(push_destination_verdict "$raw" "$cwd")" = ok ] || return 1
      ;;
    "git commit"*)
      [ "$(commit_verdict "$raw" "$cwd")" = ok ] || return 1
      # コミットされる差分に既知のトークン形式があれば自動承認しない（確認ダイアログに落とす）
      [ -n "$(secret_hits "$raw")" ] && return 1
      ;;
    "gh pr create"* | "gh pr new"* | "gh pr edit"*)
      # 別リポジトリ宛（-R / --repo）は自動許可の対象外
      printf '%s\n' "$flat" | grep -Eq -- '(^|[[:space:]])(-R|--repo)([[:space:]=]|$)' && return 1
      # 引用符で割った -R / --repo も自動承認しない（--title "- x" のような値は対象外）
      kq=$(printf '%s\n' "$raw" | awk -v keepq=1 -f "$STRIP_AWK" 2>/dev/null | tr '\n' ' ')
      set -f
      for tok in $kq; do
        nq=${tok//[\"\']/}
        [ "$tok" = "$nq" ] && continue
        case "$nq" in
          -R | --repo | --repo=*) set +f; return 1 ;;
        esac
      done
      set +f
      ;;
  esac
  if [ "$is_api" -eq 1 ] && is_pr_merge "$raw"; then return 1; fi
  return 0
}

emit_pre_deny() {
  jq -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
}
emit_pre_ask() {
  jq -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
}
emit_perm_deny() {
  jq -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"deny",message:$r}}}'
}

is_shell_tool() {
  case "$1" in Bash | run_terminal_command) return 0 ;; *) return 1 ;; esac
}

case "$event" in
  PreToolUse)
    tool=$(printf '%s' "$input" | jq -r '.tool_name // .toolName // empty')
    is_shell_tool "$tool" || exit 0
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // .toolInput.command // empty')
    [ -n "$cmd" ] || exit 0

    # サブエージェントからの git 書き込みは常に拒否する
    agent=$(printf '%s' "$input" | jq -r '.agent_id // .agentId // empty')
    if [ -n "$agent" ] && is_git_write "$cmd" "$(stripped_or_raw "$cmd")"; then
      emit_pre_deny 'コミット・push・PR の作成と更新はメインセッションが直接実行してください（サブエージェントからは実行できません）。'
      exit 0
    fi

    # force push は常に deny（引用符で割った --force は push 判定側で拾う）
    if is_force_push "$cmd"; then
      emit_pre_deny 'force push は禁止されています'
      exit 0
    fi

    # 既定ブランチへの commit / push は常に deny
    if [ "$(commit_verdict "$cmd" "$cwd")" = protected ]; then
      emit_pre_deny '既定ブランチ（main / master / origin/HEAD が指すブランチ）への commit は禁止されています。作業ブランチを作成してください。'
      exit 0
    fi
    push_kind=$(push_destination_verdict "$cmd" "$cwd")
    case "$push_kind" in
      all | delete)
        emit_pre_deny '--all / --mirror での push とリモートブランチの削除は禁止されています'
        exit 0
        ;;
      force)
        emit_pre_deny 'force push は禁止されています'
        exit 0
        ;;
      no-verify)
        emit_pre_deny '--no-verify は使いません'
        exit 0
        ;;
      protected)
        emit_pre_deny '既定ブランチ（main / master / origin/HEAD が指すブランチ）への push は禁止されています。PR 用ブランチを使ってください。'
        exit 0
        ;;
    esac

    # PR のマージは常に確認ダイアログ
    if is_pr_merge "$cmd"; then
      emit_pre_ask 'PR のマージは自動許可しません。内容を確認してから実行してください。'
      exit 0
    fi

    # 履歴改変・フック回避の commit は自動承認しない
    if [ "$(commit_verdict "$cmd" "$cwd")" = ask ]; then
      emit_pre_ask '--amend / --no-verify / -n を含むコミットは自動許可しません。内容を確認してください。'
      exit 0
    fi

    # 宛先を判定できない push は確認ダイアログ
    if [ "$push_kind" = indeterminate ]; then
      emit_pre_ask 'push の宛先を判定できません（変数・ワイルドカード等）。宛先を確認してください。'
      exit 0
    fi

    # コミット直前に、コミットされる差分の秘密情報を検査する（一致があれば自動承認しない）
    case "$cmd" in
      "git commit"*)
        hits=$(secret_hits "$cmd")
        if [ -n "$hits" ]; then
          emit_pre_ask "コミットされる差分に秘密情報の形式が見つかりました: ${hits}。該当ファイルを add から外すか、ユーザーに確認してください。"
          exit 0
        fi
        ;;
    esac

    # Grok は PermissionRequest を持たない。自動承認条件を満たさない git 書き込みは ask
    # （hook の ask は always-approve でも確認プロンプトになる）
    if [ -n "${GROK_HOOK_EVENT:-}" ] && is_git_write "$cmd" "$(stripped_or_raw "$cmd")" && ! is_auto_approvable "$cmd"; then
      emit_pre_ask 'この git 操作は自動許可の対象外です。force / amend / 既定ブランチ宛 / 複合コマンドではないか確認してください'
    fi
    ;;
  PermissionRequest)
    tool=$(printf '%s' "$input" | jq -r '.tool_name // .toolName // empty')
    is_shell_tool "$tool" || exit 0
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // .toolInput.command // empty')
    [ -n "$cmd" ] || exit 0

    # PreToolUse が無効な環境向けの二重化。既定ブランチ・force・削除系は deny。
    if is_force_push "$cmd"; then
      emit_perm_deny 'force push は禁止されています'
      exit 0
    fi
    if [ "$(commit_verdict "$cmd" "$cwd")" = protected ]; then
      emit_perm_deny '既定ブランチへの commit は禁止されています'
      exit 0
    fi
    case "$(push_destination_verdict "$cmd" "$cwd")" in
      all | delete | force | no-verify | protected)
        emit_perm_deny '既定ブランチ宛・force・削除系の push は許可されません'
        exit 0
        ;;
    esac

    # マージは確認ダイアログ（allow を返さない）
    if is_pr_merge "$cmd"; then exit 0; fi

    if is_auto_approvable "$cmd"; then
      jq -cn '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"allow"}}}'
    fi
    ;;
esac

exit 0
