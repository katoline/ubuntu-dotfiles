<!-- Claude Code 固有の差分（~/.claude/rules/claude.md はこのファイルへのリンク）。
     共通ルールは ai/core.md（~/.claude/CLAUDE.md）。ここへ重複させない。
     ブロック HTML コメントは読み込み前に除去されるので、経緯や理由はコメントに書く（コンテキストを消費しない）。
     フックの契約と Git 操作の制御の詳細は dotfiles の .claude/README.md にある（必要になったら読む） -->

# モデル運用（Claude Code）

<!-- 2026-11-04 ユーザー指定：設計・レビューは Claude Code の Opus 5.5（effort medium）、実装・調査・テストは OpenCode。
     モデル（opus[1m]）と effortLevel（medium）は .claude/settings.json、OpenCode の切替順は skills/opencode/scripts/run.sh -->

メインセッション向け（サブエージェントとして起動されたら本節と `/opencode` は使わず、与えられた指示を実行する）。委譲の原則は `~/.claude/CLAUDE.md` の「サブエージェント」。Claude Code は Opus 5.5・effort medium で動かす。

- **Claude（メイン）**：要件整理・設計・分解・指示・レビュー・最終判断。1〜2ファイルの確認と自明な局所修正は自分で行ってよい
- **OpenCode**：実装・複数ファイルにまたがる調査・テスト作成と実行・ドキュメント更新は、ユーザーの明示的な呼出しがなくても `/opencode` Skill（`~/.claude/skills/opencode/SKILL.md`）で委譲する。Claude のサブエージェント（Explore を含む）へは回さない
- **Claude のサブエージェント**：独立レビューだけに使う。新しいコンテキストの opus（`CLAUDE_CODE_SUBAGENT_MODEL`）に、Agent ツールで `effort: "medium"` を渡す

運用：

- OpenCode の切替順（利用上限のときだけ）は DeepSeek V4.1 Flash Free → GLM 5.3 Flash Free → OpenCode Go の DeepSeek V4.1 Flash → API 登録の Claude Sonnet 5.5（medium）。ランナーが自動で切り替えるので、手で `--model` を指定しない
- Sonnet まで上限になったとき、または OpenCode が使えないとき（認証・地域拒否・未インストール等）は、Claude のサブエージェントやメインで実装を肩代わりせず、状況を報告してユーザーに判断を仰ぐ
- ユーザーが「Claude でやって」等とその作業に明示したときだけ、OpenCode を使わずメインまたはサブエージェント（opus）で行う
- OpenCode が報告した検証結果は鵜呑みにせず、変更後にプロジェクトの検証コマンドをメインがフォアグラウンドで実行し直す（`verify-gate.sh` は OpenCode の編集を検出しない）

# フックの挙動（Claude Code）

実体は dotfiles の `.claude/hooks/`。

- `pr-mode.sh`：既定ブランチへの commit・push、force push、サブエージェントからの git 書き込みを拒否する。既定ブランチ以外の commit・push・PR の作成と更新は、単一コマンドなら確認なしで自動承認する。PR のマージは常に確認ダイアログになる
- `guard-destructive.sh`：範囲外の削除・破壊的な git 操作・名前指定の一括プロセス終了を拒否または確認にする。拒否パターンを増やして抜け道を塞ぎ続けない
- `verify-gate.sh`：dotfiles の検証対象を編集したセッションでは、検証コマンドが成功するまでターンを終えさせない（バックグラウンド実行では解除されないのでフォアグラウンドで実行する）
