#!/bin/bash

# 破壊的コマンドのガードフック（PreToolUse / Bash）
# permission mode（auto / acceptEdits / bypassPermissions）や allow ルールに関係なく
# 毎回発火する PreToolUse で、回復不能な操作を機構的に止める。
#
# 契約（一文）:
#   解釈できる削除（対象のコマンド置換・HEREDOC・eval を含まず、対象がすべて許可ルートか一時領域に
#   解決できるもの）は確認なし。致命的な対象と、解釈できたうえで許可ルート外の削除は deny。
#   解釈できない削除・移動、xargs / eval / sh -c 経由、閉じていない引用符・HEREDOC、一括 kill、
#   .git の削除は deny（ask は返さない）。
#
# 判定は上から順に行い、最初に決まった deny で終了する（ask は一切返さない）:
#   1. 致命 deny …… ルート / ホーム直下 / ~/.claude / dotfiles の .claude を対象にした rm・mv、
#                    curl | sh 系のリモートスクリプト実行、ディスク操作。生文字列（引用符の中も含む）で見る。
#                    シェルへ文字列を渡す形（eval / sh -c / … | sh / bash <<EOF）では、その文字列を bash が
#                    実行するので、元のコマンド文字列全体（引用符の中身・HEREDOC 本文を含む）にも同じ判定を掛ける
#   2. 削除の範囲判定 … rm / rmdir / unlink / find -delete / mv の対象を 1 つずつ解決する
#        解決できて許可ルート（.claude/dev-roots の各行）か一時領域（$TMPDIR・/tmp/claude-*）の内側 → 通す
#        解決できて外側（~/Dev 直下・ホーム・許可ルートそのもの）→ deny
#        解決できない（未知の変数・コマンド置換・追跡できない cd・範囲形ブレース・~user）→ deny
#        リンクされた git worktree のルート（直下の .git が gitdir: …/worktrees/… を指す）を
#        rm -rf で消す場合は、許可ルート外でも通す（致命対象の deny が優先）
#        同じコマンドで削除より前に直線的に実行される単純な代入（S=/tmp/x && rm -rf $S/w、T=$(mktemp -d)）は
#        値で展開してから判定する。変数名が代入以外の形（read・for 等）でも現れる、条件付き・別スコープ・
#        関数の中の削除などは解決せず deny（詳細は split_stmts の上）
#        削除前の直線的な絶対 cd は成功が分かる && の連鎖に限って基準にする（mv は従来どおり）
#        dotfiles 自体・.claude 配下の設定実体・作業中ディレクトリの再帰削除 → deny
#   3. 削除語を含むが構造を解釈できない形 … eval / sh -c / … | sh / bash <<EOF / xargs 経由、
#                    引用符や HEREDOC が閉じていない → deny
#   4. 一括 kill（killall / pkill / kill -1）と .git の削除 → deny
#
# deny の理由文は「何をするコマンドか（対象を含む 1 文）」＋「対象を具体的なパスで書き直して
# 再実行してください（必要ならユーザーに実行を依頼）」の順で書く。
# 破壊的な git 操作（reset --hard / clean / rebase 等）と絶対パスへの再帰 chmod / chown は
# 何も返さない（確認なし）。作業ツリー・履歴を壊さないことは共通指示で守る。
#
# 判定材料:
#   - lib/strip-shell.awk で引用符の中身と HEREDOC 本文を除いた文字列（s）。コミットメッセージ等の
#     リテラル（"rm -rf /" など）を誤検知しない。bash が実際に展開する部分（"…" 内の $( ) と `…`、
#     引用符無しタグの HEREDOC 本文の $( )）は判定対象に戻される
#   - rm / mv の対象パスだけは引用符を残した版（rq。引用符の中の空白・; & | は \001 に置き換え）で見る
#   - 行継続（\ + 改行）と行末の演算子（| && ||）は 1 行に結合してから判定する
#   - カンマ区切りのブレース展開（{dist,build}）は bash と同じ順で展開して各パスを判定する
#
# 範囲外: bash script.sh のようなスクリプト経由の間接実行、trash / rsync --delete 等の別手段、
# シンボリックリンク経由のパス。CLAUDE.md の指示・permissions.ask・auto mode の分類器と併用する
# 多層防御の一層と位置づけ、構文の網羅は追わない（解釈できない削除は deny に倒す）。
# git push の force / delete は pr-mode.sh が扱う。何が起きても exit 0（判定不能なら deny せず通す）。

SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
STRIP_AWK="$(dirname "$SELF")/lib/strip-shell.awk"
DEV_ROOTS="$(dirname "$SELF")/../dev-roots"

command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // .toolName // empty' 2>/dev/null) || exit 0
case "$tool" in Bash|run_terminal_command) ;; *) exit 0 ;; esac
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // .toolInput.command // empty')
[ -n "$cmd" ] || exit 0
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')

# 理由文の \001（引用符の中の空白の置き換え）は bash の置換で戻す（外部コマンドの tr はロケール依存で落ちる）
deny() { local r=${1//$'\001'/ }; jq -cn --arg r "$r" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; exit 0; }
# 解決できない削除・移動は deny。理由文の末尾に対象を書き直すよう促す一文を足す。
deny_unresolved() { deny "$(explain_unresolved "$1" "$2" "$3")。対象を具体的なパスで書き直して再実行してください（必要ならユーザーに実行を依頼）"; }

# ---- 許可ルート（.claude/dev-roots。1 行 1 パス、~/ 始まり、# はコメント）----
ALLOWED_ROOTS=""; ROOTS_DISP=""
if [ -f "$DEV_ROOTS" ]; then
  # 読み方（# 以降を落とす・前後の空白を除く・末尾の / を落とす・~/ 始まりの行だけ採る）は
  # nix/home.nix の devDirs・tests/test-guard-destructive.sh の DR テストと揃えてある
  while IFS= read -r line; do
    line=${line%%#*}; line=${line#"${line%%[![:space:]]*}"}; line=${line%"${line##*[![:space:]]}"}; line=${line%/}
    case "$line" in '~/'?*) ;; *) continue ;; esac
    ROOTS_DISP="$ROOTS_DISP${ROOTS_DISP:+・}${line}"
    ALLOWED_ROOTS="$ALLOWED_ROOTS${ALLOWED_ROOTS:+$'\n'}$HOME/${line#\~/}"
  done < "$DEV_ROOTS"
fi
[ -n "$ROOTS_DISP" ] || ROOTS_DISP="（.claude/dev-roots が読めないため許可ルートなし）"
TMP_PREFIXES="/tmp/claude-
/private/tmp/claude-"
# TMPDIR が未設定なら一時領域は /tmp/claude-* だけ（/tmp 全体を許可領域にしない）
tmpdir="${TMPDIR:-}"; tmpdir="${tmpdir%/}"
[ -n "$tmpdir" ] && TMP_PREFIXES="$TMP_PREFIXES
$tmpdir/
/private$tmpdir/"

# ---- 判定用文字列の準備 ----
if [ -f "$STRIP_AWK" ]; then
  s=$(printf '%s\n' "$cmd" | awk -f "$STRIP_AWK" 2>/dev/null) || s="$cmd"
  rq=$(printf '%s\n' "$cmd" | awk -v keepq=1 -f "$STRIP_AWK" 2>/dev/null) || rq="$cmd"
else
  s="$cmd"; rq="$cmd"
fi
# 引用符・HEREDOC・$( が閉じていないと awk は末尾に ";" だけの行を返す（解析失敗の合図）
parse_failed=0
case "$s" in ';' | *$'\n;') parse_failed=1 ;; esac
join_lines() { awk 'NR > 1 { printf "%s", (prev ~ /([|][|]|&&|[|])[ \t]*$/ ? " " : "\n") } { printf "%s", $0; prev = $0 } END { if (NR) printf "\n" }'; }
s=${s//\\$'\n'/ }; rq=${rq//\\$'\n'/ }
s=$(printf '%s\n' "$s" | join_lines); rq=$(printf '%s\n' "$rq" | join_lines)
PH=$'\001'
s1=$(printf '%s' "$s" | tr '\n' ';')      # 改行を区切りにした 1 行版
# git rm / npm rm 等のサブコマンド "rm" はファイル削除ではないので、rm の抽出に掛からないよう "git-rm" に潰す
raw1=$(printf '%s' "$rq" | tr '\n' ';' | sed -E 's/(^|[[:space:];&|(`])(git|npm|pnpm|bun|cargo|docker|podman|kubectl|helm|terraform)[[:space:]]+rm([[:space:]]|$)/\1\2-rm\3/g')

SEP='(^|[;&|(`\\][[:space:]]*|[[:space:]])'   # コマンド語の直前に来る区切り（\rm のエイリアス回避も含む）
HOME_RE='(~|\$HOME|\$\{HOME\}|/Users/[^/[:space:]"'"'"']+|/home/[^/[:space:]"'"'"']+)'
CLAUDE_CORE='(hooks|skills|agents|settings\.json|CLAUDE\.md)'
# 削除語（引用符の中の空白は \001 なので、区切りとして \001 も許す）
DEL_RE="(^|[[:space:];&|\"'\`(${PH}])(rm|rmdir|unlink)([[:space:]${PH}]|\$)|find[[:space:]${PH}][^\"']*-delete"

# 引数に分ける。引用符・コマンド置換の中の空白は同じ引数として残す。
# 閉じていない置換も末尾まで 1 引数にし、中身の -1 等を呼び出し元の引数にしない。
shell_words() {
  printf '%s' "$1" | awk '
    function emit() { if (word != "") print word; word = "" }
    BEGIN { q = ""; depth = 0; word = "" }
    {
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == "\\" && q != "'"'"'") { word = word c substr($0, ++i, 1); continue }
        if (q != "") {
          word = word c
          if (c == q) q = ""
          continue
        }
        if (c == "'"'"'" || c == "\"" || c == "`") { q = c; word = word c; continue }
        if (c == "(") depth++
        if (c == ")" && depth > 0) depth--
        if (depth == 0 && (c == " " || c == "\t")) emit()
        else word = word c
      }
    }
    END { emit() }'
}

# ---- 1. 致命 deny（生文字列で判定。引用符の中やコマンド置換の中でも止める）----
# 引数: 対象パスを見る文字列（引用符を残し、引用符の中の空白は \001）, コマンド列を見る文字列（引用符の中身を除去済み）
fatal_deny() {
  local p="$1" c="$2"
  # コマンド語の直前の区切りに引用符も含める（bash -c "rm -rf ~" を元の文字列で見るとき、rm の直前は " になる）
  local SEP='(^|[;&|(`\\"'"'"'][[:space:]]*|[[:space:]])'
  printf '%s' "$p" | grep -Eq -- "${SEP}(sudo[[:space:]]+)?([^[:space:]]*/)?rm[[:space:]]+(-[A-Za-z]+[[:space:]]+)*[\"']?(/|/\*|${HOME_RE}/?\*?)[\"']?([[:space:];&|]|$)" \
    && deny "ルート / ホーム直下の削除は禁止です"
  printf '%s' "$p" | grep -Eq -- "${SEP}(sudo[[:space:]]+)?([^[:space:]]*/)?(rm|mv)[[:space:]]+(-[A-Za-z]+[[:space:]]+)*[\"']?(${HOME_RE}/\.claude|[^[:space:]]*dotfiles/\.claude)/?\*?[\"']?([[:space:];&|]|$)" \
    && deny "~/.claude（Claude Code のグローバル設定）の削除・移動は禁止です"
  # .claude 配下の設定実体（hooks / skills / agents / settings.json）の再帰削除・移動
  # （dotfiles 側は許可ルートの内側なので範囲判定では止まらない。単一ファイルの rm は開発中の整理として許す）
  printf '%s' "$p" | grep -Eq -- "${SEP}(sudo[[:space:]]+)?([^[:space:]]*/)?(rm[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*[rR][A-Za-z]*[[:space:]]+(-[A-Za-z]+[[:space:]]+)*|mv[[:space:]]+(-[A-Za-z]+[[:space:]]+)*)[\"']?(${HOME_RE}/\.claude|[^[:space:]]*dotfiles/\.claude)/${CLAUDE_CORE}([/[:space:]\"';&|]|$)" \
    && deny "~/.claude / dotfiles/.claude の設定実体（hooks・skills 等）の再帰削除・移動は禁止です"
  # リモートスクリプトの実行: curl … | sh（途中に tee 等を挟む形も）、bash <(curl …)、sh -c "$(curl …)"、eval "$(curl …)"、source <(curl …)
  printf '%s' "$c" | grep -Eq -- "${SEP}(curl|wget)[[:space:]][^;]*\|[[:space:]]*(sudo[[:space:]]+)?((ba|z|da)?sh|python3?|ruby|perl|node|php)([[:space:]\"';&|]|$)" \
    && deny "リモートスクリプトをシェルへ直接パイプする実行は禁止です（ダウンロードして内容を確認してから実行してください）"
  printf '%s' "$c" | grep -Eq -- "${SEP}"'((sudo[[:space:]]+)?([^[:space:]]*/)?(ba|z|da)?sh[[:space:]]+(-[A-Za-z]+[[:space:]]+)*(<\(|-[A-Za-z]*c[A-Za-z]*[[:space:]]+\$\()|(eval|source|\.)[[:space:]]+(<\(|\$\())[[:space:]]*(curl|wget)[[:space:]]' \
    && deny "リモートスクリプトをシェルへ直接渡す実行は禁止です（ダウンロードして内容を確認してから実行してください）"
  printf '%s' "$c" | grep -Eq -- "${SEP}(sudo[[:space:]]+)?(diskutil[[:space:]]+(erase|partition|reformat|zero|secureErase|randomDisk|apfs[[:space:]]+(delete|erase)[A-Za-z]*)|dd[[:space:]][^;|]*of=/dev/|mkfs|newfs_)" \
    && deny "ディスクの消去・パーティション操作は禁止です"
}
fatal_deny "$raw1" "$s1"
# シェルへ文字列を渡す形（eval / bash -c / sh -c / … | sh / bash <<EOF。単語としての eval / sh だけ。tests/eval や ssh では発動しない）は、
# その文字列を bash が実行するので、元のコマンド文字列全体（引用符の中身・HEREDOC 本文を含む）にも致命 deny を掛ける。
# 致命対象でなければ段 3 で deny になる
SHELL_STR_RE='(^|[[:space:];&|(`])(eval[[:space:]]|([^[:space:]]*/)?(ba|z|da|k)?sh[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*c[A-Za-z]*([[:space:]]|$))|\|[[:space:]]*([^[:space:]]*/)?(ba|z|da|k)?sh([[:space:]]|$)|(^|[[:space:];&|(`])([^[:space:]]*/)?(ba|z|da|k)?sh([[:space:]]+-[A-Za-z]+)*[[:space:]]*<<'
shell_string=0
if printf '%s' "$raw1" | grep -Eq -- "$SHELL_STR_RE"; then
  shell_string=1
  cmd1=${cmd//\\$'\n'/ }; cmd1=$(printf '%s' "$cmd1" | tr '\n' ';')
  fatal_deny "$cmd1" "$cmd1"
fi

# -c に渡すリテラルだけを切り出せる場合は、その中の削除語を見る。
# eval・パイプ・HEREDOC・未知の値は従来どおり文字列全体を確認対象に残す。
shell_opaque=$shell_string
if [ "$shell_string" -eq 1 ] && [ "$parse_failed" -eq 0 ]; then
  shell_opaque=0
  printf '%s' "$raw1" | grep -Eq -- "${SEP}eval[[:space:]]|\|[[:space:]]*([^[:space:]]*/)?(ba|z|da|k)?sh([[:space:]]|$)|<<" && shell_opaque=1
  while IFS= read -r shseg; do
    [ -n "$shseg" ] || continue
    shseg=$(printf '%s' "$shseg" | sed -E 's/^[;&|(`]?[[:space:]]*//')
    need_body=0; got_body=0
    while IFS= read -r word; do
      if [ "$need_body" -eq 1 ]; then
        got_body=1; body=""
        case "$word" in
          \"*\") body=${word#\"}; body=${body%\"}; case "$body" in *[\$\`\\\"]*) shell_opaque=1 ;; esac ;;
          \'*\') body=${word#\'}; body=${body%\'}; case "$body" in *[\'\$\`\\]*) shell_opaque=1 ;; esac ;;
          *) shell_opaque=1 ;;
        esac
        body=${body//$'\001'/ }
        printf '%s' "$body" | grep -Eq -- "$DEL_RE|${SEP}([^[:space:]]*/)?(rm|rmdir|unlink|mv|git|kill|killall|pkill|chmod|chown|chgrp|eval|source)([[:space:]]|$)" && shell_opaque=1
        break
      fi
      case "$word" in -c | -[A-Za-z]*c*) need_body=1 ;; esac
    done < <(shell_words "$shseg")
    [ "$got_body" -eq 1 ] || shell_opaque=1
  done < <(printf '%s' "$raw1" | grep -oE -- "${SEP}([^[:space:]]*/)?(ba|z|da|k)?sh[[:space:]]+[^;&|]*")
fi

# ---- 2. 削除の範囲判定 ----
norm_path() { # 絶対パスの . と .. を解決する（実在しなくてよい）
  local IFS='/' seg out=""
  set -f
  for seg in $1; do
    case "$seg" in
      '' | '.') ;;
      '..') out="${out%/*}" ;;
      *) out="$out/$seg" ;;
    esac
  done
  set +f
  printf '%s' "${out:-/}"
}

is_tmp_path() { # 正規化済み絶対パス → 一時領域（$TMPDIR・/tmp/claude-*）なら 0
  local p="$1" root
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    case "$p" in "$root"*) return 0 ;; esac
  done <<EOF
$TMP_PREFIXES
EOF
  return 1
}

is_allowed_path() { # 正規化済み絶対パス → 許可ルートの内側（ルート自身は含まない）か一時領域なら 0
  local p="$1" root
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    case "$p" in "$root"/?*) return 0 ;; esac
  done <<EOF
$ALLOWED_ROOTS
EOF
  is_tmp_path "$p"
}

# 削除コマンドより前に cd / pushd（引数なしの "cd;" も含む）があれば相対パスの基準がずれる
has_cd=0
set_has_cd() { has_cd=0; printf '%s' "$1" | grep -Eq -- "${SEP}(cd|pushd)([[:space:];&|]|$)" && has_cd=1; }

# ---- 同じコマンド内のリテラル代入の解決（S=/tmp/claude-x && rm -rf $S/work）----
# 削除コマンドより前に直線的に実行される単純な代入（NAME=値 / export NAME=値 が独立した文で、
# ^ ; & && の直後にあるもの）だけを VARENV（NAME=値 の改行区切り）に集め、削除対象の $NAME / ${NAME} を
# その値で置き換えてから既存の範囲判定に掛ける。値はリテラル（引用符なし・'…'・$ や ` を含まない "…"）と
# $(mktemp …)（一時領域に作るものだけ）。値の中の変数は $HOME・$TMPDIR と先に解決済みの変数だけ。
# 変数を解決してよいのは、コマンド全体で NAME が $NAME / ${NAME} の参照以外に現れるのがその代入 1 か所だけのとき
# （read NAME・printf -v NAME・for NAME in・unset NAME・2 回目の代入などが 1 つでもあれば解決しない）。
# ほかに次の場合も解決しない（?var として deny）: 削除より前（削除文自身の前置きを含む）に制御構文・
# { }・( )・関数定義・eval・source がある、&& の後の代入から削除まで && 以外でつながる、|| / | の後の代入、
# ${NAME:-x} 等のパラメータ展開、HOME / TMPDIR 自体への代入
VARENV=""; VTAINT=" "
resolve_assign=0
if [ "$parse_failed" -eq 0 ] && [ "$shell_opaque" -eq 0 ]; then
  case "$raw1" in *=*) resolve_assign=1 ;; esac
  printf '%s' "$raw1" | grep -Eq -- '(^|[^A-Za-z0-9_${])(HOME|TMPDIR)(\[[^]]*\])?\+?=' && resolve_assign=0
fi

# 文に分ける（引数: 文字列）。出力は「直前の区切り<TAB>文」の行（先頭の文の区切りは ^）。
# 引用符と ( ) の中の区切りでは分けない。>& / <& / &> はリダイレクト、|& はパイプとして扱う
split_stmts() {
  printf '%s' "$1" | awk '
    function emit() { printf "%s\t%s\n", sep, cur; cur = "" }
    BEGIN { sep = "^"; cur = ""; q = ""; depth = 0 }
    {
      s = $0; n = length(s); i = 1
      while (i <= n) {
        c = substr(s, i, 1)
        if (q != "") {
          cur = cur c
          if (q == "\"" && c == "\\") { cur = cur substr(s, i + 1, 1); i += 2; continue }
          if (c == q) q = ""
          i++; continue
        }
        if (c == "\\") { cur = cur c substr(s, i + 1, 1); i += 2; continue }
        if (c == "'"'"'" || c == "\"") { q = c; cur = cur c; i++; continue }
        if (c == "(") depth++
        if (c == ")" && depth > 0) depth--
        if (depth == 0) {
          c2 = substr(s, i, 2)
          if (c2 == "&&" || c2 == "||") { emit(); sep = c2; i += 2; continue }
          if (c2 == "|&") { emit(); sep = "|"; i += 2; continue }
          if (c2 == "&>") { cur = cur c2; i += 2; continue }
          p = (i > 1) ? substr(s, i - 1, 1) : ""
          if (c == "&" && (p == ">" || p == "<")) { cur = cur c; i++; continue }
          if (c == ";" || c == "|" || c == "&") { emit(); sep = c; i++; continue }
        }
        cur = cur c; i++
      }
    }
    END { emit() }'
}

lookup_var() { # 引数: 変数名, 1 なら HOME / TMPDIR も引く。値を出力し、未知なら 1
  local line
  if [ "$2" = 1 ]; then
    case "$1" in
      HOME) printf '%s' "$HOME"; return 0 ;;
      TMPDIR) [ -n "$tmpdir" ] || return 1; printf '%s' "$tmpdir"; return 0 ;;
    esac
  fi
  while IFS= read -r line; do
    case "$line" in "$1="*) printf '%s' "${line#*=}"; return 0 ;; esac
  done <<EOF
$VARENV
EOF
  return 1
}

# $NAME / ${NAME} を解決済みの値で置き換える（引数: 文字列, lookup_var の第 2 引数）。単引用符の中は置き換えない。
# 置き換えられない $ はそのまま残る（呼び出し側が ?var として扱う）
subst_vars() {
  local in="$1" out="" c val re1='^\$\{([A-Za-z_][A-Za-z0-9_]*)\}' re2='^\$([A-Za-z_][A-Za-z0-9_]*)' sq=0 dq=0
  while [ -n "$in" ]; do
    c=${in:0:1}
    if [ "$sq" -eq 1 ]; then out="$out$c"; in=${in:1}; [ "$c" = "'" ] && sq=0; continue; fi
    case "$c" in
      "'") [ "$dq" -eq 0 ] && sq=1 ;;
      '"') dq=$((1 - dq)) ;;
      '\') out="$out${in:0:2}"; in=${in:2}; continue ;;
      '$')
        if [[ $in =~ $re1 ]] || [[ $in =~ $re2 ]]; then
          if val=$(lookup_var "${BASH_REMATCH[1]}" "$2"); then
            out="$out$val"; in=${in:${#BASH_REMATCH[0]}}; continue
          fi
        fi ;;
    esac
    out="$out$c"; in=${in:1}
  done
  printf '%s' "$out"
}

# $(mktemp 引数) の作成先（引数: mktemp の引数）。一時領域の内側と確定できるときだけ出力し、それ以外は 1
#   引数なし / -t / --tmpdir（テンプレートに / なし）→ $TMPDIR（未設定なら未解決）
#   -p DIR / --tmpdir=DIR → DIR が一時領域なら その内側。-t との併用は未解決
#   テンプレートだけ → mktemp はテンプレートをそのままパスとして作る（/ を含まなければ作業ディレクトリ）。
#   一時領域の絶対パスのときだけ解決する
mktemp_value() {
  local tflag=0 havep=0 pdir="" tpl="" dir name
  case "$1" in *[\$\`\(\)\;\&\|\<\>\'\\]* | *$'\001'*) return 1 ;; esac
  set -f; set -- $1; set +f
  while [ $# -gt 0 ]; do
    case "$1" in
      -d | --directory | -q | --quiet) ;;
      -t | --tmpdir) tflag=1 ;;
      -p) [ $# -ge 2 ] || return 1; pdir=$2; havep=1; shift ;;
      --tmpdir=*) pdir=${1#--tmpdir=}; havep=1 ;;
      --*) return 1 ;;
      -*) case "${1#-}" in *[!dqt]*) return 1 ;; *t*) tflag=1 ;; esac ;;
      *) [ -z "$tpl" ] || return 1; tpl=$1 ;;
    esac
    shift
  done
  case "$tpl" in *'"'*) return 1 ;; esac
  name=${tpl:-tmp.XXXXXXXXXX}
  if [ "$havep" -eq 1 ]; then
    [ "$tflag" -eq 0 ] || return 1
    case "$tpl" in */*) return 1 ;; esac
    dir=$(expand_value "$pdir") || return 1
  elif [ "$tflag" -eq 1 ] || [ -z "$tpl" ]; then
    case "$tpl" in */*) return 1 ;; esac
    [ -n "$tmpdir" ] || return 1
    dir=$tmpdir
  else
    case "$tpl" in /*/*) ;; *) return 1 ;; esac
    dir=${tpl%/*}; name=${tpl##*/}
  fi
  case "$dir" in /*) ;; *) return 1 ;; esac
  dir=$(norm_path "$dir")
  is_tmp_path "$dir/$name" || return 1
  printf '%s' "$dir/$name"
}

# 代入の右辺 → 値（引数: 右辺の文字列）。リテラルとして確定できなければ 1
expand_value() {
  local v="$1" inner
  inner=$v
  case "$inner" in '"$(mktemp'*')"') inner=${inner#\"}; inner=${inner%\"} ;; esac
  case "$inner" in '$(mktemp)' | '$(mktemp '*')') mktemp_value "${inner:8:${#inner}-9}"; return ;; esac
  case "$v" in *[[:space:]]* | *$'\001'* | *[\`\\\(\)]*) return 1 ;; esac
  case "$v" in
    "'"*"'")
      inner=${v#\'}; inner=${inner%\'}
      case "$inner" in '' | '~'* | *[\'\$\{\}]*) return 1 ;; esac
      printf '%s' "$inner"; return 0 ;;
    '"'*'"')
      inner=${v#\"}; inner=${inner%\"}
      case "$inner" in '~'* | *'"'*) return 1 ;; esac ;;   # 引用符の中の ~ は展開されない（相対パスの "~"）
    *[\'\"]*) return 1 ;;
    *)
      inner=$v
      case "$inner" in
        '~') inner=$HOME ;;
        '~/'*) inner="$HOME${inner#\~}" ;;
        *'~'*) return 1 ;;   # ~user や途中の ~ は展開先を特定しない
      esac ;;
  esac
  inner=$(subst_vars "$inner" 1)
  case "$inner" in '' | *[\$\{\}]*) return 1 ;; esac
  printf '%s' "$inner"
}

varenv_taint() { # 変数を未解決扱いにする（以後この変数は解決しない）
  local n line keep=""
  for n in "$@"; do
    VTAINT="$VTAINT$n "
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      case "$line" in "$n="*) ;; *) keep="$keep$line"$'\n' ;; esac
    done <<EOF
$VARENV
EOF
    VARENV=$keep; keep=""
  done
}

# コマンド全体（引用符の中も含む。HEREDOC 本文は除く）で、変数 NAME が $NAME / ${NAME} の参照以外の
# 「裸の語」として現れる回数。解決してよいのは、これが 1（= 解決対象の NAME=値 の代入そのもの）のときだけ。
# read / printf -v / for NAME in / unset / IFS= read NAME / NAME+= / 2 回目の代入などはすべてここで 2 以上になる
bare_count() { printf '%s' "$raw1" | grep -oE -- '([$][{]?[#!]?)?[A-Za-z_][A-Za-z0-9_]*' | grep -cxF -- "$1"; }

# 削除コマンドより前（引数）の直線的な代入から VARENV を作る
build_varenv() {
  local recs n idx=0 sp st first name val cond="" prev="" re
  VARENV=""; VTAINT=" "
  re='^(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$'
  recs=$(split_stmts "$1")
  n=$(printf '%s\n' "$recs" | grep -c '')
  while IFS=$'\t' read -r sp st; do
    idx=$((idx + 1))
    # 直前の代入の直後が | / & なら、その代入はサブシェルで行われ効かない
    [ -n "$prev" ] && case "$sp" in '|' | '&') varenv_taint "$prev" ;; esac
    prev=""
    # && の後の代入は、削除まで && だけでつながるときだけ有効
    if [ "$sp" != "&&" ] && [ -n "$cond" ]; then varenv_taint $cond; cond=""; fi
    st=${st#"${st%%[![:space:]]*}"}; st=${st%"${st##*[![:space:]]}"}
    first=${st%%[[:space:]]*}
    # 制御構文・{ }・( )・関数定義・eval / source が削除より前（削除文自身の前置きを含む）にあれば解決しない
    case "$first" in
      if | then | else | elif | fi | for | while | until | do | done | case | esac | select | function \
      | '{'* | '}'* | '('* | eval | source | . | exec) VARENV=""; return ;;
    esac
    case "$st" in *'()'* | *'( )'*) VARENV=""; return ;; esac
    # 最後の 1 件は削除コマンド自身の前置き（sudo・D=x rm の環境代入など）なので代入として扱わない
    [ "$idx" -lt "$n" ] || break
    [[ $st =~ $re ]] || continue
    name=${BASH_REMATCH[2]}; val=${BASH_REMATCH[3]}
    case "$sp" in '||' | '|') varenv_taint "$name"; continue ;; esac
    # 他の形（read・for・2 回目の代入など）でも現れる変数は、どの値が効くか決めない
    [ "$(bare_count "$name")" -eq 1 ] || { varenv_taint "$name"; continue; }
    if val=$(expand_value "$val"); then
      VARENV="$VARENV$name=$val"$'\n'
      [ "$sp" = "&&" ] && cond="$cond $name"
      prev=$name
    else
      varenv_taint "$name"
    fi
  done <<EOF
$recs
EOF
}

# 削除セグメントごとに、raw1 の中で前から順に位置を進めて「そのセグメントより前」を求め、VARENV を作る
# （同じ文面のセグメントが複数あっても後ろの代入を前の削除に使わない）
varenv_reset() { VREST=$raw1; VDONE=""; VARENV=""; }
varenv_for_seg() {
  local before
  VARENV=""; SEG_BEFORE=""
  case "$VREST" in *"$1"*) ;; *) VREST=""; return ;; esac
  before=${VREST%%"$1"*}
  VDONE="$VDONE$before"; VREST=${VREST#*"$1"}
  SEG_BEFORE=$VDONE
  [ "$resolve_assign" -eq 1 ] && build_varenv "$VDONE"
  VDONE="$VDONE$1"
}
# 直線的な絶対パスの cd を削除にだけ適用する。mv は従来の ?cd 判定を保つ。
# cd が成功したと分かる && の連鎖だけを追い、; / || / 別スコープなら基準を確定しない。
set_delete_cwd() {
  local sp st first words target before="" saved_env="$VARENV" saved_taint="$VTAINT" seen=0 bad=0
  delete_cwd=$cwd
  set_has_cd "$SEG_BEFORE"
  [ "$has_cd" -eq 1 ] || return
  while IFS=$'\t' read -r sp st; do
    st=${st#"${st%%[![:space:]]*}"}; st=${st%"${st##*[![:space:]]}"}
    first=${st%%[[:space:]]*}
    [ "$seen" -eq 0 ] || [ "$sp" = "&&" ] || bad=1
    case "$first" in
      if | then | else | elif | fi | for | while | until | do | done | case | esac | select | function \
      | '{'* | '}'* | '('* | eval | source | . | exec | pushd | popd) bad=1 ;;
    esac
    case "$st" in *'()'* | *'( )'*) bad=1 ;; esac
    if [ "$first" != cd ]; then
      printf '%s' "$st" | grep -Eq -- "${SEP}(cd|pushd|popd)([[:space:];&|]|$)" && bad=1
    fi
    if [ "$first" = cd ]; then
      seen=1
      case "$sp" in '^' | ';' | '&&') ;; *) bad=1 ;; esac
      words=$(shell_words "$st")
      target=${words#*$'\n'}
      case "$target" in --$'\n'*) target=${target#*$'\n'} ;; esac
      case "$target" in '' | cd | *$'\n'* | '~'* | *'$('* | *[\`\*\?\[]*) bad=1 ;;
        *)
          case "$target" in *'$'*)
            [ "$(bare_count HOME)" -eq 0 ] && [ "$(bare_count TMPDIR)" -eq 0 ] || bad=1 ;;
          esac
          VARENV=""
          [ "$resolve_assign" -eq 1 ] && build_varenv "${before}${before:+ $sp }"
          if target=$(expand_value "$target"); then
            case "$target" in
              *[\*\?\[]*) bad=1 ;;
              /*) delete_cwd=$(norm_path "$target") ;;
              *) bad=1 ;;
            esac
          else bad=1; fi ;;
      esac
    fi
    before="$before${before:+ $sp }$st"
  done < <(split_stmts "$SEG_BEFORE")
  VARENV=$saved_env; VTAINT=$saved_taint
  if [ "$seen" -eq 1 ] && [ "$bad" -eq 0 ]; then has_cd=0; else delete_cwd=$cwd; fi
}

# 削除対象のトークンに解決済みの変数を当てはめる（解決済みの変数が無ければそのまま）
apply_varenv() { if [ -n "$VARENV" ]; then subst_vars "$1" 0; else printf '%s' "$1"; fi; }

# トークン → 判定用の絶対パス。解決できなければ "?理由" を返す（?cd / ?var / ?subst / ?range / ?user / ?cwd）
resolve_target() {
  local t="$1" abs
  t=${t//[\"\']/}   # "$HOME"/x や "${TMPDIR:-/tmp}"/x のように途中にある引用符も取り除く
  case "$t" in *'$('* | *'`'*) printf '?subst'; return ;; esac
  case "${t//\$\{/}" in *\{?*\}*) printf '?range'; return ;; esac   # expand_braces が展開できなかったブレース（${VAR} と {} は除く）
  case "$t" in
    '~' | '~/'*) t="$HOME${t#\~}" ;;
    '~'*) printf '?user'; return ;;
    '$HOME' | '$HOME/'* ) t="$HOME${t#\$HOME}" ;;
    '${HOME}' | '${HOME}/'*) t="$HOME${t#\$\{HOME\}}" ;;
    '$TMPDIR' | '$TMPDIR/'*) t="$tmpdir${t#\$TMPDIR}" ;;
    '${TMPDIR}' | '${TMPDIR}/'*) t="$tmpdir${t#\$\{TMPDIR\}}" ;;
    '${TMPDIR:-'*'}' | '${TMPDIR:-'*'}/'*) t="$tmpdir${t#\$\{TMPDIR:-*\}}" ;;
  esac
  case "$t" in *'$'*) printf '?var'; return ;; esac
  # glob（dist/* 等）はディレクトリ部分だけを見る。"G:" は「そのディレクトリの中身」、"A:" はドットファイルにも
  # 一致しうる glob（glob を含む最初のパス要素が "." で始まる: .* / .[!.]* / .c*/hooks 等）。末尾の "/" は落として判定する
  local glob="" pre comp
  while [ "$t" != "/" ] && [ "${t%/}" != "$t" ]; do t=${t%/}; done
  case "$t" in
    *[\*\?\[]*)
      pre=${t%%[\*\?\[]*}; comp=${pre##*/}
      case "$comp" in .*) glob="A:" ;; *) glob="G:" ;; esac
      t=$pre
      case "$t" in */*) t=${t%/*} ;; *) t="." ;; esac
      [ -n "$t" ] || t="/"
      ;;
  esac
  [ "$2" = "glob" ] && glob="G:"
  [ "$2" = "dotglob" ] && glob="A:"
  case "$t" in
    /*) abs="$t" ;;
    *) [ "$has_cd" -eq 1 ] && { printf '?cd'; return; }; [ -n "${delete_cwd:-$cwd}" ] || { printf '?cwd'; return; }; abs="${delete_cwd:-$cwd}/$t" ;;
  esac
  printf '%s%s' "$glob" "$(norm_path "$abs")"
}

# カンマ区切りのブレース展開（{dist,build} / a/{b,c}/d。入れ子なし）を bash と同じ順で展開し、1 行ずつ出力する。
# bash は変数の中身にブレース展開を行わないので自前で行う。範囲形（{1..3}）・入れ子・カンマ無しの {x} は
# 展開後を特定できないので "?range" を出力する。${VAR} と find -exec の {} は展開ではないのでそのまま返す
expand_braces() {
  local t="$1" s pre rest inner post i
  s=${t//\$\{/$'\002'}
  case "$s" in *\{*\}*) ;; *) printf '%s\n' "$t"; return ;; esac
  pre=${s%%\{*}; rest=${s#*\{}; inner=${rest%%\}*}; post=${rest#*\}}
  case "$inner" in
    '') printf '%s\n' "$t"; return ;;          # find -exec の {}
    *\{*) printf '?range\n'; return ;;         # 入れ子
    *,*) ;;                                    # カンマ区切り（要素に ../ を含んでもよい。展開後に範囲判定する）
    *) printf '?range\n'; return ;;            # 範囲形 {1..3} とカンマ無しの {x}
  esac
  local IFS=','
  set -f
  for i in $inner; do
    expand_braces "${pre//$'\002'/\$\{}${i}${post//$'\002'/\$\{}"
  done
  set +f
}

# 解決できなかった対象の deny 理由文（引数: 理由コード, トークン, 動作）
explain_unresolved() {
  local code="$1" tok="$2" act="$3"
  case "$code" in
    '?cd')    printf '%s' "cd した先を基準に '${tok}' を${act}するコマンドです。cd 先が分からず対象を特定できません" ;;
    '?var')   printf '%s' "変数を含む '${tok}' を${act}するコマンドです。変数の値が分からず対象を特定できません" ;;
    '?subst') printf '%s' "コマンドの出力結果 '${tok}' を${act}するコマンドです。実行するまで対象が決まりません" ;;
    '?range') printf '%s' "ブレース展開 '${tok}' の結果を${act}するコマンドです。範囲形・入れ子は展開後のパスを特定できません" ;;
    '?user')  printf '%s' "~user 形式のパス '${tok}' を${act}するコマンドです。展開先を特定できません" ;;
    *)        printf '%s' "相対パス '${tok}' を${act}するコマンドです。作業ディレクトリが分からず対象を特定できません" ;;
  esac
}

# リンクされた git worktree のルートか（直下の .git が gitdir: …/worktrees/… を指すファイル）
is_linked_worktree_root() {
  local p="$1" line
  [ -f "$p/.git" ] || return 1
  IFS= read -r line < "$p/.git" || return 1
  case "$line" in gitdir:*worktrees/*) return 0 ;; esac
  return 1
}

# 解決済みの削除対象 1 件を検査する（引数: resolve_target の結果, 再帰フラグ, 変数適用後のトークン）。deny 条件に当たれば即終了
check_one_target() {
  local r="$1" rec="$2" tok="$3" mode n relative=1 wt_root=0
  tok=${tok//[\"\']/}
  case "$tok" in /* | '~'* | '$'*) relative=0 ;; esac
  mode="dir"; case "$r" in A:*) mode="dotglob"; r=${r#A:} ;; G:*) mode="glob"; r=${r#G:} ;; esac
  # リンクされた git worktree のルートを rm -rf する場合は、許可ルート外でも通す
  # （ルート / ホーム直下 / ~/.claude 等の致命対象は段 1 で deny 済み）
  if [ "$rec" -eq 1 ] && [ "$mode" = dir ] && is_linked_worktree_root "$r"; then wt_root=1; fi
  [ "$wt_root" -eq 1 ] || is_allowed_path "$r" || deny "削除は ${ROOTS_DISP} と一時領域の配下でのみ許可されています（対象: ${r}）"
  # settings.json・ai/ の共通指示と ~/.claude/CLAUDE.md はハーネスそのもの（消えると全プロジェクト・全CLIの permissions・共通指示が失われる）なので単一ファイルでも止める
  case "$r" in
    *dotfiles/.claude/settings.json | "$HOME/.claude/CLAUDE.md")
      deny "dotfiles/.claude の settings.json（~/.claude のリンク先）の削除は禁止です（対象: ${r}）" ;;
    # 全CLI共通のグローバル指示と配布スクリプト（消えると全CLIの共通指示が失われる）
    *dotfiles/ai/core.md | *dotfiles/ai/claude.md | *dotfiles/ai/install.sh)
      deny "dotfiles/ai の共通指示・配布スクリプトの削除は禁止です（対象: ${r}）" ;;
  esac
  # dotfiles/.claude 配下の設定実体は許可ルートの内側だが、再帰削除・glob 削除は止める（相対パス指定もここで捕捉する）
  if [ "$rec" -eq 1 ] || [ "$mode" != "dir" ]; then
    case "$r" in
      "$HOME/.claude" | *dotfiles/.claude) deny "~/.claude / dotfiles/.claude の削除は禁止です（対象: ${r}）" ;;
    esac
    # dotfiles 自体の再帰削除と、その直下でドットファイルに一致する glob・絞り込みの無い find -delete は .claude ごと消える
    case "$mode:$r" in
      dir:*dotfiles | dotglob:*dotfiles) deny "dotfiles リポジトリ自体（~/.claude の実体を含む）の削除は禁止です（対象: ${r}）" ;;
    esac
    # 全CLI共通のグローバル指示（dotfiles/ai）の再帰削除・glob 削除
    case "$r" in
      *dotfiles/ai | *dotfiles/ai/*)
        deny "dotfiles/ai（全CLI共通のグローバル指示）の再帰削除は禁止です（対象: ${r}）" ;;
    esac
    for n in hooks skills agents settings.json CLAUDE.md; do
      case "$r" in
        "$HOME/.claude/$n" | "$HOME/.claude/$n"/* | *dotfiles/.claude/$n | *dotfiles/.claude/$n/*)
          deny "~/.claude / dotfiles/.claude の設定実体（hooks・skills 等）の再帰削除は禁止です（対象: ${r}）" ;;
      esac
    done
  fi
  # 作業中のディレクトリ自身とその親は消させない（glob はディレクトリの中身なので、cwd 自身の中の glob は可）
  if [ -n "$cwd" ]; then
    case "$mode:$(norm_path "$cwd")" in
      "dir:$r" | "dir:$r"/* | "glob:$r"/* | "dotglob:$r"/*) deny "作業中のディレクトリ（またはその親）の削除は禁止です（対象: ${r}）" ;;
    esac
  fi
  # コマンド内の cd 先は、. / .. など相対指定で自身・親を消す場合だけ保護する
  if [ "$relative" -eq 1 ] && [ -n "$delete_cwd" ] && [ "$delete_cwd" != "$cwd" ]; then
    case "$mode:$delete_cwd" in
      "dir:$r" | "dir:$r"/* | "glob:$r"/* | "dotglob:$r"/*) deny "作業中のディレクトリ（またはその親）の削除は禁止です（対象: ${r}）" ;;
    esac
  fi
}

check_targets() { # 引数: 種別（rm|glob|dotglob）, トークン列（改行区切り）。glob は「その中身」扱い
  local kind="$1" toks="$2" tok ex r dashdash=0 rec=0
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    if [ "$dashdash" -eq 0 ]; then
      case "$tok" in
        --) dashdash=1; continue ;;
        -*) printf '%s' "$tok" | grep -Eq -- '^-[A-Za-z]*[rR][A-Za-z]*$|^--recursive$' && rec=1; continue ;;   # 再帰フラグ
      esac
    fi
    while IFS= read -r ex; do
      [ -n "$ex" ] || continue
      case "$ex" in '?'*) r="$ex" ;; *) r=$(resolve_target "$ex" "$kind") ;; esac
      case "$r" in '?'*) deny_unresolved "$r" "$tok" 削除 ;; esac
      check_one_target "$r" "$rec" "$ex"
    done < <(expand_braces "$(apply_varenv "$tok")")
  done <<EOF
$toks
EOF
}

# 解決済みの mv の移動元 1 件を検査する（引数: resolve_target の結果）
check_one_mv_source() {
  local r="$1" g n
  g=dir; case "$r" in A:*) g=dotglob; r=${r#A:} ;; G:*) g=glob; r=${r#G:} ;; esac
  case "$g:$r" in
    *:"$HOME/.claude" | *:"$HOME/.claude/CLAUDE.md" | *:*dotfiles/.claude | *:*dotfiles/.claude/settings.json | *:*dotfiles/.claude/CLAUDE.md | *:*dotfiles/ai | *:*dotfiles/ai/core.md | *:*dotfiles/ai/claude.md | dir:*dotfiles | dotglob:*dotfiles)
      deny "~/.claude / dotfiles（および .claude の settings.json・ai の共通指示）の移動は禁止です（対象: ${r}）" ;;
    glob:"$HOME" | dotglob:"$HOME") deny "ホーム直下の一括移動は禁止です（対象: $r/*）" ;;
  esac
  for n in hooks skills agents; do
    case "$r" in
      "$HOME/.claude/$n" | "$HOME/.claude/$n"/* | *dotfiles/.claude/$n | *dotfiles/.claude/$n/*)
        deny "~/.claude / dotfiles/.claude の設定実体（hooks・skills 等）の移動は禁止です（対象: ${r}）" ;;
    esac
  done
}

# コマンド語から次の区切り（; & | と $(…) / `…` の閉じ）までのセグメントを raw1 から取り出す（\rm・/bin/rm・sudo 付きも含む）
extract_segs() {
  printf '%s' "$raw1" | grep -oE -- "(^|[;&|(\`\\\\][[:space:]]*|[[:space:]])(sudo[[:space:]]+)?([^[:space:]]*/)?($1)[[:space:]]+[^;&|)\`]*" | sed -E 's/^[;&|(`\\]?[[:space:]]*//'
}
strip_cmdword() { sed -E "s/^[[:space:]]*(sudo[[:space:]]+)?([^[:space:]]*\/)?($1)[[:space:]]+//"; }

# rm / rmdir / unlink
varenv_reset
while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  varenv_for_seg "$seg"
  case "$seg" in *xargs*) deny '前のコマンドの出力を xargs で受けて削除するコマンドです。対象が実行時に決まるため拒否します。対象を具体的なパスで書き直して再実行してください（必要ならユーザーに実行を依頼）' ;; esac
  set_delete_cwd
  seg=$(printf '%s' "$seg" | strip_cmdword 'rm|rmdir|unlink')
  check_targets rm "$(printf '%s' "$seg" | tr ' \t' '\n\n')"
done < <(extract_segs 'rm|rmdir|unlink')
printf '%s' "$raw1" | grep -Eq -- "xargs[^;&|]*[[:space:]](rm|rmdir|unlink)([[:space:]]|$)" \
  && deny '前のコマンドの出力を xargs で受けて削除するコマンドです。対象が実行時に決まるため拒否します。対象を具体的なパスで書き直して再実行してください（必要ならユーザーに実行を依頼）'

# mv（移動元だけを見る。-t DIR / --target-directory=DIR の形は残りすべてが移動元、それ以外は最後の引数が移動先）
varenv_reset
while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  varenv_for_seg "$seg"
  delete_cwd=$cwd
  set_has_cd "$SEG_BEFORE"
  seg=$(printf '%s' "$seg" | strip_cmdword mv)
  if printf '%s' "$seg" | grep -Eq -- '(^|[[:space:]])(-t|--target-directory)([[:space:]=]|$)'; then
    srcs=$(printf '%s' "$seg" | tr ' \t' '\n\n' | awk 'skip { skip = 0; next } $0 == "-t" || $0 == "--target-directory" { skip = 1; next } /^--target-directory=/ { next } /^-/ { next } /^$/ { next } { print }')
  else
    toks=$(printf '%s' "$seg" | tr ' \t' '\n\n' | grep -v '^-' | grep -v '^$')
    [ "$(printf '%s\n' "$toks" | grep -c .)" -ge 2 ] || continue
    srcs=$(printf '%s\n' "$toks" | sed '$d')
  fi
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    while IFS= read -r ex; do
      [ -n "$ex" ] || continue
      case "$ex" in '?'*) r="$ex" ;; *) r=$(resolve_target "$ex" mv) ;; esac
      case "$r" in
        '?'*)
          # mv の保護対象は .claude / dotfiles だけなので、それを指しうる書き方のときだけ deny（変数入りのビルド成果物の移動などは通す）
          case "$tok" in *.claude* | *dotfiles*) deny_unresolved "$r" "$tok" 移動 ;; esac
          continue ;;
      esac
      check_one_mv_source "$r"
    done < <(expand_braces "$(apply_varenv "$tok")")
  done <<EOF
$srcs
EOF
done < <(extract_segs mv)

# find … -delete / -exec rm（起点だけを検査する。-name / -path / -regex の絞り込みが無ければ起点以下を丸ごと消すので dotglob 扱い。
# "*" だけのパターンや "." で始まるパターン（ドットファイルに一致する）は絞り込みと見なさない）
varenv_reset
while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  varenv_for_seg "$seg"
  case "$seg" in *-delete* | *'-exec rm'* | *'-execdir rm'* | *'-exec unlink'*) ;; *) continue ;; esac
  set_delete_cwd
  seg=$(printf '%s' "$seg" | strip_cmdword find)
  start=$(printf '%s' "$seg" | tr ' \t' '\n\n' | grep -v '^-' | grep -v '^$' | head -1)
  kind=dotglob
  while IFS= read -r pat; do
    pat=${pat//[\"\']/}
    case "$pat" in .* | '') ;; *[!*.]*) kind=glob ;; esac
  done < <(printf '%s' "$seg" | grep -oE -- '(^|[[:space:]])-i?(name|path|regex|wholename)[[:space:]]+[^[:space:]]+' | sed -E 's/^[[:space:]]*-i?(name|path|regex|wholename)[[:space:]]+//')
  check_targets "$kind" "${start:-.}"
done < <(extract_segs find)

# ---- 3. 削除語を含むが構造を解釈できない形 → deny ----
# 無害なリテラルの -c 本文以外は deny（致命対象は段 1 で deny 済み）。
# 引用符の中身も HEREDOC 本文も見る必要があるので元のコマンド文字列で判定する
if [ "$shell_opaque" -eq 1 ]; then
  printf '%s' "$cmd" | grep -Eq -- "$DEL_RE" \
    && deny '文字列をシェルに渡して実行し、その中で削除を行うコマンドです。中身を機械的に判定できないため拒否します。対象を具体的なパスで書き直して再実行してください（必要ならユーザーに実行を依頼）'
fi
if [ "$parse_failed" -eq 1 ]; then
  printf '%s' "$cmd" | grep -Eq -- "$DEL_RE" \
    && deny '引用符または HEREDOC が閉じておらず構文を解釈できないコマンドです。削除を含むため拒否します。対象を具体的なパスで書き直して再実行してください（必要ならユーザーに実行を依頼）'
fi

# ---- 4. 一括 kill と .git の削除は deny ----
# 破壊的な git 操作（reset --hard / clean / checkout・switch の破棄 / rebase / branch -D /
# stash drop / commit --amend / worktree remove --force 等）と絶対パスへの再帰 chmod / chown は
# 確認なしで通す（ask を返さない）。作業ツリー・履歴を壊さないことは共通指示で守る。
# コマンド置換を呼び出し元では 1 引数にし、その中のコマンドは別の行に戻す。
# kill $(kill -9 -1) のように内部で実行される kill も deny する。
kill_contexts() {
  printf '%s' "$raw1" | awk '
    function enter(kind) { outer[++depth] = out; quote[depth] = q; kinds[depth] = kind; out = ""; q = ""; paren[depth] = 0 }
    function leave() { print out; out = outer[depth] "SUBST"; q = quote[depth]; depth-- }
    BEGIN { out = ""; q = ""; depth = 0 }
    {
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == "\\" && q != "'"'"'") { out = out c substr($0, ++i, 1); continue }
        if (q != "'"'"'" && substr($0, i, 2) == "$(") { enter("("); i++; continue }
        if (q != "'"'"'" && c == "`") {
          if (depth > 0 && kinds[depth] == "`" && q == "") leave()
          else enter("`")
          continue
        }
        if (q != "") { out = out c; if (c == q) q = ""; continue }
        if (c == "'"'"'" || c == "\"") { q = c; out = out c; continue }
        if (depth > 0 && kinds[depth] == "(") {
          if (c == "(") paren[depth]++
          if (c == ")") {
            if (paren[depth] == 0) { leave(); continue }
            paren[depth]--
          }
        }
        out = out c
      }
    }
    END { print out; while (depth > 0) { print outer[depth] "SUBST"; depth-- } }'
}
# kill の直接引数だけを見る。置換の中の head -1 を全プロセス指定と誤認しない。
kill_all=0
printf '%s' "$s1" | grep -Eq -- "${SEP}(sudo[[:space:]]+)?(killall|pkill)([[:space:]]|$)" && kill_all=1
while IFS= read -r seg; do
  args=$(printf '%s' "$seg" | strip_cmdword kill)
  args=$(shell_words "$args")
  idx=0; first_arg=""
  while IFS= read -r arg; do
    idx=$((idx + 1))
    arg=${arg//[\"\']/}; arg=${arg%%)*}
    [ "$idx" -eq 1 ] && first_arg=$arg
    [ "$idx" -gt 1 ] && [ "$arg" = -1 ] && kill_all=1
  done <<EOF
$args
EOF
  [ "$idx" -eq 1 ] && [ "$first_arg" = -1 ] && kill_all=1
done < <(kill_contexts | grep -oE -- "${SEP}(sudo[[:space:]]+)?([^[:space:]]*/)?kill[[:space:]]+[^;&|]*" | sed -E 's/^[;&|(`\\]?[[:space:]]*//')
[ "$kill_all" -eq 0 ] || deny 'killall / pkill / kill -1: 名前や全体指定でプロセスをまとめて終了するコマンドです。無関係なプロセスを止めるため拒否します。PID 指定の kill か kill $(lsof -ti :<ポート>) を使ってください'
# リポジトリの .git（履歴）の削除は回復不能（rm -rf .git / ./.git / path/.git）
printf '%s' "$raw1" | grep -Eq -- "${SEP}(sudo[[:space:]]+)?([^[:space:]]*/)?rm[[:space:]]+[^;&|]*[[:space:]/]\.git/?([[:space:]\"';&|]|$)" \
  && deny 'リポジトリの履歴（.git）を削除するコマンドです。回復できないため拒否します。必要ならユーザーに実行を依頼してください'

exit 0
