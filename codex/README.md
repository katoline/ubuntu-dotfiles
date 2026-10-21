# Codexの設定とハーネス

Codex CLIとdesktopの個人用設定。Claude Codeと共通の指示・スキル手順を使い、コミット制限、削除の事故防止、dotfiles変更後の検証をCodexのフックへ接続する。

## 管理するファイル

| 実体 | 配布先・役割 |
| --- | --- |
| `config.toml` | `~/.codex/config.toml`。ユーザーのモデル・reasoning effort、`on-request` と `auto_review` と `workspace-write`、ネットワーク設定 |
| `hooks.json` | `~/.codex/hooks.json`。PR起動判定、シェル操作のガード、変更と検証の記録、終了時の検証ゲート |
| `hooks/guard.sh` | `~/.codex/hooks/guard.sh`。明示的なPRモード以外でcommit・push・PR操作を拒否 |
| `hooks/harness.sh` | `~/.codex/hooks/harness.sh`。Claudeの事故防止・検証ゲートをCodexのイベントへ接続 |
| `skills/*` | `~/.codex/skills/*`。Codex用の入口から `.claude/skills/` の共通手順を読む |
| `prompts/pr.md` | `~/.codex/prompts/pr.md`。旧 `/prompts:pr` 入口 |
| `../ai/core.md`・`../ai/codex.md` | `bash ai/install.sh` が `~/.codex/AGENTS.md` を連結生成 |

`nix/home.nix` の `mergeCliConfigs` が宣言設定をホーム側の実ファイルへマージする。モデルとreasoning effortはユーザーがリポジトリで決め、次のswitchでその値を反映する。ホーム側のUIだけで変更した宣言キーは次のswitchで戻る。Claude専用のモデル名やAgent設定は移植しない。

リポジトリにはモデル・承認・サンドボックス・desktop表示設定・pluginの有効化を置く。`projects`、`hooks.state` の信頼ハッシュ、TUIの初回案内状態、marketplaceの配置、desktop生成MCPの実行パス・環境変数はホーム側だけで保持する。Devinの `org_id`・`shell.setup_complete` も同じ扱いにする。未知のローカルキーは削除せず、宣言したキーを再帰的に上書きする（配列は置き換える）。宣言からキーを削除しても既存のホーム側の値は残るので、値を無効にするには宣言値を変更するか、ホーム側で対象キーを削除する。[公式設定の層](https://learn.chatgpt.com/docs/config-file/config-basic)、[公式設定リファレンス](https://learn.chatgpt.com/docs/config-file/config-reference)

`node_repl` の起動定義はdesktopに任せ、起動定義がホーム側にある場合だけ `enabled = true` を反映する。新規ホームに起動パスのないMCPを生成しない。pluginの配置・版はdesktopが生成したローカル状態を保持し、固定のキャッシュパスを宣言しない。

`hooks.json` は `~/.codex/hooks/` 配下のファイルを指す登録と、宣言と完全一致する登録を管理対象として宣言分に置き換え、それ以外（Orca等の外部登録）は残す。管理フックの削除やmatcher変更も反映する。私用のフックは `~/.codex/hooks/` に置かず（home-manager がリンクする置き場）、そこ以外に置く。登録順の変更で再確認が必要になる場合があるが、信頼ハッシュは変更せず保存する。生成処理は全設定を構文検査してから同じディレクトリの一時ファイル経由で置き換え、不正な設定は上書きせず失敗する。

## 旧リンクからの移行

**この変更をメインのチェックアウトへ取り込む前に**、ユーザーが次を実行する。旧リンクがリポジトリを指したまま宣言設定を更新すると、リンク先から外したローカル状態は後のactivationでは復元できない。設定内容を出力せず、現在のリンク先の内容をホーム側の実ファイルへ退避する。

```zsh
cp -L -p ~/.codex/config.toml ~/.codex/config.toml.local-migration &&
  mv -T ~/.codex/config.toml.local-migration ~/.codex/config.toml
cp -L -p ~/.codex/hooks.json ~/.codex/hooks.json.local-migration &&
  mv -T ~/.codex/hooks.json.local-migration ~/.codex/hooks.json
cp -L -p ~/.config/devin/config.json ~/.config/devin/config.json.local-migration &&
  mv -T ~/.config/devin/config.json.local-migration ~/.config/devin/config.json
```

ファイルが未作成のCLIは対応する2行を実行しない。取り込み後のswitchでは `detachCliConfigLinks` が旧管理リンクを `linkGeneration` より先に実ファイル化し、その後マージする。以後は外部ツールが実ファイルを更新してもリポジトリへ取り込まない。この作業でユーザーのホームやリンクを変更するのはユーザーが実行する移行とswitchだけ。

## 反映と使い方

マージのactivationとテストは、`flake.nix` の `cli-config-python` に定義した `tomlkit` 入りのPythonを共有する。`bash .claude/tests/run.sh` は `python3` に `tomlkit` が無ければ、flakeが固定したnixpkgsからこのPythonを自動取得する（初回は時間がかかる）。Nixが使えないなど取得に失敗した場合は、原因を表示してテストを失敗させる。Pythonを明示する場合は `CLI_CONFIG_PYTHON=/path/to/python3 bash .claude/tests/run.sh` とする。この場合は自動取得せず、指定したPythonに `tomlkit` が必要。

```zsh
bash .claude/tests/run.sh
nix eval --raw .#homeConfigurations.ubuntu.activationPackage.drvPath
bash ai/install.sh

# 設定・フック・スキルのリンク追加を反映する操作はユーザーが実行する
home-manager switch --flake ~/Dev/kaishi/ubuntu-dotfiles#ubuntu
```

以前 `~/.agents/skills/` に配布した5つの管理リンクは、上の `home-manager switch` で `~/.codex/skills/` へ移行する。ユーザーが追加した別スキルは管理対象にしない。移行後は各CLIで新しいチャットを開始し、スキル一覧を再読み込みする。

新しいCodexチャットを開始し、`/hooks` で各フックの内容を確認して信頼する。未信頼の非管理フックは実行されず、定義変更後は再確認が必要。信頼状態やハッシュはエージェントが書き換えない。[公式Hooks](https://learn.chatgpt.com/docs/hooks)

操作の承認は既定で `approvals_reviewer = "auto_review"` により自動レビューへ回す。再起動後の新しいチャットで反映を確認する。フックの信頼確認は別途ユーザーが行う。[公式Auto-review](https://learn.chatgpt.com/docs/sandboxing/auto-review)

| Claude Codeの入口 | Codexの入口 |
| --- | --- |
| `/pr` | `$pr`（旧 `/prompts:pr` も維持） |
| `/readme` | `$readme` |
| `/nix-setup` | `$nix-setup` |
| `/git-pull` | `$git-pull` |
| `/clean-branches` | `$clean-branches` |
| `/opencode` | `$opencode` |

Codex CLI 0.162.1は従来の `$CODEX_HOME/skills`（通常は `~/.codex/skills`）をユーザースキルの互換探索先として読む。他CLIも探索する `~/.agents/skills` へCodex専用の入口を配ると、Grok・OpenCode・DevinにもCodex用の指示が混入するため、専用の探索先へ隔離する。[公式実装](https://github.com/openai/codex/blob/rust-v0.162.1/codex-rs/ext/skills/src/host_roots.rs)

この探索先はdeprecatedとして互換維持されているため、将来Codexの探索仕様が変わる際は配置先を再確認する。

### OpenCodeへの委譲（`$opencode`）

`codex/skills/opencode/SKILL.md` は、Codex から OpenCode へユーザーが明示的に作業を委譲したとき（`$opencode` や「OpenCodeに任せて」）の入口。Codex が要件整理・設計・指示・レビューを担い、OpenCode が実装・調査・検証を担う。ランナーは自動で `delegated-worker` Agent を使い、単体の OpenCode（既定 build）とは分離する。worker は commit / push / PR・worktree 変更・ユーザーへの質問・子への再委譲をしない。オプションなしは今回だけ、`--session-wide` は現在の親会話で以後の実装も委譲、`--once` は解除。継続指定は親会話の状態としてのみ持ち（compact 要約に有効/無効を残す）、設定ファイル・環境変数・フックでは永続化せず、別チャットへ持ち越さない。

実行は Claude Code と共通のランナー `bash ~/.claude/skills/opencode/scripts/run.sh --dir /abs/path/to/project --title 'codex: 作業名'` に heredoc で自己完結した指示を渡す（Codex 専用の実行スクリプトは持たない）。委譲範囲のオプションはスキルが解釈し、ランナーには渡さない（ランナーの `--session` は OpenCode セッション再開用）。既定モデルは `opencode/deepseek-v4.1-flash-free`。利用上限（レート制限・quota）のときだけ `opencode/glm-5.3-flash-free` → `opencode-go/deepseek-v4.1-flash` の順に自動切替し、Go まで上限なら非0で停止する。認証・地域拒否・権限拒否・通信・モデル不存在・context length などは切り替えず停止する。ユーザーが `--model` を明示した場合は自動切替しない。`--auto` は使わない。

Go の利用上限後に従量残高を消費しないため、利用者は Console で Use balance を無効にしておく（Go サブスク枠内に留める前提。設定や認証は読まず変更しない。権限付与ではない）。

Codex の sandbox・承認・フックは OpenCode 内のツールに引き継がれないため、必要な制約は委譲プロンプトに書く。Codex は `git diff` でレビューし、追加の修正は `--session` で再依頼する。Codex 本体のモデル設定は変更しない。配布は `nix/home.nix` の `.codex/skills/opencode` リンクで行い、`home-manager switch`（ユーザーが実行）後に新しいチャットでスキル一覧を再読み込みする。

スキルは `$名前` で明示起動できる。PRは文中の `$pr`（Codex と同じく直前の文字は問わず、直後が英数字・`_` `:` `-` 以外のとき。`$prでPRを作って` も起動し、`$prune` は対象外）、または前後の空白を除いた依頼文の先頭語が `/pr`・旧 `/prompts:pr` の場合だけ起動する。説明文中の `/pr` や自然言語の「PRを出して」では起動しない。旧custom promptは非推奨なので、新しい入口にはスキルを使う。[公式Skills](https://learn.chatgpt.com/docs/build-skills)、[公式Custom Prompts](https://learn.chatgpt.com/docs/custom-prompts)

CodexのPreToolUseは拒否専用で、Claudeのフックによる自動承認は使えない。共通の事故防止ガードが確認（ask）を求める操作は、承認情報の有無にかかわらず常に拒否する。`approvals_reviewer = "auto_review"` では承認がAIの自動レビューへ回るため、`require_escalated` の再試行でユーザー確認を代替しない。対象のコマンドと理由を示し、ユーザーに手動実行を依頼する。`clean-branches` の未マージブランチ強制削除も同様に、候補の一覧と理由、手動実行するコマンドを示す。拒否対象は停止し、別の書き方やツールで迂回しない。

Codexはフックがタイムアウト・失敗すると止めずにツールを実行する（Claudeの `onFailure: "block"` に当たる設定が無い）ため、PreToolUseの `harness.sh`・`guard.sh` のtimeoutは30秒にしている。SessionEndのtimeoutはCodexの上限（3秒）を超えると毎回切り詰めの警告が出るため3秒にしている（処理はフラグの削除だけ）。

PRモードは起動したターンだけ有効。`Stop` で終了した後は、検証ゲートによって続行する場合も `$pr` の再起動が必要になる。PR手順では検証を先に済ませ、commit・push・PR操作が終わるまでターンを終えない。

CLI 0.162.1では、実行中のプロセスにはPostToolUseを発火せず、`write_stdin` で完了を取得すると `Bash` として元のコマンドと出力を渡す。`tool_input` は `{command: 元コマンド}`、`tool_response` は切り詰め済みの出力文字列で、実行中のツール応答にある `session_id` とフックのpayloadは同一ではない。長い検証は完了まで待ち、実行中なら `write_stdin` で完了結果までポーリングする。[完了時のフック呼び出し](https://github.com/openai/codex/blob/rust-v0.162.1/codex-rs/core/src/tools/handlers/unified_exec/write_stdin.rs#L158-L169)、[フック入力の生成](https://github.com/openai/codex/blob/rust-v0.162.1/codex-rs/core/src/tools/context.rs#L432-L445)

終了コードはフックに通知されず、検証ゲートは完了時の出力にある成功行で判定する。成功行が実行中のpollで消費されると最終pollには残らず、検証済みにならない。長い検証は `yield_time_ms` を長めにして完了まで待ち、成功行が完了結果に含まれることを確認する。非0終了でも成功行を含む出力は、このフック入力だけでは区別できない。

`write_stdin` を別のツール名で配信する他ランタイムへの対応は未確認。CLIの実装から、desktopなどでも同じフック入力になるとは推測しない。

CLI 0.162.1の `exec_command` は PreToolUse の入力に `workdir` を含めず、入力の cwd はセッション（ターン）の cwd になる。そのため `workdir` を指定した相対パスの削除は、削除ガードがセッションの cwd 基準で判定してしまう。削除・移動の対象は絶対パスで書き、`workdir` と相対パスを組み合わせない。

## CLIとdesktopの違い

CLI 0.162.1では `hooks`・`multi_agent` は既定で有効。機能を使うためだけの重複設定は追加しない。[公式設定リファレンス](https://learn.chatgpt.com/docs/config-file/config-reference)

desktopは独自のランタイム、承認UI、pluginsを持つ。`config.toml` のdesktop・marketplace・plugin・MCP設定はdesktopが更新することがあり、CLIの設定を直しただけで実行中のdesktopチャットへ全て反映されるとは扱わない。新しいチャットでスキル一覧と `/hooks` を確認する。CLIのシェルイベントに接続したフックが、別のMCPツールやクラウド実行にも適用されるとは扱わない。共通指示とプロジェクトの `AGENTS.md` は各環境で維持する。

## Ubuntuのサンドボックスエラー

`bwrap: setting up uid map: Permission denied` が出ると、通常の読み取り・検証まで承認が必要になる。2026-10-13の実機ではUbuntu 24.04.5、`/usr/bin/bwrap` は存在するが `kernel.apparmor_restrict_unprivileged_userns=1` で、`bwrap-userns-restrict` のAppArmorプロファイルが配置されていなかった。

Codexは `PATH` で最初に見つかる `bwrap` を使う。Ubuntu 24.04では公式手順に沿ってbubblewrap用のAppArmorプロファイルを追加し、`workspace-write` を維持して通常操作を動かす。以下はOSへの変更なのでユーザーが実行する。[公式Sandbox](https://learn.chatgpt.com/docs/sandboxing)

```zsh
sudo apt update
sudo apt install bubblewrap apparmor-profiles apparmor-utils
sudo install -m 0644 \
  /usr/share/apparmor/extra-profiles/bwrap-userns-restrict \
  /etc/apparmor.d/bwrap-userns-restrict
sudo apparmor_parser -r /etc/apparmor.d/bwrap-userns-restrict
```

反映後はCodexを起動し直し、`codex sandbox -- true` と、通常の読み取り・検証が承認なしで動くことを確認する。プロファイルがパッケージに含まれなければその時点で止めてOS側を確認する。
