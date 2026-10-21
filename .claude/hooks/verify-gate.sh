#!/bin/bash

# 検証ゲートフック（dotfiles の検証コマンドを実行するまでターンを終えさせない）
#
# 契約: dotfiles の検証対象ファイルを Edit / Write / NotebookEdit で変更したセッションでは、対応する検証コマンドが
# 成功するまでターンを終えさせない（1 回だけ続行させ、それでも未検証なら終了を許してユーザーに警告し、記録を消す）。
#
# リポジトリの AGENTS.md は「.claude/ 配下や各CLIの設定を変えたら bash .claude/tests/run.sh、flake.nix / nix/ を
# 変えたら nix eval --raw .#homeConfigurations.ubuntu.activationPackage.drvPath」と定めているが、
# 指示は守られないことがあるため Stop で機構的に強制する。
#
# 登録イベントと役割（1 本のスクリプトを hook_event_name / tool_name で分岐）:
# - PostToolUse(Edit|Write|NotebookEdit): 編集先を実体パスに解決し、dotfiles ルート（このスクリプトの実体から ../..）の
#   内側なら分類して、状態ファイルにカテゴリ名を重複なしで記録する
#     run.sh   … .claude/hooks/**・.claude/tests/**・.claude/settings.json・.claude/setup.sh・bootstrap.sh・
#                .claude/skills/** のうち .md 以外と .claude/skills/<名前>/SKILL.md・.claude/agents/<名前>.md・
#                ai/**・codex/**・devin/**・opencode/*.json・opencode/setup.sh
#                （run.sh が検査するものだけ。skills 配下の参考資料の .md や agents のサブディレクトリは対象外）
#     nix eval … flake.nix・flake.lock・nix/**/*.nix
#     両方     … .claude/dev-roots・nix/merge-cli-config.py（run.sh が検査するうえ、nix/home.nix も読み込む）
# - PostToolUse(Bash): 成功した Bash のうち、コマンドに .claude/tests/run.sh を含むか、cwd がこの dotfiles の .claude で
#   コマンドが直接の `bash tests/run.sh`（許容する `| tail -N` 形を含む）のとき、stdout に行全体が「すべて通過」の行が
#   あれば、そのコマンドが実行された checkout（ROOT または同じ Git リポジトリの worktree）の run.sh だけを記録から消す。
#   コマンドに homeConfigurations.ubuntu を含み stdout に行全体が /nix/store/<名前>.drv の行があれば、cwd の
#   checkout の nix eval だけを消す（| tail でパイプすると終了コードは tail のものになるため出力で判定する。
#   HOOKS_DIR= 付きの実行は別の場所のフックを検査しているので数えない。相対形は cwd がこの dotfiles の .claude を
#   指し、かつコマンドが cd や複合コマンドで別ディレクトリへ移らないときだけ解除する＝別リポジトリの同名
#   tests/run.sh の成功では解除しない。状態は編集した worktree ごとに保持し、別 worktree の成功では消さない）
# - Stop: 記録が残っていれば、stop_hook_active が false なら decision: block と理由で 1 回だけ続行させる（記録は残す）。
#   true なら systemMessage で未検証のまま終了した旨を警告し、記録を消す（無限ループ防止。次に対象を編集するまで促さない）
#
# 状態ファイル: ${TMPDIR:-/tmp}/claude-verify-gate-<session_id>（1 行 1 エントリ、`<カテゴリ>\t<worktree トップ>`）
# 制約: session_id 単位（サブエージェントの編集も同じ session_id で届く）。Bash（sed -i 等）による編集は検出しない。
#   session_id が無い・不正な文字を含む・jq が無い・入力 JSON が壊れている → 何もせず exit 0。どのイベントでも exit 0 固定。

exec 2>/dev/null
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
[ -n "$input" ] || exit 0
# 入力 JSON の解析は 1 回だけ（使う全フィールドを @sh で引用して位置パラメータに展開する。無いフィールドは空文字）
fields=$(printf '%s' "$input" | jq -r '
  (.tool_input | if type == "object" then . else {} end) as $ti
  | [ (.hook_event_name // ""), (.session_id // ""), (.tool_name // ""),
      ($ti.file_path // $ti.notebook_path // ""), ($ti.command // ""),
      (.tool_response | if type == "object" then (.stdout // "") elif type == "string" then . else "" end),
      (.stop_hook_active // false), (.cwd // "") ]
  | map(tostring) | @sh') || exit 0
eval "set -- $fields" || exit 0
event="$1" session="$2" tool="$3" f="$4" cmd="$5" out="$6" active="$7" cwd="$8"
[[ "$session" =~ ^[A-Za-z0-9._-]+$ ]] || exit 0

STATE="${TMPDIR:-/tmp}"
STATE="${STATE%/}/claude-verify-gate-${session}"
SELF="$(readlink -f "${BASH_SOURCE[0]}" || printf '%s' "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "$SELF")/../.." && pwd -P)" || exit 0
CMD_RUNSH="bash .claude/tests/run.sh"
CMD_NIX="nix eval --raw .#homeConfigurations.ubuntu.activationPackage.drvPath"

# 実体パスに解決する（存在しないファイルは親ディレクトリだけ解決する）
resolve() {
  local d
  if readlink -f "$1"; then return 0; fi
  d=$(cd "$(dirname "$1")" && pwd -P) || { printf '%s\n' "$1"; return 0; }
  printf '%s/%s\n' "$d" "$(basename "$1")"
}

# 同じ Git リポジトリ（common-dir が同じ）の worktree なら、そのトップを返す。
# ROOT 自身が Git 管理外（テストの模擬 repo など）なら何も返さない。
same_repo_top() {
  local p dir top common main_common real
  p="$1"
  [ -d "$p" ] || p=$(dirname "$p")
  [ -d "$p" ] || return 1
  top=$(git -C "$p" rev-parse --show-toplevel 2>/dev/null) || return 1
  common=$(git -C "$top" rev-parse --git-common-dir 2>/dev/null) || return 1
  main_common=$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in /*) ;; *) common="$top/$common" ;; esac
  case "$main_common" in /*) ;; *) main_common="$ROOT/$main_common" ;; esac
  real=$(cd "$common" 2>/dev/null && pwd -P) || return 1
  [ "$real" = "$(cd "$main_common" 2>/dev/null && pwd -P)" ] || return 1
  cd "$top" && pwd -P
}

# 実体パスから `<カテゴリ>\t<worktree トップ>` を 1 行 1 つ返す（対象外なら何も返さない）。
# ROOT の外でも、同じ Git リポジトリの worktree ならその worktree の相対パスで分類する。
# 状態はカテゴリだけでなく編集した worktree にも結び付ける（別 worktree の成功で解除しない）。
classify() {
  local rel top
  case "$1" in
    "$ROOT"/*) top="$ROOT"; rel="${1#"$ROOT"/}" ;;
    *)
      top=$(same_repo_top "$1") || return 0
      case "$1" in "$top"/*) rel="${1#"$top"/}" ;; *) return 0 ;; esac ;;
  esac
  case "$rel" in
    .claude/dev-roots | nix/merge-cli-config.py) printf 'run.sh\t%s\nnix eval\t%s\n' "$top" "$top" ;;
    .claude/hooks/* | .claude/tests/* | .claude/settings.json | .claude/setup.sh | bootstrap.sh) printf 'run.sh\t%s\n' "$top" ;;
    ai/README.md) ;;
    ai/* | codex/* | devin/* | opencode/setup.sh | opencode/*.json | opencode/plugins/* | opencode/hooks/*) printf 'run.sh\t%s\n' "$top" ;;
    .claude/skills/*)
      case "$rel" in
        *.md) [[ "${rel#.claude/skills/}" =~ ^[^/]+/SKILL\.md$ ]] && printf 'run.sh\t%s\n' "$top" ;;
        *) printf 'run.sh\t%s\n' "$top" ;;
      esac ;;
    .claude/agents/*) [[ "${rel#.claude/agents/}" =~ ^[^/]+\.md$ ]] && printf 'run.sh\t%s\n' "$top" ;;
    flake.nix | flake.lock | nix/*.nix | nix/*/*.nix) printf 'nix eval\t%s\n' "$top" ;;
  esac
  return 0
}

# checkout のトップ（ROOT または同じ Git リポジトリの worktree）なら実体パスを返す
checkout_top() {
  local p top
  [ -n "$1" ] || return 1
  p=$(resolve "$1")
  [ -d "$p" ] || return 1
  [ "$p" = "$ROOT" ] && { printf '%s\n' "$p"; return 0; }
  top=$(same_repo_top "$p" 2>/dev/null) || return 1
  [ "$top" = "$p" ] && { printf '%s\n' "$p"; return 0; }
  return 1
}

# cwd が checkout の .claude を指すなら、その checkout のトップを返す
claude_dir_top() {
  local p top
  [ -n "$1" ] || return 1
  p=$(resolve "$1")
  [ -d "$p" ] && [ "$(basename "$p")" = ".claude" ] || return 1
  top=$(cd "${p%/.claude}" 2>/dev/null && pwd -P) || return 1
  [ "$top" = "$ROOT" ] && { printf '%s\n' "$top"; return 0; }
  [ "$(same_repo_top "$top" 2>/dev/null)" = "$top" ] && { printf '%s\n' "$top"; return 0; }
  return 1
}

# 解除対象にしてよい直接実行の形だけを受け付ける。cd / 複合 / 変数 / 別コマンドへのパイプは未対応（保留）。
# 一致したら実行ファイル部分（tests/run.sh・.claude/tests/run.sh・絶対パス）を返す。
direct_runsh() {
  local re='^[[:space:]]*bash[[:space:]]+(tests/run\.sh|\.claude/tests/run\.sh|/[^[:space:]|;&]+/\.claude/tests/run\.sh)([[:space:]]+2>&1)?([[:space:]]*\|[[:space:]]*tail([[:space:]]+(-n[[:space:]]+)?-?[0-9]+)?)?[[:space:]]*$'
  [[ "$1" =~ $re ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# nix は cwd の checkout の .# を評価する直接形だけ解除する。
# 別の flake パスを明示した形は、どの worktree の検証か判定せず保留にする。
is_direct_nix_eval() {
  local re='^[[:space:]]*nix[[:space:]]+eval[[:space:]]+--raw[[:space:]]+\.#homeConfigurations\.ubuntu\.activationPackage\.drvPath([[:space:]]+2>&1)?([[:space:]]*\|[[:space:]]*tail([[:space:]]+(-n[[:space:]]+)?-?[0-9]+)?)?[[:space:]]*$'
  [[ "$1" =~ $re ]]
}

# カテゴリと worktree の組を状態ファイルから消し、空になったらファイルごと消す
remove_pending() { # category top
  [ -f "$STATE" ] || return 0
  local tmp="${STATE}.tmp.$$"
  grep -vxF -- "$1"$'\t'"$2" "$STATE" >"$tmp"
  if [ -s "$tmp" ]; then mv -f "$tmp" "$STATE"; else rm -f "$tmp" "$STATE"; fi
}

# Stop 時の説明文（カテゴリと、実際に検証すべき worktree）
explain() { # category top
  case "$1" in
    run.sh) printf -- '- run.sh（%s）: その worktree のルートで `%s` を実行し、最終行が「すべて通過」になることを確認する。理由: .claude/ は ~/.claude の実体で、編集はコミット前でも全プロジェクトの Claude Code に即反映される。フックの判定の退行や settings.json・各CLI設定の破損はこのテストでしか検出できない\n' "$2" "${CMD_RUNSH}" ;;
    "nix eval") printf -- '- nix eval（%s）: その worktree のルートで `%s` を実行し、/nix/store/…drv が出力されることを確認する。理由: flake の評価エラーや git add し忘れた .nix は、ユーザーに home-manager switch を依頼してから初めて発覚するため、依頼前にここで検出する\n' "$2" "${CMD_NIX}" ;;
  esac
}

case "$event" in
  PostToolUse)
    case "$tool" in
      Edit | Write | NotebookEdit)
        [ -n "$f" ] || exit 0
        classify "$(resolve "$f")" | while IFS=$'\t' read -r c top; do
          [ -n "$c" ] || continue
          [ -n "$top" ] || top="$ROOT"
          ! grep -qxF -- "$c"$'\t'"$top" "$STATE" 2>/dev/null && printf '%s\t%s\n' "$c" "$top" >>"$STATE"
        done ;;
      Bash)
        [ -f "$STATE" ] || exit 0
        case "$cmd" in
          *HOOKS_DIR=*) ;;
          *)
            target=$(direct_runsh "$cmd") || target=""
            if [ -n "$target" ] && printf '%s\n' "$out" | grep -qxF 'すべて通過'; then
              case "$target" in
                # .claude から実行する相対形は、その .claude の親 checkout の検証
                tests/run.sh) top=$(claude_dir_top "$cwd") || top="" ;;
                # checkout 直下から実行する相対形は、その checkout の検証
                .claude/tests/run.sh) top=$(checkout_top "$cwd") || top="" ;;
                # 絶対パスは実行ファイル自身から検証先を特定する
                /*) top="${target%/.claude/tests/run.sh}"; top=$(checkout_top "$top") || top="" ;;
              esac
              [ -n "$top" ] && remove_pending "run.sh" "$top"
            fi
            if is_direct_nix_eval "$cmd" && printf '%s\n' "$out" | grep -qE '^/nix/store/[^/[:space:]]+\.drv$'; then
              top=$(checkout_top "$cwd") || top=""
              [ -n "$top" ] && remove_pending "nix eval" "$top"
            fi ;;
        esac ;;
    esac
    ;;
  Stop)
    [ -s "$STATE" ] || exit 0
    pending=""; names=""
    while IFS=$'\t' read -r c top; do
      [ -n "$c" ] || continue
      [ -n "$top" ] || top="$ROOT"
      pending="${pending}$(explain "$c" "$top")
"
      names="${names:+${names}、}${c}（${top}）"
    done <"$STATE"
    [ -n "$names" ] || exit 0
    if [ "$active" = "true" ]; then
      msg="verify-gate: dotfiles の検証（${names}）が未実行のままターンを終了しました。変更は未検証です。検証対象のファイルを新たに編集するまで、これ以上は続行を促しません。検証するには次を実行させてください。
${pending}"
      jq -cn --arg m "$msg" '{systemMessage: $m}'
      rm -f "$STATE"
    else
      reason="verify-gate: このセッションで dotfiles の検証対象ファイルを変更しましたが、対応する検証（${names}）がまだ成功していません。ターンを終える前に次を実行してください（| tail 等でパイプしてもよい。出力で成功を判定する）。バックグラウンド実行（run_in_background）では結果が届かず解除されないので、フォアグラウンドで実行する。
${pending}
失敗した場合は自分の変更が原因なら直して再実行する。自分の変更と無関係な既存の失敗なら直さずユーザーに報告する。どうしても実行できない場合は、報告に「未検証」と明記してから終える。"
      jq -cn --arg r "$reason" '{decision: "block", reason: $r}'
    fi
    ;;
esac

exit 0
