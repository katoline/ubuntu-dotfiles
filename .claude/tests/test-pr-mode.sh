#!/bin/bash
# hooks/pr-mode.sh のテーブル駆動テスト（既定ブランチ保護方式）
# 実行: bash .claude/tests/test-pr-mode.sh（run.sh からも呼ばれる）
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
HOOK="$HOOKS_DIR/pr-mode.sh"
S=test-prmode-$$
# フックは異常時に $HOME/.claude/pr-mode.log へ書く。本物のログを汚さないよう、
# テスト中だけ HOME を一時ディレクトリに向ける（run.sh がテスト前後の行数で検査する）
export HOME="$T/claude-prmode-home.$$"
mkdir -p "$HOME/.claude"

REPO_BASE="$T/claude-prmode-repos.$$"
REPO_MAIN="$REPO_BASE/main"
REPO_MASTER="$REPO_BASE/master"
REPO_FEAT="$REPO_BASE/feat"
REPO_TRUNK="$REPO_BASE/trunk"
REPO_SEC="$REPO_BASE/secret"
STUB_BIN="$T/claude-prmode-bin.$$"
cleanup() {
  rm -rf "$REPO_BASE" "$T/claude-prmode-libless.$$" "$STUB_BIN" "$HOME"
}
trap cleanup EXIT
cleanup
mkdir -p "$HOME/.claude"

# gh pr merge の base 判定は gh をスタブにして検査する（ネットワーク・認証に依存させない）
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'STUB'
#!/bin/bash
if [ -n "${GH_STUB_ARGS_CHECK:-}" ]; then
  for a in "$@"; do
    case "$a" in
      main | --author-email | --subject=main) printf 'main\n'; exit 0 ;;
    esac
  done
  printf 'feat/x\n'
  exit 0
fi
if [ -n "${GH_STUB_BASE_MAP:-}" ]; then
  for a in "$@"; do
    case "$a" in
      1 | 3) printf 'feat/x\n'; exit 0 ;;
      2) printf 'main\n'; exit 0 ;;
    esac
  done
fi
[ -n "${GH_STUB_BASE:-}" ] || exit 1
printf '%s\n' "$GH_STUB_BASE"
STUB
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH"
unset GH_STUB_BASE

git_init() { # dir branch
  local dir="$1" branch="$2"
  mkdir -p "$dir"
  git init -q -b "$branch" "$dir" 2>/dev/null || {
    git init -q "$dir"
    git -C "$dir" checkout -q -b "$branch"
  }
}
git_commit() { # dir message
  git -C "$1" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q -m "$2"
}

git_init "$REPO_MAIN" main
git_init "$REPO_MASTER" master
git_init "$REPO_FEAT" feat/x
git_init "$REPO_TRUNK" trunk
git_init "$REPO_SEC" feat/secret
# origin/HEAD が main / master 以外を指すリポジトリ（保護ブランチは origin/HEAD に追従する）
git -C "$REPO_TRUNK" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk

pre() { report "$1" "$2" "$(decision_of "$(run_hook "$HOOK" PreToolUse "$S" "$3" "" "" "${4-/tmp}")")" "$3"; }
perm() { report "$1" "$2" "$(decision_of "$(run_hook "$HOOK" PermissionRequest "$S" "$3" "" "" "${4-/tmp}")")" "$3"; }
# PermissionRequest の任意ツール（Bash 以外）を検査する
perm_json() { report "$1" "$2" "$(decision_of "$(printf '%s' "$3" | bash "$HOOK" 2>/dev/null)")" "$3"; }

HD_BODY=$'gh pr create --title "t" --body "$(cat <<\'EOF\'\n## 概要\n- a && b || c; d | e\n- --force と -f を含む本文\n- it\'s a "quote"\nEOF\n)" --base main'
HD_COMMIT=$'git commit -m "$(cat <<\'EOF\'\nfeat: x\n\n- a && b\n\nCo-Authored-By: Claude <noreply@anthropic.com>\nEOF\n)"'
HD_DASH=$'git commit -F - <<-EOF\n\tmsg && x\n\tEOF'
HD_TRAIL=$'git commit -m "$(cat <<\'EOF\'\nmsg\nEOF\n)" && rm -rf ~/x'

echo "# A. 保護ブランチ以外の自動許可（PermissionRequest allow）"
perm A01-commit-feat allow 'git commit -m "fix: x"' "$REPO_FEAT"
perm A02-push-feat allow 'git push -u origin feat/x' "$REPO_FEAT"
perm A03-push-explicit-ref allow 'git push origin HEAD:refs/heads/feat/x' "$REPO_MAIN"
perm A04-push-similar-name allow 'git push origin feat/main-fix' "$REPO_MAIN"
perm A05-push-named-branch allow 'git push origin feat' "$REPO_MAIN"
perm A06-pr-create allow 'gh pr create --fill'
perm A07-pr-edit allow 'gh pr edit 12 --title "t" --body "b"'
perm A08-pr-new allow 'gh pr new --fill'
perm A09-api-create allow 'gh api -X POST repos/o/r/pulls -f title=t'
perm A10-api-edit allow 'gh api repos/o/r/pulls/12 -X PATCH -f title=x'
perm A11-api-graphql-create allow 'gh api graphql -f query="mutation { createPullRequest(input: {}) { pullRequest { url } } }"'
perm A12-heredoc-pr allow "$HD_BODY"
perm A13-heredoc-commit allow "$HD_COMMIT" "$REPO_FEAT"
perm A14-dash-heredoc allow "$HD_DASH" "$REPO_FEAT"
perm A15-quoted-operators allow 'git commit -m "a && b; c | d > e"' "$REPO_FEAT"
perm A16-base-main allow 'gh pr create --base "main" --title "t" --body "b"'
perm A17-set-upstream allow 'git push --set-upstream origin feat/x' "$REPO_FEAT"
perm A18-commit-am allow 'git commit -am "x"' "$REPO_FEAT"
perm A19-literal-heredoc-doc allow 'git commit -m "see <<EOF in docs"' "$REPO_FEAT"
perm A20-redirect-2>&1 allow 'git push -u origin feat/x 2>&1' "$REPO_FEAT"
# 長いオプションを短いフラグの文字判定（f / d）に掛けない
perm A21-push-follow-tags allow 'git push --follow-tags origin feat/x' "$REPO_FEAT"
perm A22-push-signed allow 'git push --signed origin feat/x' "$REPO_FEAT"
perm A23-push-dry-run allow 'git push --dry-run origin feat/x' "$REPO_FEAT"
perm A24-push-recurse-submodules allow 'git push --recurse-submodules=on-demand origin feat/x' "$REPO_FEAT"
# git commit の -m の値はオプションとして見ない
perm A25-commit-message-dash allow 'git commit -m "- add x"' "$REPO_FEAT"
perm A26-commit-two-messages-dash allow 'git commit -m "title" -m "- item"' "$REPO_FEAT"

echo "# B. PermissionRequest はマージ以外を allow（deny 条件だけ拒否）"
perm B01-force deny 'git push --force origin feat' "$REPO_FEAT"
perm B02-push-main deny 'git push -u origin main' "$REPO_MAIN"
perm B03-delete deny 'git push --delete origin feat/x' "$REPO_FEAT"
perm B04-all deny 'git push --all origin' "$REPO_FEAT"
perm B05-merge-unknown none 'gh pr merge 1'
perm B06-api-merge none 'gh api -X PUT repos/o/r/pulls/12/merge'
perm B07-amend allow 'git commit --amend --no-edit' "$REPO_FEAT"
perm B08-noverify deny 'git commit --no-verify -m x' "$REPO_FEAT"
perm B09-vars deny 'git push origin "$BRANCH"' "$REPO_FEAT"
perm B10-compound allow 'git commit -m "a" && rm -rf ~/x' "$REPO_FEAT"
perm B11-redirect allow 'git commit -m "x" > ~/.zshrc' "$REPO_FEAT"
perm B12-quoted-option allow 'git commit -m x "--amend"' "$REPO_FEAT"
perm B13-repo-option allow 'gh pr create -R other/repo --fill'
perm B14-api-get allow 'gh api repos/o/r/pulls/12'
perm B15-push-HEAD-main deny 'git push origin HEAD:main' "$REPO_MAIN"
perm B16-push-prune deny 'git push --prune origin feat/x' "$REPO_FEAT"
perm B17-push-force-if-includes deny 'git push --force-if-includes origin feat/x' "$REPO_FEAT"
# push 区間の外の引用トークン（PR の --base "main"）を既定ブランチ宛と誤認して deny しない
perm B18-push-then-pr-base allow 'git push -u origin feat/x && gh pr create --base "main" --title "x"' "$REPO_FEAT"
# gh pr merge の base 判定（main / feature / 取得失敗）
export GH_STUB_BASE=main; perm B19-merge-base-main none 'gh pr merge 1' "$REPO_FEAT"
export GH_STUB_BASE=feat/x; perm B1A-merge-base-feature allow 'gh pr merge 1' "$REPO_FEAT"
unset GH_STUB_BASE
perm B1B-merge-base-fail none 'gh pr merge 1' "$REPO_FEAT"
export GH_STUB_BASE=main; perm B1C-merge-repo-arg none 'gh pr merge 1 -R owner/repo --squash' "$REPO_FEAT"
unset GH_STUB_BASE
perm B1D-commit-n deny 'git commit -n -m x' "$REPO_FEAT"
perm B1E-commit-mn-value allow 'git commit -mn "x"' "$REPO_FEAT"

echo "# C. 既定ブランチへの commit / push は常に deny（PreToolUse）"
pre C01-commit-main deny 'git commit -m x' "$REPO_MAIN"
pre C02-commit-master deny 'git commit -m x' "$REPO_MASTER"
pre C03-commit-origin-head deny 'git commit -m x' "$REPO_TRUNK"
pre C04-push-none-main deny 'git push' "$REPO_MAIN"
pre C05-push-origin-main deny 'git push origin' "$REPO_MAIN"
pre C06-push-u-origin-main deny 'git push -u origin' "$REPO_MAIN"
pre C07-push-HEAD-main deny 'git push origin HEAD' "$REPO_MAIN"
pre C08-push-main deny 'git push origin main' "$REPO_MAIN"
pre C09-push-HEAD-colon-main deny 'git push origin HEAD:main' "$REPO_MAIN"
pre C10-push-feat-colon-master deny 'git push origin feat:master' "$REPO_MAIN"
pre C11-push-refs-heads-main deny 'git push origin HEAD:refs/heads/main' "$REPO_MAIN"
pre C12-push-refs-heads-master deny 'git push origin feat:refs/heads/master' "$REPO_MAIN"
pre C13-push-plus-main deny 'git push origin +main' "$REPO_MAIN"
pre C14-push-quoted-main deny 'git push origin "main"' "$REPO_MAIN"
pre C15-push-single-quoted-main deny "git push origin 'master'" "$REPO_MAIN"
pre C16-push-all deny 'git push --all origin' "$REPO_FEAT"
pre C17-push-mirror deny 'git push --mirror origin' "$REPO_FEAT"
pre C18-push-delete deny 'git push --delete origin feat/x' "$REPO_FEAT"
pre C19-push-d deny 'git push -d origin feat/x' "$REPO_FEAT"
pre C20-push-colon-branch deny 'git push origin :feat/x' "$REPO_FEAT"
pre C21-push-noverify deny 'git push --no-verify -u origin feat/x' "$REPO_FEAT"
pre C22-force deny 'git push --force origin feat' "$REPO_FEAT"
pre C23-force-with-lease deny 'git push --force-with-lease=feat origin feat' "$REPO_FEAT"
pre C24-force-short deny 'git push -f origin feat' "$REPO_FEAT"
pre C25-force-combined deny 'git push -fu origin feat' "$REPO_FEAT"
pre C26-push-trunk deny 'git push origin HEAD:trunk' "$REPO_TRUNK"
pre C27-push-follow-tags-main deny 'git push --follow-tags' "$REPO_MAIN"
pre C28-push-prune deny 'git push --prune origin feat/x' "$REPO_FEAT"
out=$(run_hook "$HOOK" PreToolUse "$S" 'git push --prune origin feat/x' "" "" "$REPO_FEAT")
r=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')
case "$r" in *'削除'*) v=ok ;; *) v="理由文が削除扱いでない: $r" ;; esac
report C29-push-prune-reason ok "$v" "$r"

echo "# D. 対象リポジトリの解決（git -C / cd && / フォールバック）"
pre D01-commit-gitc-main deny "git -C $REPO_MAIN commit -m x" /tmp
pre D02-commit-gitc-feat none "git -C $REPO_FEAT commit -m x" /tmp
pre D03-commit-cd-main deny "cd $REPO_MAIN && git commit -m x" /tmp
pre D04-commit-cd-feat none "cd $REPO_FEAT && git commit -m x" /tmp
pre D05-commit-cd-relative deny "cd main && git commit -m x" "$REPO_BASE"
pre D06-commit-cd-semicolon deny "cd $REPO_MAIN; git commit -m x" /tmp
pre D07-push-gitc-main deny "git -C $REPO_MAIN push" /tmp
pre D08-push-cd-main deny "cd $REPO_MAIN && git push origin" /tmp
pre D09-commit-cd-var-fallback deny 'cd "$VAR" && git commit -m x' "$REPO_MAIN"
pre D10-commit-gitc-var-fallback deny 'git -C "$VAR" commit -m x' "$REPO_MAIN"
pre D11-commit-gitc-var-feat none 'git -C "$VAR" commit -m x' "$REPO_FEAT"
pre D12-commit-after-status deny "git -C $REPO_MAIN status; git -C $REPO_MAIN commit -m x" /tmp
pre D13-commit-status-then-cwd deny "git -C $REPO_FEAT status; git commit -m x" "$REPO_MAIN"
pre D14-commit-cd-overrides none "cd $REPO_FEAT && git commit -m x" "$REPO_MAIN"
pre D15-push-explicit-main none 'git push origin feat' "$REPO_MAIN"
pre D16-push-HEAD-feat none 'git push origin HEAD' "$REPO_FEAT"
pre D17-push-similar-name none 'git push origin feat/main' "$REPO_FEAT"
pre D18-commit-paren-main deny "(cd $REPO_MAIN && git commit -m x)" /tmp
pre D19-commit-paren-feat none "(cd $REPO_FEAT && git commit -m x)" /tmp
pre D20-commit-paren-relative-main deny "(cd main && git commit -m x)" "$REPO_BASE"

echo "# E. サブエージェントからの git 書き込みは deny"
out=$(jq -cn --arg s "$S" --arg d "$REPO_FEAT" '{hook_event_name:"PreToolUse",session_id:$s,cwd:$d,agent_id:"agent-1",tool_name:"Bash",tool_input:{command:"git commit -m x"}}' | bash "$HOOK" 2>/dev/null)
report E01-subagent-commit deny "$(decision_of "$out")" "$out"
out=$(jq -cn --arg s "$S" --arg d "$REPO_MAIN" '{hook_event_name:"PreToolUse",session_id:$s,cwd:$d,agent_id:"agent-1",tool_name:"Bash",tool_input:{command:"git push origin main"}}' | bash "$HOOK" 2>/dev/null)
report E02-subagent-push-deny deny "$(decision_of "$out")" "$out"
out=$(jq -cn --arg s "$S" --arg d "$REPO_FEAT" '{hook_event_name:"PreToolUse",session_id:$s,cwd:$d,agent_id:"agent-1",tool_name:"Bash",tool_input:{command:"git status"}}' | bash "$HOOK" 2>/dev/null)
report E03-subagent-readonly none "$(decision_of "$out")" "$out"

echo "# F. PreToolUse は deny / ask（確認が必要なマージ）/ 無出力"
pre F01-merge-unknown ask 'gh pr merge 1'
pre F02-api-merge-put ask 'gh api -X PUT repos/o/r/pulls/12/merge'
pre F03-api-merge-method ask 'gh api --method PUT repos/o/r/pulls/12/merge'
pre F04-graphql-merge ask 'gh api graphql -f query="mutation { mergePullRequest(input:{}) { clientMutationId } }"'
pre F05-amend none 'git commit --amend --no-edit' "$REPO_FEAT"
pre F06-noverify deny 'git commit --no-verify -m x' "$REPO_FEAT"
pre F07-n deny 'git commit -n -m x' "$REPO_FEAT"
pre F08-quoted-amend none 'git commit -m x "--amend"' "$REPO_FEAT"
pre F09-vars deny 'git push origin "$BRANCH"' "$REPO_FEAT"
pre F10-vars-unquoted deny 'git push -u origin $BRANCH' "$REPO_FEAT"
pre F11-wildcard deny "git push origin 'refs/heads/*:refs/heads/*'" "$REPO_FEAT"
# gh pr merge の base 判定（PreToolUse は確認が必要なときだけ ask）
export GH_STUB_BASE=feat/x; pre F12-merge-base-feature none 'gh pr merge 1 --squash' "$REPO_FEAT"
export GH_STUB_BASE=main; pre F13-merge-base-main ask 'gh pr merge 1 --squash' "$REPO_FEAT"
unset GH_STUB_BASE
export GH_STUB_BASE_MAP=1
pre F14-merge-multi-feature-main ask 'gh pr merge 1 --squash && gh pr merge 2 --squash' "$REPO_FEAT"
pre F15-merge-multi-feature-feature none 'gh pr merge 1 --squash; gh pr merge 3 --squash' "$REPO_FEAT"
pre F16-merge-newline ask $'gh pr merge 1 --squash\ngh pr merge 2 --squash' "$REPO_FEAT"
unset GH_STUB_BASE_MAP
# -n は --no-verify の短縮形。値を取る短いオプションの後ろは値として見ない
pre F17-commit-n-combined deny 'git commit -an -m x' "$REPO_FEAT"
pre F18-commit-nm deny 'git commit -nm "msg"' "$REPO_FEAT"
pre F19-commit-mn-value none 'git commit -mn "x"' "$REPO_FEAT"
pre F20-commit-m-value-n none 'git commit -m n' "$REPO_FEAT"
# 引用符の中の複数行（"- " で始まる行を含む）は -m の値として扱い、オプション判定しない
ML_MSG=$'git commit -m "Fix hooks\n\n- add new tests\n- n"'
pre F21-multiline-message none "$ML_MSG" "$REPO_FEAT"
perm B1F-multiline-message allow "$ML_MSG" "$REPO_FEAT"
# --author-email の値は gh pr view に渡さない。--subject=… も - 付きで落ちる
export GH_STUB_ARGS_CHECK=1
pre F22-merge-author-email none 'gh pr merge 1 --author-email main --squash' "$REPO_FEAT"
pre F23-merge-subject-equals none 'gh pr merge 1 --subject=main --squash' "$REPO_FEAT"
unset GH_STUB_ARGS_CHECK

echo "# G. 保護ブランチ以外は PreToolUse では何も出さない（PermissionRequest に委ねる）"
pre G01-commit-feat none 'git commit -m x' "$REPO_FEAT"
pre G02-push-feat none 'git push -u origin feat/x' "$REPO_FEAT"
pre G03-push-explicit-ref none 'git push origin HEAD:refs/heads/feat/x' "$REPO_MAIN"
pre G04-pr-create none 'gh pr create --fill'
pre G05-api-create none 'gh api -X POST repos/o/r/pulls -f title=t'
pre G06-status none 'git status'
pre G07-log-grep none 'git log --grep "git commit" --oneline'
pre G08-echo none 'echo "git commit"'
pre G09-commit-tree none 'git commit-tree HEAD^{tree} -m x'
pre G10-pushx none 'git pushx'
pre G11-pr-view none 'gh pr view 12'
pre G12-cat-heredoc none $'cat > deploy.sh <<\'EOF\'\ngit push origin main\nEOF'
pre G13-quoted-message none 'git commit -m "docs: --amend and --force"'
pre G14-heredoc-trailing none "$HD_TRAIL" "$REPO_FEAT"
# git commit の -m の値・commit 区間の外の -n を ask にしない
pre G15-commit-message-dash none 'git commit -m "- add x"' "$REPO_FEAT"
pre G16-commit-two-messages-dash none 'git commit -m "title" -m "- item"' "$REPO_FEAT"
pre G17-grep-n-commit none 'grep -n foo x && git commit -m x' "$REPO_FEAT"
# push 区間の外の引用トークン（PR の --base "main"）を push の宛先と誤認しない
pre G18-push-then-pr-base none 'git push -u origin feat/x && gh pr create --base "main" --title "x"' "$REPO_FEAT"

echo "# H. gh api の /pulls 書き込み（マージ以外）は PermissionRequest が allow、読み取りも allow"
pre H01-braces none '{ gh api repos/o/r/pulls -f title=x; }'
perm H02-braces allow '{ gh api repos/o/r/pulls -f title=x; }'
pre H03-xargs none 'echo x | xargs gh api repos/o/r/pulls -f title=x'
perm H04-xargs allow 'echo x | xargs gh api repos/o/r/pulls -f title=x'
perm H05-timeout allow 'timeout 60 gh api repos/o/r/pulls -f title=x'
perm H06-get allow 'gh api repos/o/r/pulls -X GET -f state=open'
perm H07-merge-get allow 'gh api repos/o/r/pulls/12/merge -X GET'
pre H08-merge-get none 'gh api repos/o/r/pulls/12/merge -X GET'

echo "# I. 秘密情報・- a の検査（自動承認しない）"
printf 'token = "%s"\n' "ghp_$(printf 'A%.0s' $(seq 36))" > "$REPO_SEC/leak.txt"
printf 'ok\n' > "$REPO_SEC/clean.txt"
git -C "$REPO_SEC" add clean.txt 2>/dev/null
pre I01-clean none 'git commit -m "add"' "$REPO_SEC"
git -C "$REPO_SEC" add leak.txt 2>/dev/null
pre I02-secret-deny deny 'git commit -m "add"' "$REPO_SEC"
perm I03-secret-no-allow allow 'git commit -m "add"' "$REPO_SEC"
out=$(run_hook "$HOOK" PreToolUse "$S" 'git commit -m "add"' "" "" "$REPO_SEC")
r=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')
case "$r" in *'leak.txt（GitHub トークン）'*) v=ok ;; *) v="理由文が一致しない: $r" ;; esac
report I04-secret-reason ok "$v" "$r"
printf 'key = "%s"\n' "sk-ant-$(printf 'B%.0s' $(seq 24))" > "$REPO_SEC/leak2.txt"
git -C "$REPO_SEC" add leak2.txt 2>/dev/null
out=$(run_hook "$HOOK" PreToolUse "$S" 'git commit -m "add"' "" "" "$REPO_SEC")
r=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')
case "$r" in *'leak.txt（GitHub トークン）、leak2.txt（Anthropic API キー）'*) v=ok ;; *) v="連結が壊れている: $r" ;; esac
report I05-secret-reason-joined ok "$v" "$r"
# -a 付きコミットは未ステージの変更（git diff HEAD）も検査する
printf 'npm_%s\n' "$(printf 'C%.0s' $(seq 36))" > "$REPO_SEC/unstaged.txt"
git -C "$REPO_SEC" add unstaged.txt 2>/dev/null
git_commit "$REPO_SEC" init
printf 'npm_%s\n' "$(printf 'D%.0s' $(seq 36))" >> "$REPO_SEC/unstaged.txt"
pre I06-secret-commit-a deny 'git commit -am "x"' "$REPO_SEC"
pre I07-unstaged-not-checked none 'git commit -m "x"' "$REPO_SEC"

echo "# J. 壊れた入力・ログ・フラグを作らない"
out=$(printf 'not json' | bash "$HOOK" 2>/dev/null); rc=$?
report J01-garbage "0:" "$rc:$out" ""
out=$(printf '' | bash "$HOOK" 2>/dev/null); rc=$?
report J02-empty "0:" "$rc:$out" ""
out=$(printf '{"hook_event_name":"PreToolUse","session_id":"test-prmode-x","tool_name":"Edit","tool_input":{"file_path":"git commit"}}' | bash "$HOOK" 2>/dev/null)
report J03-other-tool none "$(decision_of "$out")" ""
# session_id が無くてもコマンドと cwd だけで判定する
out=$(printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"git commit -m x"}}' "$REPO_MAIN" | bash "$HOOK" 2>/dev/null)
report J04-no-session-protected deny "$(decision_of "$out")" "$out"
out=$(printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"git commit -m x"}}' "$REPO_FEAT" | bash "$HOOK" 2>/dev/null)
report J05-no-session-feat none "$(decision_of "$out")" "$out"
out=$(printf '{"hook_event_name":"PermissionRequest","cwd":"%s","tool_name":"Bash","tool_input":{"command":"git commit -m x"}}' "$REPO_FEAT" | bash "$HOOK" 2>/dev/null)
report J06-no-session-perm-allow allow "$(decision_of "$out")" "$out"
# /pr のフラグはもう作らない（どのイベントでも claude-pr-mode-* を残さない）
for ev in UserPromptExpansion UserPromptSubmit PreToolUse PermissionRequest Stop; do
  jq -cn --arg e "$ev" --arg s "$S" '{hook_event_name:$e, session_id:$s, tool_name:"Bash", command_name:"pr", prompt:"/pr", tool_input:{command:"git commit -m x"}}' \
    | bash "$HOOK" >/dev/null 2>&1
done
r=absent
[ -e "$T/claude-pr-mode-$S" ] && r=present
report J07-no-flag absent "$r" ""
# 異常時のログは（隔離した）$HOME/.claude/pr-mode.log に書かれる
[ -f "$HOME/.claude/pr-mode.log" ] && r=present || r=absent
report J08-log-in-isolated-home present "$r" "$HOME/.claude/pr-mode.log"
grep -qF '入力 JSON を解釈できません' "$HOME/.claude/pr-mode.log" 2>/dev/null && r=ok || r="文言が一致しない"
report J09-log-message-ok ok "$r" ""

echo "# K. strip に失敗したとき（awk が無い）は生文字列で判定する（fail-open にしない）"
LIBLESS="$T/claude-prmode-libless.$$"; mkdir -p "$LIBLESS/lib"
cp "$HOOK" "$LIBLESS/pr-mode.sh"; cp "$HOOKS_DIR/lib/git-write.sh" "$LIBLESS/lib/"
out=$(run_hook "$LIBLESS/pr-mode.sh" PreToolUse "$S" 'git commit -m x' "" "" "$REPO_MAIN")
report K01-no-awk-protected deny "$(decision_of "$out")" ""
out=$(run_hook "$LIBLESS/pr-mode.sh" PreToolUse "$S" 'git status' "" "" "$REPO_MAIN")
report K02-no-awk-readonly none "$(decision_of "$out")" ""
out=$(run_hook "$LIBLESS/pr-mode.sh" PermissionRequest "$S" 'git commit -m x' "" "" "$REPO_FEAT")
report K03-no-awk-perm-allow allow "$(decision_of "$out")" ""
out=$(run_hook "$LIBLESS/pr-mode.sh" PreToolUse "$S" 'git push origin "main"' "" "" "$REPO_MAIN")
report K04-no-awk-quoted-protected deny "$(decision_of "$out")" ""
rm -rf "$LIBLESS"

echo "# L. PermissionRequest は Bash 以外のツールも allow する（ユーザー操作ツールは除く）"
perm_json L01-edit allow '{"hook_event_name":"PermissionRequest","session_id":"'$S'","cwd":"/tmp","tool_name":"Edit","tool_input":{"file_path":"/tmp/x"}}'
perm_json L02-write allow '{"hook_event_name":"PermissionRequest","session_id":"'$S'","cwd":"/tmp","tool_name":"Write","tool_input":{"file_path":"/tmp/x","content":"y"}}'
perm_json L03-mcp allow '{"hook_event_name":"PermissionRequest","session_id":"'$S'","cwd":"/tmp","tool_name":"mcp__example__run","tool_input":{"x":1}}'
perm_json L04-bash-compound allow '{"hook_event_name":"PermissionRequest","session_id":"'$S'","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"git status && ls | head -1"}}'
# ユーザー操作そのものが目的のツールは allow しない
perm_json L05-ask-user-question none '{"hook_event_name":"PermissionRequest","session_id":"'$S'","cwd":"/tmp","tool_name":"AskUserQuestion","tool_input":{}}'
perm_json L06-exit-plan-mode none '{"hook_event_name":"PermissionRequest","session_id":"'$S'","cwd":"/tmp","tool_name":"ExitPlanMode","tool_input":{}}'
perm_json L07-enter-plan-mode none '{"hook_event_name":"PermissionRequest","session_id":"'$S'","cwd":"/tmp","tool_name":"EnterPlanMode","tool_input":{}}'

summary "pr-mode.sh"
