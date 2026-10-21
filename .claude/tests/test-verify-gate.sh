#!/bin/bash
# hooks/verify-gate.sh のテーブル駆動テスト
# 実行: bash .claude/tests/test-verify-gate.sh（run.sh からも呼ばれる）
# 一時ディレクトリに模擬 dotfiles（repo/.claude/hooks/verify-gate.sh）を作り、フックのコピーにその repo をルートとして
# 判定させる。状態ファイルは TMPDIR を一時ディレクトリに向けて隔離する
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
HOOK="$HOOKS_DIR/verify-gate.sh"
W="$T/claude-verifygate-test.$$"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT
cleanup
mkdir -p "$W/repo/.claude/hooks/lib" "$W/repo/.claude/tests" "$W/repo/.claude/skills/x/sub" "$W/repo/.claude/agents/sub" \
  "$W/repo/nix" "$W/repo/docs" "$W/repo/ai" "$W/repo/codex/hooks" "$W/repo/codex/prompts" "$W/repo/devin" "$W/repo/opencode" \
  "$W/outside" "$W/home/.claude" "$W/tmp"
cp "$HOOK" "$W/repo/.claude/hooks/verify-gate.sh"
H="$W/repo/.claude/hooks/verify-gate.sh"
ROOT="$(cd "$W/repo" && pwd -P)"   # macOS の TMPDIR（/var/…）は /private/var/… へのリンクなので実体で比べる
ST="$W/tmp"
for f in .claude/hooks/x.sh .claude/hooks/lib/strip-shell.awk .claude/tests/test-x.sh .claude/settings.json .claude/dev-roots \
  .claude/setup.sh .claude/skills/x/SKILL.md .claude/skills/x/ref.md .claude/skills/x/sub/SKILL.md .claude/skills/x/tool.sh \
  .claude/agents/a.md .claude/agents/sub/b.md .claude/README.md bootstrap.sh flake.nix flake.lock nix/home.nix nix/merge-cli-config.py nix/README.md README.md AGENTS.md docs/x.md \
  ai/core.md ai/claude.md ai/install.sh ai/README.md codex/config.toml codex/hooks/guard.sh codex/prompts/pr.md \
  devin/config.json opencode/opencode.json opencode/setup.sh opencode/README.md; do
  : > "$W/repo/$f"
done
: > "$W/outside/foo.sh"
ln -s "$W/repo/.claude/hooks" "$W/home/.claude/hooks"       # ~/.claude/hooks → dotfiles/.claude/hooks と同じ形のリンク
ln -s "$W/outside/foo.sh" "$W/repo/.claude/hooks/link-out.sh"  # ルート内に置いた、ルート外を指すリンク（実体で判定するので対象外）

S1=test-vg-1-$$
S2=test-vg-2-$$
S3=test-vg-3-$$

hook() { TMPDIR="$ST" bash "$H"; }
edit() { # session tool path
  local key=file_path; [ "$2" = NotebookEdit ] && key=notebook_path
  jq -cn --arg s "$1" --arg t "$2" --arg k "$key" --arg f "$3" \
    '{hook_event_name:"PostToolUse",session_id:$s,tool_name:$t,tool_input:{($k):$f},tool_response:{}}' | hook
}
bashrun() { # session command stdout [cwd]
  jq -cn --arg s "$1" --arg c "$2" --arg o "$3" --arg d "${4:-}" \
    '{hook_event_name:"PostToolUse",session_id:$s,tool_name:"Bash",tool_input:{command:$c},tool_response:{stdout:$o,stderr:"",interrupted:false,isImage:false},cwd:$d}' | hook
}
stop() { # session stop_hook_active(true/false)
  jq -cn --arg s "$1" --argjson a "$2" '{hook_event_name:"Stop",session_id:$s,stop_hook_active:$a,last_assistant_message:"done"}' | hook
}
state_of() { if [ -f "$ST/claude-verify-gate-$1" ]; then cut -f1 "$ST/claude-verify-gate-$1" | paste -sd, -; else echo none; fi; }
state_full() { if [ -f "$ST/claude-verify-gate-$1" ]; then paste -sd, - < "$ST/claude-verify-gate-$1"; else echo none; fi; }
jget() { if [ -z "$1" ]; then echo empty; else printf '%s' "$1" | jq -r "$2"; fi; }
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

RUN_OK=$'== 構文チェック ==\n  ✓ settings.json\n  ✓ guard-destructive.sh: 345 件すべて通過\nすべて通過'
RUN_NG=$'  ✓ guard-destructive.sh: 345 件すべて通過\n  ✗ pr-mode.sh: 1 件失敗 / 171 件通過\n  NG [A01] expect=allow got=none'
NIX_OK='/nix/store/abcd1234-home-manager-generation.drv'

echo "# A. run.sh カテゴリ: 編集 → Stop で 1 回続行 → 検証の成功で解除"
out=$(edit "$S1" Edit "$W/repo/.claude/hooks/x.sh"); report A01-edit-no-output "" "$out" "$out"
report A02-recorded run.sh "$(state_of "$S1")" ""
edit "$S1" Write "$W/repo/.claude/hooks/x.sh" >/dev/null
report A03-dedup run.sh "$(state_of "$S1")" ""
out=$(stop "$S1" false)
report A04-stop-block block "$(jget "$out" '.decision // "none"')" "$out"
reason=$(jget "$out" '.reason // ""')
report A05-reason-cmd yes "$(has "$reason" 'bash .claude/tests/run.sh')" "$reason"
report A06-reason-root yes "$(has "$reason" "（${ROOT}）")" "$reason"   # 変数直後の全角括弧が壊れていない
report A07-reason-no-nix no "$(has "$reason" 'nix eval --raw')" "$reason"
report A08-reason-foreground yes "$(has "$reason" 'フォアグラウンドで実行する')" "$reason"
report A09-state-kept run.sh "$(state_of "$S1")" "続行させる Stop では記録を消さない"
report A10-no-sysmsg none "$(jget "$out" '.systemMessage // "none"')" "$out"
bashrun "$S1" 'bash .claude/tests/run.sh' 'ok' >/dev/null
report A11-no-pass-line run.sh "$(state_of "$S1")" ""
bashrun "$S1" 'bash .claude/tests/run.sh 2>&1 | tail -5' "$RUN_NG" >/dev/null
report A12-summary-line-only run.sh "$(state_of "$S1")" "summary 行の「件すべて通過」は成功とみなさない"
bashrun "$S1" 'echo すべて通過' 'すべて通過' >/dev/null
report A13-other-cmd run.sh "$(state_of "$S1")" ""
bashrun "$S1" 'HOOKS_DIR=/tmp/x bash .claude/tests/run.sh' "$RUN_OK" >/dev/null
report A14-hooks-dir-override run.sh "$(state_of "$S1")" ""
bashrun "$S1" "bash $ROOT/.claude/tests/run.sh 2>&1 | tail -3" "$RUN_OK" >/dev/null
report A15-cleared none "$(state_of "$S1")" ""
out=$(stop "$S1" false); report A16-stop-silent "" "$out" "$out"
out=$(stop "$S1" true);  report A17-stop-silent-active "" "$out" "$out"
edit "$S1" Edit "$W/repo/.claude/hooks/x.sh" >/dev/null
bashrun "$S1" 'bash tests/run.sh 2>&1 | tail -3' "$RUN_OK" "$ROOT/.claude" >/dev/null
report A18-relative-cwd-cleared none "$(state_of "$S1")" "cwd がこの dotfiles の .claude なら相対実行でも解除する"
edit "$S1" Edit "$W/repo/.claude/hooks/x.sh" >/dev/null
bashrun "$S1" 'bash tests/run.sh 2>&1 | tail -3' "$RUN_OK" "$W/outside" >/dev/null
report A19-relative-other-cwd run.sh "$(state_of "$S1")" "無関係な cwd の同名 tests/run.sh の成功では解除しない"
edit "$S1" Edit "$W/repo/.claude/hooks/x.sh" >/dev/null
bashrun "$S1" 'bash tests/run.sh 2>&1 | tail -3' "$RUN_OK" "$ROOT" >/dev/null
report A20-relative-repo-root run.sh "$(state_of "$S1")" "リポジトリ直下の cwd でも相対形は解除しない（.claude のみ）"
bashrun "$S1" 'bash tests/run.sh' "$RUN_OK" >/dev/null
report A21-relative-no-cwd run.sh "$(state_of "$S1")" "cwd が無ければ相対形では解除しない"
bashrun "$S1" 'bash .claude/tests/run.sh' "$RUN_OK" >/dev/null
report A22-relative-nocwd-kept run.sh "$(state_of "$S1")" "cwd が無い相対 .claude/tests/run.sh は検証先を特定できないので解除しない"
bashrun "$S1" 'bash .claude/tests/run.sh' "$RUN_OK" "$ROOT" >/dev/null
report A22b-relative-root-cleared none "$(state_of "$S1")" "checkout 直下の cwd なら相対 .claude/tests/run.sh で解除する"
edit "$S1" Edit "$W/repo/.claude/hooks/x.sh" >/dev/null
bashrun "$S1" "cd $W/outside && bash tests/run.sh" "$RUN_OK" "$ROOT/.claude" >/dev/null
report A23-relative-cd-other run.sh "$(state_of "$S1")" "cwd=.claude でも cd で別ディレクトリへ移る相対形は解除しない"
edit "$S1" Edit "$W/repo/.claude/hooks/x.sh" >/dev/null
bashrun "$S1" 'bash tests/run.sh; echo ok' "$RUN_OK" "$ROOT/.claude" >/dev/null
report A24-relative-compound run.sh "$(state_of "$S1")" "相対形に複合コマンドを足した形は解除しない"
edit "$S1" Edit "$W/repo/.claude/hooks/x.sh" >/dev/null
bashrun "$S1" 'bash tests/run.sh 2>&1 | grep すべて' "$RUN_OK" "$ROOT/.claude" >/dev/null
report A25-relative-other-pipe run.sh "$(state_of "$S1")" "許容する tail 以外へのパイプは解除しない"
bashrun "$S1" 'bash tests/run.sh 2>&1 | tail -n 3' "$RUN_OK" "$ROOT/.claude" >/dev/null
report A26-relative-tail-n none "$(state_of "$S1")" "tail -n N 形は許容する"
rm -f "$ST/claude-verify-gate-$S1"

echo "# B. stop_hook_active が true なら止めずに systemMessage で警告し、記録を消す"
edit "$S1" Edit "$W/repo/.claude/hooks/x.sh" >/dev/null
out=$(stop "$S1" true)
report B01-no-decision none "$(jget "$out" '.decision // "none"')" "$out"
msg=$(jget "$out" '.systemMessage // ""')
report B02-sysmsg yes "$(has "$msg" '未実行のまま')" "$out"
report B03-sysmsg-cmd yes "$(has "$msg" 'bash .claude/tests/run.sh')" "$out"
report B04-state-removed none "$(state_of "$S1")" "警告した分は記録から消える（次のターンで促さない）"
out=$(stop "$S1" false); report B05-next-turn-silent "" "$out" "$out"
edit "$S1" Edit "$W/repo/flake.nix" >/dev/null
report B06-reedit-records "nix eval" "$(state_of "$S1")" "新たに編集すれば再び促す"
out=$(stop "$S1" false); report B07-reprompt block "$(jget "$out" '.decision // "none"')" "$out"
bashrun "$S1" 'nix eval --raw .#homeConfigurations.ubuntu.activationPackage.drvPath' "$NIX_OK" "$ROOT" >/dev/null
report B08-cleared none "$(state_of "$S1")" ""

echo "# C. nix eval カテゴリと両方のカテゴリ"
edit "$S2" Edit "$W/repo/nix/home.nix" >/dev/null
edit "$S2" Edit "$W/repo/flake.nix" >/dev/null
report C01-nix-dedup "nix eval" "$(state_of "$S2")" ""
reason=$(jget "$(stop "$S2" false)" '.reason // ""')
report C02-reason "yes,no" "$(has "$reason" 'nix eval --raw .#homeConfigurations.ubuntu.activationPackage.drvPath'),$(has "$reason" 'bash .claude/tests/run.sh')" "$reason"
bashrun "$S2" 'nix eval --raw .#homeConfigurations.ubuntu.activationPackage.drvPath' 'error: attribute missing' "$ROOT" >/dev/null
report C03-no-drv "nix eval" "$(state_of "$S2")" ""
bashrun "$S2" 'nix eval --raw .#homeConfigurations.ubuntu.activationPackage.drvPath 2>&1 | tail -3' \
  $'error: builder for \'/nix/store/abcd1234-home-manager-generation.drv\' failed with exit code 1' "$ROOT" >/dev/null
report C04-drv-in-error "nix eval" "$(state_of "$S2")" "行の途中の …drv では解除しない"
bashrun "$S2" 'nix eval --raw .#homeConfigurations.ubuntu.activationPackage.drvPath 2>&1' $'warning: Git tree \'/x\' is dirty\n'"$NIX_OK" "$ROOT" >/dev/null
report C05-cleared-with-warning none "$(state_of "$S2")" "2>&1 で警告が混ざっても drvPath の行があれば解除"
edit "$S2" Edit "$W/repo/.claude/dev-roots" >/dev/null
report C06-dev-roots-both "run.sh,nix eval" "$(state_of "$S2")" "dev-roots は run.sh と nix eval の両方"
reason=$(jget "$(stop "$S2" false)" '.reason // ""')
report C07-both-reason "yes,yes" "$(has "$reason" 'bash .claude/tests/run.sh'),$(has "$reason" 'nix eval --raw')" "$reason"
bashrun "$S2" 'nix eval --raw .#homeConfigurations.ubuntu.activationPackage.drvPath 2>&1 | tail -1' "$NIX_OK" "$ROOT" >/dev/null
report C08-one-left run.sh "$(state_of "$S2")" ""
reason=$(jget "$(stop "$S2" false)" '.reason // ""')
report C09-left-reason "yes,no" "$(has "$reason" 'bash .claude/tests/run.sh'),$(has "$reason" 'nix eval --raw')" "$reason"
bashrun "$S2" 'bash .claude/tests/run.sh' "$RUN_OK" "$ROOT" >/dev/null
report C10-all-cleared none "$(state_of "$S2")" ""
len=$(jget "$(edit "$S2" Edit "$W/repo/.claude/dev-roots" >/dev/null; stop "$S2" false)" '.reason // "" | length')
if [ "$len" != empty ] && [ "$len" -gt 0 ] && [ "$len" -le 10000 ]; then ok=yes; else ok=no; fi
report C11-reason-length yes "$ok" "length=${len}"
rm -f "$ST/claude-verify-gate-$S2"
edit "$S2" Edit "$W/repo/nix/merge-cli-config.py" >/dev/null
report C12-merge-cli-config-both "run.sh,nix eval" "$(state_of "$S2")" "マージスクリプトも run.sh と nix eval の両方"
reason=$(jget "$(stop "$S2" false)" '.reason // ""')
report C13-merge-cli-config-reason "yes,yes" "$(has "$reason" 'bash .claude/tests/run.sh'),$(has "$reason" 'nix eval --raw')" "$reason"
bashrun "$S2" 'bash .claude/tests/run.sh' "$RUN_OK" "$ROOT" >/dev/null
report C14-merge-cli-config-nix-left "nix eval" "$(state_of "$S2")" "run.sh だけでは解除しない"
bashrun "$S2" 'nix eval --raw .#homeConfigurations.ubuntu.activationPackage.drvPath' "$NIX_OK" "$ROOT" >/dev/null
report C15-merge-cli-config-cleared none "$(state_of "$S2")" "両方の成功で解除する"
edit "$S2" Edit "$W/repo/flake.nix" >/dev/null
bashrun "$S2" 'nix eval --raw .#homeConfigurations.ubuntu.activationPackage.drvPath' "$NIX_OK" >/dev/null
report C16-nix-no-cwd-kept "nix eval" "$(state_of "$S2")" "cwd が無い nix eval では、どの worktree か特定できないので解除しない"
bashrun "$S2" 'nix eval --raw .#homeConfigurations.ubuntu.activationPackage.drvPath' "$NIX_OK" "$W/outside" >/dev/null
report C17-nix-other-cwd-kept "nix eval" "$(state_of "$S2")" "dotfiles 以外の cwd では解除しない"
bashrun "$S2" "nix eval --raw $W/outside#homeConfigurations.ubuntu.activationPackage.drvPath" "$NIX_OK" "$ROOT" >/dev/null
report C18-nix-other-flake-kept "nix eval" "$(state_of "$S2")" "cwd 以外の flake を明示した形では解除しない"
rm -f "$ST/claude-verify-gate-$S2"

echo "# D. 分類の表（run.sh / nix eval / 対象外）"
n=0
while read -r expect path; do
  n=$((n + 1))
  rm -f "$ST/claude-verify-gate-$S3"
  edit "$S3" Edit "$path" >/dev/null
  report "D$(printf '%02d' "$n")-${path##*/}" "${expect//_/ }" "$(state_of "$S3")" "$path"
done <<EOF
run.sh $W/repo/.claude/hooks/x.sh
run.sh $W/repo/.claude/hooks/lib/strip-shell.awk
run.sh $W/repo/.claude/tests/test-x.sh
run.sh $W/repo/.claude/settings.json
run.sh $W/repo/.claude/setup.sh
run.sh $W/repo/.claude/skills/x/SKILL.md
run.sh $W/repo/.claude/skills/x/tool.sh
run.sh $W/repo/.claude/agents/a.md
run.sh $W/repo/bootstrap.sh
run.sh $W/repo/.claude/hooks/new-not-yet.sh
run.sh $W/home/.claude/hooks/x.sh
nix_eval $W/repo/flake.nix
nix_eval $W/repo/flake.lock
nix_eval $W/repo/nix/home.nix
run.sh $W/repo/ai/core.md
run.sh $W/repo/ai/claude.md
run.sh $W/repo/ai/install.sh
run.sh $W/repo/codex/config.toml
run.sh $W/repo/codex/hooks/guard.sh
run.sh $W/repo/codex/prompts/pr.md
run.sh $W/repo/devin/config.json
run.sh $W/repo/opencode/opencode.json
run.sh $W/repo/opencode/setup.sh
none $W/repo/ai/README.md
none $W/repo/opencode/README.md
none $W/repo/README.md
none $W/repo/nix/README.md
none $W/repo/AGENTS.md
none $W/repo/.claude/README.md
none $W/repo/docs/x.md
none $W/repo/.claude/skills/x/ref.md
none $W/repo/.claude/skills/x/sub/SKILL.md
none $W/repo/.claude/agents/sub/b.md
none $W/outside/foo.sh
none $W/repo/.claude/hooks/link-out.sh
run.sh,nix_eval $W/repo/nix/merge-cli-config.py
EOF
rm -f "$ST/claude-verify-gate-$S3"
edit "$S3" NotebookEdit "$W/repo/.claude/skills/x/nb.ipynb" >/dev/null
report D-notebook run.sh "$(state_of "$S3")" "notebook_path"
rm -f "$ST/claude-verify-gate-$S3"
jq -cn --arg s "$S3" --arg f "$W/repo/.claude/hooks/x.sh" \
  '{hook_event_name:"PostToolUse",session_id:$s,tool_name:"Read",tool_input:{file_path:$f}}' | hook >/dev/null
report D-read-tool none "$(state_of "$S3")" "Edit 系以外のツールは記録しない"

echo "# E. セッションの分離"
edit "$S1" Edit "$W/repo/.claude/hooks/x.sh" >/dev/null
out=$(stop "$S3" false); report E01-other-stop "" "$out" "$out"
bashrun "$S3" 'bash .claude/tests/run.sh' "$RUN_OK" "$ROOT" >/dev/null
report E02-other-clear run.sh "$(state_of "$S1")" ""
bashrun "$S1" 'bash .claude/tests/run.sh' "$RUN_OK" "$ROOT" >/dev/null
report E03-own-clear none "$(state_of "$S1")" ""

echo "# G. 同じ Git common-dir の worktree を同じ dotfiles として扱う"
G="$W/gitrepo"
GT="$W/gitwt"
mkdir -p "$G/.claude/hooks" "$G/.claude/tests" "$G/opencode/hooks"
cp "$HOOK" "$G/.claude/hooks/verify-gate.sh"
: > "$G/.claude/hooks/x.sh"
: > "$G/opencode/hooks/harness.sh"
git -C "$G" init -q
git -C "$G" add -A
git -C "$G" -c user.name=test -c user.email=test@example.com commit -q -m init
git -C "$G" worktree add -q --detach "$GT"
GH="$G/.claude/hooks/verify-gate.sh"
gedit() { # session tool path
  local key=file_path; [ "$2" = NotebookEdit ] && key=notebook_path
  jq -cn --arg s "$1" --arg t "$2" --arg k "$key" --arg f "$3" \
    '{hook_event_name:"PostToolUse",session_id:$s,tool_name:$t,tool_input:{($k):$f},tool_response:{}}' \
    | TMPDIR="$ST" bash "$GH"
}
gbashrun() { # session command stdout [cwd]
  jq -cn --arg s "$1" --arg c "$2" --arg o "$3" --arg d "${4:-}" \
    '{hook_event_name:"PostToolUse",session_id:$s,tool_name:"Bash",tool_input:{command:$c},tool_response:{stdout:$o,stderr:"",interrupted:false,isImage:false},cwd:$d}' \
    | TMPDIR="$ST" bash "$GH"
}
gstop() { jq -cn --arg s "$1" --argjson a "$2" '{hook_event_name:"Stop",session_id:$s,stop_hook_active:$a}' | TMPDIR="$ST" bash "$GH"; }
S4=test-vg-4-$$
gedit "$S4" Edit "$GT/.claude/hooks/x.sh" >/dev/null
report G01-worktree-edit run.sh "$(state_of "$S4")" "別 worktree の編集も同じリポジトリなら記録する"
report G01b-worktree-bound "run.sh	$GT" "$(state_full "$S4")" "状態は編集した worktree に結び付く"
gedit "$S4" Write "$GT/.claude/hooks/x.sh" >/dev/null
report G02-worktree-edit-hook run.sh "$(state_of "$S4")" "重複しない"
out=$(gstop "$S4" false)
report G03-worktree-stop block "$(jget "$out" '.decision // "none"')" "$out"
g3reason=$(jget "$out" '.reason // ""')
report G03b-reason-worktree yes "$(has "$g3reason" "（${GT}）")" "Stop の説明に検証すべき worktree を示す"
gbashrun "$S4" 'bash tests/run.sh 2>&1 | tail -3' "$RUN_OK" "$GT/.claude" >/dev/null
report G04-worktree-relative-cleared none "$(state_of "$S4")" "worktree の .claude からの相対実行で解除する"
gedit "$S4" Edit "$GT/.claude/hooks/x.sh" >/dev/null
gbashrun "$S4" "cd $GT/.claude && bash tests/run.sh" "$RUN_OK" "$G/.claude" >/dev/null
report G05-cd-other-worktree run.sh "$(state_of "$S4")" "開始 cwd が .claude でも cd 先の worktree では解除しない"
gbashrun "$S4" 'bash tests/run.sh' "$RUN_OK" "$GT/.claude" >/dev/null
report G06-worktree-direct-cleared none "$(state_of "$S4")" "直接の相対形なら解除する"
gedit "$S4" Edit "$GT/opencode/hooks/harness.sh" >/dev/null
report G07-worktree-opencode-hook run.sh "$(state_of "$S4")" "opencode の plugin/hook も run.sh 対象"
# メイン checkout の .claude で成功しても、編集した worktree の保留は消さない
gbashrun "$S4" 'bash tests/run.sh' "$RUN_OK" "$G/.claude" >/dev/null
report G08-main-success-keeps-worktree "run.sh	$GT" "$(state_full "$S4")" "メイン checkout の成功では worktree の保留を解除しない"
report G08b-main-no-entry no "$(has "$(state_full "$S4")" "run.sh	$G")" "メイン checkout の保留は作らない"
gbashrun "$S4" 'bash tests/run.sh' "$RUN_OK" "$GT/.claude" >/dev/null
report G09-worktree-success-clears none "$(state_of "$S4")" "同じ worktree の成功だけで解除する"
# 1 セッションで 2 つの worktree を触っても、成功した worktree だけ解除する
mkdir -p "$G/nix" "$GT/nix"
: > "$G/nix/home.nix"
: > "$GT/nix/home.nix"
gedit "$S4" Edit "$G/nix/home.nix" >/dev/null
gedit "$S4" Edit "$GT/nix/home.nix" >/dev/null
report G0A-two-worktrees "nix eval,nix eval" "$(state_of "$S4")" "2 つの worktree を別エントリで保持する"
gbashrun "$S4" 'nix eval --raw .#homeConfigurations.ubuntu.activationPackage.drvPath' "$NIX_OK" "$G" >/dev/null
report G0B-main-nix-cleared "nix eval	$GT" "$(state_full "$S4")" "メイン checkout の nix eval だけ解除する"
gbashrun "$S4" 'nix eval --raw .#homeConfigurations.ubuntu.activationPackage.drvPath' "$NIX_OK" "$GT" >/dev/null
report G0C-worktree-nix-cleared none "$(state_of "$S4")" "worktree の nix eval で解除する"
# cd で別 checkout へ移る複合形は、開始 cwd の worktree の成功とみなさない
gedit "$S4" Edit "$GT/.claude/hooks/x.sh" >/dev/null
gbashrun "$S4" "cd $G && bash .claude/tests/run.sh" "$RUN_OK" "$GT" >/dev/null
report G0D-cd-main-keeps "run.sh" "$(state_of "$S4")" "cwd が worktree でも cd 先の main の成功では解除しない"
gbashrun "$S4" "cd $GT && bash .claude/tests/run.sh" "$RUN_OK" "$G" >/dev/null
report G0E-cd-worktree-keeps "run.sh" "$(state_of "$S4")" "cwd が main でも cd 先の worktree の成功では解除しない"
gbashrun "$S4" 'bash .claude/tests/run.sh' "$RUN_OK" "$GT" >/dev/null
report G0F-worktree-root-direct-cleared none "$(state_of "$S4")" "worktree 直下からの直接形だけで解除する"
rm -f "$ST/claude-verify-gate-$S4"

echo "# F. 異常入力（何も出さず exit 0。stderr も空）"
ef() { # label input
  local out err rc
  err="$W/err.$$"
  out=$(printf '%s' "$2" | TMPDIR="$ST" bash "$H" 2>"$err"); rc=$?
  report "$1" "0::" "$rc:$out:$(cat "$err")" "$2"
}
before=$(ls "$ST" | wc -l | tr -d ' ')
ef F01-broken '{"hook_event_name":"Stop",'
ef F02-empty ''
ef F03-no-session-edit "$(jq -cn --arg f "$W/repo/flake.nix" '{hook_event_name:"PostToolUse",tool_name:"Edit",tool_input:{file_path:$f}}')"
ef F04-no-session-stop '{"hook_event_name":"Stop","stop_hook_active":false}'
ef F05-bad-session "$(jq -cn --arg f "$W/repo/flake.nix" '{hook_event_name:"PostToolUse",session_id:"../x",tool_name:"Edit",tool_input:{file_path:$f}}')"
ef F06-no-path '{"hook_event_name":"PostToolUse","session_id":"s","tool_name":"Edit","tool_input":{}}'
ef F07-not-json 'hello'
ef F08-str-tool-input "$(jq -cn --arg s "$S3" '{hook_event_name:"PostToolUse",session_id:$s,tool_name:"Edit",tool_input:"x"}')"
after=$(ls "$ST" | wc -l | tr -d ' ')
report F09-no-state-created "$before" "$after" "$(ls "$ST")"
# 正常系でも stderr は空・exit 0
err="$W/err2.$$"
jq -cn --arg s "$S1" --arg f "$W/repo/flake.nix" '{hook_event_name:"PostToolUse",session_id:$s,tool_name:"Edit",tool_input:{file_path:$f}}' \
  | TMPDIR="$ST" bash "$H" 2>"$err" >/dev/null; rc=$?
report F10-normal-rc 0 "$rc" ""
jq -cn --arg s "$S1" '{hook_event_name:"Stop",session_id:$s,stop_hook_active:false}' | TMPDIR="$ST" bash "$H" 2>>"$err" >/dev/null; rc=$?
report F11-stop-rc 0 "$rc" ""
report F12-normal-stderr "" "$(cat "$err")" "$(cat "$err")"
# Stop の入力に壊れた tool_input が付いていても続行指示は出す。jq が無い環境では exit 0 で何も出さない
out=$(jq -cn --arg s "$S1" '{hook_event_name:"Stop",session_id:$s,stop_hook_active:false,tool_input:"garbage",tool_response:7}' | hook)
report F13-stop-garbage-tool-input block "$(jget "$out" '.decision // "none"')" "$out"
out=$(jq -cn --arg s "$S1" '{hook_event_name:"Stop",session_id:$s,stop_hook_active:false}' | TMPDIR="$ST" PATH=/nonexistent /bin/bash "$H" 2>&1); rc=$?
report F14-no-jq "0:" "$rc:$out" ""
rm -f "$ST/claude-verify-gate-$S1"

cleanup
summary "verify-gate.sh"
