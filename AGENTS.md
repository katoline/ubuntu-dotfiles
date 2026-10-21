# ubuntu-dotfiles 固有の指示

Ubuntu用の個人dotfiles。全体像は `README.md`、Nix運用は `nix/README.md`、全CLI共通のグローバル指示は `ai/README.md`、各CLIの設定は `.claude/README.md`・`grok/README.md`・`opencode/README.md`。ここには作業ミスを防ぐ制約と検証方法だけを書く。

## 指示ファイル

- このリポジトリの指示はこの `AGENTS.md` だけ（`CLAUDE.md` は作らない）。Claude Code・OpenCode・Codex・Grok・Devin のいずれも `AGENTS.md` を読む。
- グローバル指示の実体は `ai/` の1か所（共通コア `ai/core.md` ＋ CLI別差分 `ai/<cli>.md`）。配布は `ai/install.sh`（読み込み規則と配り方は `ai/README.md`）。プロジェクト固有ルールを `ai/` へ書かず、共通ルールをCLI別ファイルへ重複させない。
- `ai/core.md` は5つのCLIが毎セッション全文を読むので短く保つ。CLI固有の記述（Claudeのモデル名・`settings.json`・Hooksの書き方）は `core.md` に置かない。経緯は各READMEへ。

## 脅威モデル（レビューの前提）

`.claude/hooks/`・`codex/hooks/`・`opencode/hooks/`・`opencode/plugins/shared-harness.js`・`.claude/skills/`・`ai/install.sh`・`bootstrap.sh`・`opencode/setup.sh` は**事故防止の部品**（操作者はユーザーとAIエージェントだけ）。普通の使い方で起きる事故だけを見て、難読化・敵対的な回避は対象外（共通指示の「レビューの範囲」）。例外は `claude-notify/` と `~/.claude/claude-notify.json`（VAPID秘密鍵を扱い外部へ送信する）で、秘密情報としてセキュリティの前提で見る。

## リポジトリ固有の制約

- `bootstrap.sh`・`opencode/setup.sh` は検証目的で実行しない（インストールを行う）。`home-manager switch` も実行せず、評価後にユーザーへ依頼する。
- 各CLI（Claude Code / Grok / OpenCode / Codex / Devin）をNix管理へ移さない（常に最新版を使うため公式インストーラー。導入は `bootstrap.sh`）。各CLIの認証情報と `~/.claude/claude-notify.json` は読まず保存しない。Claude/GrokのHooks・モデル設定が他CLIでも動くとは扱わない。
- 連結生成した `~/.config/opencode/AGENTS.md`・`~/.grok/AGENTS.md`・`~/.codex/AGENTS.md`・`~/.config/devin/AGENTS.md` を手で編集しない（実体は `ai/`、再配布は `bash ai/install.sh`）。`~/.config/opencode/AGENTS.md` は消さず、`opencode.json` の `instructions` に `ai/` を列挙しない（`instructions` はファイルを解決できるが、`AGENTS.md` と `core.md` の二重読みになる。理由は `ai/README.md`）。
- `grok/config.toml` の `[compat.claude]` は `rules = false`・`agents = false` を維持（true に戻すと `~/.claude/CLAUDE.md` を読んで二重になる）。`skills`・`hooks` は共有のため true のまま。
- `.claude/` は全プロジェクトに反映される。home-manager標準管理へ移さない（`setup.sh` のセルフヒーリングを維持）。`~/.claude/rules/claude.md`（実体 `ai/claude.md`）はClaude Code専用なので共通ルールを置かない。
- `.claude/settings.json` の Orca 由来のフック・`statusLine`（コマンドに `orca` を含むもの）は手で編集しない。`pr-mode.sh`・`guard-destructive.sh` の `onFailure: "block"` を外さない（外すとフックが壊れたとき黙って素通りになる）。登録元が増えたら中身を確認して `tests/run.sh` の許可リストに足す。
- `/pr` はSkill・共通指示・permission・Hookの四層で整合させる（対象コマンドを足すときは四層すべて）。`skills/pr/SKILL.md` の先頭H1とGrok用 `<!-- pr-mode-enable -->`、`codex/skills/pr/SKILL.md`・`codex/prompts/pr.md` の同マーカーは起動判定に使うため消さない。OpenCode 単体は `/pr` Command と `@pr` を持ち、commit / push / PR は通常 ask。親から委譲された `delegated-worker` だけが commit / push / PR を拒否する。
- `.claude/hooks/guard-destructive.sh` の拒否パターンを際限なく増やさない（解釈不能な書き方は説明付き確認に倒す設計を維持）。削除可能ルートの定義は `.claude/dev-roots` だけ。パスのパターンは `*dotfiles/…` と書く（リポジトリ名が `ubuntu-dotfiles` でも一致させるため）。
- `.claude/hooks/verify-gate.sh` の分類表（run.sh / nix eval）は下の「検証」節と対応させる。対象を増やしたら両方に足す。
- `codex/hooks/guard.sh` は拒否専用（Codex の PreToolUse は承認を返せない前提）。`.claude/hooks/lib/git-write.sh` はClaude（`pr-mode.sh`）・Grok・Codex（`guard.sh`）の共有判定で、変更時は `tests/test-pr-mode.sh` と `tests/test-codex-guard.sh` の両方を通す。Codexの `guard.sh` 変更時は後者、`harness.sh` 変更時は `tests/test-codex-harness.sh` を通す。
- `nix/home.nix` の構成名は `ubuntu` 固定、`username` を動的取得にしない（flakeは環境変数を読めない）。`keyboard.nix` の ibus `embed-preedit-text = false` は戻さない。`editorUserFiles` の `force = true` を外さず、`window.titleBarStyle` / `menuStyle` / `menuBarVisibility` は一緒に変更する。`direnv` を `enableZshIntegration` に置き換えない（`~/.zshrc` は `mkOutOfStoreSymlink` 管理）。
- `user.name` / `user.email` をリポジトリに書かない。

## ファイル追加・変更

- flakeはgit管理ファイルだけを評価する。新しい `.nix` を評価するときは先にユーザーへ `git add` を依頼する（`vscode/` の配布にはpushが必要）。
- `.claude/` の追加・削除は `bash .claude/setup.sh` で配布する（対象はgit管理ファイルのみ。`.claude/tests/` はリンク対象外）。
- `opencode/`・`codex/`・`devin/` の設定・Command・Agent・Skill は `nix/home.nix` から個別にリンクする。新しいファイルにはリンクを足す（グローバル指示は `ai/install.sh` が生成するのでリンクしない）。`delegated-worker` は `opencode/opencode.json` の `agents` に定義し、新規 `.nix` や staging を増やさない。`~/.codex/hooks.json`・`~/.codex/config.toml`・`~/.config/devin/config.json` は実ファイルにして、`detachCliConfigLinks`・`mergeCliConfigs` が外部ツールのローカル状態を保持する（リポジトリへの取り込みやリンクへの復元はしない）。
- `.claude/dev-roots` は1行1パス・`~/` 始まり（`#` 以降・前後の空白・末尾 `/` は無視）。読む側は `guard-destructive.sh`・`nix/home.nix`（`devDirs`）・`tests/test-guard-destructive.sh`。変更時は `git add .claude/dev-roots` をユーザーに依頼し、Nix評価・テスト・配布を通す。

## 作業記録（docs/）

`docs/` はgitignore対象の手元資料置き場で、コミットしない。後からの参照と不具合調査のため、作業の記録をここにためる。

- このリポジトリのファイルを追加・変更したら、ターンを終える前に `docs/changes/YYYY-MM-DD-<英小文字slug>.md` へ記録する（同じ日の同じ話題は追記）。書くこと：日付、変更したファイル、何をなぜ変えたか、検証コマンドと結果、影響範囲と戻し方、未解決点、関連PR・コミット。
- 変更を伴わない調査でも、結論を後で参照する価値があれば `docs/notes/YYYY-MM-DD-<slug>.md` に残す。
- ワークツリー（Orca 等）で作業していても、メインのチェックアウト（`git worktree list` の先頭）の `docs/` に書く。
- 不具合の調査では、まず該当ファイル名や症状で `docs/` を grep して過去の変更を確認する。

## 検証

検証の原則（通す・落ちたら直す・無効化で通さない・無ければ「未検証」と書く）は共通指示の「変更後の検証」。このリポジトリのコマンドは次のとおり。

- `flake.nix` / `nix/` の変更後：`nix eval --raw .#homeConfigurations.ubuntu.activationPackage.drvPath`
- `nix/merge-cli-config.py` の変更後：`bash .claude/tests/run.sh` と `nix eval --raw .#homeConfigurations.ubuntu.activationPackage.drvPath` の両方
- `.claude/`・`ai/`・`codex/`・`devin/`・`opencode/` の設定と `bootstrap.sh` の変更後：`bash .claude/tests/run.sh`（設定JSON・シェル・JS・awkの構文、SKILL.md / agents の frontmatter、settings.json のフック登録元、フックと共通指示配布・OpenCode adapter/plugin のテーブル駆動テスト）
- `ai/` の変更後は配布のため `bash ai/install.sh` も実行する（Claude Code 以外は連結生成）
- シェル変更時：対象に応じて `bash -n bootstrap.sh` / `bash -n opencode/setup.sh` / `bash -n zsh/.zshrc`（`run.sh` が見るのは上記の対象のみ）
- `claude-notify/` の変更後：`cd claude-notify && pnpm lint`
- CI（`.github/workflows/ci.yml` の `verify`）は同じ検証（`run.sh`・シェル構文・Nix評価・Biome）を main 向けPRと main へのpushで実行する。
