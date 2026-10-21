#!/bin/bash
# Codex の公式イベントと出力形式で、共有ガード・検証ゲートの接続を検査する。
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT="$(cd "$TESTS_DIR/../.." && pwd -P)"
HOOK="$ROOT/codex/hooks/harness.sh"
S="test-codex-harness-$$"
call() { printf '%s' "$1" | bash "$HOOK"; }
pre() { # command sandbox_permissions
  jq -cn --arg s "$S" --arg d "$ROOT" --arg c "$1" --arg p "${2-use_default}" \
    '{hook_event_name:"PreToolUse",session_id:$s,cwd:$d,tool_name:"Bash",tool_input:{command:$c,sandbox_permissions:$p}}'
}
post() { # tool input response(JSON value)
  jq -cn --arg s "$S" --arg d "$ROOT" --arg t "$1" --argjson i "$2" --argjson r "$3" \
    '{hook_event_name:"PostToolUse",session_id:$s,cwd:$d,tool_name:$t,tool_input:$i,tool_response:$r}'
}
stop() {
  jq -cn --arg s "$S" --argjson a "${1-false}" '{hook_event_name:"Stop",session_id:$s,stop_hook_active:$a}' | bash "$HOOK"
}
jget() { if [ -n "$1" ]; then printf '%s' "$1" | jq -r "$2"; else echo none; fi; }
edit() {
  call "$(post apply_patch '{"command":"*** Begin Patch\n*** Update File: codex/config.toml\n@@\n-a\n+b\n*** End Patch"}' '{"success":true}')" >/dev/null
}
verified() { call "$(post Bash '{"command":"bash .claude/tests/run.sh"}' "$1")" >/dev/null; }

echo '# A. 事故防止: deny を維持し、ask は承認情報にかかわらず手動実行へ導く'
out=$(call "$(pre 'git status')"); report A01-read none "$(decision_of "$out")" "$out"
out=$(call "$(pre 'git reset --hard')"); report A02-confirm deny "$(decision_of "$out")" "$out"
reason=$(jget "$out" '.hookSpecificOutput.permissionDecisionReason // ""')
case "$reason" in *'ユーザーに手動実行を依頼'*) v=yes ;; *) v=no ;; esac
report A03-manual-guidance yes "$v" "$reason"
out=$(call "$(pre 'git reset --hard' require_escalated)"); report A04-escalated-still-deny deny "$(decision_of "$out")" "$out"
reason=$(jget "$out" '.hookSpecificOutput.permissionDecisionReason // ""')
case "$reason" in *'ユーザーに手動実行を依頼'*) v=yes ;; *) v=no ;; esac
report A04-escalated-manual-guidance yes "$v" "$reason"
case "$reason" in *sandbox_permissions=require_escalated*) v=yes ;; *) v=no ;; esac
report A04-escalated-no-retry no "$v" "$reason"
out=$(call "$(pre 'rm -rf /etc/example' require_escalated)"); report A05-hard-deny deny "$(decision_of "$out")" "$out"
out=$(call "$(pre "rm -rf $ROOT/temporary-build")"); report A06-local-delete none "$(decision_of "$out")" "$out"
out=$(call "$(pre 'git branch -D topic')"); report A07-branch-confirm deny "$(decision_of "$out")" "$out"
out=$(call "$(pre 'git branch -D topic' require_escalated)"); report A08-branch-escalated-still-deny deny "$(decision_of "$out")" "$out"
# worktree の通常削除は通り、force は共有ガードの ask を harness が deny に倒す（絶対パス）
out=$(call "$(pre "git worktree remove $ROOT/temporary-wt")"); report A12-worktree-remove none "$(decision_of "$out")" "$out"
out=$(call "$(pre "git -C $ROOT worktree remove $ROOT/temporary-wt")"); report A13-worktree-remove-dash-c none "$(decision_of "$out")" "$out"
out=$(call "$(pre "git worktree remove --force $ROOT/temporary-wt")"); report A14-worktree-force deny "$(decision_of "$out")" "$out"
out=$(call "$(pre "git worktree remove -f $ROOT/temporary-wt")"); report A15-worktree-short-force deny "$(decision_of "$out")" "$out"
out=$(call "$(pre "git -C $ROOT worktree remove --force $ROOT/temporary-wt")"); report A16-worktree-dash-c-force deny "$(decision_of "$out")" "$out"
# CLI 0.162.1 の実ペイロードは command だけで承認情報を含まない。
out=$(call "$(pre 'git reset --hard' | jq 'del(.tool_input.sandbox_permissions)')")
report A09-cli-missing-permission deny "$(decision_of "$out")" "$out"
reason=$(jget "$out" '.hookSpecificOutput.permissionDecisionReason // ""')
case "$reason" in *'ユーザーに手動実行を依頼'*) v=yes ;; *) v=no ;; esac
report A10-cli-manual-guidance yes "$v" "$reason"
case "$reason" in *sandbox_permissions=require_escalated*) v=yes ;; *) v=no ;; esac
report A11-cli-no-retry no "$v" "$reason"

echo '# B. apply_patch の編集 → Stop 続行 → 正常な検証で解除'
edit
out=$(stop); report B01-patch-pending block "$(jget "$out" '.decision // "none"')" "$out"
reason=$(jget "$out" '.reason // ""')
case "$reason" in *'bash .claude/tests/run.sh'*) v=yes ;; *) v=no ;; esac
report B02-command yes "$v" "$reason"
# null exit_code は継続中、非0は失敗。見かけの成功出力で解除しない。
verified '{"output":"すべて通過\n","exit_code":null,"session_id":123}'
out=$(stop); report B03-running block "$(jget "$out" '.decision // "none"')" "$out"
verified '{"output":"すべて通過\n","exit_code":1}'
out=$(stop); report B04-failure block "$(jget "$out" '.decision // "none"')" "$out"
verified '"{\"output\":\"すべて通過\\n\",\"exit_code\":1}"'
out=$(stop); report B05-string-failure block "$(jget "$out" '.decision // "none"')" "$out"
verified '"{\"output\":\"すべて通過\\n\",\"exit_code\":null}"'
out=$(stop); report B06-string-running block "$(jget "$out" '.decision // "none"')" "$out"
verified '"{\"output\":\"すべて通過\\n\",\"exit_code\":0}"'
out=$(stop); report B07-string-success none "$(jget "$out" '.decision // "none"')" "$out"
edit
verified '{"stdout":"すべて通過\n","exit_code":0}'
out=$(stop); report B08-stdout-success none "$(jget "$out" '.decision // "none"')" "$out"

# 0.162.1 の write_stdin 完了は元 command を持つ Bash と出力文字列で届く。
# 実行中には PostToolUse が出ず、終了コードもフックには渡されない。
edit
out=$(stop); report B09-poll-pending block "$(jget "$out" '.decision // "none"')" "$out"
verified '"  ✗ harness.sh: 1 件失敗 / 20 件通過\n"'
out=$(stop); report B10-poll-text-failure block "$(jget "$out" '.decision // "none"')" "$out"
verified '"すべて通過\n"'
out=$(stop); report B11-poll-text-success none "$(jget "$out" '.decision // "none"')" "$out"

echo '# C. 移動先・失敗した編集・Stop の無限継続防止'
call "$(post apply_patch '{"command":"*** Begin Patch\n*** Update File: README.md\n*** Move to: nix/example.nix\n@@\n-a\n+b\n*** End Patch"}' '{"success":true}')" >/dev/null
out=$(stop); report C01-move-destination block "$(jget "$out" '.decision // "none"')" "$out"
reason=$(jget "$out" '.reason // ""')
case "$reason" in *'nix eval --raw'*) v=yes ;; *) v=no ;; esac
report C02-nix-required yes "$v" "$reason"
out=$(stop true); report C03-one-retry none "$(jget "$out" '.decision // "none"')" "$out"
msg=$(jget "$out" '.systemMessage // ""')
case "$msg" in *'未実行のまま'*) v=yes ;; *) v=no ;; esac
report C04-unverified-warning yes "$v" "$msg"
call "$(post apply_patch '{"command":"*** Update File: codex/config.toml"}' '{"success":false}')" >/dev/null
out=$(stop); report C05-failed-edit none "$(jget "$out" '.decision // "none"')" "$out"
call "$(post Edit '{"file_path":"'"$ROOT"'/codex/config.toml"}' '{}')" >/dev/null
out=$(stop); report C06-edit-alias block "$(jget "$out" '.decision // "none"')" "$out"
verified '{"output":"すべて通過\n","exit_code":0}'
report C07-state-separated no "$(if [ -e "$T/claude-verify-gate-$S" ]; then echo yes; else echo no; fi)" ''
report C08-registration 'Bash|apply_patch|Edit|Write|NotebookEdit' "$(jq -r '.hooks.PostToolUse[] | select(any(.hooks[]; .command | contains("harness.sh"))) | .matcher' "$ROOT/codex/hooks.json")" ''
summary 'codex-harness.sh'
