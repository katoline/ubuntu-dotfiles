# Codex 固有の補足

設定は `~/.codex/config.toml`、フックは `~/.codex/hooks.json`（dotfiles の `codex/` の宣言を home-manager がマージした実ファイル。trust・信頼ハッシュはホーム側だけに残る）。Claude/Grokの設定は読み込まず、共通の事故防止判定・検証ゲートを使う。

- `/pr` 起動は文中の `$pr`、依頼の先頭語の `/pr`・旧 `/prompts:pr`。`~/.codex/skills/pr/SKILL.md` に従う（作業完了時の commit・push・PR も同じ手順）
- PreToolUseは拒否専用。既定ブランチへの commit・push、宛先を判定できない push、PR のマージ、危険操作をフックが拒否する。確認対象は常に拒否されるので、ユーザーに手動実行を依頼する（マージはユーザーが指示したときも、Codex からは実行せずユーザーに任せる）
- 削除・移動の対象は絶対パスで書き、`workdir` 指定と相対パスを組み合わせない（フックに `workdir` が届かないため）
- フックの確認要求や拒否を、別の書き方やツールで迂回しない
- フックの追加・変更後はユーザーが `/hooks` で確認し信頼する。エージェントは信頼状態を書き換えない
- サブエージェントから commit / push / PR 操作をしない
- モデルと reasoning effort はユーザーが `config.toml` で決める（dotfiles の `codex/config.toml`。`--model` で変えない）
