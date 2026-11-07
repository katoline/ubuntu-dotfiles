# Grok 固有の補足

Claude Code のモデル名・`settings.json` の書き方は Grok に当てはまらないので使わない（`config.toml` の `[compat.claude]` は `rules = false` / `agents = false`。フックとスキルは Claude と共有する）。

## サブエージェント

- 調査は `spawn_subagent` / `explore`、計画は `plan`（どちらも編集しない。深さは prompt に `quick` / `medium` / `very thorough`）、実装は `general-purpose`
- 子はトップレベルのみ。独立なら `background: true`、回収は `get_command_or_subagent_output`
- 並列でファイルを書くときは `isolation: worktree`（同じファイルを2体に触らせない）
- `model` はユーザー指定時のみ。explore の既定は `config.toml` の `[subagents.models]`

## 権限

確認ダイアログは出ない（`permission_mode = "always-approve"`）。既定ブランチへの commit・push と force push は `pr-mode.sh` の PreToolUse が拒否し（既定ブランチ以外の commit・push・PR は通る）、PR のマージは設定の ask になる。`guard-destructive.sh` の deny も止まる。ask は always-approve でも確認プロンプトになる。
