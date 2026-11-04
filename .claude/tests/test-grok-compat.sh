#!/bin/bash
# Grok CLI 相当の入出力（camelCase・GROK_HOOK_EVENT・run_terminal_command）で
# pr-mode / guard-destructive / validate-claude-config が動くことを固定する
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PR="$HOOKS_DIR/pr-mode.sh"
GD="$HOOKS_DIR/guard-destructive.sh"
VAL="$HOOKS_DIR/validate-claude-config.sh"
S_ON=test-grok-on-$$
S_OFF=test-grok-off-$$
IN="$HOME/Dev/kaishi/ubuntu-dotfiles"
GIT_MAIN="$T/claude-grok-main.$$"
GIT_FEAT="$T/claude-grok-feat.$$"
cleanup() { rm -rf "$T/claude-grok-validate.$$" "$GIT_MAIN" "$GIT_FEAT"; }
trap cleanup EXIT
cleanup
mkdir -p "$GIT_MAIN" "$GIT_FEAT"
git init -q -b main "$GIT_MAIN" 2>/dev/null || { git init -q "$GIT_MAIN"; git -C "$GIT_MAIN" checkout -q -b main; }
git init -q -b feat/x "$GIT_FEAT" 2>/dev/null || { git init -q "$GIT_FEAT"; git -C "$GIT_FEAT" checkout -q -b feat/x; }

gpre() { report "$1" "$2" "$(decision_of "$(run_hook_grok "$PR" pre_tool_use "$3" "$4" "" "${5-/tmp}")")" "$4"; }
gperm() { report "$1" "$2" "$(decision_of "$(run_hook_grok "$PR" permission_request "$3" "$4" "" "${5-/tmp}")")" "$4"; }

echo "# Grok pr-mode: プロンプトイベントはフラグを作らない"
run_hook_grok "$PR" user_prompt_submit "$S_ON" "" "/pr" >/dev/null
[ -e "$T/claude-pr-mode-$S_ON" ] && r=present || r=absent
report G01-submit-no-flag absent "$r" ""
run_hook_grok "$PR" stop "$S_ON" >/dev/null
[ -e "$T/claude-pr-mode-$S_ON" ] && r=present || r=absent
report G02-stop-no-flag absent "$r" ""

echo "# Grok pr-mode: 保護ブランチ以外は自動許可（PreToolUse は none）"
gpre G10-commit-off none "$S_OFF" 'git commit -m x'
gpre G11-push-off none "$S_OFF" 'git push -u origin feat/x'
gpre G12-create-off none "$S_OFF" 'gh pr create --fill'
gpre G13-status-off none "$S_OFF" 'git status'
gpre G14-commit-on none "$S_ON" 'git commit -m x'
gpre G15-push-feat none "$S_ON" 'git push origin HEAD:feat/x' "$GIT_MAIN"
gpre G16-force deny "$S_ON" 'git push --force origin feat'
gpre G17-force-f deny "$S_ON" 'git push -f origin feat'
gpre G18-amend ask "$S_ON" 'git commit --amend --no-edit'
gpre G19-camel-tool none "$S_OFF" 'git commit -m x'
gpre G20-protected-commit deny "$S_ON" 'git commit -m x' "$GIT_MAIN"
gpre G21-protected-push deny "$S_ON" 'git push origin main' "$GIT_MAIN"
gpre G22-merge ask "$S_ON" 'gh pr merge 1'
gpre G23-vars ask "$S_ON" 'git push origin "$BRANCH"'
out=$(jq -cn --arg s "$S_ON" --arg d "$GIT_FEAT" '{hookEventName:"pre_tool_use",sessionId:$s,cwd:$d,agentId:"child",toolName:"run_terminal_command",toolInput:{command:"git commit -m x"}}' \
  | GROK_HOOK_EVENT=pre_tool_use GROK_SESSION_ID="$S_ON" bash "$PR" 2>/dev/null)
report G24-subagent-deny deny "$(decision_of "$out")" "$out"

echo "# Grok guard-destructive: camelCase + run_terminal_command"
gd() {
  report "$1" "$2" "$(decision_of "$(run_hook_grok "$GD" pre_tool_use test-gd "$3" "" "$IN")")" "$3"
}
gd G30-rm-root deny 'rm -rf /'
gd G31-rm-home deny 'rm -rf ~'
gd G32-rm-claude deny 'rm -rf ~/.claude'
gd G33-reset-hard ask 'git reset --hard HEAD~1'
gd G34-rm-dist none 'rm -rf dist'
gd G35-rm-outside deny 'rm -rf ~/Documents/a'

echo "# Grok validate-claude-config: camelCase toolInput.file_path"
W="$T/claude-grok-validate.$$"
mkdir -p "$W/.claude/hooks"
cp "$VAL" "$W/.claude/hooks/validate-claude-config.sh"
H="$W/.claude/hooks/validate-claude-config.sh"
printf '{"a":1}' > "$W/.claude/ok.json"
out=$(jq -cn --arg f "$W/.claude/ok.json" \
  '{hookEventName:"post_tool_use",sessionId:"t",toolName:"search_replace",toolInput:{file_path:$f}}' \
  | GROK_HOOK_EVENT=post_tool_use bash "$H" 2>&1); rc=$?
report G40-json-ok 0 "$rc" "$out"
printf '{"a":1,}' > "$W/.claude/bad.json"
out=$(jq -cn --arg f "$W/.claude/bad.json" \
  '{hookEventName:"post_tool_use",sessionId:"t",toolName:"write",toolInput:{file_path:$f}}' \
  | GROK_HOOK_EVENT=post_tool_use bash "$H" 2>&1); rc=$?
report G41-json-bad 2 "$rc" "$out"

summary "grok-compat"
