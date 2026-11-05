# Claude Code設定

## 概要

`~/.claude` の実体。ここを編集するとコミット前でも全プロジェクトの Claude Code / Grok に即反映される（構成と注意点はリポジトリ直下の `AGENTS.md` を参照）。Grok は `compat.claude.hooks`（デフォルト有効）で同じ `settings.json` の hooks を読む。

## ファイル構成

| ファイル | 役割 |
| :--- | :--- |
| `settings.json` | Claude Code の設定（フック・言語・effortLevel・permissions など） |
| （グローバル指示） | 実体はリポジトリの [`ai/`](../ai/README.md)。`ai/install.sh` が `~/.claude/CLAUDE.md` → `ai/core.md`（全CLI共通）、`~/.claude/rules/claude.md` → `ai/claude.md`（Claude Code 固有のモデル運用とフックの挙動）のリンクを張る。`.claude/setup.sh` の配布対象ではない |
| `hooks/notify.sh` | Stop / Notification 時に iPhone へプッシュ通知するフック（送信本体は `claude-notify/send-push.mjs`）。Claude / Grok |
| `hooks/pr-mode.sh` | 既定ブランチへの git commit / push を拒否し、マージ以外のツール利用を自動承認する。確認ダイアログは既定ブランチを base にする PR のマージだけ（Claude / Grok） |
| `hooks/guard-destructive.sh` | 回復不能な操作（ルート・ホーム直下の削除、破壊的git操作等）を機構的に止めるフック |
| `hooks/verify-gate.sh` | dotfiles の検証対象ファイルを編集したセッションで、対応する検証コマンド（`bash .claude/tests/run.sh` / `nix eval`）が成功するまでターンを終えさせないフック。Stop は `stop_hook_active=false` なら block して block 済みマーカーを作り、`true` かつマーカーあり（自分の block の 2 回目）なら systemMessage で警告して記録を消す。`true` でもマーカーが無ければ他フックの block 由来なので block する。マーカーは検証対象の再編集で消え、もう一度だけ止める。block 後の再編集で再 block する挙動は Codex にも適用される |
| `hooks/completion-gate.sh` | ファイルを変更したターンの Stop で「完了チェック（PDCA の Check）」を最大3回まで促し、要件ごとの根拠・検証・独立レビュー・付随作業の確認を報告させるフック。このセッションが起動した OpenCode（ランナーの起動形を検出して記録）が実行中のときだけ完了待ちとみなして促さない。既知の制約: 抑止は「このセッションが起動した（`opencode=1`）」と「同じリポジトリ（git common-dir が同じ）のどこかでランナーが動いている」の組み合わせで判定するため、自分のランナーが終わった後でも、同じリポジトリの別 worktree で別セッションのランナーが動いている間は抑止される |
| `hooks/validate-claude-config.sh` | `~/.claude` 配下の設定ファイル編集直後にJSON構文・シェル構文・frontmatterを検証するフック |
| `hooks/lib/strip-shell.awk` | シェルコマンド文字列から引用符の中身とHEREDOC本文を除去する共通ライブラリ（pr-mode.sh・guard-destructive.shが利用） |
| `hooks/lib/scan-secrets.sh` | コミットされる差分の追加行を既知のトークン形式で検査する（pr-mode.sh が commit を自動承認する直前に呼ぶ） |
| `hooks/lib/opencode-running.sh` | 委譲した OpenCode（`.claude/skills/opencode/scripts/run.sh`）が指定ディレクトリで実行中かを判定する共通関数（`notify.sh` の Stop 通知抑止と `completion-gate.sh` の完了チェック抑止が使う） |
| `agents/Explore.md` | 組み込みの Explore を上書きする読み取り専用の探索エージェント定義（`model: haiku` 固定・`omitClaudeMd` でグローバル指示を読ませない） |
| `dev-roots` | Claude Code が確認なしで削除・移動できる作業ルートの**唯一の定義**（1行1パス、`~/` 始まり、`#` から行末はコメント、前後の空白と末尾の `/` は無視、`~/` 始まり以外の行は読まれない）。`hooks/guard-destructive.sh`・`nix/home.nix`（`devDirs`）・`tests/test-guard-destructive.sh` が同じ読み方で読む。変更したら `git add` すること（flakeはgit追跡ファイルしか読まない） |
| `skills/readme/SKILL.md` | `/readme` スキル：READMEを最新状態に更新（なければ新規作成） |
| `skills/pr/SKILL.md` | `pr` スキル：作業完了時または `/pr` 起動時に、変更をコミット・pushしてGitHubにPRを作成（マージはしない） |
| `skills/clean-branches/SKILL.md` | `/clean-branches` スキル：ローカルブランチのうちデフォルトブランチ・使用中のブランチ以外を削除して整理（未マージは確認後のみ） |
| `skills/nix-setup/SKILL.md` | `/nix-setup` スキル：新規プロジェクトの開発環境をNix devShell + direnvでセットアップ |
| `skills/git-pull/SKILL.md` | `/git-pull` スキル：直下の各リポジトリを `main` に切り替えてfast-forward-onlyでpull（変更があるリポジトリはスキップ） |
| `skills/opencode/SKILL.md` | `/opencode` スキル：Claude Code から OpenCode を非対話で起動して作業を任せ、結果を要約・レビューする。Claude Code では全セッションで常時有効で、実装・調査・テストは明示的な呼出しがなくても OpenCode へ委譲する（`--session-wide` / `--once` は廃止。Codex の `$opencode` は従来どおりオプションなしは今回だけ・`--session-wide`・`--once`）。既定モデル `opencode/deepseek-v4.1-flash-free`、利用上限時は `opencode/glm-5.3-flash-free` → `opencode-go/deepseek-v4.1-flash` → `console-anthropic/claude-sonnet-5-5#medium`（Anthropic API の従量課金）の順に自動切替し、Sonnet まで上限なら停止（`--model` 明示時は切替なし、`--auto` は使わない）。Go は Console の Use balance を無効にする前提。Claude Code 専用（OpenCode では `opencode.json` で deny）。Codex は `codex/skills/opencode/SKILL.md` から同じ `scripts/run.sh` を使う。ランナーは OpenCode を `--agent delegated-worker`（Skill / subagent / question / execute・Git 書き込み・PR・worktree 変更なし）で起動し、単体の build とは分離する |
| `claude-notify.example.json` | iPhoneプッシュ通知（claude-notify）設定のテンプレート |
| `setup.sh` | `.claude/` 配下（gitが管理するファイルのみ）を `~/.claude` へシンボリックリンクするスクリプト |
| `tests/` | git-pull の一時リポジトリ統合テスト、フックのテーブル駆動テスト（pr-mode / guard-destructive / verify-gate / completion-gate / validate-claude-config / Grok 互換 / Codex の `codex/hooks/guard.sh`）、OpenCode 委譲ランナーのモデル切替テスト（opencode-run）、OpenCode の単体 build / `delegated-worker` の実効 permission テスト（opencode-permissions）、共通指示の配布テスト（ai-install）。一括実行は `bash .claude/tests/run.sh`（配布対象外） |

## セットアップ（反映方法）

```zsh
bash ~/Dev/kaishi/ubuntu-dotfiles/.claude/setup.sh
```

`.claude/` 配下でgitが認識しているファイル（追跡済み＋未追跡かつ`.gitignore`対象外。gitが使えない環境では`find`にフォールバックし、除外リストだけで秘密ファイル等を守る）が `~/.claude` へシンボリックリンクされる。ディレクトリ構成はそのまま再現される。グローバル指示（`~/.claude/CLAUDE.md` と `~/.claude/rules/claude.md`）は全CLI共通の [`ai/`](../ai/README.md) が実体なので、こちらではなく `bash ai/install.sh` が配る。以後はこのリポジトリを編集するだけで全プロジェクトに即反映される（コピー作業は不要）。

ただし「リンク先の実体が更新される」ことと「実行中の LLM セッションが指示を読み直す」ことは別。グローバル指示はセッション開始時に読み込まれた版が使われ、変更は再起動か `/clear` まで反映されない。プロジェクトルートの `CLAUDE.md` だけは `/compact` でも読み直されるが、このリポジトリは `AGENTS.md` に集約しており `CLAUDE.md` は新設しない（`AGENTS.md` が compact で再読されるかは断定しない）。詳細は [memory](https://code.claude.com/docs/en/memory)。

- **ファイルを追加したら再実行するだけ**でリンクされる（スクリプトの修正は不要）
- `skills/` や `commands/` などのディレクトリを作れば、そのまま `~/.claude` 配下に反映され、Claude / Grok で使える
- リポジトリから削除・除外されたファイルの切れたリンク（旧パスを指すものを含む）は、再実行時に自動で掃除される
- `setup.sh`・`README.md`・`claude-notify.example.json`・`tests/`（フックのテスト。配布不要）・`claude-notify.json`・`settings.local.json`（秘密鍵・プロジェクト固有設定）・エディタの一時ファイルやバックアップ（`*.swp`・`*~`・`*.backup.*` 等）はリンク対象外
- 既に正しいリンクが張られているファイルには触らない（冪等。inodeを変えないので `switch` 中にリンクが一瞬消える窓もできない）
- 1ファイルの失敗で処理は止まらない。失敗はまとめて末尾に表示され、スクリプトは非ゼロで終了する

### Claude Code が設定を書き込んだ場合の挙動

`/model` や `/config` などセッション内での設定変更は、シンボリックリンクを辿って**そのままリポジトリ側の `settings.json` に書き込まれる**。変更内容は `git diff` で確認してコミットするだけでよい。

万一リンクが実体ファイルで上書きされた場合（Claude Codeが設定保存時に一時ファイル＋renameのアトミック書き込みを行うため起こりうる。[claude-code#40857](https://github.com/anthropics/claude-code/issues/40857)）、`setup.sh` を再実行すると自動でセルフヒーリングする：

- 実体側がリポジトリ側より新しければ、**内容をリポジトリへ取り込んだうえでリンクを張り直す**（`git diff` で確認してコミット）
- 実体側がリポジトリ側より古ければ、`~/.claude/.setup-backups/` へ退避してからリンクを張り直す

## settings.json

- `permissions.deny`：`~/.claude/claude-notify.json`・`~/.claude/history.jsonl` に加え、SSH秘密鍵・AWS認証情報・`gh` の hosts.yml・Docker設定・`.netrc`・GPG鍵・kubeconfig・`.npmrc`・主要な `.env` 変種（`.env.example` は除く。一覧は settings.json）などの秘密ファイルの読み取りと `sudo` の実行を禁止（詳細は settings.json）
- `permissions.ask`：`git commit` / `git push` / `gh pr create` / `gh pr new` / `gh pr edit` / `gh pr merge` に加え、`apt` / `snap`・`npm install -g` 系・`pip install --user`・`pipx`・`uv tool install`・`cargo` / `gem` / `go install`・`nix profile` / `nix-env`・`home-manager` など、プロジェクト外へ恒久的な変更を及ぼすコマンドを実行前に必ず確認（詳細は settings.json）。Grok の always-approve でもシェルの ask ルールは効く
- `hooks`：`PreToolUse`(Bash) で `hooks/pr-mode.sh` と `hooks/guard-destructive.sh`、`PermissionRequest`(*) で `hooks/pr-mode.sh`、`PostToolUse`(Edit|Write|NotebookEdit|write|search_replace) で `hooks/validate-claude-config.sh` と `hooks/verify-gate.sh` と `hooks/completion-gate.sh`、`PostToolUse`(Bash) で `hooks/verify-gate.sh` と `hooks/completion-gate.sh`、`UserPromptSubmit` で `hooks/completion-gate.sh`、`Stop` で `hooks/verify-gate.sh` と `hooks/completion-gate.sh`、`Stop` / `Notification`(matcher: `permission_prompt`) で `hooks/notify.sh`。Grok の matcher `Bash` は `run_terminal_command` にも当たる
  - `PreToolUse` の `hooks/pr-mode.sh`・`hooks/guard-destructive.sh` は、高負荷時の打ち切りを減らすため timeout を30秒とし、`onFailure: "block"` を付けている。**外さないこと**（外すと安全装置が壊れたとき＝起動不能・タイムアウト・想定外の exit コードのときに黙って素通りになる）。代償として、フックのファイルが消える・壊れると全 Bash が止まる
  - Orca（エージェント管理アプリ）が書き込んだフックと `statusLine`（コマンドに `orca` を含むもの）は外部ツール由来なので手で編集しない。`tests/run.sh` が「登録元が `bash $HOME/.claude/hooks/<実在するスクリプト>` か許可リストの外部ツールか」を検査し、知らない登録元が増えたら落ちる
- `env.CLAUDE_CODE_SUBAGENT_MODEL`：`opus`（サブエージェントの既定モデル。振り分けは `ai/claude.md`）
- Agent ツール呼び出しの `effort`（`ai/claude.md` でレビュー用サブエージェントに `medium` を渡す指定）は Claude Code v2.1.292 以降が対応（[Choose an effort level](https://code.claude.com/docs/en/sub-agents)）。サブエージェントのモデル既定値 `CLAUDE_CODE_SUBAGENT_MODEL` は変更しない
- `skipWorkflowUsageWarning`：`true`
- `theme`：`dark`
- `model`：`/model` で Claude Code 自身が書き換えるため現在値は転記しない（実際の値は settings.json を参照）
- `language`：`japanese`
- `effortLevel`：`/effort` や `/config` で Claude Code 自身が書き換えるため、このREADMEには現在値を転記しない（実際の値は settings.json を参照。差分はコミットするだけでよい）
- `tui`：`fullscreen`
- `agentPushNotifEnabled`：`false`（Remote Control接続時にClaudeの判断でスマホへプッシュ通知する公式機能。バックグラウンドのエージェント実行でも通知が飛ぶため無効。claude-notifyとは別系統で、こちらの通知は維持する）

## Git操作の制限（既定ブランチ保護）

方針は「既定ブランチ（`main` / `master` / `origin/HEAD` の指すブランチ）への commit・push は常に拒否し、それ以外の作業ブランチでの commit・push・PR の作成と更新は自動承認する。確認ダイアログを出すのは既定ブランチを base にする PR のマージだけ」。`/pr` は同じ手順を明示的に起動する入口で、許可判定は `/pr` を起動したかどうかに依存しない。判定の実体は `hooks/lib/git-write.sh` の1か所で、Claude / Grok / OpenCode の adapter / Codex が共有する。

各層の役割：

- `ai/core.md`（`~/.claude/CLAUDE.md`）：検証が通ったら作業ブランチで commit・push・PR 作成まで進めること、既定ブランチへは commit・push しないこと、PR のマージはユーザーの明示的な指示があるときだけ行い自分から提案しないことを指示する（Claude が試みること自体を抑止）
- `skills/pr/SKILL.md`：手順（検証→現状把握→ブランチ準備→コミット分割→push と PR 作成→報告）と、自動承認を受けるための単一コマンドの条件
- `settings.json` の `permissions.ask`：`git commit` / `git push` / `gh pr create` / `gh pr new` / `gh pr edit` / `gh pr merge` は設定上の ask（Grok が使う）。Claude では `hooks/pr-mode.sh` の `PermissionRequest` がマージ以外を allow に変える
- `hooks/pr-mode.sh`：状態を持たず、コマンドと対象リポジトリの状態から毎回判定する（`PreToolUse`(Bash) の deny / Grok 用 ask と、`PermissionRequest`(*) の allow）

判定：

- 保護ブランチ：`main`・`master`、および対象リポジトリの `git symbolic-ref --short refs/remotes/origin/HEAD` の `origin/` 以降（取得できなければ `main` / `master` のみ）
- 対象リポジトリ：コマンドに `git -C <dir>` があればその dir、コマンド先頭が `cd <dir> &&`（または `;`。先頭の `(` は読み飛ばすので `(cd <dir> && …)` も解決する）ならその dir（フック入力の cwd からの相対も解決）、それ以外はフック入力の cwd。変数・コマンド置換で解決できないときは cwd
- `PreToolUse`(Bash)：
  - サブエージェントからの git 書き込み、force push、`--all` / `--mirror`、リモートブランチ削除、`--no-verify` の push、保護ブランチへの commit / push を deny する。push の宛先は refspec（`main` / `HEAD:main` / `feat:main` / `refs/heads/main` / `+main` 等）と、refspec 無し・`HEAD` 単独のときの現在ブランチで判定する
  - `--no-verify` / `-n` を含む commit、変数などで宛先を判定できない push、コミットされる差分の秘密情報（`hooks/lib/scan-secrets.sh`）も deny する。`--amend` を含む commit は何も返さない（確認なし）
  - 確認が必要な PR のマージ（既定ブランチ宛・base 判定不能の `gh pr merge`、`gh api` のマージ）は `PreToolUse` で ask を返す。既定ブランチ以外宛の `gh pr merge` は何も返さない（`PermissionRequest` が allow する）
  - Grok は `PermissionRequest` を持たないため、自動承認条件を満たさない git 書き込みも `PreToolUse` で ask にする（always-approve でも確認になる）。stdin は snake_case / camelCase 両対応、ツール名は `Bash` と `run_terminal_command` を見る
- `PermissionRequest`(*)（Claude）：ツールの種類（Bash / Edit / Write / MCP 等）とコマンドの形（複合コマンドを含む）を問わず、次を除いて `behavior: allow` を返す（`PreToolUse` の allow では `permissions.ask` を上書きできないため、確認ダイアログの代替はここで行う）
  - force push、保護ブランチへの commit / push、`--no-verify` / `-n`、削除系 push、宛先を判定できない push は `behavior: deny`
  - PR のマージは何も返さない（= 確認ダイアログ）。`gh pr merge` は対象リポジトリの cwd で `gh pr view <同じ引数> --json baseRefName -q .baseRefName` を実行し、base が `main` / `master` / `origin/HEAD` の指すブランチなら確認、それ以外のブランチ宛なら allow する。base を取得できない・判定できない場合も確認（安全側）。`gh api` の `/pulls/N/merge` への PUT / GraphQL の `mergePullRequest` は常に確認
- 二重化：`PreToolUse` が無効な環境向けに、`PermissionRequest` 側でも保護ブランチ宛・force・削除系・`--no-verify`・宛先不明 push の deny を判定する

Git 書き込みの検出は `git commit` / `git push` / `gh pr create`（`/usr/bin/git` / `\git` / `command \git` / `env X=1 git` のようなエイリアス回避・絶対パスの形も含む）に加え、`gh api` の `/pulls` への書き込み（`-X POST` や `-f` / `--input` による暗黙の POST）と GraphQL の `createPullRequest`（`gh api` / `graphql` の文脈にあるものだけ。`grep createPullRequest` のような単なる文字列一致では反応しない）を対象にする。`gh api` は引用の外の区切り（`;` `&` `|` 改行）で分けた区間ごとに見て（括弧・バッククォートは語を分けるだけ）、前置き語（`timeout` / `nix develop -c` / `env -u …` 等）は問わない（`echo gh api … -f x` のような文字列も書き込み扱いになるのは許容する）。`gh api` の GET（PR 一覧・`/pulls/N/comments` の取得など）は対象外。`bash -c "…"` / `eval` / `bash <<EOF` / `… | sh` のようにシェルへ文字列を渡す形は生文字列で見る（ただし `bash -c` / `eval` のときは HEREDOC 本文を除いた生文字列で見る。`cat > x.sh <<'EOF' … EOF` のようにスクリプトを書き出すだけのコマンドは、本文に `eval` や `git commit` の語があっても bash は実行しないため対象外。シェルに流す HEREDOC・パイプは本文そのものが実行されるので従来どおり本文を見る）。引用符の除去に失敗したとき（awk が読めない等）は生文字列で判定し、fail-open にしない。

git 操作はメインセッションが直接実行する（サブエージェントからの実行はフック入力の `agent_id` で判別して deny する）。判定は状態を持たないため、`session_id` が取れなくてもコマンドと cwd だけで判定する。

CLI ごとの違い：

- Claude Code：`PreToolUse`（deny）と `PermissionRequest`（allow / マージだけ確認）の二段構え。マージ以外はツールの種類・コマンドの形を問わず確認なしで通る
- Grok：`PermissionRequest` が無く `permission_mode = "always-approve"` なので、`PreToolUse` が自動承認条件を満たさない git 書き込みだけ ask にする。force push・保護ブランチ宛・削除系は deny
- OpenCode：`opencode/plugins/shared-harness.js` が `opencode/hooks/harness.sh` 経由で同じ `pr-mode.sh` を呼び、`PreToolUse` の deny と `PermissionRequest` の allow を permission 評価に反映する。`pr-request` の allow はフル入力の単一コマンドだけに使い、複合コマンドで設定の ask を消さない。plugin を読み込めない場合は `opencode.json` の ask が残る。`delegated-worker` と通常 subagent は permission で git 書き込みを拒否する
- Codex：`codex/hooks/guard.sh` が同じ `git-write.sh` を使う拒否専用フック。`PreToolUse` が ask を返せないため、PR のマージ・宛先を判定できない push・`--amend` / `--no-verify` / `-n` も deny する。既定ブランチ以外の commit・push・PR 作成/更新と、`guard-destructive.sh` が確認なしで通す操作は Codex の承認ポリシーに任せる
- Devin：フックが無い。`devin/config.json` の `ask`（commit / push / `gh pr merge`）と `deny`（force push / `sudo`）、共通指示の「既定ブランチでは作業しない」で守る

## 破壊的コマンドのガード

`hooks/guard-destructive.sh`（`PreToolUse`/Bash）は、Git 操作の制限とは独立に「正当な用途がほぼ無い、または取り返しがつかない操作」を機構的に止める。**契約は一文**（フック冒頭のコメントと同じ）：

> 解釈できる削除（対象のコマンド置換・HEREDOC・eval を含まず、対象がすべて許可ルートか一時領域に解決できるもの）は確認なし。致命的な対象と、解釈できたうえで許可ルート外の削除は deny。解釈できない削除・移動、xargs / eval / sh -c 経由、閉じていない引用符・HEREDOC、一括 kill、.git の削除も deny（ask は返さない）。

判定は 4 段構造で、上から順に評価して最初に決まった deny で終了する（ask は返さない）：

1. **致命 deny**（生文字列で判定するので引用符の中でも止まる。`eval` / `sh -c` / `… | sh` / `bash <<EOF` のようにシェルへ文字列を渡す形では、その文字列を bash が実行するので元のコマンド文字列全体にも同じ判定を掛ける。`bash -c "rm -rf ~"` は deny）：ルート・ホーム直下の `rm`、`~/.claude` および dotfiles の `.claude` を対象にした `rm` / `mv`（`settings.json`・`~/.claude/CLAUDE.md`・`ai/core.md`・`ai/claude.md`・`ai/install.sh` は単一ファイルの `rm` でも止める）、`.claude` 配下の設定実体（`hooks` / `skills` / `agents` 等）と `ai/`（全CLI共通のグローバル指示）の再帰削除・移動、`curl|sh` 等のリモートスクリプトのパイプ実行（多段パイプ・`bash <(curl …)`・`sh -c "$(curl …)"`・`eval "$(curl …)"`・`source <(curl …)` / `. <(curl …)` の形も含む）、ディスク操作（`diskutil erase` / `apfs delete`・`dd of=/dev/`・`mkfs` 等）
2. **削除の範囲判定**（`rm` / `rmdir` / `unlink` / `find -delete` / `mv`。`\rm` / `/bin/rm` の表記も含む）：対象を 1 つずつ絶対パスへ解決し、`dev-roots` の各ルートと一時領域（`$TMPDIR`・`/tmp/claude-*`。`TMPDIR` 未設定時は `/tmp` 全体ではなく `/tmp/claude-*` だけ）の**内側**なら確認なしで通す。解決できて外側（`~/Dev` 直下・ホーム・その上・許可ルートそのもの）なら **deny**。解決できない書き方は **deny**。リンクされた git worktree のルート（直下の `.git` が `gitdir: …/worktrees/…` を指すファイル）を `rm -rf` する場合は、許可ルート外でも通す（ルート / ホーム直下 / `~/.claude` 等の致命対象 deny が優先）。加えて dotfiles リポジトリ自体・`.claude` の設定実体・作業中ディレクトリ自身やその親の再帰削除は deny。相対パスは hook 入力の `cwd` 基準で解決し、glob は手前のディレクトリで判定する。カンマ区切りのブレース展開（`{dist,build}`）は bash と同じ順に展開して各パスを判定する（展開後に外へ出る `{dist,../../../Documents}` は deny）。同じコマンドで削除より前に直線的に実行される単純な代入（`S=/tmp/claude-x && rm -rf $S/work`、`export T=$(mktemp -d)` のように一時領域へ作る mktemp も含む）は値で展開してから同じ判定に掛ける（`D=~/Documents && rm -rf "$D"` は deny）。解決するのは、コマンド全体でその変数名が `$NAME` / `${NAME}` の参照以外に現れるのがその代入 1 か所だけのとき（`read NAME`・`printf -v NAME`・`for NAME in`・2 回目の代入などが 1 つでもあれば解決しない）。削除より前（削除文自身の前置きを含む）に制御構文・`{ }`・`( )`・関数定義がある形、`||` の後の代入、パラメータ展開・mktemp 以外のコマンド置換・削除より後の代入も deny
   - 削除（`rm` / `rmdir` / `unlink` / `find`）では、直線的な `cd /絶対パス && … && rm -rf 相対パス` の移動先を基準にする。同じコマンド内で解決済みの変数や `$HOME` も使える。`cd` 後に `;`・`||` 等を挟む形、条件分岐・別スコープ、`cd -`・引数なし・未解決の変数、相対パス・`~` 表記の `cd` は deny。`mv` の `cd` 追跡は対象外。引用符付き `~` の代入（`D="~/orca/workspaces/x/y"`）はシェルで展開されないため解決せず deny
3. **削除語を含むが構造を解釈できない形** → **deny**：`eval` / `sh -c` / `… | sh` / `bash <<EOF` / `xargs` 経由、引用符や HEREDOC が閉じていない書き方。ただし `sh -c` / `bash -c` 等に渡す引用文字列を切り出せて、中に削除・移動などのガード対象語や未解決の展開がなければ、外側の削除は通常の範囲判定を行う
4. **一括 kill と `.git` の削除は deny**：`killall` / `pkill` / `kill -1` / `kill <sig> -1`（`kill` の直接引数だけで判定し、`kill $(head -1 …)`・`kill $(lsof -ti :3000)` は一括指定と見なさない）、リポジトリの `.git` の `rm`。作業ツリー・履歴を壊す git 操作（`reset --hard` / `clean -f` / `checkout`・`switch`・`restore` での全変更破棄 / `branch -D` / `stash drop`・`clear` / rebase / `pull --rebase` / `commit --amend` / `filter-branch` / `reflog expire`・`update-ref -d` / `worktree remove --force`）と絶対パスへの再帰 `chmod` / `chown` は何も返さない（確認なし）

**許可ルートの定義は `dev-roots` だけ**（現在 `~/Dev/kaishi`・`~/Dev/seino914`・`~/Dev/hobby`・`~/orca/workspaces`）。フックは `ALLOWED_ROOTS`（判定）と deny 理由文の表示に使い、`nix/home.nix` の `devDirs` とテスト DR1〜DR3 も同じファイルを読む。

**deny の理由文は「何をするコマンドか（対象を含む 1 文）」＋「対象を具体的なパスで書き直して再実行してください（必要ならユーザーに実行を依頼）」の順**で書く。対象を解決できないときは理由コード（`?cd` / `?var` / `?subst` / `?range` / `?user` / `?cwd`）ごとに `explain_unresolved` が文を作る。理由文の書式はテスト X01〜X21 で固定してあるので、説明を変えたらテストも変える。

判定は `hooks/lib/strip-shell.awk` で引用符の中身と HEREDOC 本文・行末コメントを除いた文字列に対して行い、コミットメッセージ等に含まれるリテラル（`"fix: rm -rf / の誤爆"` など）を誤検知しない（`rm` / `mv` の対象パスを取り出す版でも、引用符の中の空白・`;` `&` `|` を `\001` に置き換えて中身を 1 トークンにする）。`git rm` / `npm rm` / `docker rm` 等のサブコマンドの `rm` も削除判定に掛けない。行継続（`\` + 改行）と行末の演算子（`|` `&&` `||`）は 1 行に結合してから判定する。引用符の扱いは bash に合わせる：`$'…'`（ANSI-C 引用）も引用として扱う一方、二重引用符の中のバッククォート置換と引用符無しタグの HEREDOC（`<<EOF`）本文の `$( )` / バッククォートは bash が実際に実行するので判定対象に戻す（`<<'EOF'` / `<<"EOF"` / `<<\EOF` の本文は展開されないので捨てる）。この awk は「解釈できるか」の分類器であり、取りこぼしは deny に倒れるので網羅性は追わない。`git push` の force / delete は `pr-mode.sh` が扱うためここでは見ない。

**設計方針**：解釈できない削除は「穴」ではなく「deny」に倒す。新しい書き方が見つかっても個別の正規表現を足すのではなく、「解釈不能に分類されて deny になるか」を確認するだけにする（判断基準は `docs/harness-plan-2026-09-05.md` の原則 1〜6、差分の詳細は `docs/harness-changes-2026-09-05.md`。どちらも `.gitignore` 対象の手元資料）。

### 既知の抜け道

正規表現ベースの多層防御の一層であり、次は捕捉しない。`CLAUDE.md` の指示・`permissions.ask`・auto mode の分類器と併用して抑止する：

- **`bash script.sh` のようなスクリプトファイル経由の間接実行**（両フック共通）。フックが見るのは Bash ツールに渡されたコマンド文字列だけで、スクリプトの中身は読まない。そのため拒否メッセージでも「スクリプトに書いて実行する」回避策は案内しない
- **git alias 経由**（`git -c alias.x=commit x`）。`pr-mode.sh` の保護ブランチ判定にも自動承認にも掛からない
- **`pushd` / `GIT_DIR=…` / `--git-dir=…` で対象ディレクトリを切り替える形**。対象リポジトリの解決は `git -C` とコマンド先頭の `cd` だけを見る（先頭の `(` は読み飛ばす）
- `trash` / `rsync --delete` / `> file` での空化 など、`rm` 以外の削除手段（`guard-destructive.sh`）
- シンボリックリンク経由のパス（リンクを解決しない）。`find` は起点ディレクトリだけを検査する

なお `eval` / `sh -c` / `bash -c` のようにシェルへ文字列を渡す形は、保護ブランチの判定に掛からない（git alias と同じ既知の抜け道）。`pr-mode.sh` は状態を持たず、解釈できない形を deny に倒すのではなく自動承認しないだけなので、CLI 側の通常の permission 判定（Claude は `PermissionRequest` の allow、Codex は承認ポリシー）に委ねる。共通指示の「既定ブランチでは commit・push しない」で抑止する。

## 設定ファイルの自動検証

`hooks/validate-claude-config.sh`（`PostToolUse`/Edit・Write・NotebookEdit）は、`~/.claude` または dotfiles の `.claude` 配下を編集した直後に構文を検証する：

- `*.json` → `jq empty`。`settings.json` はさらに、`hooks` が参照する `$HOME/.claude/hooks/…` の実在を確認する（フックの改名・削除と settings.json の更新がずれて、そのフックだけ黙って効かなくなるのを防ぐ）
- `*.sh` → `bash -n`
- `*.awk` → `awk -f` による構文チェック（`hooks/lib/strip-shell.awk` は2フックが共有するため、壊すと両方が生文字列判定へ落ちる）
- `skills/*/SKILL.md`・`agents/*.md` → frontmatter（1行目が `---` で始まる・`name:` がある・`description:` がある）

失敗時は `exit 2` として stderr にエラーを返し、Claude にその場で修正させる（編集自体は巻き戻さない）。Grok の PostToolUse は観察専用（stdout は無視、stderr はスクロールバック）なので、Grok では自動修正まではしない。`~/.claude/projects`・`plans`・`sessions`・`backups` 配下の自動生成ファイルは対象外。stdin は snake_case / camelCase 両対応。

## 検証（テスト）

```zsh
bash .claude/tests/run.sh
```

各CLIの設定 JSON（`settings.json`・`opencode/*.json`・`codex/hooks.json`・`devin/config.json`）の構文、シェルスクリプト全体の `bash -n`（`hooks/`・`hooks/lib/`・`setup.sh`・`skills/*/scripts/`・`tests/`・`bootstrap.sh`・`ai/*.sh`・`codex/hooks/*.sh`・`opencode/setup.sh`）、`hooks/lib/*.awk` の構文、SKILL.md / agents の frontmatter（1行目の `---`・`name:`・`description:` に加え、閉じの `---` があること）、`settings.json` のフック・`statusLine` の登録元検査、およびフック（pr-mode / guard-destructive / verify-gate / completion-gate / validate-claude-config、加えて Grok 互換の入出力と Codex の `codex/hooks/guard.sh`）と共通指示の配布（ai-install）のテーブル駆動テストを実行する。guard のテストには、許可ルート内の通常の削除が確認なしで通ることを固定する不変条件セクション（IV01〜IV13）、`dev-roots` の各ルートを検査する DR1〜DR3、`dev-roots` の文法（行内コメント・空白・`~/` 以外の行）を作業コピーで検査する DC1〜DC4、同じコマンド内の代入の解決（解決できる形・deny になる形）を検査する V01〜V47、リンクされた git worktree のルートを許可する W01〜W03、deny の理由文が「何をするコマンドか」で始まることを検査する X01〜X21 が含まれる。`tests/` 自体は `setup.sh` の配布対象外（`~/.claude` にはリンクされない）。test-pr-mode.sh は `HOME` を一時ディレクトリに向けて実行するので、壊れた入力や `session_id` 欠落のケースを流してもフックの本物のログ `~/.claude/pr-mode.log` には書き込まない（run.sh がテスト前後の行数で検査する。E07 はそのログの文言が文字化けしていないことも見る）。`hooks/pr-mode.sh`・`hooks/guard-destructive.sh`・`hooks/verify-gate.sh`・`hooks/completion-gate.sh`・`hooks/validate-claude-config.sh`・`hooks/lib/` や `ai/`・`codex/`・`devin/`・`opencode/` の設定を変更したときは必ず実行して通す（`hooks/verify-gate.sh` が、通すまでターンを終えさせない）。作業コピーのフックを試すときは `HOOKS_DIR=/path/to/hooks bash .claude/tests/run.sh`。

## iPhoneプッシュ通知（claude-notify）

`Stop`（タスク完了）/ `Notification`（許可待ち。matcher で `permission_prompt` のみ）イベントで `hooks/notify.sh` を実行し、Web Push で iPhone の PWA に通知する。委譲した OpenCode（`run.sh`）が同じプロジェクトで実行中の間は Stop 通知を送らない（同じリポジトリの worktree でも抑止。マーカー `~/.cache/claude-opencode-running/`）。送信本体（`claude-notify/send-push.mjs`）は**この dotfiles リポジトリに同梱**されており、notify.sh は自身の実体パスから場所を解決する（`CLAUDE_NOTIFY_REPO` などの環境変数は不要）。依存（`web-push`）は `home-manager switch` 時に home-manager の activation が `pnpm install --frozen-lockfile` で自動導入する。依存が入っていない PC では何もせず静かに終了する。受信側の PWA は別リポジトリ claude-notify-mobile（Vercel 配信）にあり、仕組みは同リポジトリの `docs/SETUP.md` を参照。

**Grok CLI でも同じ通知が届く**。notify.sh が `GROK_HOOK_EVENT` で呼び出し元を判別し、応答完了（`reason == "end_turn"` の Stop）と許可待ち（`notificationType == "permission_prompt"` の Notification）だけをタイトル「(Grok)」付きで通知する。

**OpenCode V2 からは通知を送信しない**。`opencode/cli.json` の `attention.notifications` を `false` にし、`opencode/plugins/mobile-notify.js` は無効化した互換入口として残している（イベント購読・送信プロセス起動を行わない）。Claude/Grok の通知フック・claude-notify 送信機能・設定そのものは変更していない。

新しい PC で使うには（`home-manager switch` 実行後）:

1. `claude-notify.example.json` を `~/.claude/claude-notify.json` にコピーし、VAPID 鍵と購読情報を記入する（値は既存 PC の `~/.claude/claude-notify.json` からコピーすればよい。iPhone 側の再設定は不要）。**新 PC で必要な手動作業はこれだけ**（送信スクリプトも依存も dotfiles 側で揃う）
2. 疎通テスト: `node ~/Dev/kaishi/ubuntu-dotfiles/claude-notify/send-push.mjs --title "テスト" --body "OK" --event Stop`

**注意**: 記入済みの `~/.claude/claude-notify.json` は VAPID 秘密鍵を含むため、このリポジトリ（PUBLIC）には絶対にコミットしないこと（`settings.json` の `permissions.deny` で Claude 自身の読み取りも禁止済み）。実行ログは `~/.claude/claude-notify.log` に追記される（1MB を超えると次回送信時に切り詰め）。
