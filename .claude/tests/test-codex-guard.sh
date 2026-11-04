#!/bin/bash
# codex/hooks/guard.sh（Codex CLI の Git 操作ガード）のテーブル駆動テスト
# 実行: bash .claude/tests/test-codex-guard.sh（run.sh からも呼ばれる）
# 公式イベントの Bash 入力を使い、コマンド自体は実行せずフックの判定だけを検査する。
# 既定ブランチ保護方式のため、対象リポジトリは一時ディレクトリに作る。
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
HOOK="$(cd "$TESTS_DIR/../../codex/hooks" && pwd)/guard.sh"
S=test-codex-guard-$$

REPO_BASE=$(mktemp -d "${TMPDIR:-/tmp}/codex-guard-repos.XXXXXX") || exit 1
REPO_MAIN="$REPO_BASE/main"
REPO_MASTER="$REPO_BASE/master"
REPO_FEAT="$REPO_BASE/feat"
REPO_TRUNK="$REPO_BASE/trunk"

cleanup() { rm -rf "$REPO_BASE" "$T/codex-pr-mode-$S"; }
trap cleanup EXIT
cleanup
mkdir -p "$REPO_MAIN" "$REPO_MASTER" "$REPO_FEAT" "$REPO_TRUNK"

git_init() { # dir branch
  local dir="$1" branch="$2"
  git init -q -b "$branch" "$dir" 2>/dev/null || {
    git init -q "$dir"
    git -C "$dir" checkout -q -b "$branch"
  }
}
# 作業ツリーのリポジトリの git 状態を変えないよう、テスト用リポジトリだけを操作する
git_init "$REPO_MAIN" main
git_init "$REPO_MASTER" master
git_init "$REPO_FEAT" feat/x
git_init "$REPO_TRUNK" trunk
# origin/HEAD が main / master 以外を指すリポジトリ（保護ブランチは origin/HEAD に追従する）
git -C "$REPO_TRUNK" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk

pre() { # label expected cmd [cwd] [agent]
  local out
  out=$(jq -cn --arg s "$S" --arg d "${4-/tmp}" --arg c "$3" --arg a "${5-}" \
    '{hook_event_name:"PreToolUse",session_id:$s,cwd:$d,tool_name:"Bash",tool_input:{command:$c}}
     + (if $a != "" then {agent_id:$a} else {} end)' \
    | bash "$HOOK" 2>/dev/null)
  report "$1" "$2" "$(decision_of "$out")" "$3"
}
event() { # label expected event prompt
  local out
  out=$(jq -cn --arg s "$S" --arg e "$3" --arg p "${4-}" \
    '{hook_event_name:$e,session_id:$s,cwd:"/tmp",prompt:$p}' | bash "$HOOK" 2>/dev/null)
  report "$1" "$2" "$out" ""
}

HD_COMMIT=$'git commit -m "$(cat <<\'EOF\'\nfeat: x\n\n- a && b\n\nCo-Authored-By: Claude <noreply@anthropic.com>\nEOF\n)"'

echo "# A. 既定ブランチへの commit は常に deny（/pr の起動は不要）"
pre A01-commit-main deny 'git commit -m x' "$REPO_MAIN"
pre A02-commit-master deny 'git commit -m x' "$REPO_MASTER"
pre A03-commit-origin-head deny 'git commit -m x' "$REPO_TRUNK"
pre A04-commit-feat none 'git commit -m x' "$REPO_FEAT"
pre A05-commit-no-repo none 'git commit -m x' /tmp
pre A06-amend-feat deny 'git commit --amend --no-edit' "$REPO_FEAT"
pre A07-noverify-feat deny 'git commit --no-verify -m x' "$REPO_FEAT"
pre A08-n-feat deny 'git commit -n -m x' "$REPO_FEAT"
pre A09-quoted-amend-feat deny 'git commit -m x "--amend"' "$REPO_FEAT"
pre A10-heredoc-main deny "$HD_COMMIT" "$REPO_MAIN"
pre A11-heredoc-feat none "$HD_COMMIT" "$REPO_FEAT"
# 長いオプションを短いフラグの文字判定（f / d）に掛けない
pre A12-push-follow-tags none 'git push --follow-tags origin feat/x' "$REPO_FEAT"
pre A13-push-signed none 'git push --signed origin feat/x' "$REPO_FEAT"
pre A14-push-dry-run none 'git push --dry-run origin feat/x' "$REPO_FEAT"
pre A15-push-recurse-submodules none 'git push --recurse-submodules=on-demand origin feat/x' "$REPO_FEAT"
# git commit の -m の値・commit 区間の外の -n を deny にしない
pre A16-commit-message-dash none 'git commit -m "- add x"' "$REPO_FEAT"
pre A17-commit-two-messages-dash none 'git commit -m "title" -m "- item"' "$REPO_FEAT"
pre A18-grep-n-commit none 'grep -n foo x && git commit -m x' "$REPO_FEAT"
# push 区間の外の引用トークン（PR の --base "main"）を push の宛先と誤認しない
pre A19-push-then-pr-base none 'git push -u origin feat/x && gh pr create --base "main" --title "x"' "$REPO_FEAT"

echo "# B. 対象リポジトリの解決（git -C / cd && / cd ; / 相対 / フォールバック）"
pre B01-gitc-main deny "git -C $REPO_MAIN commit -m x" /tmp
pre B02-gitc-feat none "git -C $REPO_FEAT commit -m x" /tmp
pre B03-gitc-with-option-main deny "git -c core.quotePath=false -C $REPO_MAIN commit -m x" /tmp
pre B04-cd-and-main deny "cd $REPO_MAIN && git commit -m x" /tmp
pre B05-cd-and-feat none "cd $REPO_FEAT && git commit -m x" /tmp
pre B06-cd-semicolon-main deny "cd $REPO_MAIN; git commit -m x" /tmp
pre B07-cd-relative-main deny "cd main && git commit -m x" "$REPO_BASE"
pre B08-cd-var-fallback deny 'cd "$VAR" && git commit -m x' "$REPO_MAIN"
pre B09-gitc-var-fallback deny 'git -C "$VAR" commit -m x' "$REPO_MAIN"
pre B10-gitc-var-feat none 'git -C "$VAR" commit -m x' "$REPO_FEAT"
pre B11-status-then-gitc deny "git -C $REPO_MAIN status; git -C $REPO_MAIN commit -m x" /tmp
pre B12-cd-overrides none "cd $REPO_FEAT && git commit -m x" "$REPO_MAIN"
pre B13-commit-paren-main deny "(cd $REPO_MAIN && git commit -m x)" /tmp
pre B14-commit-paren-feat none "(cd $REPO_FEAT && git commit -m x)" /tmp
pre B15-commit-paren-relative-main deny "(cd main && git commit -m x)" "$REPO_BASE"

echo "# C. push の宛先判定"
pre C01-push-feat none 'git push -u origin feat/x' "$REPO_FEAT"
pre C02-push-HEAD-feat none 'git push origin HEAD' "$REPO_FEAT"
pre C03-push-explicit-refs none 'git push origin HEAD:refs/heads/feat/x' "$REPO_FEAT"
pre C04-push-similar-name none 'git push origin feat/main' "$REPO_FEAT"
pre C05-push-none-main deny 'git push' "$REPO_MAIN"
pre C06-push-origin-main deny 'git push origin' "$REPO_MAIN"
pre C07-push-u-origin-main deny 'git push -u origin' "$REPO_MAIN"
pre C08-push-HEAD-main deny 'git push origin HEAD' "$REPO_MAIN"
pre C09-push-main-from-feat deny 'git push origin main' "$REPO_FEAT"
pre C10-push-HEAD-colon-main deny 'git push origin HEAD:main' "$REPO_FEAT"
pre C11-push-feat-colon-master deny 'git push origin feat:master' "$REPO_FEAT"
pre C12-push-refs-heads-main deny 'git push origin HEAD:refs/heads/main' "$REPO_FEAT"
pre C13-push-plus-main deny 'git push origin +main' "$REPO_FEAT"
pre C14-push-quoted-main deny 'git push origin "main"' "$REPO_FEAT"
pre C15-push-trunk deny 'git push origin HEAD:trunk' "$REPO_TRUNK"
pre C16-push-all deny 'git push --all origin' "$REPO_FEAT"
pre C17-push-mirror deny 'git push --mirror origin' "$REPO_FEAT"
pre C18-push-delete deny 'git push --delete origin feat/x' "$REPO_FEAT"
pre C19-push-d deny 'git push -d origin feat/x' "$REPO_FEAT"
pre C20-push-colon-branch deny 'git push origin :feat/x' "$REPO_FEAT"
pre C21-push-noverify deny 'git push --no-verify -u origin feat/x' "$REPO_FEAT"
pre C22-force-long deny 'git push --force origin feat' "$REPO_FEAT"
pre C23-force-lease deny 'git push --force-with-lease=feat origin feat' "$REPO_FEAT"
pre C24-force-short deny 'git push -f origin feat' "$REPO_FEAT"
pre C25-force-combined deny 'git push -fu origin feat' "$REPO_FEAT"
pre C26-vars-quoted deny 'git push origin "$BRANCH"' "$REPO_FEAT"
pre C27-vars-unquoted deny 'git push -u origin $BRANCH' "$REPO_FEAT"
pre C28-wildcard deny "git push origin 'refs/heads/*:refs/heads/*'" "$REPO_FEAT"
pre C29-gitc-main deny "git -C $REPO_MAIN push" /tmp
pre C30-cd-main deny "cd $REPO_MAIN && git push origin" /tmp
pre C31-push-follow-tags-main deny 'git push --follow-tags' "$REPO_MAIN"
pre C32-push-prune deny 'git push --prune origin feat/x' "$REPO_FEAT"
out=$(jq -cn --arg s "$S" --arg d "$REPO_FEAT" '{hook_event_name:"PreToolUse",session_id:$s,cwd:$d,tool_name:"Bash",tool_input:{command:"git push --prune origin feat/x"}}' | bash "$HOOK" 2>/dev/null)
reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')
case "$reason" in *'削除'*) v=ok ;; *) v="理由文が削除扱いでない: $reason" ;; esac
report C33-push-prune-reason ok "$v" "$reason"

echo "# D. PR の作成・更新は何も返さない（Codex の承認ポリシーに任せる）"
pre D01-create none 'gh pr create --fill'
pre D02-new none 'gh pr new --fill'
pre D03-edit none 'gh pr edit 12 --title t'
pre D04-api-create none 'gh api -X POST repos/o/r/pulls -f title=t'
pre D05-api-edit none 'gh api repos/o/r/pulls/12 -X PATCH -f title=x'
pre D06-graphql-create none 'gh api graphql -f query="mutation { createPullRequest(input: {}) { pullRequest { url } } }"'
pre D07-heredoc-body none $'gh pr create --title "t" --body "$(cat <<\'EOF\'\n## 概要\n- a && b || c\nEOF\n)"'

echo "# E. PR のマージは deny（Codex は ask を返せない）"
pre E01-pr-merge deny 'gh pr merge 12 --squash'
pre E02-api-put deny 'gh api -X PUT repos/o/r/pulls/12/merge'
pre E03-api-method-put deny 'gh api --method PUT repos/o/r/pulls/12/merge'
pre E04-api-field-merge deny 'gh api -f commit_message=x repos/o/r/pulls/12/merge'
pre E05-graphql-merge deny 'gh api graphql -f query="mutation { mergePullRequest(input:{}) { clientMutationId } }"'
pre E06-api-merge-get none 'gh api repos/o/r/pulls/12/merge -X GET'
pre E07-api-similar-none none 'gh api repos/o/r/pulls/12'
out=$(jq -cn --arg s "$S" '{hook_event_name:"PreToolUse",session_id:$s,cwd:"/tmp",tool_name:"Bash",tool_input:{command:"gh pr merge 1"}}' | bash "$HOOK" 2>/dev/null)
reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')
case "$reason" in *'ユーザー自身が実行するか Claude Code'*) v=yes ;; *) v=no ;; esac
report E08-merge-guidance yes "$v" "$reason"

echo "# F. 常時拒否（従来どおり）"
pre F01-sudo deny 'sudo apt-get install -y x'
pre F02-git-read none 'git status'
pre F03-pr-view none 'gh pr view 12'
pre F04-other-command none 'npm test'
pre F05-literal none "printf 'git commit -m x\\n'"
pre F06-subagent-commit deny 'git commit -m x' "$REPO_FEAT" child
pre F07-subagent-push-protected deny 'git push origin main' "$REPO_FEAT" child
pre F08-subagent-pr-create deny 'gh pr create --fill' /tmp child
pre F09-subagent-read none 'git status' "$REPO_FEAT" child
pre F10-agent-read-merge deny 'gh pr merge 1' /tmp child

echo "# G. /pr フラグは作られず、プロンプトに左右されない"
event G01-prompt-no-flag '' UserPromptSubmit '$pr'
[ -e "$T/codex-pr-mode-$S" ] && r=present || r=absent
report G02-no-flag-file absent "$r" ""
event G03-stop-no-output '' Stop ''
event G04-session-end-no-output '' SessionEnd ''
pre G05-commit-feat-after-pr-prompt none 'git commit -m x' "$REPO_FEAT"
pre G06-commit-main-after-pr-prompt deny 'git commit -m x' "$REPO_MAIN"

echo "# H. 異常入力（何も出さず exit 0）"
out=$(printf 'not json' | bash "$HOOK" 2>/dev/null); rc=$?
report H01-garbage "0:" "$rc:$out" ""
out=$(printf '' | bash "$HOOK" 2>/dev/null); rc=$?
report H02-empty "0:" "$rc:$out" ""
out=$(jq -cn --arg s "$S" '{hook_event_name:"PreToolUse",session_id:$s,cwd:"/tmp",tool_name:"shell",tool_input:{command:["bash","-lc","printf \"git commit\"\n"]}}' | bash "$HOOK" 2>/dev/null)
report H03-legacy-array none "$(decision_of "$out")" "$out"
out=$(jq -cn --arg s "$S" --arg d "$REPO_MAIN" '{hook_event_name:"PreToolUse",session_id:$s,cwd:$d,tool_name:"apply_patch",tool_input:{command:"git commit -m x"}}' | bash "$HOOK" 2>/dev/null)
report H04-other-tool deny "$(decision_of "$out")" "判定本体はツール名に依存しない（hooks.json は Bash に登録）"

echo "# I. codex/hooks.json の登録（PreToolUse のみ・フラグ用イベントは無し）"
HOOKS_JSON="$TESTS_DIR/../../codex/hooks.json"
report I01-bash-registration Bash "$(jq -r '.hooks.PreToolUse[] | select(any(.hooks[]; .command | contains("guard.sh"))) | .matcher' "$HOOKS_JSON")" ""
report I02-no-prompt-submit 0 "$(jq -r '[.hooks.UserPromptSubmit[]?.hooks[].command | select(contains("guard.sh"))] | length' "$HOOKS_JSON")" ""
report I03-no-session-end 0 "$(jq -r '[.hooks.SessionEnd[]?.hooks[].command | select(contains("guard.sh"))] | length' "$HOOKS_JSON")" ""
report I04-no-guard-on-stop 0 "$(jq -r '[.hooks.Stop[]?.hooks[].command | select(contains("guard.sh"))] | length' "$HOOKS_JSON")" ""
report I05-harness-on-stop 1 "$(jq -r '[.hooks.Stop[]?.hooks[].command | select(contains("harness.sh"))] | length' "$HOOKS_JSON")" ""

summary "codex-guard.sh"
