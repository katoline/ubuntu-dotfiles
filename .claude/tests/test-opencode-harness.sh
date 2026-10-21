#!/bin/bash
# opencode/hooks/harness.sh（OpenCode plugin と共通フックの adapter）のテスト。
# 既存の本物の guard-destructive.sh / pr-mode.sh / verify-gate.sh を使い、HOME / TMPDIR を
# 一時ディレクトリへ隔離する（~/.claude/pr-mode.log や実セッションのフラグに書かない）。
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
REPO_DIR="$(cd "$TESTS_DIR/../.." && pwd)"
ADAPTER="$REPO_DIR/opencode/hooks/harness.sh"
W="$T/claude-opencode-harness.$$"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT
cleanup
mkdir -p "$W/home/.claude" "$W/home/orca/workspaces/repo/tmp" "$W/tmp" "$W/out"
export HOME="$W/home"
export TMPDIR="$W/tmp"

op() { printf '%s' "$2" | bash "$ADAPTER" "$1"; }
decision() {
  if [ -z "$1" ]; then echo none; else printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // .hookSpecificOutput.decision.behavior // "none"'; fi
}
reason() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // .hookSpecificOutput.decision.message // ""'; }
state_of() { if [ -f "$TMPDIR/claude-verify-gate-$1" ]; then cut -f1 "$TMPDIR/claude-verify-gate-$1" | paste -sd, -; else echo none; fi; }

SAFE="$HOME/orca/workspaces/repo/tmp/safe"
mkdir -p "$SAFE/dir"

echo "# A. guard（削除・Git 以外の共通判定）"
out=$(op guard "$(jq -cn --arg c "rm -rf $SAFE/dir" --arg d "$HOME/orca/workspaces/repo" '{session_id:"opencode-g1",command:$c,cwd:$d}')")
report A01-safe-rm none "$(decision "$out")" "$out"
out=$(op guard "$(jq -cn '{session_id:"opencode-g1",command:"rm -rf /etc/nope",cwd:"/tmp"}')")
report A02-outside-rm deny "$(decision "$out")" "$out"
out=$(op guard "$(jq -cn '{session_id:"opencode-g1",command:"rm -rf $VAR/x",cwd:"/tmp"}')")
report A03-opaque-rm ask "$(decision "$out")" "$out"
out=$(op guard "$(jq -cn '{session_id:"opencode-g1",command:"chmod -R 777 /tmp/x",cwd:"/tmp"}')")
report A04-chmod-ask ask "$(decision "$out")" "$out"
out=$(op guard "$(jq -cn '{session_id:"opencode-g1",command:"git commit -m x",cwd:"/tmp"}')")
report A05-guard-git-none none "$(decision "$out")" "Git の可否は pr-mode が担当する"

echo "# B. pr-mode（通常・/pr 中・子・force）"
out=$(op pr-pre "$(jq -cn '{session_id:"opencode-p1",command:"git commit -m x",cwd:"/tmp"}')")
report B01-before-pr deny "$(decision "$out")" "$out"
out=$(op pr-start '{"session_id":"opencode-p1"}')
report B02-start-empty "" "$out" "pr-mode のフラグ作成（出力なし）"
out=$(op pr-pre "$(jq -cn '{session_id:"opencode-p1",command:"git commit -m x",cwd:"/tmp"}')")
report B03-in-pr-none none "$(decision "$out")" "$out"
out=$(op pr-request "$(jq -cn '{session_id:"opencode-p1",command:"git commit -m x",cwd:"/tmp"}')")
report B04-in-pr-allow allow "$(decision "$out")" "$out"
out=$(op pr-request "$(jq -cn '{session_id:"opencode-p1",command:"gh pr merge 1",cwd:"/tmp"}')")
report B05-merge-none none "$(decision "$out")" "merge は自動 allow しない"
out=$(op pr-pre "$(jq -cn '{session_id:"opencode-p1",command:"git push --force origin x",cwd:"/tmp"}')")
report B06-force-deny deny "$(decision "$out")" "$out"
out=$(op pr-pre "$(jq -cn '{session_id:"opencode-p1",command:"git commit -m x",cwd:"/tmp",agent_id:"child"}')")
report B07-child-deny deny "$(decision "$out")" "$out"
out=$(op pr-stop '{"session_id":"opencode-p1"}')
report B08-stop-empty "" "$out" "通常プロンプトの解除は canonical な pr-stop だけを使う（本文は渡さない）"
out=$(op pr-pre "$(jq -cn '{session_id:"opencode-p1",command:"git commit -m x",cwd:"/tmp"}')")
report B09-after-submit-deny deny "$(decision "$out")" "$out"

echo "# C. verify-gate（adapter の正規化と TMPDIR 隔離）"
VS=opencode-vg-$$
VG_PATH="$REPO_DIR/opencode/hooks/harness.sh"
out=$(op verify-post "$(jq -cn --arg s "$VS" --arg f "$VG_PATH" '{session_id:$s,tool_name:"Edit",file_path:$f}')")
report C01-edit-empty "" "$out" "記録だけ"
report C02-state run.sh "$(state_of "$VS")" ""
out=$(op verify-stop "$(jq -cn --arg s "$VS" '{session_id:$s,stop_hook_active:false}')")
report C03-stop-block block "$(printf '%s' "$out" | jq -r '.decision // "none"')" "$out"
out=$(op verify-post "$(jq -cn --arg s "$VS" '{session_id:$s,tool_name:"Bash",command:"bash .claude/tests/run.sh",stdout:"すべて通過",cwd:"'"$REPO_DIR"'"}')")
report C04-run-empty "" "$out" ""
report C05-cleared none "$(state_of "$VS")" "成功した run.sh で解除する"

echo "# D. 異常系（fail-closed）"
printf '{}' | env PATH=/nonexistent /bin/bash "$ADAPTER" guard >/dev/null 2>&1
report D01-no-tools 1 "$?" "jq / 共通スクリプトを解決できないときは成功扱いにしない"
printf '{' | bash "$ADAPTER" guard >/dev/null 2>&1
report D02-broken-json 1 "$?" "壊れた JSON は失敗"
printf '{}' | bash "$ADAPTER" unknown >/dev/null 2>&1
report D03-unknown-op 1 "$?" "未知の操作は失敗"
printf '{"session_id":"../x"}' | bash "$ADAPTER" pr-start >/dev/null 2>&1
report D04-bad-session 1 "$?" "session id を検証する"
out=$(op guard '{"session_id":"opencode-g1","command":"true","cwd":"/tmp"}')
report D05-no-decision none "$(decision "$out")" "通常コマンドは no-decision"

cleanup
summary "opencode-harness.sh"
