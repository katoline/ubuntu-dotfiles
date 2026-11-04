---
name: pr
description: 作業が完了して検証が通ったとき、またはユーザーが $pr ・ /pr を指定してPR作成・更新を明示的に指示したときに、変更をコミットしGitHubのPRを作成・更新する。使い方や設定の説明依頼では実行しない。
---

<!-- pr-mode-enable -->

# PR作成（Codex）

作業が完了して検証が通ったとき、またはユーザーがPR作成・更新を明示的に指示したときに、この環境の `/pr` 起動として扱う。文中の `$pr`、前後の空白を除いた依頼文の先頭語として指定された `/pr`・旧 `/prompts:pr` も同じ入口で、このスキルに従う。`$pr` の使い方や設定の説明依頼ではcommit・push・PR操作を行わない。

手順の実体は `~/.claude/skills/pr/SKILL.md`。このファイルを読み、次のCodex固有の読み替えを適用して最後まで実行する。

- Claudeの `allowed-tools`・モデル指定はCodexの権限設定ではない。シェル操作は利用可能なCodexツールを使う。
- Codexのフックは拒否専用で、自動承認しない。既定ブランチ（main / master / origin/HEAD が指すブランチ）への commit・push、PR のマージ、force push・リモートブランチの削除・`--amend` / `--no-verify` / `-n`・宛先を判定できない push はフックが拒否する。それ以外のブランチでの commit・push・PR の作成と更新は Codex の承認ダイアログに従い、commit・push・PR操作を1つずつ独立して実行する。
- `AskUserQuestion` は利用可能なCodexの質問手段へ読み替える。
- PR本文などの複数行テキストは一時ファイルへ書き、`--body-file` で渡す。

作成・更新したPRのURL、ブランチ名、コミット一覧、検証結果を報告する。
