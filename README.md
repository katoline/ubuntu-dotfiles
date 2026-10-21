# dotfiles

## 概要
Ubuntu環境全体をNix（home-manager standalone）で宣言的に管理する個人用dotfilesリポジトリ。CLIツールやGNOMEデスクトップ設定（テーマ・電源管理・キーバインド・Dock等）に加え、ターミナル（zsh / Oh My Zsh / Powerlevel10k）、tmux（iPhone SSH切断後も grok を残す）、VSCode / Cursor の共通設定（settings・keybindings・拡張機能）、gitconfig、Claude Code / Grok / OpenCode / Codex / Devin の共通AIエージェント設定（指示・スキル・コマンド・権限・フック）を管理する。グローバル指示の実体は `ai/`（共通コア＋CLI別差分）の1か所で、`ai/install.sh` が各CLIへ配る。`.claude/`はClaude CodeとGrok向け、`opencode/`はOpenCode向け、`codex/`・`devin/`はそれぞれのCLI向けの設定で、home-managerがリンクまたはホーム側の実ファイルへの宣言設定のマージで配る。共通のGitHub Actionsワークフロー（`.github/`）もここで管理し、他リポジトリへコピーして使う。Nixで管理できないGUIアプリ・IME（Google Chrome・VSCode・Slack・ibus-mozc等）やOh My Zsh・Claude Code・Grok CLI・OpenCode・Codex CLI・Devin CLI、外出先のiPhoneからTailscale経由でSSHするためのOpenSSH / Tailscaleは`bootstrap.sh`が導入する。tmux本体はNix、SSH時の自動attachは`.zshrc`。

## 技術スタック
- Nix / home-manager standalone（Ubuntu環境の宣言的管理。`flake.nix` + `nix/`。CLIツールとGNOMEデスクトップのdconf設定の両方を含む）
- Zsh（Oh My Zsh + Powerlevel10k。プロンプト設定は`zsh/.p10k.zsh`。本体は`bootstrap.sh`が導入し、あえてNix管理外）
- tmux（`packages.nix`。iPhoneからのSSH時に`.zshrc`が自動attach。切断してもセッションが残る）
- VSCode / Cursor（`vscode/`配下の共通設定をhome-manager経由で書き込み可能リンクし、拡張機能をactivation時に自動導入）
- direnv / nix-direnv（`nix/home.nix`のhome-manager設定で導入。`.envrc`のあるプロジェクトディレクトリでflakeのdevShellを自動ON/OFF）
- Bash（`bootstrap.sh`、`.claude/setup.sh`、`.claude/hooks/`配下のシェルスクリプト）
- 全CLI共通のグローバル指示（`ai/core.md` ＋ CLI別差分。`ai/install.sh` が Claude Code へはリンク、OpenCode / Grok / Codex / Devin へは連結生成で配る。詳細は`ai/README.md`）
- Claude Code（`settings.json` / Skills / Agents / Hooksによるグローバル設定管理）
- Grok CLI（xAI。`grok/config.toml`をhome-manager経由で書き込み可能リンク。グローバル指示は`ai/`から連結生成。本体は`bootstrap.sh`が公式インストーラーで導入）
- OpenCode（`opencode/`のSkills / Commands / permissions / CLI設定をhome-manager経由でリンク。単体でも普通に使え、Claude Code / Codexの親セッションから呼ばれたときだけ `delegated-worker` Agentで軽量に動く。本体は公式インストーラーで導入）
- Codex CLI（OpenAI。home-managerが`codex/config.toml`・`hooks.json`の宣言値をホーム側の実ファイルへマージし、フックスクリプト・スキル・旧プロンプトはリンクする。共通スキルの入口は[codex/README.md](/codex/README.md)を参照。本体は`bootstrap.sh`が公式インストーラーで導入。反映とUbuntuのサンドボックス対策は`codex/README.md`）
- Devin CLI（Cognition。home-managerが`devin/config.json`の宣言値をホーム側の実ファイルへマージし、`org_id`等のローカル状態を保持する。本体は`bootstrap.sh`が公式インストーラーで導入）
- Web Push通知（dotfiles内蔵の送信スクリプト`claude-notify/send-push.mjs`が、Claude/GrokのStop・Notification時にiPhoneへプッシュ通知。OpenCodeからは送らない。受信側PWAは別リポジトリ`claude-notify-mobile`をVercelで配信。Node.js + `web-push` + `jq`）
- GitHub Actions（`.github/workflows/`配下で共通ワークフローを管理し、他リポジトリへ配布）
- GitHub CLI（`gh`、`/pr`スキル内でPR作成に使用）

## ディレクトリ構成
```
dotfiles/
├── README.md
├── AGENTS.md              # Claude Code / OpenCode共通のリポジトリ固有指示
├── flake.nix              # Nix環境のエントリポイント（home-manager standalone）
├── flake.lock             # パッケージバージョンの固定（`nix flake update`後は必ずコミット）
├── bootstrap.sh           # 新しいUbuntuマシンの1コマンドセットアップ
├── nix/
│   ├── README.md          # Nix運用の詳細ドキュメント
│   ├── packages.nix       # CLIツール（git・gh・vim・Node.js等。Nixで管理）
│   ├── home.nix           # home-manager設定（zsh・gitconfig・Grok/OpenCode・VSCode/Cursorのリンク、VSCode IME用起動ラッパー、拡張機能、direnv、.claude/、claude-notify依存、ghエイリアス、GNOME Terminal見た目、既定ブラウザ、作業ディレクトリ作成（`.claude/dev-roots` から導出））
│   ├── keyboard.nix       # GNOMEのキーボード設定（JIS配列・IME切り替え・キーリピート delay=180ms / interval=20ms・TUI向け embed-preedit-text=false）
│   └── desktop.nix        # GNOMEデスクトップ設定（テーマ・電源・キーバインド・Dock・ウィンドウボタン左上。VSCode側は vscode/）
├── git/
│   ├── README.md
│   └── .gitconfig         # gitconfigの実体（home.nixが~/.gitconfigへ書き込み可能リンク。user.name/emailは~/.gitconfig.localに手動配置）
├── ai/                    # 全CLI共通のグローバル指示（実体はここ1か所）
│   ├── README.md          # 各CLIの読み込み規則と配り方・重複を避ける方針
│   ├── core.md            # 共通ルール（言語・Git・削除・検証・レビューの範囲・秘密情報・Nix・サブエージェント・compact）
│   ├── claude.md          # Claude Code固有（モデル運用とレビューのモデル分離・フックの挙動）
│   ├── grok.md            # Grok固有
│   ├── opencode.md        # OpenCode固有
│   ├── codex.md           # Codex固有
│   ├── devin.md           # Devin固有
│   └── install.sh         # 各CLIのグローバル指示ファイルへ配布（リンク or 連結生成。switch時にも自動実行）
├── grok/
│   ├── README.md
│   └── config.toml        # Grok CLI（xAI）の設定実体（home.nixが~/.grok/config.tomlへ書き込み可能リンク）
├── codex/
│   ├── config.toml        # Codex CLIの設定（承認ポリシー・サンドボックス）
│   ├── README.md          # 設定反映・フック信頼・CLIとdesktop・Ubuntuのサンドボックス対策
│   ├── hooks.json         # Codexのフック登録（PR制限・削除ガード・変更後の検証ゲート）
│   ├── hooks/guard.sh     # /pr 外のコミット・push・PR操作と危険な操作を拒否（拒否専用）
│   ├── hooks/harness.sh   # Claudeの事故防止ガード・検証ゲートをCodexイベントへ接続
│   ├── skills/            # ~/.codex/skills への個別リンク（共通手順のCodex用入口）
│   └── prompts/pr.md      # Codexの旧 /prompts:pr 入口（新しい入口は $pr）
├── devin/
│   └── config.json        # Devin CLIの設定（permissions・他ツールのルール読み込みの可否）
├── opencode/
│   ├── README.md          # OpenCode設定とClaude Code / Codexからの委譲範囲
│   ├── opencode.json      # 権限設定（既定build・delegated-worker・Git/PR/worktree等）
│   ├── cli.json           # TUI設定（ダークテーマ・権限確認・OS通知）
│   ├── plugins/mobile-notify.js # 通知を無効化した互換入口（home-managerリンク維持）
│   ├── commands/          # /pr・/readme・/clean-branches・/nix-setup・/git-pull・/code-review
│   ├── agents/            # /pr 専用Agentとread-onlyレビューAgent
│   ├── skills/pr/SKILL.md # OpenCode用のPR作成手順
│   └── setup.sh           # OpenCode公式インストーラー
├── vscode/
│   ├── README.md          # VSCode/Cursor共通設定の詳細ドキュメント（統合ターミナルの日本語IME含む）
│   ├── settings.json      # エディタ設定の実体（両エディタで共有）
│   ├── keybindings.json   # キーバインドの実体（両エディタで共有）
│   ├── code               # snap VSCodeのIME用起動ラッパー（home.nixが~/.local/bin/codeへリンク）
│   ├── extensions.txt     # 導入する拡張機能のIDリスト
│   └── install-extensions.sh # 拡張機能をVSCode/Cursorへ導入（activation時に自動実行）
├── commands/
│   ├── claude-code.md    # Claude Code組み込みスラッシュコマンド一覧（リファレンス）
│   └── private.md        # このリポジトリで使えるコマンド・スキルの個人用早見表
├── .github/
│   ├── dependabot.yml               # Nix・pnpm・GitHub Actionsの日次更新
│   └── workflows/
│       ├── ci.yml                   # このリポジトリの検証（verify）
│       ├── delete-merged-branch.yml # PRマージ後にheadブランチを自動削除
│       └── request-dependabot-review.yml # Dependabot PRでレビューを自動依頼
├── zsh/
│   ├── .zshrc            # Oh My Zsh + Powerlevel10k、SSH時のtmux attach、direnv フック
│   ├── .bashrc           # 対話bashを即zshへexecする引き継ぎ用
│   ├── .p10k.zsh         # Powerlevel10kの見た目設定（macOS風の最小構成）
│   └── README.md
├── tmux/
│   ├── README.md         # SSH切断後もセッションを残す説明
│   └── .tmux.conf        # 256色・履歴（home.nix が ~/.tmux.conf へリンク）
├── claude-notify/         # iPhoneプッシュ通知の送信スクリプト（Claude/Grokフックから呼ばれる）
│   ├── README.md
│   ├── send-push.mjs     # Web Push送信本体（VAPID署名。設定は ~/.claude/claude-notify.json）
│   ├── package.json      # web-push と開発用の Biome
│   └── pnpm-lock.yaml    # node_modules は activation 時に自動導入（gitignore）
├── ssh-tailscale/         # iPhoneからTailscale経由SSH（OpenSSH + Tailscale。本体はNix管理外）
│   ├── README.md         # iPhone側の接続手順とUbuntu側の残作業
│   └── setup.sh          # OpenSSH / Tailscale を冪等に導入（bootstrap と home-manager switch から実行）
└── .claude/
    ├── settings.json      # フック・permissions・env・languageなどの設定
    ├── setup.sh           # .claude/ 配下（gitが管理するファイル）を ~/.claude へシンボリックリンク
    ├── dev-roots          # 削除・作業ディレクトリ作成の許可ルートの唯一の定義
    ├── claude-notify.example.json # iPhoneプッシュ通知設定のテンプレート（~/.claude/claude-notify.json へコピー）
    ├── hooks/
    │   ├── notify.sh                 # Stop/Notification時にiPhoneへWeb Push通知
    │   ├── pr-mode.sh                # /pr 実行中だけgit操作を自動許可、それ以外は拒否
    │   ├── guard-destructive.sh      # 回復不能な操作（rm -rf・破壊的git操作等）を止める
    │   ├── verify-gate.sh            # dotfilesの検証コマンドを通すまでターンを終えさせない
    │   ├── validate-claude-config.sh # 設定ファイル編集直後の構文検証
    │   ├── lib/strip-shell.awk       # 引用符・HEREDOC除去の共通ライブラリ
    │   └── lib/scan-secrets.sh       # コミットされる差分の既知のトークン形式を検査（pr-mode.shが呼ぶ）
    ├── agents/Explore.md  # 読み取り専用の探索エージェント（haiku固定。組み込みを上書き）
    ├── skills/
    │   ├── pr/SKILL.md            # /pr スキル
    │   ├── readme/SKILL.md        # /readme スキル
    │   ├── clean-branches/SKILL.md # /clean-branches スキル
    │   ├── nix-setup/SKILL.md     # /nix-setup スキル
    │   ├── git-pull/              # /git-pull スキルと共有スクリプト
    │   └── opencode/              # /opencode（Claude Code）/ $opencode（Codex）からOpenCodeへ実装を委譲
    ├── tests/             # フックのテーブル駆動テスト（run.shで一括実行。~/.claude へは配布しない）
    └── README.md
```

## セットアップ
### 新しいUbuntuマシンのセットアップ（Nix）
```zsh
curl -fsSL https://raw.githubusercontent.com/seino914/ubuntu-dotfiles/main/bootstrap.sh | bash
```
`bootstrap.sh`が前提パッケージ（git・curl・zsh）の確認、Nix（Determinate Systemsインストーラー）の導入、`~/Dev/kaishi/ubuntu-dotfiles`へのクローン、`flake.nix`の`username`書き換え、home-managerの初回適用（tmux・`.tmux.conf`・SSH時の自動attach、Claude Code / Grok / OpenCode / Codex / Devinの設定配布（リンク・実ファイルへのマージ）と、`ai/install.sh`による共通指示の配布を含む）、ログインシェルのzshへの変更、Oh My ZshとPowerlevel10kの導入、Claude Code / Grok / OpenCode / Codex / Devin CLIの導入（取得や実行に失敗したCLIは警告して飛ばし、最後に一覧で再掲する）、さらにNixで管理できないGUIアプリ・IME（ibus-mozc・mozc-utils-gui・VSCode・Slack・Google Chrome）のapt/snap経由での導入、OpenSSHサーバーとTailscaleの導入までを1コマンドで行う（冪等。sudoが使えない環境では該当ステップを警告してスキップする）。初回の `home-manager switch` は VSCode 導入より先に走るため、拡張機能は bootstrap 完了後にもう一度 `home-manager switch` する。手動で必要な残作業（`~/.gitconfig.local`の配置、`~/.claude/claude-notify.json`の配置、Docker Engineの導入、各AIツールの認証、`sudo tailscale up`、iPhoneのTailscale / SSHアプリ等）は[nix/README.md](/nix/README.md)と[ssh-tailscale/README.md](/ssh-tailscale/README.md)を参照。tmuxは追加作業なし（SSHした時点で入る）。

### Nix環境の適用・更新（2回目以降）
```zsh
home-manager switch --flake ~/Dev/kaishi/ubuntu-dotfiles#ubuntu
```
設定ファイル（`flake.nix` / `nix/*.nix`）を変更した後に実行する。sudoは不要だが環境そのものを書き換えるため、Claude Codeからは実行せずユーザーが手動で行う。

### Claude Code設定の反映
```zsh
bash ~/Dev/kaishi/ubuntu-dotfiles/.claude/setup.sh
```
`.claude/`配下のうちgitが管理するファイル（`setup.sh`・`README.md`・`tests/` 等の除外分を除く）が`~/.claude`へシンボリックリンクされる（`home-manager switch`時にはactivationからも自動実行される）。

### 全CLI共通のグローバル指示の配布
```zsh
bash ~/Dev/kaishi/ubuntu-dotfiles/ai/install.sh
```
`ai/core.md`（共通ルール）と`ai/<cli>.md`（CLI別差分）を各CLIへ配る。Claude Codeは`~/.claude/CLAUDE.md`・`~/.claude/rules/claude.md`へのリンクなので編集が即反映され、OpenCode / Grok / Codex / Devinは`~/.config/opencode/AGENTS.md`・`~/.grok/AGENTS.md`・`~/.codex/AGENTS.md`・`~/.config/devin/AGENTS.md`への連結生成なので`ai/`を編集したら再実行する（`home-manager switch`時にも自動実行される）。詳細は[ai/README.md](/ai/README.md)。

### OpenCode

`bootstrap.sh`がOpenCode CLIを公式インストーラーで導入する。設定はhome-managerで`~/.config/opencode/`へリンクされる。xAI/Grokを使う場合はOpenCode起動後に`/connect`で接続し、`/models`でモデルを選ぶ。詳細は[opencode/README.md](/opencode/README.md)。

### Codex

home-managerが`config.toml`・`hooks.json`の宣言値をホーム側の実ファイルへマージし、trust・フックの信頼ハッシュ等のローカル状態をホーム側に残す。フックスクリプト・個人用スキル・旧プロンプトはリンクする。Claude Codeと共通の手順を使うスキルの入口は[codex/README.md](/codex/README.md)を参照。フック追加・変更後は新しいチャットの`/hooks`で内容を確認して信頼する。反映方法、CLIとdesktopの違い、Ubuntuで通常のシェル操作が承認を求め続ける場合の対処は[codex/README.md](/codex/README.md)。

### zsh設定の反映
```zsh
source ~/.zshrc
```

## コマンド
### Nix環境
```zsh
# 適用（設定ファイル変更後）
home-manager switch --flake ~/Dev/kaishi/ubuntu-dotfiles#ubuntu

# 初回（home-manager未導入時）
nix run home-manager/master -- switch --flake .#ubuntu -b hm-backup

# パッケージのバージョン更新（実行後、flake.lock を必ずコミット）
nix flake update
```

### AIエージェント用コマンド・スキル
- `/pr`：Claude Code / Grok / Codex / OpenCode単体では明示的な `/pr` 起動（OpenCodeは発言先頭の `@pr` も）で、変更をコミットしブランチをpushしてGitHubへPull Requestを作成する（通常の「PRを出して」だけでは起動しない。親から委譲された `delegated-worker` は commit / push / PR を行わない）
- `/readme`：READMEをコードベースの現状に合わせて更新（なければ新規作成）する
- `/clean-branches`：ローカルブランチのうちmain・develop以外を削除して整理する
- `/nix-setup`：新規プロジェクトの開発環境をNixのdevShell + direnvでセットアップする
- `/git-pull`：ワークスペース直下のリポジトリをmainに切り替えてfast-forward-onlyでpullする（変更中や分岐したリポジトリは保全）
- `/opencode` / `$opencode`：Claude Codeの `/opencode`、Codexの `$opencode` からOpenCodeを非対話で起動して実装を任せ、結果を親CLIがレビューする。新しいランナーは自動で `delegated-worker` Agentを使い、commit / push / PR・worktree変更・ユーザーへの質問・子への再委譲を行わない（OpenCode単体は build のままで通常どおり使える）。既定は `opencode/deepseek-v4.1-flash-free` で、利用上限時のみ `opencode/glm-5.3-flash-free` → `opencode-go/deepseek-v4.1-flash` へ切り替える。通常は今回の依頼だけ、`--session-wide` は現在の会話の以後の実装すべて、`--once` は解除。詳細は [Claude用](/.claude/skills/opencode/SKILL.md)・[Codex用](/codex/skills/opencode/SKILL.md)

### セットアップスクリプト
- `bash .claude/setup.sh`：`.claude/`配下（gitが管理するファイルのみ）を`~/.claude`へシンボリックリンク
- `bash ai/install.sh`：`ai/`の共通指示を各CLIへ配布（冪等。`ai/`を変更したら実行する）
- `bash .claude/tests/run.sh`：各CLI設定JSON（`settings.json`・`opencode/`・`codex/`・`devin/`）とシェル・awkの構文チェック、SKILL.md / agents の frontmatter、`settings.json`のフック・statusLineの登録元検査、git-pullの一時リポジトリ統合テスト、フック（pr-mode・guard-destructive・verify-gate・validate-claude-config）と共通指示配布（ai-install）のテーブル駆動テスト。test-pr-mode.sh は HOME を隔離するので本物の `~/.claude/pr-mode.log` は増えない。`.claude/`・`ai/`・`codex/`・`devin/`・`opencode/`を変更したら必ず通す
- `nix eval --raw .#homeConfigurations.ubuntu.activationPackage.drvPath`：`flake.nix` / `nix/`の評価エラーと`git add`漏れを検出（`switch`の前に流す）
- `.claude/dev-roots`（削除・作業ディレクトリの許可ルート。1行1パス・`~/`始まり・`#`から行末はコメント）を変更したときは、`git add .claude/dev-roots`のうえで上記を実行し、`bash .claude/setup.sh`も再実行する
- `bash vscode/install-extensions.sh`：`vscode/extensions.txt`の拡張機能をVSCode/Cursorへ導入（`home-manager switch`時にも自動実行される。冪等）
- OpenSSH / Tailscale：`bootstrap.sh` と `home-manager switch` の両方で `ssh-tailscale/setup.sh` が自動実行される（ログインだけ `sudo tailscale up` が手動。iPhone側は [ssh-tailscale/README.md](/ssh-tailscale/README.md)）

### GitHub Actionsワークフローのコピー
`ci.yml` の `verify` は main 向けPRと main へのpushで設定・シェル構文・Nix評価・claude-notify の Biome を検証する。このリポジトリ専用なので、他リポジトリへは共通ワークフローだけをコピーする。導入したいリポジトリのルートに移動して、そのまま実行する：
```zsh
mkdir -p .github/workflows
cp ~/Dev/kaishi/ubuntu-dotfiles/.github/workflows/{delete-merged-branch,request-dependabot-review}.yml .github/workflows/
```

### コマンドリファレンス（[commands](/commands/private.md)）
- `commands/claude-code.md`：Claude Code組み込みスラッシュコマンドの一覧表
- `commands/private.md`：このリポジトリで使えるスキル・コマンドの個人用早見表

## 設定一覧
- [Nix](/nix/README.md)
- [zsh](/zsh/README.md)
- [VSCode](/vscode/README.md)
- [git](/git/README.md)
- [全CLI共通のグローバル指示（ai/）](/ai/README.md)
- [Grok](/grok/README.md)
- [OpenCode](/opencode/README.md)
- [Claude Code](/.claude/README.md)
- [claude-notify](/claude-notify/README.md)
- [iPhoneからSSH（Tailscale）](/ssh-tailscale/README.md)
- [tmux](/tmux/README.md)
