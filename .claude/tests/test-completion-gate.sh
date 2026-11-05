#!/bin/bash
# hooks/completion-gate.sh のテーブル駆動テスト
# 実行: bash .claude/tests/test-completion-gate.sh（run.sh からも呼ばれる）
# TMPDIR を一時ディレクトリへ隔離し、HOME も一時ディレクトリへ向けて本物の ~/.cache を触らない。
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
HOOK="$HOOKS_DIR/completion-gate.sh"
W="$T/claude-completiongate-test.$$"
LIVE_PID=""
cleanup() { [ -n "$LIVE_PID" ] && kill "$LIVE_PID" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT
cleanup
mkdir -p "$W/tmp" "$W/home/.cache/claude-opencode-running" "$W/project" "$W/other"
ST="$W/tmp"
HOME_DIR="$W/home"
MARKER_DIR="$HOME_DIR/.cache/claude-opencode-running"
PROJECT="$(cd "$W/project" && pwd -P)"
OTHER="$(cd "$W/other" && pwd -P)"
# 一時領域の外にある編集先（実在しないパス。リポジトリやホームを汚さず、/tmp 判定にも掛からない）
OUTSIDE=/completion-gate-test/work/a.txt
FAKE_HOME=/completion-gate-test-home

# 生存中の run.sh 相当プロセス（cmdline に opencode/scripts/run.sh を含む）
LIVE_SCRIPT="$T/fake-opencode/scripts/run.sh"
mkdir -p "$(dirname "$LIVE_SCRIPT")"
printf '#!/usr/bin/env bash\nsleep 60\n' >"$LIVE_SCRIPT"
bash "$LIVE_SCRIPT" &
LIVE_PID=$!

S1=test-cg-1-$$
S2=test-cg-2-$$
S3=test-cg-3-$$
S4=test-cg-4-$$
S5=test-cg-5-$$
S6=test-cg-6-$$
S7=test-cg-7-$$
S8=test-cg-8-$$
D1=test-cg-d-$$

hook() { TMPDIR="$ST" HOME="${CG_HOME:-$HOME_DIR}" bash "$HOOK"; }
edit() { # session tool path [home]
  local key=file_path; [ "$2" = NotebookEdit ] && key=notebook_path
  jq -cn --arg s "$1" --arg t "$2" --arg k "$key" --arg f "$3" \
    '{hook_event_name:"PostToolUse",session_id:$s,tool_name:$t,tool_input:{($k):$f},tool_response:{}}' \
    | TMPDIR="$ST" HOME="${4:-$HOME_DIR}" bash "$HOOK"
}
bashrun() { # session command
  jq -cn --arg s "$1" --arg c "$2" \
    '{hook_event_name:"PostToolUse",session_id:$s,tool_name:"Bash",tool_input:{command:$c},tool_response:{stdout:"",stderr:""}}' \
    | hook
}
stop() { # session [cwd] [home]
  jq -cn --arg s "$1" --arg d "${2:-}" \
    '{hook_event_name:"Stop",session_id:$s,stop_hook_active:false,cwd:$d,last_assistant_message:"done"}' \
    | TMPDIR="$ST" HOME="${3:-$HOME_DIR}" bash "$HOOK"
}
prompt() { # session
  jq -cn --arg s "$1" '{hook_event_name:"UserPromptSubmit",session_id:$s,prompt:"next"}' | hook
}
state_of() { if [ -f "$ST/claude-completion-gate-$1" ]; then paste -sd, - <"$ST/claude-completion-gate-$1"; else echo none; fi; }
jget() { if [ -z "$1" ]; then echo empty; else printf '%s' "$1" | jq -r "$2"; fi; }
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
marker() { # name pid dir
  printf '%s\n%s\n' "$2" "$3" >"$MARKER_DIR/$1"
}
dead_pid() { sh -c 'echo $$'; }

echo "# A. 編集が無ければ Stop は何もしない"
out=$(stop "$S1")
report A01-silent "" "$out" "$out"
report A02-no-state none "$(state_of "$S1")" ""

echo "# B. 編集後の Stop で block し、理由に要件・根拠・検証・独立レビュー・残り回数を含む"
edit "$S1" Edit "$OUTSIDE" >/dev/null
report B01-recorded "edited=1,blocks=0,opencode=0" "$(state_of "$S1")" ""
out=$(stop "$S1")
report B02-block block "$(jget "$out" '.decision // "none"')" "$out"
reason=$(jget "$out" '.reason // ""')
report B02b-reason-previous yes "$(has "$reason" '前回のチェック以降にファイルを変更')" "$reason"
report B02c-reason-background yes "$(has "$reason" 'バックグラウンドのサブエージェント・タスクの完了待ち')" "$reason"
report B03-reason-requirements yes "$(has "$reason" '要件として列挙')" "$reason"
report B04-reason-evidence yes "$(has "$reason" '根拠（file:line')" "$reason"
report B05-reason-verify yes "$(has "$reason" 'フォアグラウンドで実行')" "$reason"
report B06-reason-review yes "$(has "$reason" '独立レビュー')" "$reason"
report B07-reason-remaining yes "$(has "$reason" '残り 2 回')" "$reason"
report B08-no-sysmsg none "$(jget "$out" '.systemMessage // "none"')" "$out"
report B09-state-after-block "edited=0,blocks=1,opencode=0" "$(state_of "$S1")" "block したら edited を戻し blocks を進める"
out=$(stop "$S1")
report B10-second-stop-silent "" "$out" "$out"
edit "$S1" Write "$OUTSIDE" >/dev/null
report B11-rewrite-keeps-blocks "edited=1,blocks=1,opencode=0" "$(state_of "$S1")" "edited を立て直しても blocks は保持する"
out=$(stop "$S1")
report B12-second-block block "$(jget "$out" '.decision // "none"')" "$out"
report B13-remaining-1 yes "$(has "$(jget "$out" '.reason // ""')" '残り 1 回')" "$out"

echo "# C. 一時領域と ~/.claude/projects 配下の編集は対象外"
edit "$S2" Edit "$ST/a.txt" >/dev/null
report C01-tmpdir none "$(state_of "$S2")" "$ST 配下"
edit "$S2" Write "/tmp/completion-gate-test-$$.txt" >/dev/null
report C02-tmp none "$(state_of "$S2")" "/tmp 配下"
edit "$S2" NotebookEdit "$ST/nb.ipynb" >/dev/null
report C03-tmpdir-notebook none "$(state_of "$S2")" "notebook_path も同じ"
edit "$S2" Edit "$HOME_DIR/.claude/projects/x/memory.md" >/dev/null
report C04-projects none "$(state_of "$S2")" "Claude のメモリ"
edit "$S2" Edit "$FAKE_HOME/.claude/projects/x/memory.md" "$FAKE_HOME" >/dev/null
report C05-projects-home none "$(state_of "$S2")" "一時領域の外にある HOME の配下でも対象外"
edit "$S2" Edit "$OUTSIDE" >/dev/null
report C06-outside-recorded "edited=1,blocks=0,opencode=0" "$(state_of "$S2")" "一時領域の外なら記録する"

echo "# D. OpenCode ランナーの起動形だけを編集と見なす"
launch_case() { # label expected command
  rm -f "$ST/claude-completion-gate-$D1"
  bashrun "$D1" "$3" >/dev/null
  report "$1" "$2" "$(state_of "$D1")" "$3"
}
LAUNCH="edited=1,blocks=0,opencode=1"
launch_case D01-relative "$LAUNCH" 'bash .claude/skills/opencode/scripts/run.sh --prompt "x"'
launch_case D02-home "$LAUNCH" 'bash ~/.claude/skills/opencode/scripts/run.sh --dir /x'
launch_case D03-absolute "$LAUNCH" 'bash /tmp/project/.claude/skills/opencode/scripts/run.sh'
launch_case D04-and "$LAUNCH" 'cd /tmp/x && bash .claude/skills/opencode/scripts/run.sh'
launch_case D05-semicolon "$LAUNCH" 'echo x; bash .claude/skills/opencode/scripts/run.sh'
launch_case D06-pipe "$LAUNCH" 'printf x | bash .claude/skills/opencode/scripts/run.sh'
launch_case D07-or "$LAUNCH" 'false || bash .claude/skills/opencode/scripts/run.sh'
launch_case D08-sed none 'sed -n 1,80p .claude/skills/opencode/scripts/run.sh'
launch_case D09-grep none 'grep x .claude/skills/opencode/scripts/run.sh'
launch_case D10-bash-n none 'bash -n .claude/skills/opencode/scripts/run.sh'
launch_case D11-cat none 'cat .claude/skills/opencode/scripts/run.sh'
launch_case D12-echo none 'echo bash .claude/skills/opencode/scripts/run.sh'
launch_case D13-suffix none 'bash .claude/skills/opencode/scripts/run.sh.bak note'
rm -f "$ST/claude-completion-gate-$D1"

echo "# E. このセッションが起動した OpenCode が実行中の間だけ Stop を抑止する"
# 他セッションが起動したランナーのマーカーだけでは抑止しない
edit "$S4" Edit "$OUTSIDE" >/dev/null
marker live "$LIVE_PID" "$PROJECT"
out=$(stop "$S4" "$PROJECT")
report E01-other-session-block block "$(jget "$out" '.decision // "none"')" "起動を検出していないセッションは抑止しない"
report E02-other-session-state "edited=0,blocks=1,opencode=0" "$(state_of "$S4")" ""
rm -f "$MARKER_DIR/live"
prompt "$S4" >/dev/null
# 自分が起動したランナーが実行中なら何も出さず、状態も変えない
bashrun "$S4" 'bash .claude/skills/opencode/scripts/run.sh --dir /x' >/dev/null
report E03-launch-recorded "edited=1,blocks=0,opencode=1" "$(state_of "$S4")" ""
marker live "$LIVE_PID" "$PROJECT"
out=$(stop "$S4" "$PROJECT")
report E04-suppressed "" "$out" "$out"
report E05-state-unchanged "edited=1,blocks=0,opencode=1" "$(state_of "$S4")" "完了待ちの間は状態も変えない"
out=$(stop "$S4" "")
report E06-no-cwd-block block "$(jget "$out" '.decision // "none"')" "cwd が無ければ実行中とみなさない"
report E07-opencode-reset "edited=0,blocks=1,opencode=0" "$(state_of "$S4")" "抑止しない Stop で opencode を戻す"
# マーカーの dir が別プロジェクトなら抑止しない
rm -f "$MARKER_DIR/live"
prompt "$S4" >/dev/null
bashrun "$S4" 'bash .claude/skills/opencode/scripts/run.sh' >/dev/null
marker other "$LIVE_PID" "$OTHER"
out=$(stop "$S4" "$PROJECT")
report E08-other-project-block block "$(jget "$out" '.decision // "none"')" "マーカーの dir が別プロジェクトなら止める"
# 死んだ PID のマーカーは無視する
rm -f "$MARKER_DIR/other"
prompt "$S4" >/dev/null
bashrun "$S4" 'bash .claude/skills/opencode/scripts/run.sh' >/dev/null
marker dead "$(dead_pid)" "$PROJECT"
out=$(stop "$S4" "$PROJECT")
report E09-dead-pid-block block "$(jget "$out" '.decision // "none"')" "PID が死んでいるマーカーは無視する"
# マーカーが無ければ止める
rm -f "$MARKER_DIR"/*
prompt "$S4" >/dev/null
bashrun "$S4" 'bash .claude/skills/opencode/scripts/run.sh' >/dev/null
out=$(stop "$S4" "$PROJECT")
report E10-no-marker-block block "$(jget "$out" '.decision // "none"')" ""
rm -f "$MARKER_DIR"/*

echo "# F. 上限（このターン3回）に達したら systemMessage で終了を許可する"
for n in 1 2 3; do
  edit "$S6" Edit "$OUTSIDE" >/dev/null
  out=$(stop "$S6")
  report "F0${n}-block" block "$(jget "$out" '.decision // "none"')" "$out"
done
report F03-remaining-0 yes "$(has "$(jget "$out" '.reason // ""')" '残り 0 回')" "$out"
edit "$S6" Edit "$OUTSIDE" >/dev/null
out=$(stop "$S6")
report F04-no-decision none "$(jget "$out" '.decision // "none"')" "$out"
report F05-sysmsg yes "$(has "$(jget "$out" '.systemMessage // ""')" '完了チェックの上限')" "$out"
report F06-state "edited=0,blocks=3,opencode=0" "$(state_of "$S6")" "blocks は戻さない"
out=$(stop "$S6")
report F07-next-stop-silent "" "$out" "$out"

echo "# G. UserPromptSubmit で blocks が 0 に戻る（edited はそのまま）"
edit "$S7" Edit "$OUTSIDE" >/dev/null
stop "$S7" >/dev/null
edit "$S7" Edit "$OUTSIDE" >/dev/null
stop "$S7" >/dev/null
edit "$S7" Edit "$OUTSIDE" >/dev/null
report G01-before-prompt "edited=1,blocks=2,opencode=0" "$(state_of "$S7")" ""
prompt "$S7" >/dev/null
report G02-prompt-resets-blocks "edited=1,blocks=0,opencode=0" "$(state_of "$S7")" ""
out=$(stop "$S7")
report G03-after-prompt-block block "$(jget "$out" '.decision // "none"')" "$out"
report G04-after-prompt-remaining yes "$(has "$(jget "$out" '.reason // ""')" '残り 2 回')" "$out"
prompt "$S8" >/dev/null
report G05-prompt-no-state none "$(state_of "$S8")" "状態が無ければ作らない"
# UserPromptSubmit は blocks だけ戻し、opencode（このセッションが起動したランナー）は保持する
bashrun "$S8" 'bash .claude/skills/opencode/scripts/run.sh' >/dev/null
prompt "$S8" >/dev/null
report G06-prompt-keeps-opencode "edited=1,blocks=0,opencode=1" "$(state_of "$S8")" ""

echo "# H. 異常入力（何も出さず exit 0。stderr も空）"
ef() { # label input
  local out err rc
  err="$W/err.$$"
  out=$(printf '%s' "$2" | TMPDIR="$ST" HOME="$HOME_DIR" bash "$HOOK" 2>"$err"); rc=$?
  report "$1" "0::" "$rc:$out:$(cat "$err")" "$2"
}
before=$(ls "$ST" | wc -l | tr -d ' ')
ef H01-broken '{"hook_event_name":"Stop",'
ef H02-empty ''
ef H03-no-session-edit "$(jq -cn --arg f "$OUTSIDE" '{hook_event_name:"PostToolUse",tool_name:"Edit",tool_input:{file_path:$f}}')"
ef H04-no-session-stop '{"hook_event_name":"Stop","stop_hook_active":false}'
ef H05-bad-session "$(jq -cn --arg f "$OUTSIDE" '{hook_event_name:"PostToolUse",session_id:"../x",tool_name:"Edit",tool_input:{file_path:$f}}')"
ef H06-no-path "$(jq -cn '{hook_event_name:"PostToolUse",session_id:"s",tool_name:"Edit",tool_input:{}}')"
ef H07-not-json 'hello'
ef H08-str-tool-input "$(jq -cn --arg s "$S8" '{hook_event_name:"PostToolUse",session_id:$s,tool_name:"Edit",tool_input:"x"}')"
after=$(ls "$ST" | wc -l | tr -d ' ')
report H09-no-state-created "$before" "$after" "$(ls "$ST")"
out=$(jq -cn --arg s "$S5" '{hook_event_name:"Stop",session_id:$s,stop_hook_active:false,tool_input:"garbage",tool_response:7}' | hook)
report H10-stop-garbage-tool-input "" "$out" "編集が無ければ壊れた tool_input でも何も出さない"
out=$(jq -cn --arg s "$S1" '{hook_event_name:"Stop",session_id:$s}' | TMPDIR="$ST" HOME="$HOME_DIR" PATH=/nonexistent /bin/bash "$HOOK" 2>&1); rc=$?
report H11-no-jq "0:" "$rc:$out" ""

cleanup
summary "completion-gate.sh"
