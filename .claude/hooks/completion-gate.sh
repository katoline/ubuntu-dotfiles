#!/bin/bash

# 完了チェックゲートフック（ファイルを変更したターンを、PDCA の Check を報告するまで終えさせない）
#
# 契約: 前回のチェック以降にファイルを変更したセッション（Claude 自身の Edit / Write / NotebookEdit と、OpenCode への委譲）では、
# Stop のたびに decision: block と完了チェックの理由を返し、ターンを終えさせない。ただし同じターンで続行を促すのは
# 最大 3 回まで（blocks が 3 以上なら systemMessage で終了を許可し、次のユーザー入力まで促さない）。
# このセッションが起動した OpenCode ランナーが同じプロジェクトで実行中のときは、完了待ちで止まっているだけなので
# 何もせず状態も変えない（他セッションが起動したランナーでは抑止しない）。
# 既知の制約: 抑止は「このセッションが起動した（opencode=1）」と「同じリポジトリ（git common-dir が同じ）のどこかで
# ランナーが動いている」の組み合わせで判定するため、自分のランナーが終わった後でも、同じリポジトリの別 worktree で
# 別セッションのランナーが動いている間は完了チェックが抑止される。
#
# 登録イベントと役割（1 本のスクリプトを hook_event_name / tool_name で分岐）:
# - UserPromptSubmit: blocks を 0 に戻す（edited と opencode はそのまま）。新しいターンの始まり。
# - PostToolUse(Edit|Write|NotebookEdit): 編集先（file_path / notebook_path）が一時領域（${TMPDIR:-/tmp}・/tmp）と
#   $HOME/.claude/projects/ の外なら edited=1。Claude のメモリや一時ファイルは「成果物の変更」と見なさない。
# - PostToolUse(Bash): コマンドの先頭か `&&` `;` `|` `||` の直後に `bash <パス>/.claude/skills/opencode/scripts/run.sh` の
#   起動形があるなら edited=1・opencode=1（委譲先の編集はフックに見えないため）。grep / sed / cat / bash -n は数えない。
# - Stop: このセッションが起動した OpenCode（opencode=1）が実行中なら何もせず状態も変えない。
#   それ以外の Stop では opencode=0 に戻したうえで、edited=1 なら次の順で判定する。
#   - blocks >= 3 なら systemMessage で上限到達を伝え、edited=0 にする（blocks は戻さない）
#   - それ以外は decision: block と理由（残り回数入り）を返し、edited=0・blocks+1 に更新する
#   stop_hook_active は見ない（Claude の再入フラグではなく、このスクリプト自身の回数で無限ループを防ぐ）。
#
# 状態ファイル: ${TMPDIR:-/tmp}/claude-completion-gate-<session_id>
#   （`edited=0|1`・`blocks=<整数>`・`opencode=0|1` の 3 行）
# 制約: session_id 単位（サブエージェントの編集も同じ session_id で届く）。Esc などで中断したターンの edited は
#   ターン境界で消さないため次のターンへ持ち越され、次に Stop したときに未チェックの編集として拾われる
#   （UserPromptSubmit が戻すのは blocks だけ）。session_id が無い・不正な文字を含む・jq が無い・入力 JSON が
#   壊れている → 何もせず exit 0。どのイベントでも exit 0 固定。

exec 2>/dev/null
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
[ -n "$input" ] || exit 0
# 入力 JSON の解析は 1 回だけ（使う全フィールドを @sh で引用して位置パラメータに展開する。無いフィールドは空文字）
fields=$(printf '%s' "$input" | jq -r '
  (.tool_input | if type == "object" then . else {} end) as $ti
  | [ (.hook_event_name // ""), (.session_id // ""), (.tool_name // ""),
      ($ti.file_path // $ti.notebook_path // ""), ($ti.command // ""), (.cwd // "") ]
  | map(tostring) | @sh') || exit 0
eval "set -- $fields" || exit 0
event="$1" session="$2" tool="$3" f="$4" cmd="$5" cwd="$6"
[[ "$session" =~ ^[A-Za-z0-9._-]+$ ]] || exit 0

STATE="${TMPDIR:-/tmp}"
STATE="${STATE%/}/claude-completion-gate-${session}"
MAX_BLOCKS=3
SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" || printf '%s' "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd -P)" || exit 0
OPENCODE_RUNNING_LIB="$SELF_DIR/lib/opencode-running.sh"
if [ -r "$OPENCODE_RUNNING_LIB" ]; then
  # shellcheck source=lib/opencode-running.sh
  . "$OPENCODE_RUNNING_LIB"
fi

# 実体パスに解決する（存在しないファイルは親ディレクトリだけ解決する）
resolve() {
  local d
  if readlink -f "$1" 2>/dev/null; then return 0; fi
  d=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P) || { printf '%s\n' "$1"; return 0; }
  printf '%s/%s\n' "$d" "$(basename "$1")"
}

# 状態を読む（無い・壊れている行は既定値のまま。blocks は 10 進の整数だけを受け付ける）
load_state() {
  edited=0
  blocks=0
  opencode=0
  [ -f "$STATE" ] || return 0
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      edited) [ "$v" = "1" ] && edited=1 ;;
      opencode) [ "$v" = "1" ] && opencode=1 ;;
      blocks)
        case "$v" in
          '' | *[!0-9]*) ;;
          *)
            while [ "${v#0}" != "$v" ]; do v="${v#0}"; done
            blocks="${v:-0}" ;;
        esac ;;
    esac
  done <"$STATE"
  return 0
}

save_state() { # edited blocks [opencode]
  printf 'edited=%s\nblocks=%s\nopencode=%s\n' "$1" "$2" "${3:-0}" >"$STATE"
}

# 成果物の変更と見なさない編集先か（一時領域・Claude のメモリ）
is_ignored_path() { # resolved path
  local p="$1" tmp home
  tmp=$(resolve "${TMPDIR:-/tmp}")
  tmp="${tmp%/}"
  [ -n "$tmp" ] || tmp="/tmp"
  case "$p" in
    "$tmp"/* | /tmp/*) return 0 ;;
  esac
  if [ -n "${HOME:-}" ]; then
    home=$(resolve "$HOME")
    home="${home%/}"
    case "$p" in "$home/.claude/projects/"*) return 0 ;; esac
  fi
  return 1
}

# OpenCode ランナーの起動形か（コマンド先頭か `&&` `;` `|` `||` の直後の `bash <…>/run.sh`）。
# grep / sed / cat / `bash -n` など、run.sh を読むだけのコマンドは起動と見なさない。
is_opencode_launch() { # command
  local re='(^[[:space:]]*|(&&|\|\||;|\|)[[:space:]]*)bash[[:space:]]+[^[:space:]]*\.claude/skills/opencode/scripts/run\.sh([[:space:]]|$)'
  [[ "$1" =~ $re ]]
}

case "$event" in
  UserPromptSubmit)
    load_state
    [ -f "$STATE" ] && save_state "$edited" 0 "$opencode"
    ;;
  PostToolUse)
    case "$tool" in
      Edit | Write | NotebookEdit)
        [ -n "$f" ] || exit 0
        is_ignored_path "$(resolve "$f")" && exit 0
        load_state
        save_state 1 "$blocks" "$opencode"
        ;;
      Bash)
        if is_opencode_launch "$cmd"; then
          load_state
          save_state 1 "$blocks" 1
        fi
        ;;
    esac
    ;;
  Stop)
    load_state
    # このセッションが起動したランナーが実行中なら、完了待ちで止まっているだけなので状態も変えない
    if [ "$opencode" = "1" ] && declare -F opencode_running_in_cwd >/dev/null 2>&1 \
      && opencode_running_in_cwd "$cwd"; then
      exit 0
    fi
    # ここから先は抑止しない Stop。opencode は次の起動まで戻す
    if [ "$edited" != "1" ]; then
      [ -f "$STATE" ] && save_state "$edited" "$blocks" 0
      exit 0
    fi
    if [ "$blocks" -ge "$MAX_BLOCKS" ]; then
      msg="completion-gate: 完了チェックの上限（このターン${MAX_BLOCKS}回）に達したため終了を許可しました。未完了の要件が残っていないか確認してください。"
      save_state 0 "$blocks" 0
      jq -cn --arg m "$msg" '{systemMessage: $m}'
      exit 0
    fi
    remaining=$((MAX_BLOCKS - blocks - 1))
    reason="completion-gate（PDCA の Check）: 前回のチェック以降にファイルを変更しました（OpenCode への委譲を含む）。終える前に次を確認し、未達があれば直してから終えてください。すべて満たしていれば、確認結果を報告に書いてそのまま終えてよい。ユーザーの回答待ち、またはバックグラウンドのサブエージェント・タスクの完了待ちで止める場合は、その旨を書いて終えてよい。
1. 最初の依頼と途中の追加指示を要件として列挙し、各要件を満たした根拠（file:line・コマンドの出力）を挙げる。根拠を示せない要件は未完了として扱う
2. プロジェクトの検証コマンド（AGENTS.md / CLAUDE.md）をフォアグラウンドで実行し、成功を確認した（無ければ報告に「未検証」と書く）
3. 挙動に関わる変更は新しいコンテキストの独立レビューを受け、指摘の採否を判断した
4. 直した場合は、修正した差分に対して 2・3 をやり直した
5. プロジェクト指示にある付随作業（作業記録・README・配布・PR など）を済ませた
6. 報告に要件ごとの「完了 / 未完了（理由）」を書く
（このターンで続行を促すのは残り ${remaining} 回）"
    save_state 0 "$((blocks + 1))" 0
    jq -cn --arg r "$reason" '{decision: "block", reason: $r}'
    ;;
esac

exit 0
