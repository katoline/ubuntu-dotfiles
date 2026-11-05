# 委譲した OpenCode（.claude/skills/opencode/scripts/run.sh）が指定ディレクトリで実行中かを判定する。
# notify.sh（実行中の Stop 通知を送らない）と completion-gate.sh（完了待ちで止まっている間は完了チェックを促さない）が共有する。
# マーカーは run.sh が <PID>\n<解決済み dir>\n<git common dir>\n で作り、終了時に消す。
# 3行目が無い古い形式のマーカーはパス判定だけで見る。git が無い・失敗しても判定は続ける。
# 古いマーカーは無視するだけで削除しない（この関数は書き込まない）。
# 引数: 判定するディレクトリ（空なら実行中とみなさない）
opencode_running_in_cwd() {
  local cwd="${1-}"
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
