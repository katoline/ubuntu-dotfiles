#!/bin/bash
# Claude Code・Grok・Codex で共有する、状態を持たない Git 書き込みの判定。
# 呼び出し側が STRIP_AWK を設定してから source する。

# 引用符の中身と HEREDOC 本文を除去する。失敗時は ";" を返して複合扱いにする
strip_cmd() {
  local out
  if [ ! -f "$STRIP_AWK" ]; then printf ';'; return; fi
  out=$(printf '%s\n' "$1" | awk -f "$STRIP_AWK" 2>/dev/null) || { printf ';'; return; }
  if [ -z "$out" ] && [ -n "$1" ]; then printf ';'; return; fi
  printf '%s' "$out"
}

# 拒否判定用: 除去に失敗したとき（awk が無い等）は生文字列で判定する。
# ";" だけを返して「何も含まない」と見なすと拒否側が fail-open になるため
stripped_or_raw() {
  local st
  st=$(strip_cmd "$1")
  [ "$st" = ';' ] && st="$1"
  printf '%s' "$st"
}

# 生文字列で見る判定（bash -c "git commit" のようにシェルへ文字列で渡す形）用に、
# HEREDOC 本文だけを取り除いた生文字列を返す。引用符とその中身は残す。
# HEREDOC 本文は bash が実行しない「書き込まれるファイルの中身」なので、本文に出てくる
# eval や git commit の語を実コマンドと誤認しないために除く（スクリプトを heredoc で
# 書き出すだけのコマンドが拒否される誤検知を防ぐ）。
# keepq 版は引用符の中の空白を \001 に置き換えるので、語として見られるよう空白へ戻す。
# 取り除きに失敗したら生文字列を返す（fail-open にしない）
raw_no_heredoc() {
  local out
  [ -f "$STRIP_AWK" ] || { printf '%s' "$1"; return; }
  out=$(printf '%s\n' "$1" | awk -v keepq=1 -f "$STRIP_AWK" 2>/dev/null | tr '\001' ' ') || { printf '%s' "$1"; return; }
  if [ -z "$out" ] && [ -n "$1" ]; then printf '%s' "$1"; return; fi
  printf '%s' "$out"
}

# gh api による /pulls への書き込みか。引用の外の ; & | 改行で区間に分け（括弧・バッククォートは語を分けるだけ。
# body="$(cat x)" の後ろにエンドポイントがあっても見逃さない）、区間内に gh … api、その後ろに /pulls（/N）のエンドポイントと書き込みの指定（POST/PUT/PATCH、または
# メソッド指定なしの -f / -F / --input 等）がそろえば書き込みとみなす。前置き語（timeout / nix develop -c /
# env 等）は問わない。echo の引数のような文字列も書き込み扱いになるのは許容する
is_pr_api_write() {
  local q raw="$1" token gh=0 api=0 endpoint=0 method="" field=0 next_method=0
  local -a tokens
  raw=${raw//\\$'\n'/ }
  q=$(printf '%s\n' "$raw" | awk -v keepq=1 -v join_quoted_lines=1 -f "$STRIP_AWK" 2>/dev/null) || q="$raw"
  q=${q//$'\n'/;}
  q=$(printf '%s\n' "$q" | sed -E 's/[;&|]/ ; /g; s/[()`]/ /g')
  read -r -a tokens <<<"$q ;"
  for token in "${tokens[@]}"; do
    if [ "$token" = ';' ]; then
      if [ "$endpoint" -eq 1 ]; then
        case "$method" in POST | PUT | PATCH) return 0 ;; '') [ "$field" -eq 1 ] && return 0 ;; esac
      fi
      gh=0 api=0 endpoint=0 method="" field=0 next_method=0
      continue
    fi
    token=${token//\"/}; token=${token//\'/}; token=${token//$'\001'/ }
    if [ "$api" -eq 0 ]; then
      case "$token" in gh | */gh | '\gh') gh=1 ;; api) api=$gh ;; esac
      continue
    fi
    if [ "$next_method" -eq 1 ]; then method="$token"; next_method=0; continue; fi
    case "$token" in
      -X | --method) next_method=1 ;;
      --method=*) method="${token#--method=}" ;;
      -f | -F | --field | --raw-field | --input | --field=* | --raw-field=* | --input=*) field=1 ;;
      *) [[ "$token" =~ ^[^[:space:]]+/pulls(/[0-9]+)?$ ]] && endpoint=1 ;;
    esac
  done
  return 1
}

# 除去後の文字列にコミット・push・PR作成が含まれるか（引数: 生コマンド, 除去後）
is_git_write() {
  local raw="$1" s="$2" rawh
  rawh=$(raw_no_heredoc "$raw")
  # 行継続（\ + 改行）を結合し、改行は区切り ";" にして 1 行で判定する
  s=${s//\\$'\n'/ }
  s=${s//$'\n'/;}
  local wrap='(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|command|env|exec|nohup|time|builtin)[[:space:]]+)*'
  local gitopt='((-[cC]|--git-dir|--work-tree|--namespace)[[:space:]]+[^[:space:]]+[[:space:]]+|--?[A-Za-z][^[:space:]]*[[:space:]]+)*'
  # 末尾は空白・行末のほか ; & | ) も区切りとして扱う（"git push;" / "(git push)" / "{ git push; }" の形）。
  # コマンド語直前の \（\git のエイリアス回避）も許す
  local re="(^|[[:space:];&|(\`])${wrap}([^[:space:]]*/)?\\\\?git[[:space:]]+${gitopt}(commit|push)([[:space:];&|)<>]|\$)"
  # PR の作成（create / 別名 new）と更新（edit）を同じ扱いにする
  local re_gh="(^|[[:space:];&|(\`])${wrap}([^[:space:]]*/)?\\\\?gh[[:space:]]+pr[[:space:]]+(create|new|edit)([[:space:];&|)<>]|\$)"
  printf '%s\n' "$s" | grep -Eq -- "$re" && return 0
  printf '%s\n' "$s" | grep -Eq -- "$re_gh" && return 0
  is_pr_api_write "$raw" && return 0
  # GraphQL の createPullRequest mutation（クエリは引用符の中なので生文字列で見る。
  # gh api / graphql の文脈にあるときだけ。grep createPullRequest のような読み取りでは発動しない）
  case "$s" in *gh*api* | *graphql*) case "$rawh" in *createPullRequest*) return 0 ;; esac ;; esac
  # 引用符・HEREDOC・パイプでシェルに文字列を渡す形（bash -c "…" / sh -c / eval … / bash <<EOF / … | sh）は
  # リテラル判定ができないので生文字列で見る。単語としての eval / sh だけを対象にし、
  # "eval" を含むファイル名等（tests/eval, evaluate）や ssh では発動しない
  if printf '%s\n' "$rawh" | grep -Eq -- '(^|[[:space:];&|(`])(eval[[:space:]]|([^[:space:]]*/)?(ba|z|da|k)?sh[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*c[A-Za-z]*([[:space:]]|$)|([^[:space:]]*/)?(ba|z|da|k)?sh([[:space:]]+-[A-Za-z]+)*[[:space:]]*<<)|\|[[:space:]]*([^[:space:]]*/)?(ba|z|da|k)?sh([[:space:]]|$)'; then
    # HEREDOC やパイプでシェルに流す形（bash <<EOF / … | sh）は、本文そのものが実行されるので生文字列で見る。
    # それ以外（bash -c "…" / eval "…"）は引用符の中に実コマンドがあり、HEREDOC 本文は実行されないので
    # 本文を除いた版で見る（スクリプトを heredoc で書き出すだけのコマンドの誤検知を防ぐ）
    local hay="$rawh"
    if printf '%s\n' "$rawh" | grep -Eq -- '(^|[[:space:];&|(`])([^[:space:]]*/)?(ba|z|da|k)?sh([[:space:]]+-[A-Za-z]+)*[[:space:]]*<<|\|[[:space:]]*([^[:space:]]*/)?(ba|z|da|k)?sh([[:space:]]|$)'; then
      hay="$raw"
    fi
    case "$hay" in *'git commit'* | *'git push'* | *'gh pr create'* | *'gh pr new'* | *'gh pr edit'*) return 0 ;; esac
  fi
  return 1
}

# ---------------------------------------------------------------------------
# 保護ブランチ（既定ブランチ）判定。Claude Code / Grok / OpenCode / Codex で共有する。
# 既定ブランチ（main / master / origin/HEAD の指すブランチ）への commit・push は
# 常に deny し、それ以外への git 書き込みを自動承認の対象にする。
# ---------------------------------------------------------------------------

# パスをフック入力の cwd 基準の絶対パスにする。変数・コマンド置換を含む場合は cwd を返す
# （呼び出し側は「解決できない -> cwd」として扱う）。
_resolve_dir_arg() {
  local dir="$1" cwd="$2"
  case "$dir" in
    *'$'* | *'`'*) printf '%s' "$cwd" ;;
    /*) printf '%s' "$dir" ;;
    *) if [ "$cwd" = / ]; then printf '/%s' "$dir"; else printf '%s/%s' "${cwd%/}" "$dir"; fi ;;
  esac
}

# git ... -C <dir> の dir（commit / push より前の -C だけ）。引用符付きのパスも扱う。
# 見つからなければ空を返す。
_git_c_dir() {
  local raw="$1" q tok base ingit=0 skip=0 want=0 candidate=""
  [ -f "$STRIP_AWK" ] || return 0
  raw=${raw//\\$'\n'/ }
  q=$(printf '%s\n' "$raw" | awk -v keepq=1 -f "$STRIP_AWK" 2>/dev/null) || return 0
  q=${q//$'\n'/;}
  q=$(printf '%s' "$q" | tr ';&|()' ' ')
  set -f
  local -a toks
  read -r -a toks <<<"$q"
  for tok in "${toks[@]}"; do
    tok=${tok//\"/}
    tok=${tok//\'/}
    tok=${tok//$'\001'/ }
    [ -n "$tok" ] || continue
    if [ "$want" -eq 1 ]; then candidate=$tok; want=0; continue; fi
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    if [ "$ingit" -eq 0 ]; then
      base=${tok##*/}
      base=${base#\\}
      [ "$base" = git ] && ingit=1
      continue
    fi
    case "$tok" in
      -C) want=1 ;;
      -c | --git-dir | --work-tree | --namespace | --config-env | --exec-path) skip=1 ;;
      commit | push) set +f; printf '%s' "$candidate"; return 0 ;;
      -*) ;;
      *) ingit=0; candidate="" ;;
    esac
  done
  set +f
  return 0
}

# コマンド先頭の cd <dir> && / cd <dir> ; の dir。単独の cd や他形は返さない。
# 先頭の ( は読み飛ばす（(cd <dir> && git commit ...) の形）。
_cd_dir() {
  local raw="$1" rest dir after q
  raw=${raw#"${raw%%[![:space:]]*}"}
  while [ "${raw#(}" != "$raw" ]; do
    raw=${raw#(}
    raw=${raw#"${raw%%[![:space:]]*}"}
  done
  case "$raw" in
    cd[[:space:]]*) rest=${raw#cd} ;;
    *) return 0 ;;
  esac
  rest=${rest#"${rest%%[![:space:]]*}"}
  case "$rest" in
    \"*)
      q=${rest#\"}
      dir=${q%%\"*}
      after=${q#*\"}
      ;;
    \'*)
      q=${rest#\'}
      dir=${q%%\'*}
      after=${q#*\'}
      ;;
    *)
      dir=${rest%%[[:space:]\;\&\|]*}
      after=${rest#"$dir"}
      ;;
  esac
  [ -n "$dir" ] || return 0
  after=${after#"${after%%[![:space:]]*}"}
  case "$after" in
    '&&'* | ';'*) printf '%s' "$dir" ;;
  esac
}

# 対象リポジトリのディレクトリを解決する（引数: 生コマンド, フック入力の cwd）。
# git -C <dir> -> 先頭の cd <dir> && / ; -> cwd の順。
resolve_repo_dir() {
  local raw="$1" cwd="${2:-$PWD}" dir
  dir=$(_git_c_dir "$raw")
  if [ -n "$dir" ]; then
    _resolve_dir_arg "$dir" "$cwd"
    return
  fi
  dir=$(_cd_dir "$raw")
  if [ -n "$dir" ]; then
    _resolve_dir_arg "$dir" "$cwd"
    return
  fi
  printf '%s' "$cwd"
}

current_branch() { git -C "$1" branch --show-current 2>/dev/null; }

# main・master・origin/HEAD の指すブランチ（origin/ を除いた名前）を出力する。
protected_branch_names() {
  local dir="$1" head
  printf '%s\n' main master
  head=$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null) || head=""
  case "$head" in
    origin/*) printf '%s\n' "${head#origin/}" ;;
  esac
}

is_protected_branch_name() {
  local dir="$1" name="$2"
  [ -n "$name" ] || return 1
  protected_branch_names "$dir" | grep -qxF -- "$name"
}

# 除去後の文字列に git <sub> が含まれるか（sub = commit / push）。
_has_git_subcommand() {
  local sub="$1" s="$2"
  s=${s//\\$'\n'/ }
  s=${s//$'\n'/;}
  local wrap='(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|command|env|exec|nohup|time|builtin)[[:space:]]+)*'
  local gitopt='((-[cC]|--git-dir|--work-tree|--namespace)[[:space:]]+[^[:space:]]+[[:space:]]+|--?[A-Za-z][^[:space:]]*[[:space:]]+)*'
  local re="(^|[[:space:];&|(\`])${wrap}([^[:space:]]*/)?\\\\?git[[:space:]]+${gitopt}${sub}([[:space:];&|)<>]|\$)"
  printf '%s\n' "$s" | grep -Eq -- "$re"
}

# 除去後のコマンド文字列から、git commit の引数トークンを 1 行ずつ出力する。
# 引用符の中身を残した文字列（keepq 版）を渡す。区間（; & | 改行）をまたがない。
_commit_arg_tokens() {
  local s="$1" tok base ingit=0 seen=0 skip=0
  local -a toks
  s=${s//\\$'\n'/ }
  s=${s//$'\n'/;}
  s=$(printf '%s' "$s" | sed -E 's/[;&|]/ ; /g')
  set -f
  read -r -a toks <<<"$s"
  for tok in "${toks[@]}"; do
    [ -n "$tok" ] || continue
    if [ "$tok" = ';' ]; then
      ingit=0
      seen=0
      skip=0
      continue
    fi
    if [ "$seen" -eq 1 ]; then
      printf '%s\n' "$tok"
      continue
    fi
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    base=${tok##*/}
    base=${base#\\}
    case "$tok" in
      *\"* | *\'*) ;;
      *) base=${base#(}; base=${base%\)} ;;
    esac
    if [ "$ingit" -eq 0 ]; then
      [ "$base" = git ] && ingit=1
      continue
    fi
    case "$tok" in
      commit) seen=1 ;;
      -C | -c | --git-dir | --work-tree | --namespace | --config-env) skip=1 ;;
      -*) ;;
      *) ingit=0 ;;
    esac
  done
  set +f
}

# git commit の引数に --amend / --no-verify / -n（引用符で割ったものを含む）があるか。
# -m / -F / --message / --file / -C / -c 等の値はオプションとして見ない。
_commit_unsafe_option() {
  local raw="$1" kq tok nq quoted optval=0 rest i ch len
  [ -f "$STRIP_AWK" ] || return 1
  kq=$(printf '%s\n' "$raw" | awk -v keepq=1 -f "$STRIP_AWK" 2>/dev/null | tr '\n' ' ') || return 1
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    if [ "$optval" -eq 1 ]; then optval=0; continue; fi
    nq=${tok//[\"\']/}
    quoted=0
    [ "$tok" != "$nq" ] && quoted=1
    nq=${nq//$'\001'/ }
    if [ "$quoted" -eq 0 ]; then
      case "$nq" in '('*) nq=${nq#(} ;; esac
      case "$nq" in *')') nq=${nq%\)} ;; esac
    fi
    case "$nq" in
      --amend | --no-verify) return 0 ;;
      --message | --file | --author | --date | --template | --fixup | --squash | --trailer | --cleanup | --reuse-message | --reedit-message) optval=1 ;;
      --*=*) ;;
      --*) ;;
      -m | -F | -C | -c | -t) optval=1 ;;
      -[!-]*)
        rest=${nq#-}
        len=${#rest}
        i=0
        while [ "$i" -lt "$len" ]; do
          ch=${rest:i:1}
          case "$ch" in
            n) return 0 ;;
            m | F | C | c | t)
              if [ $((i + 1)) -lt "$len" ]; then break; fi
              optval=1
              break
              ;;
          esac
          i=$((i + 1))
        done
        ;;
    esac
  done < <(_commit_arg_tokens "$kq")
  return 1
}

# git commit の可否: none（対象外）/ protected / ask / ok
commit_verdict() {
  local raw="$1" cwd="${2:-$PWD}" s dir branch
  s=$(stripped_or_raw "$raw")
  _has_git_subcommand commit "$s" || { printf none; return; }
  dir=$(resolve_repo_dir "$raw" "$cwd")
  branch=$(current_branch "$dir")
  if is_protected_branch_name "$dir" "$branch"; then printf protected; return; fi
  if _commit_unsafe_option "$raw"; then printf ask; return; fi
  printf ok
}

# push の解析状態（1 コマンド内の複数 push は優先度の高い結果を残す）
_push_refspecs=()
_push_vars=0
_push_all=0
_push_delete=0
_push_force=0
_push_noverify=0
_push_quoted_opt=0
_push_protected=0

_push_reset() {
  _push_refspecs=()
  _push_vars=0
  _push_all=0
  _push_delete=0
  _push_force=0
  _push_noverify=0
  _push_quoted_opt=0
  _push_protected=0
}

# git push より後ろのトークンを解析する（引用符は除去済み）。
_push_analyze_args() {
  local tok skip=0 options=1 positional=0
  for tok in "$@"; do
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    if [ "$options" -eq 1 ]; then
      case "$tok" in
        --) options=0; continue ;;
        --all | --mirror) _push_all=1; continue ;;
        --delete | --prune) _push_delete=1; continue ;;
        --no-verify) _push_noverify=1; continue ;;
        --force | --force=* | --force-with-lease | --force-with-lease=* | --force-if-includes) _push_force=1; continue ;;
        --push-option | --receive-pack | --exec | --repo | -o) skip=1; continue ;;
        --push-option=* | --receive-pack=* | --exec=* | --repo=*) continue ;;
        # 未知の長いオプション（--follow-tags / --signed / --dry-run 等）は無視する
        --*) continue ;;
        # 短いフラグ群だけを文字で判定する（-f / -d / -fu 等）
        -[!-]*)
          case "$tok" in *f*) _push_force=1 ;; esac
          case "$tok" in *d*) _push_delete=1 ;; esac
          continue
          ;;
      esac
    fi
    case "$tok" in
      *'$'* | *'`'*) _push_vars=1 ;;
    esac
    case "$tok" in
      :*) _push_delete=1; continue ;;
      +*) tok=${tok#+} ;;
    esac
    if [ "$positional" -eq 0 ]; then
      positional=1 # 最初の位置引数はリモート名
    else
      _push_refspecs+=("$tok")
    fi
  done
}

# refspec の宛先が保護ブランチなら 0。判定できない形（変数・ワイルドカード）は
# _push_vars を立てて 1 を返す。
_push_ref_is_protected() {
  local dir="$1" ref="$2" dest
  ref=${ref#+}
  case "$ref" in *'*'* | *'$'* | *'`'*) _push_vars=1; return 1 ;; esac
  case "$ref" in
    *:*) dest=${ref#*:} ;;
    *) dest=$ref ;;
  esac
  dest=${dest#+}
  if [ -z "$dest" ]; then _push_delete=1; return 1; fi
  [ "$dest" = HEAD ] && dest=$(current_branch "$dir")
  case "$dest" in
    refs/heads/*) dest=${dest#refs/heads/} ;;
    refs/*) return 1 ;;
  esac
  is_protected_branch_name "$dir" "$dest"
}

# 1 つの push 区間の宛先を判定する。
_push_finalize() {
  local dir="$1" branch r
  branch=$(current_branch "$dir")
  if [ "${#_push_refspecs[@]}" -eq 0 ]; then
    is_protected_branch_name "$dir" "$branch" && _push_protected=1
    return
  fi
  for r in "${_push_refspecs[@]}"; do
    _push_ref_is_protected "$dir" "$r" && _push_protected=1
  done
}

# 引用符の中身を残した文字列から、git push の引数トークンを 1 行ずつ出力する。
# 区間（; & | 改行）をまたがない。引用符の中の区切りは \001 になっている前提。
_push_arg_tokens() {
  local q="$1" tok nq base ingit=0 seen=0 skip=0 pvalskip=0
  local -a toks
  q=${q//\\$'\n'/ }
  q=${q//$'\n'/;}
  q=$(printf '%s' "$q" | sed -E 's/[;&|]/ ; /g')
  set -f
  read -r -a toks <<<"$q"
  for tok in "${toks[@]}"; do
    [ -n "$tok" ] || continue
    if [ "$tok" = ';' ]; then
      ingit=0
      seen=0
      skip=0
      pvalskip=0
      continue
    fi
    nq=${tok//[\"\']/}
    nq=${nq//$'\001'/ }
    if [ "$seen" -eq 1 ]; then
      if [ "$pvalskip" -eq 1 ]; then pvalskip=0; continue; fi
      printf '%s\n' "$tok"
      case "$nq" in
        --push-option | --receive-pack | --exec | --repo | -o) pvalskip=1 ;;
      esac
      continue
    fi
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    base=${nq##*/}
    base=${base#\\}
    case "$tok" in
      *\"* | *\'*) ;;
      *) base=${base#(}; base=${base%\)} ;;
    esac
    if [ "$ingit" -eq 0 ]; then
      [ "$base" = git ] && ingit=1
      continue
    fi
    case "$nq" in
      push) seen=1 ;;
      -C | -c | --git-dir | --work-tree | --namespace | --config-env) skip=1 ;;
      commit) ingit=0 ;;
      -*) ;;
      *) ingit=0 ;;
    esac
  done
  set +f
}

# git push 区間の引用符で割ったトークン（"--force" / -"f" / "main" / "$BRANCH" 等）を検出する。
_push_quoted_flags() {
  local raw="$1" dir="$2" kq tok nq
  [ -f "$STRIP_AWK" ] || return 0
  kq=$(printf '%s\n' "$raw" | awk -v keepq=1 -f "$STRIP_AWK" 2>/dev/null | tr '\n' ' ') || return 0
  set -f
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    nq=${tok//[\"\']/}
    [ "$tok" = "$nq" ] && continue
    nq=${nq//$'\001'/ }
    case "$nq" in
      --force | --force=* | --force-with-lease | --force-with-lease=* | --force-if-includes) _push_force=1 ;;
      --delete | --prune) _push_delete=1 ;;
      --all | --mirror) _push_all=1 ;;
      --no-verify) _push_noverify=1 ;;
      -*) _push_quoted_opt=1 ;;
      *)
        case "$nq" in *'$'* | *'`'*) _push_vars=1 ;; esac
        _push_ref_is_protected "$dir" "$nq" && _push_protected=1
        ;;
    esac
  done < <(_push_arg_tokens "$kq")
  set +f
}

# git push の可否: none / all / delete / force / no-verify / protected / indeterminate / ok
# indeterminate は宛先を判定できない（変数・ワイルドカード・引用符で割った未知のオプション）。
push_destination_verdict() {
  local raw="$1" cwd="${2:-$PWD}" s dir tok base ingit=0 seen=0 skip=0
  s=$(stripped_or_raw "$raw")
  _has_git_subcommand push "$s" || { printf none; return; }
  _push_reset
  dir=$(resolve_repo_dir "$raw" "$cwd")

  s=${s//\\$'\n'/ }
  s=${s//$'\n'/;}
  s=$(printf '%s' "$s" | sed -E 's/[;&|()]/ ; /g')
  set -f
  local -a toks args
  read -r -a toks <<<"$s"
  args=()
  for tok in "${toks[@]}"; do
    tok=${tok//\"/}
    tok=${tok//\'/}
    if [ "$tok" = ';' ]; then
      if [ "$seen" -eq 1 ]; then
        _push_analyze_args "${args[@]}"
        _push_finalize "$dir"
        args=()
        _push_refspecs=()
      fi
      ingit=0
      seen=0
      skip=0
      continue
    fi
    if [ "$seen" -eq 1 ]; then
      args+=("$tok")
      continue
    fi
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    base=${tok##*/}
    base=${base#\\}
    if [ "$ingit" -eq 0 ]; then
      [ "$base" = git ] && ingit=1
      continue
    fi
    case "$tok" in
      push) seen=1 ;;
      -C | -c | --git-dir | --work-tree | --namespace | --config-env) skip=1 ;;
      commit) ingit=0 ;;
      -*) ;;
      *) ingit=0 ;;
    esac
  done
  if [ "$seen" -eq 1 ]; then
    _push_analyze_args "${args[@]}"
    _push_finalize "$dir"
  fi
  set +f

  _push_quoted_flags "$raw" "$dir"

  if [ "$_push_all" -eq 1 ]; then printf all
  elif [ "$_push_delete" -eq 1 ]; then printf delete
  elif [ "$_push_force" -eq 1 ]; then printf force
  elif [ "$_push_noverify" -eq 1 ]; then printf no-verify
  elif [ "$_push_protected" -eq 1 ]; then printf protected
  elif [ "$_push_vars" -eq 1 ] || [ "$_push_quoted_opt" -eq 1 ]; then printf indeterminate
  else printf ok
  fi
}

# PR のマージ（gh pr merge / gh api の /pulls/N/merge への PUT / GraphQL の
# mergePullRequest）か。マージは常に確認ダイアログにする（Codex は deny）。
is_pr_merge() {
  local raw="$1" s q token gh=0 api=0 endpoint=0 method="" field=0 next_method=0
  local -a tokens
  s=$(stripped_or_raw "$raw")
  s=${s//\\$'\n'/ }
  s=${s//$'\n'/;}
  printf '%s\n' "$s" | grep -Eq -- '(^|[[:space:];&|(`])([^[:space:]]*/)?\\?gh[[:space:]]+pr[[:space:]]+merge([[:space:];&|)<>]|$)' && return 0
  case "$s" in *gh*api* | *graphql*) case "$raw" in *mergePullRequest*) return 0 ;; esac ;; esac
  [ -f "$STRIP_AWK" ] || return 1
  raw=${raw//\\$'\n'/ }
  q=$(printf '%s\n' "$raw" | awk -v keepq=1 -v join_quoted_lines=1 -f "$STRIP_AWK" 2>/dev/null) || q="$raw"
  q=${q//$'\n'/;}
  q=$(printf '%s\n' "$q" | sed -E 's/[;&|]/ ; /g; s/[()`]/ /g')
  read -r -a tokens <<<"$q ;"
  for token in "${tokens[@]}"; do
    if [ "$token" = ';' ]; then
      if [ "$endpoint" -eq 1 ]; then
        case "$method" in PUT) return 0 ;; '') [ "$field" -eq 1 ] && return 0 ;; esac
      fi
      gh=0
      api=0
      endpoint=0
      method=""
      field=0
      next_method=0
      continue
    fi
    token=${token//\"/}
    token=${token//\'/}
    token=${token//$'\001'/ }
    if [ "$api" -eq 0 ]; then
      case "$token" in gh | */gh | '\gh') gh=1 ;; api) api=$gh ;; esac
      continue
    fi
    if [ "$next_method" -eq 1 ]; then method="$token"; next_method=0; continue; fi
    case "$token" in
      -X | --method) next_method=1 ;;
      --method=*) method="${token#--method=}" ;;
      -f | -F | --field | --raw-field | --input | --field=* | --raw-field=* | --input=*) field=1 ;;
      *) [[ "$token" =~ ^[^[:space:]]*/pulls/[0-9]+/merge$ ]] && endpoint=1 ;;
    esac
  done
  return 1
}

# force push は /pr 中でも deny（Claude の ask も Grok の always-approve も通さない）
is_force_push() {
  local raw="$1" s
  s=$(stripped_or_raw "$raw")
  s=${s//\\$'\n'/ }
  s=${s//$'\n'/;}
  printf '%s\n' "$s" | grep -Eq -- '(^|[[:space:];&|(`])([^[:space:]]*/)?\\?git[[:space:]]+' || return 1
  case "$s" in *"git push"* | *" push "*) ;; *)
    printf '%s\n' "$s" | grep -Eq -- '(^|[[:space:];&|(`])([^[:space:]]*/)?\\?git[[:space:]]+((-[cC]|--git-dir|--work-tree|--namespace)[[:space:]]+[^[:space:]]+[[:space:]]+|--?[A-Za-z][^[:space:]]*[[:space:]]+)*push([[:space:];&|)<>]|$)' || return 1
    ;;
  esac
  case "$s" in *--force* | *--force-with-lease*) return 0 ;; esac
  local saw_push=0 t
  s=$(printf '%s' "$s" | tr ';|&()' ' ')
  for t in $s; do
    [ "$t" = "push" ] && saw_push=1
    if [ "$saw_push" -eq 1 ]; then
      case "$t" in
        -f|--force|--force-with-lease|--force=*|--force-with-lease=*) return 0 ;;
        --*) ;;
        -*) printf '%s' "$t" | grep -Eq -- '^-[A-Za-z]*f[A-Za-z]*$' && return 0 ;;
      esac
    fi
  done
  return 1
}
