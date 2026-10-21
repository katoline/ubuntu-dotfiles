#!/bin/bash

# 共通指示（ai/core.md）と CLI 別差分（ai/<cli>.md）を、各 AI コーディング CLI の
# グローバル指示ファイルへ配布する。
#   bash ai/install.sh
#
# 方針:
# - 共通ルールの実体は ai/core.md 1 本だけ。CLI 別ファイルには差分しか書かない
#   （同じ内容を各 CLI のファイルへ重複記載すると、コンテキストを二重に消費し、
#     片方だけ直して食い違う）
# - 複数ファイルを読める CLI はリンクで参照させ、1 ファイルしか読まない CLI は連結生成する
#     Claude Code … ~/.claude/CLAUDE.md（core）と ~/.claude/rules/claude.md（差分）へのリンク。
#                    編集が即反映される（リンクなので install.sh の再実行は不要）
#     OpenCode     … ~/.config/opencode/AGENTS.md を連結生成。V2 は AGENTS.md のみを読み、
#                    CLAUDE.md へのフォールバックは無い。instructions はファイル・glob・URL を
#                    解決できるが、ai/ を列挙すると AGENTS.md との二重読みになるため使わない
#     Grok         … ~/.grok/AGENTS.md を連結生成
#     Codex        … ~/.codex/AGENTS.md を連結生成
#     Devin        … ~/.config/devin/AGENTS.md を連結生成
# - 連結生成した4つは ai/*.md を編集したら再実行が必要（home-manager switch 時にも自動実行される）
# - 内容が同じなら書き換えない（mtime を動かさない）。1 つの失敗で残りを止めず、末尾にまとめて報告する

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="$SCRIPT_DIR/core.md"
failed=""

echo "AI コーディング CLI の共通指示を配布します..."

[ -f "$CORE" ] || { echo "エラー: $CORE が見つかりません" >&2; exit 1; }

# $1 をリンク先 $2 のシンボリックリンクにする（実体ファイルが居座っていたら .bak へ退避）
link_file() {
  local src="$1" dest="$2" rel="${2#$HOME/}"
  if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
    echo "  = ~/$rel"
    return 0
  fi
  mkdir -p "$(dirname "$dest")" || return 1
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    mv "$dest" "$dest.bak" || return 1
    echo "  ! 実体ファイルを ~/$rel.bak へ退避しました（不要なら削除してください）"
  fi
  [ -L "$dest" ] && { rm "$dest" || return 1; }
  ln -s "$src" "$dest" || return 1
  echo "  ✓ ~/$rel -> $src"
}

# core.md + 差分ファイルを連結して $3 へ書く（内容が同じなら触らない）
generate_file() {
  local label="$1" delta="$2" dest="$3" rel="${3#$HOME/}" tmp
  [ -f "$delta" ] || { echo "  ✗ $label: $delta が見つかりません" >&2; return 1; }
  mkdir -p "$(dirname "$dest")" || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/ai-install.XXXXXX")" || return 1
  {
    # ヘッダーは各 CLI のコンテキストに毎回載るので 1 行に収める（実体はファイル名だけ示す）
    printf '<!-- 自動生成ファイル（編集しない）。実体は dotfiles の ai/%s と ai/%s。変更したら bash ai/install.sh -->\n\n' \
      "$(basename "$CORE")" "$(basename "$delta")"
    cat "$CORE"
    printf '\n'
    cat "$delta"
  } >"$tmp" || { rm -f "$tmp"; return 1; }
  if [ -f "$dest" ] && [ ! -L "$dest" ] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    echo "  = ~/$rel"
    return 0
  fi
  # 旧構成のリンク（リポジトリの grok/AGENTS.md 等を指す）が残っていたら外す
  [ -L "$dest" ] && { rm "$dest" || { rm -f "$tmp"; return 1; } }
  mv "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
  chmod 644 "$dest" 2>/dev/null
  echo "  ✓ ~/$rel（$label）"
}

# Claude Code: リンク（編集が即反映される）
link_file "$CORE" "$HOME/.claude/CLAUDE.md" || failed="$failed ~/.claude/CLAUDE.md"
link_file "$SCRIPT_DIR/claude.md" "$HOME/.claude/rules/claude.md" || failed="$failed ~/.claude/rules/claude.md"

# グローバル指示を 1 ファイルしか読まない CLI: 連結生成
generate_file "OpenCode" "$SCRIPT_DIR/opencode.md" "$HOME/.config/opencode/AGENTS.md" || failed="$failed ~/.config/opencode/AGENTS.md"
generate_file "Grok" "$SCRIPT_DIR/grok.md" "$HOME/.grok/AGENTS.md" || failed="$failed ~/.grok/AGENTS.md"
generate_file "Codex" "$SCRIPT_DIR/codex.md" "$HOME/.codex/AGENTS.md" || failed="$failed ~/.codex/AGENTS.md"
generate_file "Devin" "$SCRIPT_DIR/devin.md" "$HOME/.config/devin/AGENTS.md" || failed="$failed ~/.config/devin/AGENTS.md"

echo ""
if [ -n "$failed" ]; then
  echo "警告: 以下の配布に失敗しました:$failed" >&2
  exit 1
fi
echo "配布が完了しました。OpenCode / Grok / Codex / Devin は連結生成なので、ai/*.md を編集したら再実行してください。"
