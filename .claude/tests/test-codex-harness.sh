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
# 検証ゲートの判定。完了チェックの出力は検証ゲートが何も返さなかった Stop でだけ出るので none と扱う。
vdec() {
  case "$(jget "$1" '.reason // .systemMessage // ""')" in
    completion-gate*) echo none ;;
    *) jget "$1" '.decision // "none"' ;;
  esac
}
# Stop の出力に含まれる JSON 値の個数
jcount() { printf '%s' "$1" | jq -s 'length'; }
edit() {
  call "$(post apply_patch '{"command":"*** Begin Patch\n*** Update File: codex/config.toml\n@@\n-a\n+b\n*** End Patch"}' '{"success":true}')" >/dev/null
}
verified() { call "$(post Bash '{"command":"bash .claude/tests/run.sh"}' "$1")" >/dev/null; }

echo '# A. 事故防止: guard の deny を維持し、確認なしで通す操作は Codex の承認ポリシーに任せる'
out=$(call "$(pre 'git status')"); report A01-read none "$(decision_of "$out")" "$out"
out=$(call "$(pre 'git reset --hard')"); report A02-reset-hard-none none "$(decision_of "$out")" "$out"
report A03-no-ask none "$(decision_of "$out")" "$out"
out=$(call "$(pre 'git reset --hard' require_escalated)"); report A04-escalated-none none "$(decision_of "$out")" "$out"
report A04-escalated-no-ask none "$(decision_of "$out")" "$out"
reason=""
case "$reason" in *sandbox_permissions=require_escalated*) v=yes ;; *) v=no ;; esac
report A04-escalated-no-retry no "$v" "$reason"
out=$(call "$(pre 'rm -rf /etc/example' require_escalated)"); report A05-hard-deny deny "$(decision_of "$out")" "$out"
out=$(call "$(pre "rm -rf $ROOT/temporary-build")"); report A06-local-delete none "$(decision_of "$out")" "$out"
out=$(call "$(pre 'git branch -D topic')"); report A07-branch-none none "$(decision_of "$out")" "$out"
out=$(call "$(pre 'git branch -D topic' require_escalated)"); report A08-branch-escalated-none none "$(decision_of "$out")" "$out"
# worktree の削除は --force も含めて確認なしで通す（絶対パス）
out=$(call "$(pre "git worktree remove $ROOT/temporary-wt")"); report A12-worktree-remove none "$(decision_of "$out")" "$out"
out=$(call "$(pre "git -C $ROOT worktree remove $ROOT/temporary-wt")"); report A13-worktree-remove-dash-c none "$(decision_of "$out")" "$out"
out=$(call "$(pre "git worktree remove --force $ROOT/temporary-wt")"); report A14-worktree-force none "$(decision_of "$out")" "$out"
out=$(call "$(pre "git worktree remove -f $ROOT/temporary-wt")"); report A15-worktree-short-force none "$(decision_of "$out")" "$out"
out=$(call "$(pre "git -C $ROOT worktree remove --force $ROOT/temporary-wt")"); report A16-worktree-dash-c-force none "$(decision_of "$out")" "$out"
# CLI 0.162.1 の実ペイロードは command だけで承認情報を含まない。
out=$(call "$(pre 'git reset --hard' | jq 'del(.tool_input.sandbox_permissions)')")
report A09-cli-missing-permission none "$(decision_of "$out")" "$out"
report A10-cli-no-ask none "$(decision_of "$out")" "$out"
reason=""
case "$reason" in *sandbox_permissions=require_escalated*) v=yes ;; *) v=no ;; esac
report A11-cli-no-retry no "$v" "$reason"

echo '# B. apply_patch の編集 → Stop 続行 → 正常な検証で解除'
edit
out=$(stop); report B01-patch-pending block "$(vdec "$out")" "$out"
reason=$(jget "$out" '.reason // ""')
case "$reason" in *'bash .claude/tests/run.sh'*) v=yes ;; *) v=no ;; esac
report B02-command yes "$v" "$reason"
# null exit_code は継続中、非0は失敗。見かけの成功出力で解除しない。
verified '{"output":"すべて通過\n","exit_code":null,"session_id":123}'
out=$(stop); report B03-running block "$(vdec "$out")" "$out"
verified '{"output":"すべて通過\n","exit_code":1}'
out=$(stop); report B04-failure block "$(vdec "$out")" "$out"
verified '"{\"output\":\"すべて通過\\n\",\"exit_code\":1}"'
out=$(stop); report B05-string-failure block "$(vdec "$out")" "$out"
verified '"{\"output\":\"すべて通過\\n\",\"exit_code\":null}"'
out=$(stop); report B06-string-running block "$(vdec "$out")" "$out"
verified '"{\"output\":\"すべて通過\\n\",\"exit_code\":0}"'
out=$(stop); report B07-string-success none "$(vdec "$out")" "$out"
edit
verified '{"stdout":"すべて通過\n","exit_code":0}'
out=$(stop); report B08-stdout-success none "$(vdec "$out")" "$out"

# 0.162.1 の write_stdin 完了は元 command を持つ Bash と出力文字列で届く。
# 実行中には PostToolUse が出ず、終了コードもフックには渡されない。
edit
out=$(stop); report B09-poll-pending block "$(vdec "$out")" "$out"
verified '"  ✗ harness.sh: 1 件失敗 / 20 件通過\n"'
out=$(stop); report B10-poll-text-failure block "$(vdec "$out")" "$out"
verified '"すべて通過\n"'
out=$(stop); report B11-poll-text-success none "$(vdec "$out")" "$out"

# block の後に記録対象を再編集すると、active=true の Stop でも再び block し、再編集しなければ次は警告になる
edit
out=$(stop); report B12-first-block block "$(vdec "$out")" "$out"
edit
out=$(stop true); report B13-reblock-after-reedit block "$(vdec "$out")" "$out"
out=$(stop true); report B14-warn-without-reedit none "$(vdec "$out")" "$out"

echo '# C. 移動先・失敗した編集・Stop の無限継続防止'
call "$(post apply_patch '{"command":"*** Begin Patch\n*** Update File: README.md\n*** Move to: nix/example.nix\n@@\n-a\n+b\n*** End Patch"}' '{"success":true}')" >/dev/null
out=$(stop); report C01-move-destination block "$(vdec "$out")" "$out"
reason=$(jget "$out" '.reason // ""')
case "$reason" in *'nix eval --raw'*) v=yes ;; *) v=no ;; esac
report C02-nix-required yes "$v" "$reason"
out=$(stop true); report C03-one-retry none "$(vdec "$out")" "$out"
msg=$(jget "$out" '.systemMessage // ""')
case "$msg" in *'未実行のまま'*) v=yes ;; *) v=no ;; esac
report C04-unverified-warning yes "$v" "$msg"
call "$(post apply_patch '{"command":"*** Update File: codex/config.toml"}' '{"success":false}')" >/dev/null
out=$(stop); report C05-failed-edit none "$(vdec "$out")" "$out"
call "$(post Edit '{"file_path":"'"$ROOT"'/codex/config.toml"}' '{}')" >/dev/null
out=$(stop); report C06-edit-alias block "$(vdec "$out")" "$out"
verified '{"output":"すべて通過\n","exit_code":0}'
report C07-state-separated no "$(if [ -e "$T/claude-verify-gate-$S" ]; then echo yes; else echo no; fi)" ''
report C08-registration 'Bash|apply_patch|Edit|Write|NotebookEdit' "$(jq -r '.hooks.PostToolUse[] | select(any(.hooks[]; .command | contains("harness.sh"))) | .matcher' "$ROOT/codex/hooks.json")" ''
report C09-pre-registration Bash "$(jq -r '.hooks.PreToolUse[] | select(any(.hooks[]; .command | contains("harness.sh"))) | .matcher' "$ROOT/codex/hooks.json")" ''
report C10-stop-registration 1 "$(jq -r '[.hooks.Stop[]?.hooks[].command | select(contains("harness.sh"))] | length' "$ROOT/codex/hooks.json")" ''
report C11-no-flag-events 0 "$(jq -r '[.hooks.SessionEnd[]?.hooks[].command] | map(select(contains("harness.sh") or contains("guard.sh"))) | length' "$ROOT/codex/hooks.json")" ''
report C12-prompt-registration 1 "$(jq -r '[.hooks.UserPromptSubmit[]?.hooks[].command | select(contains("harness.sh"))] | length' "$ROOT/codex/hooks.json")" ''
report C13-no-guard-on-prompt 0 "$(jq -r '[.hooks.UserPromptSubmit[]?.hooks[].command | select(contains("guard.sh"))] | length' "$ROOT/codex/hooks.json")" ''

echo '# D. 完了チェックゲート: 編集したターンの Stop を一度止め、検証ゲートと JSON を重ねない'
# 状態を B/C と分け、OpenCode 実行中マーカーをホストから読まない。
S="$S-completion"
export HOME="$T/home"
mkdir -p "$HOME"
prompt() { jq -cn --arg s "$S" --arg d "$ROOT" '{hook_event_name:"UserPromptSubmit",session_id:$s,cwd:$d,prompt:"x"}' | bash "$HOOK"; }
patch() { # path
  call "$(post apply_patch "$(jq -cn --arg p "$1" '{command:("*** Begin Patch\n*** Update File: " + $p + "\n@@\n-a\n+b\n*** End Patch")}')" '{"success":true}')" >/dev/null
}
out=$(prompt); report D01-prompt-silent '' "$out" "$out"
patch README.md
out=$(stop); report D02-block-count 1 "$(jcount "$out")" "$out"
report D03-block block "$(jget "$out" '.decision // "none"')" "$out"
case "$(jget "$out" '.reason // ""')" in completion-gate*) v=yes ;; *) v=no ;; esac
report D04-completion-reason yes "$v" "$out"
out=$(stop); report D05-consumed '' "$out" "$out"
# 一時領域だけの編集は成果物の変更と見なさない
patch "$T/scratch.txt"
out=$(stop); report D06-temp-ignored '' "$out" "$out"
# 検証ゲートが止めた Stop では、その JSON だけを返す。検証後の Stop で完了チェックが出る。
out=$(prompt); report D07-prompt-silent-again '' "$out" "$out"
patch codex/config.toml
out=$(stop); report D08-verify-only-count 1 "$(jcount "$out")" "$out"
reason=$(jget "$out" '.reason // ""')
case "$reason" in completion-gate*) v=no ;; *'bash .claude/tests/run.sh'*) v=yes ;; *) v=no ;; esac
report D09-verify-reason yes "$v" "$out"
verified '{"output":"すべて通過\n","exit_code":0}'
out=$(stop); report D10-completion-after-verify 1 "$(jcount "$out")" "$out"
case "$(jget "$out" '.reason // ""')" in completion-gate*) v=yes ;; *) v=no ;; esac
report D11-completion-after-verify-reason yes "$v" "$out"
# OpenCode ランナーの起動は失敗・継続中の結果でも記録する
out=$(prompt)
call "$(post Bash '{"command":"bash ~/.claude/skills/opencode/scripts/run.sh task"}' '{"output":"","exit_code":null,"session_id":7}')" >/dev/null
out=$(stop); case "$(jget "$out" '.reason // ""')" in completion-gate*) v=yes ;; *) v=no ;; esac
report D12-opencode-launch yes "$v" "$out"
# PostToolUse は完了チェックの出力を返さない
out=$(call "$(post Edit '{"file_path":"'"$ROOT"'/README.md"}' '{}')"); report D13-post-silent '' "$out" "$out"
out=$(stop); report D14-edit-block block "$(jget "$out" '.decision // "none"')" "$out"
summary 'codex-harness.sh'
