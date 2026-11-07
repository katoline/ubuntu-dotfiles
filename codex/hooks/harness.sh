#!/bin/bash
# Claude の事故防止・dotfiles 検証ゲート・完了チェックゲートを Codex のイベントへ接続する。
# ask は承認情報にかかわらず拒否し、ユーザーの手動実行へ導く。deny は常に維持する。
exec 2>/dev/null
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
printf '%s' "$input" | jq -e 'type == "object"' >/dev/null || exit 0
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "$SELF")/../.." && pwd -P)" || exit 0
fields=$(printf '%s' "$input" | jq -r '
  (.tool_input | if type == "object" then . else {} end) as $ti
  | [(.hook_event_name // ""), (.session_id // ""), (.tool_name // ""), (.cwd // ""),
     ($ti.command // $ti.cmd // "" | if type == "array" then (if length >= 3 and (.[0] | test("(^|/)(bash|sh|zsh)$")) and (.[1] | test("^-[A-Za-z]*c[A-Za-z]*$")) then .[2] else join(" ") end) elif type == "string" then . else "" end)]
  | @sh') || exit 0
eval "set -- $fields" || exit 0
event="$1" session="$2" tool="$3" cwd="$4" cmd="$5"
[[ "$session" =~ ^[A-Za-z0-9._-]+$ ]] || exit 0
# Claude セッションと状態ファイルを共用しない。
normalized=$(printf '%s' "$input" | jq -c --arg s "codex-$session" --arg c "$cmd" '
  .session_id=$s | .tool_input=(.tool_input // {}) | .tool_input.command=$c') || exit 0
gate() { printf '%s' "$1" | bash "$ROOT/.claude/hooks/verify-gate.sh"; }
# 完了チェックは状態の記録だけ。PostToolUse・UserPromptSubmit の出力は Codex の文脈に入るため捨てる。
complete() { printf '%s' "$1" | bash "$ROOT/.claude/hooks/completion-gate.sh" >/dev/null; }
case "$event" in
  UserPromptSubmit) complete "$normalized" ;;
  PreToolUse)
    case "$tool" in Bash | shell | exec_command) ;; *) exit 0 ;; esac
    normalized=$(printf '%s' "$normalized" | jq -c '.tool_name="Bash"')
    result=$(printf '%s' "$normalized" | bash "$ROOT/.claude/hooks/guard-destructive.sh")
    [ -n "$result" ] || exit 0
    decision=$(printf '%s' "$result" | jq -r '.hookSpecificOutput.permissionDecision // ""')
    case "$decision" in
      deny) printf '%s\n' "$result" ;;
      ask)
        reason=$(printf '%s' "$result" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')
        guidance='実行前にユーザーの確認が必要です。承認情報の有無にかかわらず、エージェントからこの操作は実行できません。対象のコマンドと理由を示し、ユーザーに手動実行を依頼してください。別の書き方やツールで迂回しないでください。'
        jq -cn --arg r "$reason
$guidance" \
          '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' ;;
    esac ;;
  PostToolUse)
    # OpenCode ランナーの起動は継続中・失敗でも記録する（委譲先の編集はフックに見えず、実行中は Stop を抑止したい）。
    case "$tool" in
      Bash | shell | exec_command) complete "$(printf '%s' "$normalized" | jq -c '.tool_name="Bash"')" ;;
    esac
    # 結果が継続中・失敗の場合は、成功出力の断片で検証済みにしない。
    printf '%s' "$input" | jq -e '
      .tool_response | (if type == "string" then (fromjson? // .) else . end)
      | if type == "object" then
        ((has("exit_code") | not) or .exit_code == 0) and (.error == null)
        and (.success != false) and (.session_id == null)
      else true end' >/dev/null || exit 0
    case "$tool" in
      apply_patch)
        # apply_patch の通常のパッチヘッダーを Edit へ変換する。移動先も検証対象。
        while IFS= read -r path; do
          [ -n "$path" ] || continue
          case "$path" in /*) ;; *) path="$cwd/$path" ;; esac
          edit=$(printf '%s' "$normalized" | jq -c --arg f "$path" '.tool_name="Edit" | .tool_input={file_path:$f}')
          gate "$edit"
          complete "$edit"
        done < <(printf '%s\n' "$cmd" | sed -nE 's/^\*\*\* (Add File|Update File|Delete File|Move to): (.*)$/\2/p') ;;
      Edit | Write | NotebookEdit)
        gate "$normalized"
        complete "$normalized" ;;
      Bash | shell | exec_command)
        normalized=$(printf '%s' "$normalized" | jq -c '
          .tool_name="Bash" | .tool_response={stdout:(.tool_response |
            if type == "object" then (.stdout // .output // "")
            elif type == "string" then (fromjson? // . | if type == "object" then (.stdout // .output // "") else . end)
            else "" end)}') || exit 0
        gate "$normalized" ;;
    esac ;;
  Stop)
    # Stop の出力は JSON 1 個だけ。検証ゲートが何か返したら、完了チェックは状態を残したまま次の Stop に回す。
    result=$(gate "$normalized")
    [ -n "$result" ] || result=$(printf '%s' "$normalized" | bash "$ROOT/.claude/hooks/completion-gate.sh")
    [ -z "$result" ] || printf '%s\n' "$result" ;;
esac
exit 0
