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
report A03-opaque-rm deny "$(decision "$out")" "$out"
out=$(op guard "$(jq -cn '{session_id:"opencode-g1",command:"chmod -R 777 /tmp/x",cwd:"/tmp"}')")
report A04-chmod-none none "$(decision "$out")" "$out"
out=$(op guard "$(jq -cn '{session_id:"opencode-g1",command:"git commit -m x",cwd:"/tmp"}')")
report A05-guard-git-none none "$(decision "$out")" "Git の可否は pr-mode が担当する"

echo "# B. pr-mode（既定ブランチ保護。pr-pre / pr-request の結果をそのまま使う）"
REPOS="$W/repos"
git_init() { # dir branch
  local dir="$1" branch="$2"
  mkdir -p "$dir"
  git init -q -b "$branch" "$dir" 2>/dev/null || {
    git init -q "$dir"
    git -C "$dir" checkout -q -b "$branch"
  }
}
git_init "$REPOS/main" main
git_init "$REPOS/feat" feat/x
git_init "$REPOS/trunk" trunk
git -C "$REPOS/trunk" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk

pre() { op pr-pre "$(jq -cn --arg s opencode-p1 --arg c "$1" --arg d "${2-/tmp}" '{session_id:$s,command:$c,cwd:$d}')"; }
request() { op pr-request "$(jq -cn --arg s opencode-p1 --arg c "$1" --arg d "${2-/tmp}" '{session_id:$s,command:$c,cwd:$d}')"; }
out=$(pre 'git commit -m x' "$REPOS/main")
report B01-commit-main deny "$(decision "$out")" "$out"
out=$(pre 'git commit -m x' "$REPOS/feat")
report B02-commit-feat none "$(decision "$out")" "$out"
out=$(request 'git commit -m x' "$REPOS/feat")
report B03-request-commit-feat allow "$(decision "$out")" "$out"
out=$(request 'git commit -m x' "$REPOS/main")
report B04-request-commit-main deny "$(decision "$out")" "$out"
out=$(pre 'gh pr merge 1')
report B05-merge-ask ask "$(decision "$out")" "確認が必要な merge は PreToolUse で ask"
out=$(request 'gh pr merge 1')
report B06-request-merge-none none "$(decision "$out")" "merge は自動 allow しない"
out=$(pre 'git push --force origin x' "$REPOS/feat")
report B07-force-deny deny "$(decision "$out")" "$out"
out=$(op pr-pre "$(jq -cn --arg d "$REPOS/feat" '{session_id:"opencode-p1",command:"git commit -m x",cwd:$d,agent_id:"child"}')")
report B08-child-deny deny "$(decision "$out")" "$out"
out=$(pre 'git push origin "$BRANCH"' "$REPOS/feat")
report B09-vars-deny deny "$(decision "$out")" "$out"
# OpenCode の pr-request は main 時点の範囲（git の自動承認対象だけ）に戻す
out=$(request 'home-manager switch' "$REPOS/feat")
report B0K-request-home-manager-none none "$(decision "$out")" "$out"
out=$(request 'apt install -y x' "$REPOS/feat")
report B0L-request-apt-none none "$(decision "$out")" "$out"
out=$(request 'git reset --hard' "$REPOS/feat")
report B0M-request-reset-hard-none none "$(decision "$out")" "$out"
out=$(pre 'git push origin main' "$REPOS/feat")
report B0A-push-dest-main deny "$(decision "$out")" "$out"
out=$(pre 'git push origin feat/x' "$REPOS/feat")
report B0B-push-dest-feat none "$(decision "$out")" "$out"
out=$(pre "git -C $REPOS/main commit -m x" /tmp)
report B0C-gitc-main deny "$(decision "$out")" "$out"
out=$(pre "git -C $REPOS/feat commit -m x" /tmp)
report B0D-gitc-feat none "$(decision "$out")" "$out"
out=$(pre "cd $REPOS/main && git commit -m x" /tmp)
report B0E-cd-main deny "$(decision "$out")" "$out"
out=$(pre 'git push --all origin' "$REPOS/feat")
report B0F-push-all deny "$(decision "$out")" "$out"
out=$(pre 'git commit -m x' "$REPOS/trunk")
report B0G-origin-head-deny deny "$(decision "$out")" "$out"
out=$(op pr-pre "$(jq -cn --arg d "$REPOS/feat" '{session_id:"opencode-p1",command:"git commit -m x",cwd:$d,prompt:"/pr"}')")
report B0H-prompt-pr-same none "$(decision "$out")" "プロンプトが /pr でも判定は変わらない"
out=$(op pr-request "$(jq -cn --arg d "$REPOS/feat" '{session_id:"opencode-p1",command:"git commit -m x",cwd:$d,prompt:"/pr"}')")
report B0I-prompt-pr-request-allow allow "$(decision "$out")" "プロンプトが /pr でも同じ"
r=absent
[ -e "$TMPDIR/claude-pr-mode-opencode-p1" ] && r=present
report B0J-no-flag absent "$r" "フラグは作らない"

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

echo "# E. completion-gate（adapter の正規化と TMPDIR 隔離）"
CS=opencode-cg-$$
dec() { if [ -z "$1" ]; then echo none; else printf '%s' "$1" | jq -r '.decision // (if .systemMessage then "message" else "none" end)'; fi; }
cstop() { op complete-stop "$(jq -cn --arg s "$1" --arg d "$REPO_DIR" '{session_id:$s,cwd:$d}')"; }
out=$(op complete-post "$(jq -cn --arg s "$CS" --arg f "$REPO_DIR/opencode/hooks/harness.sh" --arg d "$REPO_DIR" '{session_id:$s,tool_name:"Edit",file_path:$f,cwd:$d}')")
report E01-post-empty "" "$out" "記録だけ"
r=absent
[ -f "$TMPDIR/claude-completion-gate-$CS" ] && r=present
report E02-state-in-tmpdir present "$r" "状態は隔離した TMPDIR に置く"
out=$(cstop "$CS")
report E03-stop-block block "$(dec "$out")" "$out"
out=$(cstop "$CS")
report E04-stop-again-none none "$(dec "$out")" "block で edited を消費する"
CT=opencode-cg-tmp-$$
out=$(op complete-post "$(jq -cn --arg s "$CT" --arg f "$TMPDIR/scratch.txt" '{session_id:$s,tool_name:"Write",file_path:$f}')")
out=$(cstop "$CT")
report E05-tmp-edit-none none "$(dec "$out")" "一時領域の編集は数えない"
out=$(op complete-post "$(jq -cn --arg s "$CT" '{session_id:$s,tool_name:"Bash",command:"echo hi",cwd:"/tmp"}')")
out=$(cstop "$CT")
report E06-bash-none none "$(dec "$out")" "通常の Bash は数えない"
CP=opencode-cg-prompt-$$
for i in 1 2 3; do
  op complete-post "$(jq -cn --arg s "$CP" --arg f "$REPO_DIR/README.md" '{session_id:$s,tool_name:"Edit",file_path:$f}')" >/dev/null
  cstop "$CP" >/dev/null
done
op complete-post "$(jq -cn --arg s "$CP" --arg f "$REPO_DIR/README.md" '{session_id:$s,tool_name:"Edit",file_path:$f}')" >/dev/null
out=$(cstop "$CP")
report E07-cap-message message "$(dec "$out")" "同ターン 3 回で上限の systemMessage"
op complete-prompt "$(jq -cn --arg s "$CP" '{session_id:$s}')" >/dev/null
report E08-prompt-rc 0 "$?" ""
op complete-post "$(jq -cn --arg s "$CP" --arg f "$REPO_DIR/README.md" '{session_id:$s,tool_name:"Edit",file_path:$f}')" >/dev/null
out=$(cstop "$CP")
report E09-prompt-resets-blocks block "$(dec "$out")" "新しいターンで再び促せる"
printf '{"session_id":"../x"}' | bash "$ADAPTER" complete-stop >/dev/null 2>&1
report E10-bad-session 1 "$?" "session id を検証する"
printf '{"session_id":"opencode-cg"}' | bash "$ADAPTER" complete-post >/dev/null 2>&1
report E11-post-no-tool 1 "$?" "tool_name が無い入力は失敗"
printf '{' | bash "$ADAPTER" complete-prompt >/dev/null 2>&1
report E12-broken-json 1 "$?" "壊れた JSON は失敗"

echo "# D. 異常系（fail-closed）"
printf '{}' | env PATH=/nonexistent /bin/bash "$ADAPTER" guard >/dev/null 2>&1
report D01-no-tools 1 "$?" "jq / 共通スクリプトを解決できないときは成功扱いにしない"
printf '{' | bash "$ADAPTER" guard >/dev/null 2>&1
report D02-broken-json 1 "$?" "壊れた JSON は失敗"
printf '{}' | bash "$ADAPTER" unknown >/dev/null 2>&1
report D03-unknown-op 1 "$?" "未知の操作は失敗"
printf '{"session_id":"../x","command":"true"}' | bash "$ADAPTER" pr-pre >/dev/null 2>&1
report D04-bad-session 1 "$?" "session id を検証する"
out=$(op guard '{"session_id":"opencode-g1","command":"true","cwd":"/tmp"}')
report D05-no-decision none "$(decision "$out")" "通常コマンドは no-decision"

cleanup
summary "opencode-harness.sh"
