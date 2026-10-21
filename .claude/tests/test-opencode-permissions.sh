#!/bin/bash
# opencode/opencode.json の権限評価（単体 build と delegated-worker）と、配布入口の検査
# 実行: bash .claude/tests/test-opencode-permissions.sh（run.sh からも呼ばれる）
# OpenCode V2 の permission は全体一致のワイルドカード（* は / も含む）で、最後に一致した規則が勝つ。
# 評価順は「ベース allow → global → agent」（公式 docs の Merging）。単体はベース + global、
# delegated-worker はさらに agents.delegated-worker.permissions を後ろに足して実効値を検査する。
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
REPO_DIR="$(cd "$TESTS_DIR/../.." && pwd)"
CFG="$REPO_DIR/opencode/opencode.json"
BASE="$T/opencode-base.rules"
GLOBAL="$T/opencode-global.rules"
AGENT="$T/opencode-agent.rules"

# 全 agent 共通のベース（permissions docs の Defaults）
printf '%s\t%s\t%s\n' \
  '*' '*' allow \
  'read' '*.env' ask \
  'read' '*.env.*' ask \
  'read' '*.env.example' allow >"$BASE"
jq -r '.permissions[] | [.action, .resource, .effect] | @tsv' "$CFG" >"$GLOBAL" || {
  echo "  NG [A00] opencode.json の permissions を読めません"
  exit 1
}
jq -r '.agents["delegated-worker"].permissions[] | [.action, .resource, .effect] | @tsv' "$CFG" >"$AGENT" || {
  echo "  NG [A00] agents.delegated-worker.permissions を読めません"
  exit 1
}

matches() { # pattern value（[[ ]] の右辺はクォートしない＝ワイルドカードとして扱う）
  local pattern="$1" value="$2"
  [[ "$value" == $pattern ]] && return 0
  # "… *" は引数なしにも一致する（公式 docs の shell 規則）
  [[ "$pattern" == *' *' && "$value" == ${pattern% *} ]] && return 0
  return 1
}

apply_rules() { # file action resource current
  local file="$1" action="$2" resource="$3" effect="$4" act res eff
  while IFS=$'\t' read -r act res eff; do
    if matches "$act" "$action" && matches "$res" "$resource"; then
      effect="$eff"
    fi
  done <"$file"
  printf '%s\n' "$effect"
}

effect_for() { # mode action resource
  local mode="$1" action="$2" resource="$3" effect=ask
  effect="$(apply_rules "$BASE" "$action" "$resource" "$effect")"
  effect="$(apply_rules "$GLOBAL" "$action" "$resource" "$effect")"
  if [ "$mode" = worker ]; then
    effect="$(apply_rules "$AGENT" "$action" "$resource" "$effect")"
  fi
  printf '%s\n' "$effect"
}

eff() { effect_for standalone "$1" "$2"; }
weff() { effect_for worker "$1" "$2"; }
denied() { [ "$(eff "$1" "$2")" = deny ] && echo yes || echo no; }
wdenied() { [ "$(weff "$1" "$2")" = deny ] && echo yes || echo no; }

echo "# A. 単体 build の通常体験（対話・Skill・subagent・Code Mode）"
report A01-default-agent build "$(jq -r '.default_agent // "なし"' "$CFG")" "通常起動は build"
report A02-skill-pr allow "$(eff skill pr)" "OpenCode 用 pr Skill を許可"
report A03-skill-opencode deny "$(eff skill opencode)" "入れ子起動の防止"
report A04-skill-codex deny "$(eff skill codex)" "入れ子起動の防止"
report A05-skill-readme allow "$(eff skill readme)" "他の共通 Skill は必要時に読める"
report A06-skill-synced allow "$(eff skill docs)" "同期 Skill も通常どおり"
report A07-question allow "$(eff question '*')" "ユーザーへ質問できる"
report A08-subagent-general allow "$(eff subagent general)" "サブ agent を使える"
report A09-subagent-explore allow "$(eff subagent explore)" ""
report A0A-execute allow "$(eff execute '*')" "Code Mode / MCP を使える"
report A0B-read allow "$(eff read src/app.ts)" ""
report A0C-edit allow "$(eff edit src/app.ts)" ""
report A0D-npm-test allow "$(eff shell 'npm test')" ""

echo "# B. 単体 build の Git・PR・worktree"
report B01-commit ask "$(eff shell 'git commit -m x')" ""
report B02-dash-c-commit ask "$(eff shell 'git -C /tmp/r commit -m x')" ""
report B03-bare-commit ask "$(eff shell 'git commit')" "引数なしも確認"
report B04-push ask "$(eff shell 'git push origin feat/x')" ""
report B05-dash-c-push ask "$(eff shell 'git -C /tmp/r push')" ""
report B06-bare-push ask "$(eff shell 'git push')" ""
report B07-pr-create ask "$(eff shell 'gh pr create --fill')" ""
report B08-pr-new ask "$(eff shell 'gh pr new --fill')" ""
report B09-pr-edit ask "$(eff shell 'gh pr edit 1 --title x')" ""
report B0A-pr-merge ask "$(eff shell 'gh pr merge 1 --squash')" ""
report B0B-gh-R-create ask "$(eff shell 'gh -R owner/repo pr create --fill')" "通常のグローバル引数"
report B0C-gh-R-edit ask "$(eff shell 'gh -R owner/repo pr edit 1 --title x')" ""
report B0D-git-c-gh-R-merge ask "$(eff shell 'gh -R owner/repo pr merge 1 --squash')" ""
report B0E-gh-api ask "$(eff shell 'gh api repos/o/r')" "読み取り調査用"
report B0F-force-push deny "$(eff shell 'git push --force origin feat/x')" "force push は拒否"
report B10-dash-c-force-push deny "$(eff shell 'git -C /tmp/r push --force')" ""
report B11-worktree-remove allow "$(eff shell 'git worktree remove /abs/wt')" "保存確認後の通常 cleanup"
report B12-worktree-remove-dash-c allow "$(eff shell 'git -C /tmp/r worktree remove /abs/wt')" ""
report B13-worktree-add allow "$(eff shell 'git worktree add /abs/wt -b feat/x')" "作業用 worktree を作れる"
report B14-worktree-list allow "$(eff shell 'git worktree list --porcelain')" ""
report B15-worktree-list-dash-c allow "$(eff shell 'git -C /tmp/r worktree list')" ""
report B16-worktree-force ask "$(eff shell 'git worktree remove --force /abs/wt')" ""
report B17-worktree-force-after ask "$(eff shell 'git worktree remove /abs/wt --force')" ""
report B18-worktree-short-force ask "$(eff shell 'git worktree remove -f /abs/wt')" ""
report B19-worktree-short-force-after ask "$(eff shell 'git worktree remove /abs/wt -f')" ""
report B1A-worktree-dash-c-force ask "$(eff shell 'git -C /tmp/r worktree remove --force /abs/wt')" ""
report B1B-worktree-dash-c-force-after ask "$(eff shell 'git -C /tmp/r worktree remove /abs/wt --force')" ""
report B1C-worktree-dash-c-short-force ask "$(eff shell 'git -C /tmp/r worktree remove -f /abs/wt')" ""
report B1D-worktree-dash-c-short-force-after ask "$(eff shell 'git -C /tmp/r worktree remove /abs/wt -f')" ""
report B1E-env-deny deny "$(eff read .env)" ""
report B1F-env-example-allow allow "$(eff read .env.example)" ""
report B1G-sudo-deny deny "$(eff shell 'sudo ls')" ""
report B1H-rm-ask ask "$(eff shell 'rm -rf /tmp/x')" ""
report B1I-global-install-ask ask "$(eff shell 'npm install -g pkg')" ""

echo "# C. delegated-worker の軽量制限"
report C01-skill-pr deny "$(weff skill pr)" "Skill は親が選ぶ"
report C02-skill-synced deny "$(weff skill docs)" ""
report C03-subagent deny "$(weff subagent general)" "再委譲しない"
report C04-explore-subagent deny "$(weff subagent explore)" ""
report C05-question deny "$(weff question '*')" "ユーザーへ直接質問しない"
report C06-execute deny "$(weff execute '*')" "Code Mode（内蔵 session / worktree 管理・MCP）を外す"
report C07-commit deny "$(weff shell 'git commit -m x')" ""
report C08-dash-c-commit deny "$(weff shell 'git -C /tmp/r commit -m x')" ""
report C09-bare-commit deny "$(weff shell 'git commit')" ""
report C0A-push deny "$(weff shell 'git push origin feat/x')" ""
report C0B-dash-c-push deny "$(weff shell 'git -C /tmp/r push')" ""
report C0C-bare-push deny "$(weff shell 'git push')" ""
report C0D-pr-create deny "$(weff shell 'gh pr create --fill')" ""
report C0E-pr-new deny "$(weff shell 'gh pr new --fill')" ""
report C0F-pr-edit deny "$(weff shell 'gh pr edit 1 --title x')" ""
report C10-pr-merge deny "$(weff shell 'gh pr merge 1 --squash')" ""
report C11-gh-R-create deny "$(weff shell 'gh -R owner/repo pr create --fill')" ""
report C12-gh-R-edit deny "$(weff shell 'gh -R owner/repo pr edit 1 --title x')" ""
report C13-gh-R-merge deny "$(weff shell 'gh -R owner/repo pr merge 1 --squash')" ""
report C14-worktree-remove deny "$(weff shell 'git worktree remove /abs/wt')" ""
report C15-worktree-add deny "$(weff shell 'git worktree add /abs/wt -b x')" ""
report C16-worktree-prune deny "$(weff shell 'git worktree prune')" ""
report C17-worktree-move deny "$(weff shell 'git worktree move /a /b')" ""
report C18-worktree-lock deny "$(weff shell 'git worktree lock /a')" ""
report C19-worktree-unlock deny "$(weff shell 'git worktree unlock /a')" ""
report C1A-dash-c-worktree-remove deny "$(weff shell 'git -C /tmp/r worktree remove /abs/wt')" ""
report C1B-worktree-list allow "$(weff shell 'git worktree list')" "読み取りだけ許可"
report C1C-worktree-list-porcelain allow "$(weff shell 'git worktree list --porcelain')" ""
report C1D-dash-c-worktree-list allow "$(weff shell 'git -C /tmp/r worktree list')" ""
report C1E-read no "$(wdenied read src/app.ts)" ""
report C1F-edit no "$(wdenied edit src/app.ts)" ""
report C1G-npm-test no "$(wdenied shell 'npm test')" ""
report C1H-pytest no "$(wdenied shell 'pytest -q')" ""
report C1I-git-status no "$(wdenied shell 'git status')" ""
report C1J-git-diff no "$(wdenied shell 'git diff --stat')" ""
report C1K-gh-api-ask ask "$(weff shell 'gh api repos/o/r')" "読み取り調査の ask は維持"
report C1L-env-deny deny "$(weff read .env)" "global の秘密制約を継承"
report C1M-sudo-deny deny "$(weff shell 'sudo ls')" ""
report C1N-force-push-deny deny "$(weff shell 'git push --force')" ""

echo "# D. Agent 定義と入口・配布の復活"
report D01-worker-count 1 "$(jq '[.agents // {} | to_entries[] | select(.key == "delegated-worker")] | length' "$CFG")" ""
report D02-worker-mode primary "$(jq -r '.agents["delegated-worker"].mode // ""' "$CFG")" ""
report D03-worker-hidden true "$(jq -r '.agents["delegated-worker"].hidden // false' "$CFG")" "一覧から隠す（明示 --agent 用）"
report D04-worker-no-model true "$(jq -r 'if (.agents["delegated-worker"] | has("model")) then false else true end' "$CFG")" "モデルは runner の --model を使う"
report D05-worker-system yes "$(jq -r 'if ((.agents["delegated-worker"].system // "") | length) > 0 then "yes" else "no" end' "$CFG")" ""
report D06-worker-system-parent yes "$(jq -r '.agents["delegated-worker"].system // "" | if (contains("親") and contains("再委譲") and contains("変更ファイル")) then "yes" else "no" end' "$CFG")" ""
report D07-command-count 6 "$(find "$REPO_DIR/opencode/commands" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')" ""
for f in "$REPO_DIR"/opencode/commands/*.md; do
  v=no
  if ! grep -q '廃止' "$f" && { grep -q 'SkillツールでID' "$f" || grep -q 'コードレビューを開始' "$f"; }; then v=yes; fi
  report "D08-$(basename "$f" .md)-restored" yes "$v" "${f#$REPO_DIR/}"
done
report D09-pr-agent-primary yes "$(grep -qx 'mode: primary' "$REPO_DIR/opencode/agents/pr.md" && echo yes || echo no)" ""
report D0A-pr-agent-hidden yes "$(grep -qx 'hidden: true' "$REPO_DIR/opencode/agents/pr.md" && echo yes || echo no)" ""
report D0A1-pr-agent-no-allow 0 "$(grep -c 'effect: allow' "$REPO_DIR/opencode/agents/pr.md")" "固定 Git allow を持たず global ask を継承する"
report D0A2-pr-agent-keeps-deny yes "$(grep -q 'effect: deny' "$REPO_DIR/opencode/agents/pr.md" && echo yes || echo no)" "force/amend 等の拒否は維持する"
report D0B-review-agent-subagent yes "$(grep -qx 'mode: subagent' "$REPO_DIR/opencode/agents/code-review.md" && echo yes || echo no)" ""
report D0C-no-disabled 0 "$(grep -rlE '^disabled: true' "$REPO_DIR/opencode/agents" | wc -l | tr -d ' ')" ""
report D0D-pr-skill-restored yes "$(grep -q 'opencode/autoinvoke: false' "$REPO_DIR/opencode/skills/pr/SKILL.md" && ! grep -q '廃止' "$REPO_DIR/opencode/skills/pr/SKILL.md" && echo yes || echo no)" ""
report D0E-command-links 6 "$(grep -cE '^[[:space:]]*"\.config/opencode/commands/' "$REPO_DIR/nix/home.nix")" ""
report D0F-agent-links 2 "$(grep -cE '^[[:space:]]*"\.config/opencode/agents/' "$REPO_DIR/nix/home.nix")" ""
report D0G-skill-links 1 "$(grep -cE '^[[:space:]]*"\.config/opencode/skills/' "$REPO_DIR/nix/home.nix")" ""
report D0H-shared-harness-registered yes "$(jq -r 'if (.plugins // []) | index("./plugins/shared-harness.js") then "yes" else "no" end' "$CFG")" ""
report D0I-shared-harness-links 2 "$(grep -cE '^[[:space:]]*"\.config/opencode/(plugins/shared-harness\.js|hooks/harness\.sh)"' "$REPO_DIR/nix/home.nix")" ""

summary "opencode-permissions"
