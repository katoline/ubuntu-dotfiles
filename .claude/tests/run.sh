#!/bin/bash
# .claude/ 配下の検証をまとめて実行する（sudo 不要）
#   bash .claude/tests/run.sh
# 内容: 設定 JSON（settings.json・opencode/・codex/・devin/）の構文、シェルスクリプトの構文、
#       hooks/lib/*.awk の構文、SKILL.md / agents の frontmatter、
#       settings.json のフック・statusLine の登録元検査、
#       フックと共通指示の配布、ホーム側の CLI 設定マージのテスト
#       （pr-mode / guard-destructive / verify-gate / validate-claude-config / ai-install / codex-guard / codex-harness / grok-compat / git-pull / cli-config / opencode-permissions / opencode-harness。
#         各テストの summary 行も検査する）
# 環境変数 HOOKS_DIR を指定すると、別の場所にあるフック（作業コピー）をテストできる
# CLI 設定マージは python3 に tomlkit が無ければ flake の共通 Python を Nix で取得する（初回は時間がかかる）。
# CLI_CONFIG_PYTHON で Python を指定した場合は自動取得しない。
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_DIR="$(cd "$CLAUDE_DIR/.." && pwd)"
HOOKS_DIR="${HOOKS_DIR:-$CLAUDE_DIR/hooks}"
export HOOKS_DIR
status=0

echo "== 構文チェック =="
# 各CLIの設定 JSON（コメント不可の素の JSON だけを対象にする）
for j in "$CLAUDE_DIR/settings.json" "$REPO_DIR"/opencode/*.json "$REPO_DIR/codex/hooks.json" "$REPO_DIR/devin/config.json"; do
  [ -f "$j" ] || continue
  if jq empty "$j" 2>/dev/null; then echo "  ✓ ${j#$REPO_DIR/}"; else echo "  ✗ ${j#$REPO_DIR/}: JSON が不正"; status=1; fi
done
for f in "$HOOKS_DIR"/*.sh "$HOOKS_DIR"/lib/*.sh "$CLAUDE_DIR/setup.sh" "$CLAUDE_DIR"/skills/*/scripts/*.sh "$TESTS_DIR"/*.sh \
  "$REPO_DIR/bootstrap.sh" "$REPO_DIR"/ai/*.sh "$REPO_DIR"/codex/hooks/*.sh "$REPO_DIR/opencode/hooks/*.sh" "$REPO_DIR/opencode/setup.sh" "$HOOKS_DIR"/lib/*.awk; do
  [ -f "$f" ] || continue
  case "$f" in
    # awk は -f で読み込ませるだけで構文検査になる（/dev/null 入力なので本体は動かない）
    *.awk) if awk -f "$f" /dev/null >/dev/null 2>&1; then echo "  ✓ $(basename "$f")"; else echo "  ✗ $f: 構文エラー"; awk -f "$f" /dev/null >/dev/null; status=1; fi ;;
    *) if bash -n "$f" 2>/dev/null; then echo "  ✓ $(basename "$f")"; else echo "  ✗ $f: 構文エラー"; bash -n "$f"; status=1; fi ;;
  esac
done
# OpenCode plugin の JS 構文（V2 は Node/Bun で直接読み込むため、構文だけでも run.sh で検査する）
for f in "$REPO_DIR"/opencode/plugins/*.js "$TESTS_DIR"/*.mjs; do
  [ -f "$f" ] || continue
  if node --check "$f" 2>/dev/null; then echo "  ✓ ${f#$REPO_DIR/}"
  else echo "  ✗ ${f#$REPO_DIR/}: JS 構文エラー"; node --check "$f"; status=1; fi
done
# frontmatter は validate-claude-config.sh と同じ条件で見る（1 行目の --- ／ 閉じ --- ／ name: ／ description:）
for f in "$CLAUDE_DIR"/skills/*/SKILL.md "$CLAUDE_DIR"/agents/*.md "$REPO_DIR"/codex/skills/*/SKILL.md; do
  [ -f "$f" ] || continue
  fm=$(awk 'NR>1 && /^---$/{exit} NR>1{print}' "$f")
  if [ "$(sed -n '1p' "$f")" = '---' ] && [ "$(sed -n '2,$p' "$f" | grep -c '^---$')" -ge 1 ] \
    && printf '%s\n' "$fm" | grep -q '^name:' && printf '%s\n' "$fm" | grep -q '^description:'; then
    echo "  ✓ ${f#$REPO_DIR/}"
  else
    echo "  ✗ ${f#$REPO_DIR/}: frontmatter（1 行目の --- / 閉じる --- / name: / description:）が不正"; status=1
  fi
done

# settings.json のフック・statusLine の登録元検査。外部アプリが ~/.claude/settings.json（=このリポジトリ）へ
# 黙ってフックを書き込んでも、validate-claude-config.sh は Claude 自身の編集しか見ないため気づけない。
# 許すのは「bash $HOME/.claude/hooks/<実在するスクリプト>」と、下の許可リストに載せた外部ツールだけ。
# 新しいツールを採用するときは、中身を確認してから許可リストに足す。
# 外部ツールはコマンドへの部分一致で許す（Orca は版が上がるとコマンド文が変わるため完全一致にしない）。
# 想定する脅威は「外部アプリが黙って書き込む」ことで、settings.json を意図的に改ざんできる相手は対象外
ALLOWED_EXTERNAL_HOOKS='/.orca/agent-hooks/claude-hook'            # Orca（エージェント管理アプリ）。Orca 外では何もしない
ALLOWED_EXTERNAL_STATUSLINE='/.orca/agent-hooks/claude-statusline'  # 同上
SETTINGS="$CLAUDE_DIR/settings.json"
# jq が失敗した（hooks の構造が壊れている・式の誤り）ときは「何も見つからなかった」と区別して失敗にする
src_err=""
unknown=$(jq -r --arg ext "$ALLOWED_EXTERNAL_HOOKS" '
  .hooks // {} | to_entries[] | .key as $e | .value[] | (.matcher // "") as $m | .hooks[]
  | select(((.type == "command") and ((.command // "") | test("^bash \\$HOME/\\.claude/hooks/[A-Za-z0-9_.-]+\\.sh$"))) | not)
  | select(((.type == "command") and ((.command // "") | contains($ext))) | not)
  | "    \($e)(\($m)): type=\(.type) \((.command // .url // .prompt // "") | tostring | .[0:80])"' "$SETTINGS" 2>&1) \
  || { src_err="hooks の走査"; unknown=""; }
cmds=$(jq -r '.hooks // {} | .[][] | .hooks[] | select(.type == "command") | .command // ""' "$SETTINGS" 2>&1) \
  || { src_err="${src_err:+${src_err}・}フックスクリプトの列挙"; cmds=""; }
missing=$(printf '%s\n' "$cmds" | sed -n 's|^bash \$HOME/\.claude/hooks/\([A-Za-z0-9_.-]*\.sh\)$|\1|p' | sort -u \
  | while IFS= read -r h; do [ -f "$CLAUDE_DIR/hooks/$h" ] || printf '    hooks/%s\n' "$h"; done)
sl=$(jq -r --arg ext "$ALLOWED_EXTERNAL_STATUSLINE" \
  '.statusLine // empty | select((.command // "") | contains($ext) | not) | "    \((.command // "") | .[0:80])"' "$SETTINGS" 2>&1) \
  || { src_err="${src_err:+${src_err}・}statusLine の検査"; sl=""; }
if [ -n "$src_err" ]; then
  echo "  ✗ settings.json の登録元検査で jq が失敗しました（${src_err}。hooks / statusLine の構造が壊れていないか確認する）"; status=1
elif [ -z "$unknown$missing$sl" ]; then
  echo "  ✓ settings.json のフック・statusLine はすべて既知の登録元"
else
  status=1
  [ -z "$unknown" ] || printf '  ✗ settings.json に登録元が不明なフックがあります（外部ツールの書き込みなら中身を確認し、採用するなら run.sh の許可リストに足す）:\n%s\n' "$unknown"
  [ -z "$missing" ] || printf '  ✗ settings.json が参照するフックスクリプトが存在しません:\n%s\n' "$missing"
  [ -z "$sl" ] || printf '  ✗ settings.json の statusLine が許可リストにない登録元です:\n%s\n' "$sl"
fi

echo "== フックのテスト（HOOKS_DIR=${HOOKS_DIR}）=="
out="${TMPDIR:-/tmp}/claude-tests-$$.out"   # 一時出力はリポジトリ内に作らない
# テストがフックの本物のログ（~/.claude/pr-mode.log）に書き込まないことを、前後の行数で検査する
# （test-pr-mode.sh は HOME を一時ディレクトリに向ける。別セッションのフックが同時に書くと誤検出になりうる）
PRLOG="$HOME/.claude/pr-mode.log"
log_lines() { if [ -f "$PRLOG" ]; then wc -l < "$PRLOG" | tr -d ' '; else echo 0; fi; }
log_before=$(log_lines)
for t in "$TESTS_DIR"/test-*.sh; do
  bash "$t" >"$out" 2>&1 || { status=1; }
  grep -E '^  [✓✗]' "$out"; grep -E '^  NG' "$out"
  # summary 行がちょうど 1 行あることを要求する（summary の呼び忘れや、summary の後ろに
  # ケースを足したファイルを「出力が無いから成功」と見なさないため）
  n=$(grep -cE '^  [✓✗]' "$out")
  if [ "$n" -ne 1 ]; then
    echo "  ✗ $(basename "$t"): summary 行が ${n} 行（末尾で summary を 1 回だけ呼ぶこと）"; status=1
    if [ -s "$out" ]; then echo "    --- 出力の末尾 ---"; tail -5 "$out" | sed 's/^/    /'; else echo "    （出力なし）"; fi
  fi
done
rm -f "$out"
log_after=$(log_lines)
if [ "$log_after" -eq "$log_before" ]; then
  echo "  ✓ ~/.claude/pr-mode.log は未変更（テストは本物のログに書かない）"
else
  echo "  ✗ テストが ~/.claude/pr-mode.log に $((log_after - log_before)) 行書き込んだ（HOME の隔離が効いていない）"; status=1
fi

if [ "$status" -eq 0 ]; then echo "すべて通過"; else echo "失敗があります" >&2; fi
exit "$status"
