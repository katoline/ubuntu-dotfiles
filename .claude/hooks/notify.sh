#!/usr/bin/env bash
# Claude Code の hook（Stop / Notification）から呼ばれ、iPhone へ Web Push 通知を送る。
# Grok CLI も Claude 互換モード（compat.claude.hooks、デフォルト有効）で
# ~/.claude/settings.json の同じ hooks を実行する。
# Grok は stdin JSON が camelCase（hookEventName 等、イベント値は小文字）になるので、
# Grok が全フックに注入する環境変数 GROK_HOOK_EVENT で判別・正規化する。
# 送信本体は同じ dotfiles リポジトリ内の claude-notify/send-push.mjs
# （このスクリプトも dotfiles 管理。~/.claude/hooks/notify.sh にリンクされる）。
# 受信側の PWA は別リポジトリ claude-notify-mobile（Vercel 配信）にある。
# stdin に hook イベントの JSON が流れてくる。
# 委譲した OpenCode（.claude/skills/opencode/scripts/run.sh）が同じプロジェクトで
# 実行中の間は、ターン終了時の Stop 通知を送らない（マーカーは run.sh が作る）。
# 何が起きても即座に exit 0 で終わる（Claude Code の動作を妨げないため）。

set -u

# このスクリプトは ~/.claude/hooks/notify.sh からシンボリックリンクされるため、
# 実体パスを解決して dotfiles ルートを求める
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
DOTFILES_DIR="$(cd "$(dirname "$SCRIPT_PATH")/../.." && pwd)"
SENDER="$DOTFILES_DIR/claude-notify/send-push.mjs"
LOG_FILE="$HOME/.claude/claude-notify.log"

# 送信スクリプトや jq がなければ何もせず終了（依存の欠如で Claude Code を止めない）
if [ ! -f "$SENDER" ] || ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

input="$(cat 2>/dev/null)"
if [ -z "$input" ]; then
  exit 0
fi

event="$(printf '%s' "$input" | jq -r '.hook_event_name // .hookEventName // empty' 2>/dev/null)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // .workspaceRoot // empty' 2>/dev/null)"
message="$(printf '%s' "$input" | jq -r '.message // empty' 2>/dev/null)"

# Grok CLI からの呼び出し。判定は GROK_HOOK_EVENT（stdin のキー有無に依存しない）
source_label=""
if [ -n "${GROK_HOOK_EVENT:-}" ]; then
  source_label=" (Grok)"
  case "$GROK_HOOK_EVENT" in
    stop) event="Stop" ;;
    notification) event="Notification" ;;
    *) [ -n "$event" ] || event="$GROK_HOOK_EVENT" ;;
  esac

  # Grok の Stop は応答完了以外（セッション終了時など）にも発火するため、
  # reason == "end_turn" のときだけ通知する
  if [ "$event" = "Stop" ]; then
    reason="$(printf '%s' "$input" | jq -r '.reason // empty' 2>/dev/null)"
    [ "$reason" = "end_turn" ] || exit 0
  fi

  # Grok の Notification は idle_prompt など多種のタイプを含み、
  # idle_prompt は Stop と重複する。許可待ち（permission_prompt）だけ通知する
  if [ "$event" = "Notification" ]; then
    ntype="$(printf '%s' "$input" | jq -r '.notificationType // empty' 2>/dev/null)"
    [ "$ntype" = "permission_prompt" ] || exit 0
  fi
fi

# 委譲した OpenCode が同じプロジェクトで実行中かどうか。
# マーカーは run.sh が <PID>\n<解決済み dir>\n<git common dir>\n で作り、終了時に消す。
# 3行目が無い古い形式のマーカーはパス判定だけで見る。git が無い・失敗しても通知は従来どおり。
# 古いマーカーは無視するだけで削除しない（notify.sh は書き込まない）。
opencode_running_in_cwd() {
  [ -n "$cwd" ] || return 1
  local marker_dir="$HOME/.cache/claude-opencode-running"
  [ -d "$marker_dir" ] || return 1
  local resolved
  resolved="$(cd -- "$cwd" 2>/dev/null && pwd -P)" || resolved="$cwd"
  [ -n "$resolved" ] || return 1
  local cwd_common
  cwd_common="$(git -C "$resolved" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  local marker pid mdir mcommon
  for marker in "$marker_dir"/*; do
    [ -f "$marker" ] || continue
    pid=""
    mdir=""
    mcommon=""
    { IFS= read -r pid; IFS= read -r mdir; IFS= read -r mcommon; } < "$marker" 2>/dev/null || true
    [ -n "$pid" ] && [ -n "$mdir" ] || continue
    kill -0 "$pid" 2>/dev/null || continue
    tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q 'opencode/scripts/run.sh' || continue
    [ "$resolved" = "$mdir" ] && return 0
    case "$resolved/" in "$mdir"/*) return 0 ;; esac
    case "$mdir/" in "$resolved"/*) return 0 ;; esac
    if [ -n "$cwd_common" ] && [ "$cwd_common" = "$mcommon" ]; then
      return 0
    fi
  done
  return 1
}

if [ "$event" = "Stop" ] && opencode_running_in_cwd; then
  exit 0
fi

if [ -z "$cwd" ]; then
  project="unknown"
else
  project="$(basename "$cwd")"
fi

if [ -z "$message" ] || [ "$message" = "null" ]; then
  case "$event" in
    Stop)
      message="タスクが完了しました"
      ;;
    Notification)
      message="確認待ちです"
      ;;
    *)
      message="通知があります"
      ;;
  esac
fi

# home-manager で導入した node（~/.nix-profile/bin/node）をフォールバックにする。
# Claude Code の hook 環境では PATH が狭いことがある
NODE_BIN="${CLAUDE_NOTIFY_NODE:-$(command -v node || echo "$HOME/.nix-profile/bin/node")}"

if [ ! -x "$NODE_BIN" ] && ! command -v "$NODE_BIN" >/dev/null 2>&1; then
  exit 0
fi

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null

# ログの無限成長を防ぐ（1MB超なら切り詰めてから追記する）
if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  : > "$LOG_FILE"
fi

nohup "$NODE_BIN" "$SENDER" \
  --title "[$project] $event$source_label" \
  --body "$message" \
  --event "$event" \
  --project "$project" \
  </dev/null >>"$LOG_FILE" 2>&1 &

disown 2>/dev/null || true

exit 0
