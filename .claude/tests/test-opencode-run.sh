#!/bin/bash
# 共有 OpenCode ランナー（.claude/skills/opencode/scripts/run.sh）のモデル自動切替テスト
# 実行: bash .claude/tests/test-opencode-run.sh（run.sh からも呼ばれる）
# PATH 先頭のスタブ opencode で、実課金・ネットワークなしに挙動だけを検査する
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
REPO_DIR="$(cd "$TESTS_DIR/../.." && pwd)"
RUNNER="$REPO_DIR/.claude/skills/opencode/scripts/run.sh"
STUB_DIR="$T/opencode-stub"
STATE="$T/opencode-state"
PROJECT="$T/opencode-project"
mkdir -p "$STUB_DIR" "$PROJECT"

cat > "$STUB_DIR/opencode" <<'STUB'
#!/usr/bin/env bash
set -u
state="${STUB_STATE:?}"
if [ "${1:-}" = "session" ]; then
  exit 0
fi
model=""
session=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --format|--title) shift 2 ;;
    -m|--model) model="${2-}"; shift 2 ;;
    --session|-s) session="${2-}"; shift 2 ;;
    --) shift; break ;;
    *) shift ;;
  esac
done
prompt="${1-}"
printf '%s\n' "$model" >> "$state/models"
printf '%s\n' "$session" >> "$state/sessions"
printf '%s\n' "$prompt" >> "$state/prompts"
n=$(wc -l < "$state/models" | tr -d ' ')
sid="ses_stub_$n"
in_list() { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac; }
emit_session() {
  in_list "${STUB_NO_SESSION_MODELS:-}" "$model" && return 0
  printf '{"sessionID":"%s"}\n' "$sid"
}
emit_text() { printf '{"type":"text","part":{"text":"%s"}}\n' "$1"; }

if in_list "${STUB_LIMIT_MODELS:-}" "$model"; then
  emit_session
  printf '%s\n' '{"type":"error","error":{"type":"provider.quota","status":429,"message":"FreeUsageLimitError: usage limit reached"}}'
  in_list "${STUB_ZERO_RC_MODELS:-}" "$model" && exit 0
  exit 1
fi
if in_list "${STUB_AUTH_MODELS:-}" "$model"; then
  emit_session
  printf '%s\n' '{"type":"error","error":{"type":"provider.auth","status":401,"message":"unauthorized"}}'
  exit 1
fi
if in_list "${STUB_REGION_MODELS:-}" "$model"; then
  emit_session
  printf '%s\n' '{"type":"error","error":{"type":"provider.region","status":403,"message":"Global region not allowed"}}'
  exit 1
fi
if in_list "${STUB_TOOL_MODELS:-}" "$model"; then
  emit_session
  printf '%s\n' '{"type":"error","error":{"type":"tool","message":"tool failed"}}'
  exit 0
fi
emit_session
if in_list "${STUB_BODY_QUOTA_MODELS:-}" "$model"; then
  emit_text "本文中の rate limit / quota / FreeUsageLimitError は無関係"
fi
emit_text "完了"
exit 0
STUB
chmod +x "$STUB_DIR/opencode"
export PATH="$STUB_DIR:$PATH"
export STUB_STATE="$STATE"

INPUT_PROMPT="指示本文"
ENVS=()
OUT=""
ERR=""
RC=0

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
line_at() { sed -n "${1}p" "$2"; }
count_lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
envs() { ENVS=("$@"); }
run_runner() { # name [run.sh の引数...]
  local name="$1"; shift
  rm -rf "$STATE" "$T/claude-opencode-logs"
  mkdir -p "$STATE"
  OUT="$T/$name.out"
  ERR="$T/$name.err"
  printf '%s\n' "$INPUT_PROMPT" | env "${ENVS[@]}" bash "$RUNNER" --dir "$PROJECT" --title 'test: opencode-run' "$@" >"$OUT" 2>"$ERR"
  RC=$?
  ENVS=()
}
attempt_logs() { find "$T/claude-opencode-logs" -name '*-attempt*.jsonl' 2>/dev/null | wc -l | tr -d ' '; }
attempt_errlogs() { find "$T/claude-opencode-logs" -name '*-attempt*.stderr.log' 2>/dev/null | wc -l | tr -d ' '; }

DEFAULT="opencode/deepseek-v4.1-flash-free"
GLM="opencode/glm-5.3-flash-free"
GO="opencode-go/deepseek-v4.1-flash"

echo "# A. 既定モデルの実行と順次切替"
envs
run_runner A01-default-success
report A01-rc 0 "$RC" "$(cat "$ERR")"
report A01-one-model 1 "$(count_lines "$STATE/models")" "$(cat "$STATE/models" 2>/dev/null)"
report A01-model "$DEFAULT" "$(line_at 1 "$STATE/models")" ""
report A01-output yes "$(has "$(cat "$OUT")" "- モデル: $DEFAULT")" ""

envs "STUB_LIMIT_MODELS=$DEFAULT"
run_runner A02-limit-to-glm
report A02-rc 0 "$RC" "$(cat "$ERR")"
report A02-two-models 2 "$(count_lines "$STATE/models")" "$(cat "$STATE/models")"
report A02-second-model "$GLM" "$(line_at 2 "$STATE/models")" ""
report A02-switch-note yes "$(has "$(cat "$OUT")" '利用上限のため次のモデルへ切替')" ""
report A02-final-model yes "$(has "$(cat "$OUT")" "- モデル: $GLM")" ""

envs "STUB_LIMIT_MODELS=$DEFAULT $GLM"
run_runner A03-limit-to-go
report A03-rc 0 "$RC" "$(cat "$ERR")"
report A03-three-models 3 "$(count_lines "$STATE/models")" "$(cat "$STATE/models")"
report A03-third-model "$GO" "$(line_at 3 "$STATE/models")" ""
report A03-final-model yes "$(has "$(cat "$OUT")" "- モデル: $GO")" ""

envs "STUB_LIMIT_MODELS=$DEFAULT $GLM $GO"
run_runner A04-all-limit
report A04-nonzero yes "$(if [ "$RC" -ne 0 ]; then echo yes; else echo no; fi)" "rc=$RC"
report A04-three-models 3 "$(count_lines "$STATE/models")" "$(cat "$STATE/models")"
report A04-stop-note yes "$(has "$(cat "$OUT")" '利用上限のため停止')" ""
report A04-final-go yes "$(has "$(cat "$OUT")" "- モデル: $GO")" ""

echo "# B. 明示 --model / -m は自動切替しない"
envs "STUB_LIMIT_MODELS=$DEFAULT"
run_runner B01-explicit-same-model --model "$DEFAULT"
report B01-nonzero yes "$(if [ "$RC" -ne 0 ]; then echo yes; else echo no; fi)" "rc=$RC"
report B01-one-model 1 "$(count_lines "$STATE/models")" "$(cat "$STATE/models")"
report B01-no-autoswitch yes "$(has "$(cat "$OUT")" '明示（自動切替なし）')" ""

envs "STUB_LIMIT_MODELS=$DEFAULT"
run_runner B02-short-m -m "$GLM"
report B02-rc 0 "$RC" "$(cat "$ERR")"
report B02-one-model 1 "$(count_lines "$STATE/models")" "$(cat "$STATE/models")"
report B02-model "$GLM" "$(line_at 1 "$STATE/models")" ""

echo "# C. 利用上限以外の失敗は切替えない"
envs "STUB_AUTH_MODELS=$DEFAULT"
run_runner C01-auth
report C01-nonzero yes "$(if [ "$RC" -ne 0 ]; then echo yes; else echo no; fi)" "rc=$RC"
report C01-one-model 1 "$(count_lines "$STATE/models")" "$(cat "$STATE/models")"
report C01-stop-note yes "$(has "$(cat "$OUT")" '利用上限以外の失敗のため停止')" ""

envs "STUB_LIMIT_MODELS=$DEFAULT $GLM" "STUB_REGION_MODELS=$GO"
run_runner C02-go-region
report C02-nonzero yes "$(if [ "$RC" -ne 0 ]; then echo yes; else echo no; fi)" "rc=$RC"
report C02-three-models 3 "$(count_lines "$STATE/models")" "$(cat "$STATE/models")"
report C02-stops-at-go "$GO" "$(line_at 3 "$STATE/models")" ""

envs "STUB_TOOL_MODELS=$DEFAULT"
run_runner C03-tool-error-zero-exit
report C03-nonzero yes "$(if [ "$RC" -ne 0 ]; then echo yes; else echo no; fi)" "rc=$RC（CLIは0終了）"
report C03-one-model 1 "$(count_lines "$STATE/models")" "$(cat "$STATE/models")"

envs "STUB_BODY_QUOTA_MODELS=$DEFAULT"
run_runner C04-body-quota-text
report C04-rc 0 "$RC" "$(cat "$ERR")"
report C04-one-model 1 "$(count_lines "$STATE/models")" "$(cat "$STATE/models")"
report C04-answer yes "$(has "$(cat "$OUT")" 'FreeUsageLimitError')" ""

echo "# D. セッションの引継ぎとログ"
envs "STUB_LIMIT_MODELS=$DEFAULT"
run_runner D01-session-continue
report D01-rc 0 "$RC" "$(cat "$ERR")"
report D01-second-session ses_stub_1 "$(line_at 2 "$STATE/sessions")" ""
report D01-continue-prompt yes "$(has "$(cat "$STATE/prompts")" '未完了の作業から再開')" ""
report D01-original-prompt 2 "$(grep -c "^$INPUT_PROMPT$" "$STATE/prompts")" "継続プロンプトにも元の指示を含める"
report D01-attempt-logs 2 "$(attempt_logs)" ""
report D01-attempt-errlogs 2 "$(attempt_errlogs)" ""

envs "STUB_LIMIT_MODELS=$DEFAULT" "STUB_NO_SESSION_MODELS=$DEFAULT"
run_runner D02-no-session-limit
report D02-rc 0 "$RC" "$(cat "$ERR")"
report D02-two-models 2 "$(count_lines "$STATE/models")" "$(cat "$STATE/models")"
report D02-no-session-on-retry "" "$(line_at 2 "$STATE/sessions")" ""
report D02-no-continue-prompt no "$(has "$(cat "$STATE/prompts")" '未完了の作業から再開')" ""

envs "STUB_LIMIT_MODELS=$DEFAULT"
run_runner D03-user-session --session ses_user
report D03-rc 0 "$RC" "$(cat "$ERR")"
report D03-keeps-user-session ses_user "$(line_at 2 "$STATE/sessions")" ""

envs "STUB_LIMIT_MODELS=$DEFAULT $GLM $GO" "STUB_NO_SESSION_MODELS=$DEFAULT $GLM $GO"
run_runner D04-all-limit-no-session
report D04-nonzero yes "$(if [ "$RC" -ne 0 ]; then echo yes; else echo no; fi)" "rc=$RC"
report D04-three-models 3 "$(count_lines "$STATE/models")" "$(cat "$STATE/models")"
report D04-no-session yes "$(has "$(cat "$OUT")" 'セッションID: 取得できませんでした')" ""
report D04-final-go yes "$(has "$(cat "$OUT")" "- モデル: $GO")" ""
report D04-switch-reason yes "$(has "$(cat "$OUT")" '利用上限のため次のモデルへ切替')" ""
report D04-stop-reason yes "$(has "$(cat "$OUT")" '利用上限のため停止')" ""
report D04-trial-1 yes "$(has "$(cat "$OUT")" "1. $DEFAULT")" ""
report D04-trial-2 yes "$(has "$(cat "$OUT")" "2. $GLM")" ""
report D04-trial-3 yes "$(has "$(cat "$OUT")" "3. $GO")" ""
report D04-attempt-logs 3 "$(attempt_logs)" ""
report D04-attempt-errlogs 3 "$(attempt_errlogs)" ""
report D04-jsonl-lines 4 "$(grep -c 'JSONL: ' "$OUT")" "試行3件＋最終ログ"
report D04-stderr-lines 4 "$(grep -c 'stderr: ' "$OUT")" "試行3件＋最終ログ"
report D04-no-continue-hint yes "$(has "$(cat "$OUT")" '続行案内はありません')" ""

envs "STUB_AUTH_MODELS=$DEFAULT" "STUB_NO_SESSION_MODELS=$DEFAULT"
run_runner D05-auth-no-session
report D05-nonzero yes "$(if [ "$RC" -ne 0 ]; then echo yes; else echo no; fi)" "rc=$RC"
report D05-one-model 1 "$(count_lines "$STATE/models")" "$(cat "$STATE/models")"
report D05-no-session yes "$(has "$(cat "$OUT")" 'セッションID: 取得できませんでした')" ""
report D05-final-model yes "$(has "$(cat "$OUT")" "- モデル: $DEFAULT")" ""
report D05-stop-reason yes "$(has "$(cat "$OUT")" '利用上限以外の失敗のため停止')" ""
report D05-attempt-logs 1 "$(attempt_logs)" ""
report D05-log-in-output yes "$(has "$(cat "$OUT")" 'JSONL: ')" ""
report D05-no-session-total yes "$(has "$(cat "$OUT")" 'セッションIDがないため取得できませんでした')" ""

echo "# E. 既定の禁止事項"
envs
run_runner E01-auto-rejected --auto
report E01-rc 2 "$RC" "$(cat "$ERR")"
report E01-no-run 0 "$(count_lines "$STATE/models")" "$(cat "$STATE/models" 2>/dev/null)"
report E01-message yes "$(has "$(cat "$ERR")" '--auto は受け付けません')" "$(cat "$ERR")"

summary "opencode-run"
