#!/usr/bin/env bash
# Claude Code / Codex から OpenCode を非対話で起動して作業を任せ、結果を要約して表示する。
# 指示は標準入力から読む。生の JSONL と stderr は ${TMPDIR:-/tmp}/claude-opencode-logs/ に残す。
# 既定モデルが利用上限（レート制限・quota）のときだけ、fallback_models の順に切り替える。
# --model を明示した場合はそのモデルだけで実行し、自動切替しない。
# --auto は ask 規則（rm・git commit・git push 等）を自動承認してしまうため、決して付けない。
set -euo pipefail

default_model="opencode/deepseek-v4.1-flash-free"
# 利用上限のときだけ、この順に1回ずつ試す（通常従量課金の opencode/deepseek-v4.1-flash は含めない）
fallback_models=(
  "opencode/deepseek-v4.1-flash-free"
  "opencode/glm-5.3-flash-free"
  "opencode-go/deepseek-v4.1-flash"
)

usage() {
  cat >&2 <<'EOF'
Usage: run.sh [--dir DIR] [--model PROVIDER/MODEL#VARIANT] [--session ID] [--title TITLE] <<'PROMPT'
...指示...
PROMPT

--model を省略した場合、利用上限（レート制限・quota）のときだけ
opencode/deepseek-v4.1-flash-free → opencode/glm-5.3-flash-free → opencode-go/deepseek-v4.1-flash
の順に1回ずつ切り替える。--model を明示した場合は自動切替しない。
EOF
  exit 2
}

need_value() {
  if [ "$#" -lt 2 ] || [ -z "$2" ]; then
    echo "エラー: $1 には値が必要です" >&2
    usage
  fi
}

dir="$PWD"
model="$default_model"
model_explicit=0
session=""
title=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir) need_value "$@"; dir="$2"; shift 2 ;;
    --model|-m) need_value "$@"; model="$2"; model_explicit=1; shift 2 ;;
    --session|-s) need_value "$@"; session="$2"; shift 2 ;;
    --title) need_value "$@"; title="$2"; shift 2 ;;
    --auto)
      echo "エラー: --auto は受け付けません（ask 規則の操作が自動承認されるため）" >&2
      exit 2
      ;;
    -h|--help) usage ;;
    *) echo "エラー: 不明な引数: $1" >&2; usage ;;
  esac
done

for cmd in opencode jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "エラー: $cmd が見つかりません" >&2
    exit 127
  fi
done

if [ ! -d "$dir" ] || ! dir="$(cd -- "$dir" && pwd -P)"; then
  echo "エラー: 作業ディレクトリが見つかりません: $dir" >&2
  exit 2
fi

if [ -t 0 ]; then
  echo "エラー: 指示を標準入力（heredoc）で渡してください" >&2
  usage
fi
prompt="$(cat)"
if [ -z "${prompt//[[:space:]]/}" ]; then
  echo "エラー: 指示が空です" >&2
  exit 2
fi

if [ -z "$title" ]; then
  # 最初の空でない行の先頭40文字（jq はコードポイント単位で切るので日本語でも壊れない）
  title="claude-code: $(printf '%s' "$prompt" | jq -Rrs '[splits("\n") | gsub("^\\s+|\\s+$"; "") | select(length > 0)][0] // "" | .[0:40]')"
fi

log_dir="${TMPDIR:-/tmp}/claude-opencode-logs"
mkdir -p "$log_dir"
stamp="$(date +%Y%m%d-%H%M%S)-$$"

# --model を明示したときは自動切替しない（既定値と同じ文字列でも明示指定を優先する）
candidates=("${fallback_models[@]}")
if [ "$model_explicit" -eq 1 ]; then
  candidates=("$model")
fi

resume_session="$session"
user_session="$session"
final_model=""
final_log_json=""
final_log_err=""
final_rc=1
attempt_count=0
attempt_model=()
attempt_status=()
attempt_log=()
attempt_errlog=()
attempt_session=()

# 利用上限だけを切替対象にする。通常の本文やツール出力に含まれる文言は見ない。
limit_jq='
  [inputs | fromjson? | select(type == "object" and .type == "error") | .error]
  | any(
      (. as $e
       | ((($e | type) == "object") and (
           (((($e.type // "") | tostring)) | test("^provider\\.(rate-limit|quota)$"))
           or (((($e.status // "") | tostring)) == "429")
           or (((($e.name // "") | tostring)) | test("^(FreeUsageLimitError|GoUsageLimitError)$"))
           or (((($e.type // "") | tostring)) | test("^(FreeUsageLimitError|GoUsageLimitError)$"))
           or (((($e.message // "") | tostring)) | test("FreeUsageLimitError|GoUsageLimitError"))
         ))
       or ((($e | type) == "string") and ((($e | tostring)) | test("FreeUsageLimitError|GoUsageLimitError")))
      )
    )
'

for candidate in "${candidates[@]}"; do
  attempt_count=$((attempt_count + 1))
  log_json="$log_dir/$stamp-attempt$attempt_count.jsonl"
  log_err="$log_dir/$stamp-attempt$attempt_count.stderr.log"

  used_session="$resume_session"
  run_prompt="$prompt"
  if [ "$attempt_count" -gt 1 ] && [ -n "$resume_session" ]; then
    # 直前の試行で得た OpenCode セッションを続ける。完了済みの操作をやり直させない
    run_prompt="前回の実行は利用上限で途中終了した。同じOpenCodeセッションの続きとして、完了済みの操作をやり直さず、未完了の作業から再開して最後まで完了すること。

$prompt"
  fi

  args=(run --format json -m "$candidate" --title "$title")
  if [ -n "$resume_session" ]; then
    args+=(--session "$resume_session")
  fi

  rc=0
  (cd -- "$dir" && opencode "${args[@]}" -- "$run_prompt" </dev/null >"$log_json" 2>"$log_err") || rc=$?

  sid="$(jq -Rrn 'first(inputs | fromjson? | .sessionID // empty)' "$log_json")"
  if [ -z "$user_session" ] && [ -n "$sid" ]; then
    # 利用者が --session を指定した場合はそのIDを維持する
    resume_session="$sid"
  fi

  has_error=0
  n_err="$(jq -Rrn '[inputs | fromjson? | select(type == "object" and .type == "error")] | length' "$log_json" "$log_err")"
  if [ "${n_err:-0}" -gt 0 ]; then
    has_error=1
  fi
  is_limit=0
  if [ "$has_error" -eq 1 ] && [ "$(jq -Rrn "$limit_jq" "$log_json" "$log_err")" = "true" ]; then
    is_limit=1
  fi
  # stderr に明確な上限エラーのクラス名だけが出る場合も切替対象にする（本文の rate limit 文言は見ない）
  if [ "$is_limit" -eq 0 ] && [ "$rc" -ne 0 ] && grep -Eq '(FreeUsageLimitError|GoUsageLimitError)' "$log_err" 2>/dev/null; then
    is_limit=1
  fi

  attempt_model[$attempt_count]="$candidate"
  attempt_log[$attempt_count]="$log_json"
  attempt_errlog[$attempt_count]="$log_err"
  attempt_session[$attempt_count]="${used_session:-なし}"

  if [ "$has_error" -eq 1 ] || [ "$rc" -ne 0 ]; then
    final_model="$candidate"
    final_log_json="$log_json"
    final_log_err="$log_err"
    if [ "$rc" -eq 0 ]; then
      final_rc=1   # 0 終了でも error イベントが残る実行は成功扱いしない
    else
      final_rc="$rc"
    fi
    if [ "$is_limit" -eq 1 ] && [ "$model_explicit" -eq 0 ] && [ "$attempt_count" -lt "${#candidates[@]}" ]; then
      attempt_status[$attempt_count]="利用上限のため次のモデルへ切替"
      continue
    fi
    if [ "$is_limit" -eq 1 ]; then
      attempt_status[$attempt_count]="利用上限のため停止"
    elif [ "$has_error" -eq 1 ]; then
      attempt_status[$attempt_count]="利用上限以外の失敗のため停止"
    else
      attempt_status[$attempt_count]="失敗のため停止"
    fi
    break
  fi

  final_model="$candidate"
  final_log_json="$log_json"
  final_log_err="$log_err"
  final_rc=0
  attempt_status[$attempt_count]="成功"
  break
done

session_id="$resume_session"
if [ -z "$session_id" ] && [ -n "$final_log_json" ]; then
  session_id="$(jq -Rrn 'first(inputs | fromjson? | .sessionID // empty)' "$final_log_json")"
fi
# セッションIDが取れない実行は、成功終了でも続行不能として非0にする
if [ -z "$session_id" ] && [ "$final_rc" -eq 0 ]; then
  final_rc=1
fi

model="$final_model"
log_json="$final_log_json"
log_err="$final_log_err"

# stderr に出る「permission requested: ...; auto-rejecting」を JSON 側の取りこぼし対策として拾う
rejected_stderr="$(sed 's/\x1b\[[0-9;]*m//g' "$log_err" | grep -E 'auto-rejecting' | sed 's/^[^a-zA-Z]*//' || true)"

echo "## OpenCode 実行結果"
echo
if [ -n "$session_id" ]; then
  echo "- セッションID: $session_id"
else
  echo "- セッションID: 取得できませんでした（--session での続行はできません）"
fi
echo "- モデル: $model"
echo "- 作業ディレクトリ: $dir"
echo "- 終了コード: $final_rc"
if [ "$model_explicit" -eq 1 ]; then
  echo "- モデル指定: 明示（自動切替なし）"
elif [ "$attempt_count" -gt 1 ]; then
  echo "- モデルの自動切替: 利用上限のため ${attempt_count} 回試行"
fi
echo

jq -Rnr --arg dir "$dir" '
  def short: tostring | gsub("[\r\n\t]+"; " ") | if length > 120 then .[0:117] + "..." else . end;
  def target:
    (.state.input // {}) as $in
    | ($in.command // $in.filePath // $in.file_path // $in.path // $in.pattern // $in.url // $in.description
       // (if ($in | length) > 0 then ($in | tojson) else "" end))
    | tostring
    # 作業ディレクトリ配下のパスは相対にして短くする
    | if startswith($dir + "/") then .[($dir | length) + 1:] else . end;
  [inputs | fromjson? | select(type == "object")] as $ev
  | [$ev[] | select(.type == "tool_use") | .part] as $tools
  | [$tools[] | select(.state.status != "completed")] as $bad
  | [$ev[] | select(.type == "error")] as $errs
  | [$ev[] | select(.type == "step_finish") | .part] as $steps
  | "### 実行したツール（\($tools | length) 件）",
    (if ($tools | length) == 0 then "（なし）"
     else
       # 読む側のトークンを抑えるため末尾20件だけ出す（失敗は下の節に全件出る）
       (if ($tools | length) > 20 then "（先頭 \(($tools | length) - 20) 件は省略）" else empty end),
       ($tools | to_entries | .[-20:][] | "\(.key + 1). [\(.value.state.status // "?")] \(.value.tool // "?"): \(.value | target | short)")
     end),
    "",
    "### 拒否された権限・失敗したツール",
    (if ($bad | length) == 0 and ($errs | length) == 0 then "（なし）"
     else
       ($bad[] | "- [\(.state.status // "?")] \(.tool // "?"): \(. | target | short) — \((.state.error // "") | short)"),
       ($errs[] | "- [error イベント] \((.error // .part // .) | tojson | short)")
     end),
    "",
    "### 最終回答",
    ([$ev[] | select(.type == "text") | .part.text // empty] | if length == 0 then "（テキスト応答なし）" else join("\n\n") end),
    "",
    "### コストとトークン",
    # 最終ステップの step_finish は JSONL に出ないため、この合計は実際より少なめになる
    "- この実行（JSONL の step_finish 合計・最終ステップ分を含まない）: $\(([$steps[] | .cost // 0] | add // 0) * 1000000 | round / 1000000)",
    ( [$steps[] | .tokens // {}] as $t
      | "  - トークン: input \([$t[] | .input // 0] | add // 0) / output \([$t[] | .output // 0] | add // 0) / reasoning \([$t[] | .reasoning // 0] | add // 0) / cache read \([$t[] | .cache.read // 0] | add // 0) / cache write \([$t[] | .cache.write // 0] | add // 0)" )
' "$log_json"

if [ -n "$session_id" ]; then
  # 正確な値はセッション累計として session export の info から取る（本文は保存しない）
  session_total="$(cd -- "$dir" && timeout 60 opencode session export "$session_id" </dev/null 2>/dev/null | jq -r '
    .info | select(.cost != null)
    | "- セッション累計（session export）: $\(.cost * 1000000 | round / 1000000)\n  - トークン: input \(.tokens.input // 0) / output \(.tokens.output // 0) / reasoning \(.tokens.reasoning // 0) / cache read \(.tokens.cache.read // 0) / cache write \(.tokens.cache.write // 0)"
  ' 2>/dev/null || true)"
  if [ -n "$session_total" ]; then
    printf '%s\n' "$session_total"
  else
    echo "- セッション累計: 取得できませんでした（opencode session export $session_id で確認）"
  fi
else
  echo "- セッション累計: セッションIDがないため取得できませんでした"
fi

if [ -n "$rejected_stderr" ]; then
  echo
  echo "### stderr の権限拒否"
  printf '%s\n' "$rejected_stderr" | sed 's/^/- /'
fi

echo
echo "### モデル試行"
for i in $(seq 1 "$attempt_count"); do
  echo "- $i. ${attempt_model[$i]}（セッション: ${attempt_session[$i]}）: ${attempt_status[$i]}"
  echo "  - JSONL: ${attempt_log[$i]}"
  echo "  - stderr: ${attempt_errlog[$i]}"
done

echo
echo "### ログ（最終試行）"
echo "- JSONL: $log_json"
echo "- stderr: $log_err"
echo
echo "### 続行方法"
if [ -n "$session_id" ]; then
  printf "bash ~/.claude/skills/opencode/scripts/run.sh --dir %q --session %s <<'EOF'\n...追加の指示...\nEOF\n" "$dir" "$session_id"
  if [ "$model_explicit" -eq 1 ]; then
    echo "（同じモデルで続けるなら --model $(printf '%q' "$model") も付ける）"
  fi
else
  echo "- セッションIDが取得できなかったため、--session での続行案内はありません。上の試行ログを確認してください。"
fi

exit "$final_rc"
