# ai/ — 全CLI共通のグローバル指示

Claude Code・Grok・OpenCode・Codex・Devin の 5 つの CLI へ、**同じ共通ルールを 1 か所から**配るディレクトリ。

## 方針

- 共通ルールの実体は [`core.md`](core.md) だけ。CLI 別ファイルには**その CLI でしか成り立たない差分**しか書かない
  - 同じ内容を各 CLI のファイルへ書くと、セッションごとに同じ文章を二重に読ませてコンテキストを圧迫し、片方だけ直して食い違う
  - 逆に「共通ルールは他のファイルを見ろ」と参照だけ書くのも避ける（CLI によっては読みに行かないため、実質ルールが無い状態になる）
- 共通ファイルは短く保つ。人間向けの経緯・理由は README とブロック HTML コメントに置く（Claude Code は読み込み前にブロックコメントを除去する）
- プロジェクト固有のルールは各リポジトリの `AGENTS.md` に書き、ここへ重複させない

## ファイル

| ファイル | 役割 |
| --- | --- |
| `core.md` | 共通ルール（言語・Git操作の制限・ファイル削除とプロセス停止・変更後の検証・レビューの範囲・秘密情報・Nix運用・サブエージェント・compact時に残すこと） |
| `claude.md` | Claude Code 固有（モデル運用とレビューのモデル分離、フックの挙動） |
| `grok.md` | Grok 固有（サブエージェントの種類、permission mode と `/pr`） |
| `opencode.md` | OpenCode 固有（単体はメイン担当、`delegated-worker` は親から委譲された実装・調査・検証担当、Hooks が動かないこと） |
| `codex.md` | Codex 固有（`config.toml` / `hooks.json`、拒否専用フック、個人用スキルと `$pr`） |
| `devin.md` | Devin 固有（`config.json` の permissions、クラウド側セッションの注意） |
| `install.sh` | 上記を各 CLI のグローバル指示ファイルへ配布する（冪等） |

## 各CLIへの配り方

CLI によって「グローバル指示をどこから読むか」「複数ファイルを読めるか」が違うため、include を持つものはリンク・設定で参照させ、持たないものだけ連結生成する。

| CLI | 読み込み先 | 配り方 |
| --- | --- | --- |
| Claude Code | `~/.claude/CLAUDE.md`（全セッション）＋ `~/.claude/rules/*.md`（frontmatter の `paths` が無ければ常時読み込み） | `core.md` と `claude.md` へのシンボリックリンク。**リンク先の実体が即更新される**（再実行は不要）。ただし実行中のセッションは読み込み時点の版を使い続ける（再起動か `/clear` で読み直す） |
| OpenCode | `~/.config/opencode/AGENTS.md` | `core.md` + `opencode.md` を連結生成。V2 は `AGENTS.md` のみを読み、`CLAUDE.md` へのフォールバックは無い。`instructions` はファイル・glob・URL を解決するが、`ai/` を列挙すると二重読みになるため使わない |
| Grok | `~/.grok/AGENTS.md` | `core.md` + `grok.md` を連結生成（`config.toml` の `[compat.claude] rules = false` で Claude のルールは読ませない） |
| Codex | `~/.codex/AGENTS.md`（`AGENTS.override.md` があればそちらが優先される） | `core.md` + `codex.md` を連結生成 |
| Devin | `~/.config/devin/AGENTS.md` | `core.md` + `devin.md` を連結生成（`devin/config.json` の `read_config_from.claude = false` で Claude のルールは読ませない） |

連結生成した 4 つ（OpenCode / Grok / Codex / Devin）は `ai/*.md` を編集したら再配布が必要：

```zsh
bash ~/Dev/kaishi/ubuntu-dotfiles/ai/install.sh
```

`home-manager switch` の activation（`nix/home.nix` の `linkAiInstructions`）でも自動実行される。生成ファイルの先頭には「自動生成（編集しない）」と実体のパスが入る。

Codexの個人用スキルは `nix/home.nix` が `codex/skills/` から従来の互換探索先 `~/.codex/skills/` へ個別にリンクする。他CLIも探索する `~/.agents/skills/` にCodex専用の指示を置かない。各スキルは `.claude/skills/` の共通手順を必要時に読む。Claude専用のモデル名・ツール権限はCodexへ持ち込まない。スキル入口の対応表、旧管理リンクからの移行と新しいチャットでの確認は [`../codex/README.md`](../codex/README.md) を参照。

## 他のCLI互換読み込みを切る理由

Grok（`[compat.claude]` の `rules` と `agents`。`agents` が `~/.claude/CLAUDE.md` の読み込みを制御する）と Devin（`read_config_from.claude`）は Claude Code の指示ファイルを読み込む機能を持つが、どちらも切っている（Grok の `skills` と `hooks` は共有したいので true のまま）。入れると `~/.claude/CLAUDE.md` と自分の `AGENTS.md` の両方に共通ルールが載って二重読みになり、Claude 固有のモデル名やフックの記述まで持ち込まれるため。

OpenCode V2 は `AGENTS.md` のみを読み、V1 の `CLAUDE.md` フォールバックは使わない。`~/.config/opencode/AGENTS.md` を消すと共通ルールと `ai/opencode.md` の両方が読まれなくなるため、連結生成したファイルを維持する。`opencode.json` の `instructions` はファイル・glob・URL を解決できるが、`ai/` を列挙すると `AGENTS.md` と二重読みになるため列挙しない（[V2の指示](https://opencode.ai/v2/docs/instructions/)・[V1からの移行](https://opencode.ai/v2/docs/migrate-v1/)）。

## 変更したときの検証

```zsh
bash .claude/tests/run.sh   # install.sh の構文・配布の挙動（test-ai-install.sh）・各CLI設定JSONの構文
```

## 既知の制約

- CodexはCLI 0.162.1で設定の読み込みを確認している。フック判定は `.claude/tests/test-codex-guard.sh` などの模擬入力で検査する。実行中のdesktopセッションへの反映は、新しいチャットとフックの信頼確認が必要（[`../codex/README.md`](../codex/README.md)）。Devinの設定と `AGENTS.md` の配置は実機未確認
- Claude Code 以外は生成物なので、`ai/*.md` を直してから `install.sh` を流すまでの間は古い内容が読まれる
- Claude Code の指示も、シンボリックリンクの実体更新と実行中セッションの再読は別。変更は再起動か `/clear` まで反映されず、プロジェクトルートの `CLAUDE.md` だけは `/compact` でも読み直される（[memory](https://code.claude.com/docs/en/memory)）。このリポジトリは `AGENTS.md` に集約しているので `CLAUDE.md` は新設しない
- プロジェクト側の読み込み規則は CLI ごとに違う（Claude Code は v2.1.277 以降、プロジェクト指示の設定が既定の `claude-md-or-agents-md` で、作業ディレクトリより上に `CLAUDE.md` / `CLAUDE.local.md` が無ければ `AGENTS.md` を読む。OpenCode / Codex / Grok / Devin は `AGENTS.md`）。このリポジトリは `AGENTS.md` に集約している
