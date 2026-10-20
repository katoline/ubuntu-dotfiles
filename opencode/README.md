# OpenCode

OpenCode V2のグローバル設定。設定ファイルはhome-managerで `~/.config/opencode/` にリンクし、全プロジェクトで利用する。

## 管理ファイル

| ファイル | 役割 |
|---|---|
| [`../ai/opencode.md`](../ai/opencode.md) | OpenCode 固有の差分のみ（共通ルールは [`../ai/core.md`](../ai/core.md)。両者を連結した `~/.config/opencode/AGENTS.md` を `ai/install.sh` が生成する） |
| [`opencode.json`](opencode.json) | Skillのソース、秘密ファイルの読み取り禁止、Git書き込み・破壊的操作・恒久インストールの確認、`sudo` / force pushの拒否 |
| [`cli.json`](cli.json) | TUIのダークテーマ、権限確認、通知の無効化（`attention.notifications: false`）、usage-footerの明示登録 |
| [`plugins/mobile-notify.js`](plugins/mobile-notify.js) | 通知の無効化用の互換入口（処理を持たない）。home-manager の既存リンクとプラグイン id を維持するために残す |
| [`plugins/usage-footer/`](plugins/usage-footer/) | チャット欄下にOpenCode Goの5時間利用率（ローカル履歴からの推定）とセッションコンテキスト使用率を表示 |
| [`commands/`](commands/) | `/pr`・`/readme`・`/clean-branches`・`/nix-setup`・`/git-pull`・`/code-review` |
| [`agents/code-review.md`](agents/code-review.md) | 差分を調査する、Kimi K2.7 Code使用の読み取り専用レビューAgent |
| [`agents/pr.md`](agents/pr.md) | `/pr` 専用Agent。通常コミット・`origin` push・PR作成のみ確認なしで許可 |
| [`skills/pr/SKILL.md`](skills/pr/SKILL.md) | OpenCode用の `/pr` 手順。Claude/Grokフックの代わりにOpenCodeの権限確認を利用 |
| [`setup.sh`](setup.sh) | 公式インストーラーによるOpenCode CLI導入（冪等） |

## Claude Code / Grokとの共有

- 全プロジェクト共通の指示は `~/.config/opencode/AGENTS.md`。実体は [`ai/core.md`](../ai/README.md)（全CLI共通）＋ `ai/opencode.md`（OpenCode固有の差分）で、`ai/install.sh` が連結生成する（手で編集しない）。**このファイルを消さないこと**：V2 は `AGENTS.md` のみを読み、`CLAUDE.md` へのフォールバックは無いため、消すと共通ルールとOpenCode固有の差分が両方読まれなくなる。`opencode.json` の `instructions` は現在参照を解決しないため代替にならず、将来対応した際の二重読みも避けるため `ai/` を列挙しない（[V2の指示](https://opencode.ai/v2/docs/instructions/)・[V1からの移行](https://opencode.ai/v2/docs/migrate-v1/)）。
- OpenCodeは `~/.claude/skills/` も互換ソースとして検索するため、`readme`・`clean-branches`・`nix-setup`・`git-pull` Skillsは既存定義を共有する。`pr` は明示した `opencode/skills` ソースから読み、Claude Code版のフック手順と重ならないようOpenCode用のpermission手順を使う。
- `~/.claude/skills/opencode`（Claude CodeからOpenCodeを起動するSkill）は共有しない。OpenCodeが互換ソース経由で読み込んで入れ子起動しないよう、`opencode.json` で `skill` の `opencode` を deny している。`codex` の deny は削除済みのClaude用Skillを将来復活させた場合の入れ子起動防止として残す。
- Claude CodeのHooks、settings.json、モデル振り分けはOpenCodeでは動かない。代替としてOpenCodeのpermissionルールを設定している。
- `/pr` Command本文の受信、またはユーザー発言先頭の独立した `@pr` を明示起動として扱い、SkillツールでID `pr` を読み込んで子セッションを作らず実行する。通常の `gh pr create`・`gh pr new`・`gh pr edit` は確認する。通常コミット・`origin` へのPR用ブランチprefixのpush・`gh pr create` / `gh pr new` の許可は非表示の専用Agentにだけ設定する。`gh pr edit` はSkillに本文編集手順が無いため専用Agentでも確認を維持する。force push・refspec push等は拒否する。
- OpenCode からは claude-notify の通知を送信しない。`cli.json` の `attention.notifications` を `false` にし、`plugins/mobile-notify.js` は無効化した互換入口として残すだけで、イベント購読・送信プロセス起動を行わない。Claude/Grok と同じ `~/.claude/claude-notify.json`・送信スクリプト・PWA は OpenCode からは使わない（Claude/Grok 側の通知は変更しない）。
- `plugins/usage-footer/` はTUIの `prompt.footer` にGo 5時間枠の推定値と現在セッションのコンテキスト使用率を表示する。Goの5時間枠はモデル別で、TUI向けの正確なアカウント使用量APIが公開されていないため、Goの標準プラン上限とこのOpenCodeが持つ直近5時間のセッション履歴・コストから推定する。別端末やOpenCode以外のクライアントの使用量、Go Plusの上限は含まれない。履歴を持たないモデルでは `--` を表示する。
- usage-footerは `cli.json` の `plugins` に `./plugins/usage-footer` と明示登録する。相対パスは `cli.json` のあるディレクトリが基準で、既存のhome-managerリンク先の `tui.ts` から `tui.tsx` を読む。[公式CLIプラグイン仕様](https://opencode.ai/v2/docs/cli/plugins)と実機v2.0.22にはディレクトリの自動探索もあるが、登録を設定に明示する。実機のローダーはローカルの `tui` 入口を解決し、`@opencode/plugin/tui`・`solid-js`・OpenTUIを実行時に共有するため、追加の `package.json` や依存インストールは不要。設定の反映はTUIを起動し直す。読み込み経路は公式仕様とバイナリ内の実装で確認済みだが、表示は未確認（[CLIプラグインの作成](https://opencode.ai/v2/docs/build/plugins/cli/)）。
- 無効化の反映にはバックグラウンドサービスの再読み込み（`opencode service restart`）が必要で、実行中セッションは切断される。
- OpenCode V2はプロジェクトの `CLAUDE.md` を読まず、`AGENTS.md` を読む。ルートの `AGENTS.md` はClaude Codeも対応バージョン・設定で直接読めるため、このリポジトリでは `CLAUDE.md` を重複管理しない。

## インストール・認証

新しいマシンでは `bootstrap.sh` が `setup.sh` を呼び、[OpenCode公式インストーラー](https://opencode.ai/install)で最新CLIを導入する。現在のマシンで手動実行する場合：

```sh
bash ~/Dev/kaishi/ubuntu-dotfiles/opencode/setup.sh
```

設定リンクは `home-manager switch --flake ~/Dev/kaishi/ubuntu-dotfiles#ubuntu` で反映する。xAI/Grokをモデルとして使う場合はOpenCode内で `/connect` からxAIアカウントを接続し、`/models` でモデルを選ぶ。認証情報はOpenCode自身のデータ領域に保存し、dotfilesには含めない。

OpenCode V2の設定仕様に合わせ、Claude/Grokと共通化できないフックは移植せず、permission確認を安全境界として使う。OpenCodeの設定詳細は [公式ドキュメント](https://opencode.ai/v2/docs/) を参照。

## 日本語表示の範囲

- `AGENTS.md`、Commandの説明・本文、Agentの説明・指示を日本語にし、応答・確認時の案内・レビュー結果も日本語で出すよう指定している。
- OpenCode V2の公式CLI設定にはUI言語／localeの項目がない。組み込み確認ダイアログ、権限操作の選択肢、CLI/TUIの固定文言は設定から翻訳できないため変更していない。コマンド名・設定キー・パス・モデルIDも識別子として維持する。

## `/code-review` の設計と公式仕様

### 対象にしたClaude Code機能

Anthropic公式の [Code Reviewドキュメント](https://code.claude.com/docs/en/code-review#review-a-diff-locally) が説明する、Claude Code内蔵のローカル `/code-review` を対象にした。公式資料によれば、通常は作業ブランチのupstreamより先のコミットと未コミット変更をレビューし、ファイル・PR番号・ブランチ・ref rangeを対象指定できる。レビューは会話を圧迫しない背景Subagentで走り、`low`〜`max` のeffort、`--fix`、GitHub/GitLabへの `--comment`、対応バージョンでの `--max-findings` がある。`low` / `medium` は高確度の指摘に絞り、effortを上げるほど調査範囲を広げる。ローカルレビューはプロジェクトの `CLAUDE.md` を読むが、Code Reviewサービス向けの `REVIEW.md` は読まない。

Anthropic公開リポジトリの [`plugins/code-review`](https://github.com/anthropics/claude-code/tree/main/plugins/code-review) は別配布物のプラグインであり、内蔵コマンドではない。プラグインの公開実装はPR状態確認、複数の役割別Agent、候補検証、信頼度80未満の除外、GitHubコメント投稿を記述している。これらはプラグイン固有の挙動で、内蔵ローカル `/code-review` の仕様としては移植していない。また、内蔵コマンドの非公開プロンプト／内部実装は公開リポジトリで確認できないため、公式ドキュメントに明記された動作だけを再現対象とした。組織向けCode Reviewサービスの「複数Agentを並列実行し、検証・重複排除・重大度順に統合」する機能もローカルコマンドとは別機能である。

### OpenCodeでの再現

- `/code-review` Commandは `subagent: true` で背景実行し、専用の `code-review` Agentへ委譲する。Command側にもモデルIDを明示し、OpenCode V2で確認したCommand／Agentの現行仕様を使用している。
- 引数なしではupstream以降のブランチ差分と `HEAD` からの作業ツリー差分（staged / unstaged）を調べる。ファイル、ブランチ、`base...head`、PR番号／URLも対象にでき、未追跡ファイルも一覧から対象に含める。
- レビューAgentには全操作を既定denyし、ファイル変更・書込み・別Agent起動を禁止したうえで、読み取り・検索と限定したGit / `gh pr diff` / `gh pr view` のみ許可する。秘密ファイルは対象から除外する。
- 変更によって導入されたと確認でき、差分とコードで根拠を示せる重大なバグ・回帰・適用可能なルール違反だけを報告する。既存問題、推測、好み、細かな指摘、lintだけで検出する問題、テスト不足だけの指摘は除外する。候補を個別に再確認し、重複を除く。公式内蔵ローカル版が公開資料で明記する単一背景Subagentの体験に合わせ、プラグイン版の複数Agent構成や80点閾値は導入しない。
- `low` / `medium` / `high` / `max` と `--max-findings` はレビュー指示として扱う。OpenCodeにはClaude Codeのeffort値の継承・記憶や共通effort APIがないため、モデルに調査範囲を伝える方式であり、数値スコア閾値ではない。
- レビュー出力と問題なしの明示は日本語。モデル候補は現在の `opencode models` と実リクエストで確認した。DeepSeek V4 Proはリージョン設定またはOpenCodeアカウント残高により利用できなかったため、提示された比較表でPrecisionが最も高いKimi K2.7 Code（F1 43.1 / Recall 37.9% / Precision 50.0%、`opencode-go/kimi-k2.7-code`）を、現在のOpenCode Go経由で利用できる候補として選び、特に誤検知を抑える方針を優先する。

### 再現しない機能・制約

- `--fix` はレビューAgentのread-only権限と両立しないため、差分を書き換えず指摘だけ返す。修正はユーザーがメインAgentへ別途依頼する。
- `--comment` / `--post` はGitHub/GitLabへの書込みを許可せず、実行しない。
- `ultra` はClaude Codeのクラウドレビュー機能であり、OpenCodeのローカルCommandから実行できない。
- OpenCodeにはClaude Codeのeffort記憶、組織のクラウドレビュー、Claudeの固有レビューUIはない。PRの状態による自動スキップやクラウド上の複数Agent統合も移植していない。

### 使い方

home-managerで設定リンクを反映した後、TUIで `/code-review` を実行する。例：

```text
/code-review
/code-review high src/auth.ts
/code-review main...feature/auth
/code-review 123 --max-findings 5
```

新しいAgentとCommandは `nix/home.nix` の個別リンクで配布する。設定を有効化するにはユーザーが `home-manager switch --flake ~/Dev/kaishi/ubuntu-dotfiles#ubuntu` を実行する必要がある。
