# claude-notify（送信側）

Claude Code / Grok CLI の Stop / Notification フックから iPhone へ Web Push するための送信スクリプト。OpenCode からは送らない（`opencode/cli.json` の `attention.notifications: false` と無効化したプラグイン）。呼び出し側・新PCでのセットアップ手順は [`.claude/README.md`](../.claude/README.md) を正本とする。受信側 PWA は別リポジトリ `claude-notify-mobile`（Vercel配信）。

## ファイル構成

| ファイル | 役割 |
|---|---|
| [`send-push.mjs`](send-push.mjs) | Web Push 送信本体（VAPID署名） |
| [`package.json`](package.json) | 依存は `web-push` のみ |
| [`pnpm-lock.yaml`](pnpm-lock.yaml) | lock。`node_modules` は gitignore で、`home-manager switch` 時に activation が `pnpm install --frozen-lockfile` する |

## 設定ファイル

記入済み設定は `~/.claude/claude-notify.json`（VAPID秘密鍵を含むためリポジトリ禁止）。テンプレートは [`.claude/claude-notify.example.json`](../.claude/claude-notify.example.json)。

任意の `filters` キー:

- `events` — 送るイベント名（既定は Stop / Notification）
- `debounceSeconds` — 同一イベントの連打を抑制する秒数
- `quietHours.start` / `quietHours.end` — `HH:MM`。この時間帯は送らない（日跨ぎ可。例: `23:00`〜`07:00`）

パスを変えたいときだけ環境変数 `CLAUDE_NOTIFY_CONFIG`（設定JSON）と `CLAUDE_NOTIFY_NODE`（node バイナリ）を使う。通常は不要。

## 疎通テスト

```zsh
node ~/Dev/kaishi/ubuntu-dotfiles/claude-notify/send-push.mjs --title "テスト" --body "OK" --event Stop
```
