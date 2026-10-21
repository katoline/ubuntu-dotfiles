#!/bin/bash
# ai/install.sh（全CLI共通のグローバル指示の配布）のテスト
# 実行: bash .claude/tests/test-ai-install.sh（run.sh からも呼ばれる）
# 一時ディレクトリを HOME に見立てて配布させ、リンク・連結生成・冪等性・旧構成の片付けを検査する
# （リポジトリ側の ai/*.md は読むだけ。実際の ~/ には触らない）
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
AI_DIR="$(cd "$TESTS_DIR/../../ai" && pwd)"
INSTALL="$AI_DIR/install.sh"
H="$T/claude-ai-install-home.$$"
cleanup() { rm -rf "$H"; }
trap cleanup EXIT
cleanup
mkdir -p "$H"

run_install() { HOME="$H" bash "$INSTALL" >"$H/out.txt" 2>"$H/err.txt"; }

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
link_of() { if [ -L "$1" ]; then readlink "$1"; else echo "not-a-link"; fi; }
body_of() { if [ -f "$1" ]; then cat "$1"; else echo ""; fi; }

echo "# A. 初回配布"
run_install; rc=$?
report A01-exit-0 0 "$rc" "$(cat "$H/err.txt" 2>/dev/null)"
report A02-claude-md-link "$AI_DIR/core.md" "$(link_of "$H/.claude/CLAUDE.md")" ""
report A03-claude-rules-link "$AI_DIR/claude.md" "$(link_of "$H/.claude/rules/claude.md")" ""
for cli in opencode grok codex devin; do
  case "$cli" in
    opencode) dest="$H/.config/opencode/AGENTS.md" ;;
    grok) dest="$H/.grok/AGENTS.md" ;;
    codex) dest="$H/.codex/AGENTS.md" ;;
    devin) dest="$H/.config/devin/AGENTS.md" ;;
  esac
  b=$(body_of "$dest")
  report "A04-${cli}-core" yes "$(has "$b" '# レビューの範囲')" "$dest"
  report "A05-${cli}-delta" yes "$(has "$b" "$(grep -m1 '^# ' "$AI_DIR/$cli.md")")" "$dest"
  report "A06-${cli}-generated-note" yes "$(has "$b" '自動生成ファイル（編集しない）')" "$dest"
  report "A07-${cli}-is-file" no "$(if [ -L "$dest" ]; then echo yes; else echo no; fi)" "$dest"
done
# 共通コアは 1 か所だけ: 生成ファイルに「# 言語」が 2 回出ない（core と差分の二重連結の検出）
n=$(grep -c '^# 言語$' "$H/.grok/AGENTS.md")
report A08-core-once 1 "$n" ""

echo "# B. 冪等性（内容が同じなら書き換えない）"
before=$(stat -c %Y "$H/.codex/AGENTS.md" 2>/dev/null || stat -f %m "$H/.codex/AGENTS.md")
sleep 1
run_install
after=$(stat -c %Y "$H/.codex/AGENTS.md" 2>/dev/null || stat -f %m "$H/.codex/AGENTS.md")
report B01-mtime-kept "$before" "$after" "内容が同じなら mtime を動かさない"
report B02-no-change-mark yes "$(has "$(cat "$H/out.txt")" '= ~/.codex/AGENTS.md')" "$(cat "$H/out.txt")"

echo "# C. 旧構成・実体ファイルの片付け"
# CLAUDE.md がリンクでなく実体ファイルに戻っていたら .bak へ退避してリンクし直す
rm -f "$H/.claude/CLAUDE.md"; printf 'ローカルで書き換えた内容\n' > "$H/.claude/CLAUDE.md"
run_install
report C01-relinked "$AI_DIR/core.md" "$(link_of "$H/.claude/CLAUDE.md")" ""
report C02-backup-kept yes "$(if [ -f "$H/.claude/CLAUDE.md.bak" ]; then echo yes; else echo no; fi)" ""
# 旧構成（~/.grok/AGENTS.md がリポジトリの grok/AGENTS.md へのリンク）は実体ファイルに置き換える
rm -f "$H/.grok/AGENTS.md"; ln -s "$AI_DIR/grok.md" "$H/.grok/AGENTS.md"
run_install
report C03-grok-link-replaced no "$(if [ -L "$H/.grok/AGENTS.md" ]; then echo yes; else echo no; fi)" ""
report C04-grok-has-core yes "$(has "$(body_of "$H/.grok/AGENTS.md")" '# レビューの範囲')" ""
# 旧構成（リポジトリの opencode/AGENTS.md へのリンク）は実体ファイルに置き換える
rm -f "$H/.config/opencode/AGENTS.md"; ln -s "$AI_DIR/opencode.md" "$H/.config/opencode/AGENTS.md"
run_install
report C05-opencode-link-replaced no "$(if [ -L "$H/.config/opencode/AGENTS.md" ]; then echo yes; else echo no; fi)" ""
report C06-opencode-has-core yes "$(has "$(body_of "$H/.config/opencode/AGENTS.md")" '# レビューの範囲')" ""
report C07-opencode-has-delta yes "$(has "$(body_of "$H/.config/opencode/AGENTS.md")" "$(grep -m1 '^# ' "$AI_DIR/opencode.md")")" ""

echo "# D. 設定との整合（OpenCode のグローバル指示は 1 ファイルに連結する）"
OC_JSON="$(cd "$TESTS_DIR/../.." && pwd)/opencode/opencode.json"
# instructions を使わない: ~/.config/opencode/AGENTS.md と ai/core.md の二重読み込みになるため
# （OpenCode はグローバル指示が無いとき ~/.claude/CLAUDE.md＝ai/core.md を互換フォールバックで読む）
n=$(jq -r '.instructions // [] | length' "$OC_JSON" 2>/dev/null)
report D01-no-instructions 0 "$n" "instructions で ai/ を重ねて読ませない"
report D02-skills-source yes "$(has "$(jq -r '.skills // [] | join(",")' "$OC_JSON" 2>/dev/null)" 'opencode/skills')" ""
# home.nix では AGENTS.md を配らない（install.sh が連結生成する）
n=$(grep -cE '^\s*"(\.config/opencode|\.grok|\.codex|\.config/devin)/AGENTS\.md" *=' "$(cd "$TESTS_DIR/../.." && pwd)/nix/home.nix")
report D03-no-generated-links 0 "$n" "連結生成するファイルを home.file のリンクにしない"
# Grok は Claude 側の指示ファイルを読まない（読むと ~/.grok/AGENTS.md と二重になる）。
# skills / hooks は共有するので false にしない
GROK_TOML="$(cd "$TESTS_DIR/../.." && pwd)/grok/config.toml"
compat=$(sed -n '/^\[compat\.claude\]/,/^\[/p' "$GROK_TOML" | grep -E '^[a-z]+ *=' | tr -d ' ' | paste -sd, -)
report D04-grok-rules-off yes "$(has "$compat" 'rules=false')" "$compat"
report D05-grok-agents-off yes "$(has "$compat" 'agents=false')" "$compat"
report D06-grok-skills-kept no "$(has "$compat" 'skills=false')" "$compat"
report D07-grok-hooks-kept no "$(has "$compat" 'hooks=false')" "$compat"
# Devin も Claude のルールを読み込まない
DEVIN_JSON="$(cd "$TESTS_DIR/../.." && pwd)/devin/config.json"
report D08-devin-claude-off false "$(jq -r '.read_config_from.claude' "$DEVIN_JSON" 2>/dev/null)" ""

echo "# E. 異常系"
# 差分ファイルが無ければ失敗（非ゼロ）で終わり、他のファイルは配布する
cp "$INSTALL" "$H/install-copy.sh"
D2="$H/ai-broken"; mkdir -p "$D2"; cp "$AI_DIR/core.md" "$AI_DIR/claude.md" "$AI_DIR/grok.md" "$AI_DIR/opencode.md" "$D2/"
cp "$INSTALL" "$D2/install.sh"
H2="$T/claude-ai-install-home2.$$"; rm -rf "$H2"; mkdir -p "$H2"
HOME="$H2" bash "$D2/install.sh" >"$H2/out.txt" 2>&1; rc=$?
report E01-missing-delta-rc 1 "$rc" "$(cat "$H2/out.txt")"
report E02-claude-still-linked "$D2/core.md" "$(link_of "$H2/.claude/CLAUDE.md")" "1 つ失敗しても残りは配る"
rm -rf "$H2" "$D2"

echo "# F. Codex専用スキルを他CLIの共有探索先へ配らない"
REPO_DIR="$(cd "$TESTS_DIR/../.." && pwd)"
# home.file の宛先と Codex スキルの source の組を取り出す。
# 同名スキルを6本置くだけでなく、実際のリンク先が専用ディレクトリであることを確認する。
codex_skill_links=$(awk '
  /^[[:space:]]*"[^"]+"[[:space:]]*=[[:space:]]*\{/ {
    dest = $0
    sub(/^[[:space:]]*"/, "", dest)
    sub(/".*$/, "", dest)
  }
  /source = .*\/codex\/skills\// {
    skill = $0
    sub(/^.*\/codex\/skills\//, "", skill)
    sub(/".*$/, "", skill)
    print dest "=" skill
  }
' "$REPO_DIR/nix/home.nix")
n=$(printf '%s\n' "$codex_skill_links" | grep -c '=')
report F01-codex-skill-count 6 "$n" "$codex_skill_links"
for skill in pr readme nix-setup git-pull clean-branches opencode; do
  actual=$(printf '%s\n' "$codex_skill_links" | grep -Fx ".codex/skills/$skill=$skill")
  report "F02-${skill}-private-link" ".codex/skills/$skill=$skill" "$actual" "$codex_skill_links"
done
n=$(printf '%s\n' "$codex_skill_links" | grep -c '^\.agents/')
report F03-no-codex-shared-links 0 "$n" "他CLIも探索する .agents へ Codex の source を配らない"
codex_instructions=$(body_of "$H/.codex/AGENTS.md")
pr_prompt=$(body_of "$REPO_DIR/codex/prompts/pr.md")
for entry in instructions prompt; do
  case "$entry" in
    instructions) b="$codex_instructions" ;;
    prompt) b="$pr_prompt" ;;
  esac
  report "F04-${entry}-private-pr" yes "$(has "$b" '~/.codex/skills/pr/SKILL.md')" "$entry"
  report "F05-${entry}-no-shared-skills" no "$(has "$b" '~/.agents/skills')" "$entry"
done
for cli in opencode grok devin; do
  case "$cli" in
    opencode) dest="$H/.config/opencode/AGENTS.md" ;;
    grok) dest="$H/.grok/AGENTS.md" ;;
    devin) dest="$H/.config/devin/AGENTS.md" ;;
  esac
  report "F06-${cli}-no-codex-skills" no "$(has "$(body_of "$dest")" '~/.codex/skills')" "$dest"
done

cleanup
summary "ai-install"
