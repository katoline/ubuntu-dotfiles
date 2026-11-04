# Grok CLI 設定

Grok CLI（xAI）の設定実体。適用は [nix/home.nix](../nix/home.nix) が担い、`~/.grok/config.toml` へ書き込み可能なシンボリックリンクを張る。グローバル指示 `~/.grok/AGENTS.md` は全CLI共通の [`ai/`](../ai/README.md) から `ai/install.sh` が連結生成する（`ai/core.md` + `ai/grok.md`）。本体は [bootstrap.sh](../bootstrap.sh) が公式インストーラーで導入する（Claude Code と同様、常に最新版を使うためあえてNix管理外）。

## ファイル構成

| ファイル | 役割 |
|---|---|
| [`config.toml`](config.toml) | Grok CLI の設定実体（UI・marketplace・権限モード） |
| [`../ai/grok.md`](../ai/grok.md) | Grok 向けグローバル指示の**差分のみ**（共通ルールは `ai/core.md`。連結して `~/.grok/AGENTS.md` を生成する） |

## グローバル指示の構成

言語・Git・Nix・検証・レビューの範囲・破壊的操作の許可ルートなどの共通ルールは `ai/core.md` にあり、Grok 固有の差分（`spawn_subagent` の使い分け、Claude のモデル名を使わないこと、always-approve でも hook の ask / deny が効くこと）だけを `ai/grok.md` に書く。両者を連結した実体が `~/.grok/AGENTS.md`（自動生成。手で編集せず、`ai/` を直して `bash ai/install.sh`）。

`config.toml` の `[compat.claude]` は `rules = false`・`agents = false` のまま運用する（`agents` は `~/.claude/` の名前付き指示ファイル＝`~/.claude/CLAUDE.md`（= `ai/core.md`）の読み込みを制御する。true に戻すと `~/.grok/AGENTS.md` と合わせて共通ルールを二重に読み、Claude 専用のモデル振り分けまで持ち込まれる）。`skills`（`~/.claude/skills/` の共有スキル）と `hooks`（`pr-mode.sh`・`guard-destructive.sh` の共有に必須）は既定の true のまま。

## 管理対象外

`~/.grok/` 直下の次は秘密情報・キャッシュ・セッションなのでリポジトリに置かない。

- `auth.json`（認証）
- `sessions/` / `logs/` / `marketplace-cache/` / `worktrees.db` などランタイム生成物
- `trusted_folders.toml`（このマシンで信頼したディレクトリ）

## 権限モードと Git操作の制限（既定ブランチ保護）

`config.toml` の `permission_mode = "always-approve"` は通常の確認ダイアログを出さない設定。その代わり:

- `pr-mode.sh` の `PreToolUse` が、既定ブランチ（main / master / origin/HEAD）への `git commit` / `git push`、force push、リモートブランチの削除を deny する。既定ブランチ以外の commit / push / PR 作成・更新は `/pr` の起動有無にかかわらず通し、自動承認条件を満たさない git 書き込み（`--amend` / `--no-verify` / 宛先を判定できない push など）だけ ask（always-approve でも確認になる）
- `guard-destructive.sh` が致命的な削除を deny し、解釈できない削除は ask
- `settings.json` のシェル `ask` / `deny` ルールは always-approve でも効く（`gh pr merge`・`sudo`・グローバル install など）

Git の判定は `/pr` の起動状態に依存せず、コマンドと対象リポジトリの状態から毎回行う。stdin は camelCase、イベント名は `GROK_HOOK_EVENT`、ツール名は `run_terminal_command`（matcher `Bash` のエイリアスでも当たる）。

## VSCode 統合ターミナルの日本語IME

Grok を VSCode の統合ターミナルで使うと、Mozc の変換中プレビューが確定扱いされ「この」が「ｋこｎこのこの」になることがある。Grok 側の設定ではなく ibus / エディタ側の問題。本体の対策は [`../nix/keyboard.nix`](../nix/keyboard.nix) の `embed-preedit-text = false`。経緯と補助設定は [`../vscode/README.md`](../vscode/README.md) の「統合ターミナルの日本語IME」を見る。

## サブエージェントのモデル

`[subagents.models] explore = "grok-4.5"` で調査だけ親より軽いモデルへ振る。plan / general-purpose は未設定なので親（いまは grok-4.6）を継承する。

## リンクが実体化したとき

Grok 自身が `config.toml` へ書き込む。書き込み可能リンクなら変更はリポジトリ側に届くが、シンボリックリンクを実体ファイルで置き換える場合がある。`home.nix` の `captureGrokConfigWrites` が `home-manager switch` の直前に、実体の方が新しければリポジトリへ取り込み、`force = true` でリンクに戻す。
