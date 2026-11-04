#!/bin/bash
# notify.sh の Stop 通知抑止テスト（委譲した OpenCode が同じプロジェクトで実行中の間は送らない）
# 実行: bash .claude/tests/test-notify.sh（run.sh からも呼ばれる）
# HOME を一時ディレクトリにし、送信は CLAUDE_NOTIFY_NODE のスタブで印だけ残す（実通知は送らない）
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
NOTIFY="$HOOKS_DIR/notify.sh"
HOME_DIR="$T/notify-home"
SENT="$T/notify-sent"
NODE_STUB="$T/notify-node-stub"
MARKER_DIR="$HOME_DIR/.cache/claude-opencode-running"
PROJECT="$(cd "$T" && mkdir -p notify-project && cd notify-project && pwd -P)"
OTHER="$(cd "$T" && mkdir -p notify-other && cd notify-other && pwd -P)"
mkdir -p "$HOME_DIR" "$MARKER_DIR"

cat > "$NODE_STUB" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CLAUDE_NOTIFY_TEST_MARK"
STUB
chmod +x "$NODE_STUB"

# 生存中の run.sh 相当プロセス（cmdline に opencode/scripts/run.sh を含む）
LIVE_SCRIPT="$T/fake-opencode/scripts/run.sh"
mkdir -p "$(dirname "$LIVE_SCRIPT")"
printf '#!/usr/bin/env bash\nsleep 60\n' > "$LIVE_SCRIPT"
bash "$LIVE_SCRIPT" &
LIVE_PID=$!
cleanup() { kill "$LIVE_PID" 2>/dev/null || true; }
trap cleanup EXIT

marker() { # name pid dir [git-common-dir]
  printf '%s\n%s\n' "$2" "$3" > "$MARKER_DIR/$1"
  if [ "$#" -ge 4 ]; then
    printf '%s\n' "$4" >> "$MARKER_DIR/$1"
  fi
}
clear_markers() { rm -f "$MARKER_DIR"/*; }
dead_pid() { sh -c 'echo $$'; }
run_notify() { # event cwd
  jq -cn --arg e "$1" --arg d "$2" '{hook_event_name:$e, cwd:$d}' \
    | env HOME="$HOME_DIR" CLAUDE_NOTIFY_NODE="$NODE_STUB" CLAUDE_NOTIFY_TEST_MARK="$SENT" \
        bash "$NOTIFY" >/dev/null 2>&1
}
# notify.sh はスタブ node をバックグラウンド起動するので、印を短い待機付きで確認する
sent() {
  local i=0
  while [ "$i" -lt 40 ]; do
    [ -f "$SENT" ] && { echo yes; return; }
    sleep 0.05
    i=$((i + 1))
  done
  echo no
}

echo "# A. 委譲した OpenCode 実行中の Stop は通知しない"
clear_markers
marker live "$LIVE_PID" "$PROJECT"
rm -f "$SENT"
run_notify Stop "$PROJECT"
report A01-suppressed no "$(sent)" "生存プロセス＋同じ cwd のマーカー"

echo "# B. 別プロジェクト・死んだ PID・Notification は従来どおり通知する"
clear_markers
marker other "$LIVE_PID" "$OTHER"
rm -f "$SENT"
run_notify Stop "$PROJECT"
report B01-other-project yes "$(sent)" "マーカーの dir が別プロジェクト"

clear_markers
marker dead "$(dead_pid)" "$PROJECT"
rm -f "$SENT"
run_notify Stop "$PROJECT"
report B02-dead-pid yes "$(sent)" "PID が死んでいるマーカー"

clear_markers
marker live "$LIVE_PID" "$PROJECT"
rm -f "$SENT"
run_notify Notification "$PROJECT"
report B03-notification yes "$(sent)" "Notification（許可待ち）は抑止しない"

echo "# C. 同じリポジトリの worktree（パスが重ならない）も抑止する"
# テスト用リポジトリは一時ディレクトリ内だけに作り、git -C で操作する
GIT_MAIN="$T/git-main"
GIT_WT="$T/git-wt"
GIT_OTHER="$T/git-other"
git init -q "$GIT_MAIN"
git -C "$GIT_MAIN" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q --allow-empty -m init
git -C "$GIT_MAIN" worktree add -q --detach "$GIT_WT"
git init -q "$GIT_OTHER"
GIT_MAIN="$(cd "$GIT_MAIN" && pwd -P)"
GIT_WT="$(cd "$GIT_WT" && pwd -P)"
GIT_OTHER="$(cd "$GIT_OTHER" && pwd -P)"
GIT_COMMON="$(git -C "$GIT_WT" rev-parse --path-format=absolute --git-common-dir)"

clear_markers
marker worktree "$LIVE_PID" "$GIT_WT" "$GIT_COMMON"
rm -f "$SENT"
run_notify Stop "$GIT_MAIN"
report C01-worktree-suppressed no "$(sent)" "マーカー dir=worktree・cwd=メイン checkout"

clear_markers
marker worktree "$LIVE_PID" "$GIT_WT" "$GIT_COMMON"
rm -f "$SENT"
run_notify Stop "$GIT_OTHER"
report C02-other-repo yes "$(sent)" "無関係な別リポジトリの cwd では送信する"

summary "notify-stop-suppression"
