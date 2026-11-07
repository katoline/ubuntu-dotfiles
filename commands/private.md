# コマンド

ルート README のコマンド節からの個人用早見表。詳細・設計理由は各ディレクトリの README を見る。

## Claude Code

### Skills
```
/pr
/readme
/clean-branches
/nix-setup
/git-pull
/opencode
```

`/opencode` は Claude Code 専用で、OpenCode へ実装を委譲する（既定は `opencode/deepseek-v4.1-flash-free`）。Claude Code では全セッションで常時有効で、実装・調査・テストは明示的な呼出しがなくても委譲する。利用上限時は GLM 5.3 Flash Free → Go → Sonnet 5.5（従量課金）へ自動切替。Codex からは `$opencode` を使う（Codex でも常時有効）。詳細は [`.claude/skills/opencode/SKILL.md`](../.claude/skills/opencode/SKILL.md) と [`codex/skills/opencode/SKILL.md`](../codex/skills/opencode/SKILL.md)。

## OpenCode

```text
/pr
/readme
/clean-branches
/nix-setup
/git-pull
/code-review
```

単体起動はメインが Opus 5.5（設計・レビュー）、サブエージェントが DeepSeek V4.1 Flash Free（実装・調査）で、`/code-review` も Opus 5.5。Claude Code / Codex の `/opencode`・`$opencode` から呼ばれたときだけ `delegated-worker` Agent（commit / push / PR・worktree 変更・質問・再委譲なし）で動く。

OpenCodeのグローバル設定は [`opencode/README.md`](../opencode/README.md)。設定リンクは `home-manager switch`、CLIは次のコマンドで導入する：

```zsh
bash ~/Dev/kaishi/ubuntu-dotfiles/opencode/setup.sh
```

## Codex

```text
/pr
$opencode
```

`$opencode` は Codex から OpenCode へ実装を委譲する入口で、メインセッションでは明示しなくても常時委譲する。Codex のサブエージェントは独立レビュー（`reviewer`）だけに使う。PR作成の手順の実体は `.claude/skills/pr/SKILL.md`（`codex/prompts/pr.md` がそれを読ませる）。既定ブランチへのコミット・push と PR のマージは `codex/hooks/guard.sh` が拒否する。設定は [`codex/`](../codex)。

## Grok / Devin（休止中）

設定は [`archive/`](../archive/README.md) に保管（配布・導入しない）。

### 設定の配布・検証
```zsh
bash ~/Dev/kaishi/ubuntu-dotfiles/.claude/setup.sh      # .claude/ を ~/.claude へリンク（ファイル追加後に再実行）
bash ~/Dev/kaishi/ubuntu-dotfiles/ai/install.sh         # 全CLI共通のグローバル指示を各CLIへ配布（ai/ の変更後に再実行）
bash ~/Dev/kaishi/ubuntu-dotfiles/.claude/tests/run.sh  # 構文チェック＋フック・配布のテスト
nix eval --raw .#homeConfigurations.ubuntu.activationPackage.drvPath
```

## Github Workflow

```zsh
mkdir -p .github/workflows
cp ~/Dev/kaishi/ubuntu-dotfiles/.github/workflows/*.yml .github/workflows/
```

## zsh

```zsh
source ~/.zshrc
```

## PCセットアップ

### 初回

```zsh
curl -fsSL https://raw.githubusercontent.com/seino914/ubuntu-dotfiles/main/bootstrap.sh | bash
```

### 2回目以降

```zsh
home-manager switch --flake ~/Dev/kaishi/ubuntu-dotfiles#ubuntu
```

### 手動残作業（新マシン）

- `~/.gitconfig.local` に `user.name` / `user.email`
- `~/.claude/claude-notify.json`（iPhone通知を使う場合）
- Docker Engine + `docker` グループ
- `gh auth login`、SSH鍵、各アプリへのサインイン
- `sudo tailscale up`（未ログインのときだけ。iPhone側は `ssh-tailscale/README.md`）
- iPhone SSH は自動で tmux（切断しても claude / codex 等が残る。詳細は `tmux/README.md`）

OpenSSH / Tailscale は `bootstrap.sh` と `home-manager switch` が `ssh-tailscale/setup.sh` を実行する。

### パッケージの更新

```zsh
cd ~/Dev/kaishi/ubuntu-dotfiles
nix flake update
home-manager switch --flake .#ubuntu
```
