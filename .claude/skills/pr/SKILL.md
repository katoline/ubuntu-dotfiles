---
name: pr
description: 作業が完了して検証が通ったとき、またはユーザーが /pr と打ったときに、既定ブランチ以外の作業ブランチへ変更をコミット・push して PR を作成する（既存の open な PR があれば説明を作り直して更新する）。PR のマージはしない。
allowed-tools:
  - Bash(git status:*)
  - Bash(git diff:*)
  - Bash(git log:*)
  - Bash(git branch:*)
  - Bash(git rev-parse:*)
  - Bash(git symbolic-ref:*)
  - Bash(git fetch:*)
  - Bash(git add:*)
  - Bash(git checkout -b:*)
  - Bash(git switch -c:*)
  - Bash(gh repo view:*)
  - Bash(gh pr view:*)
  - Bash(gh pr list:*)
  - Bash(git restore --staged:*)
---

<!-- 下の H1 とマーカーは旧 /pr フラグ方式の名残として残す（現在のフックは起動判定に使わない）。行を消さないこと -->

# PR作成

<!-- pr-mode-enable -->

現在の作業内容をコミットし、GitHubへPull Requestを作成する。

## 前提（機構上の制約）

- 作業が完了して検証が通ったとき、またはユーザーが `/pr` と打ったときに実行する。「PRを出して」だけの依頼でも、検証が済んだ作業なら同じ手順を実行してよい
- 既定ブランチ（`main` / `master` / `origin/HEAD` の指すブランチ）への `git commit` / `git push` は、フックが常に拒否する。既定ブランチ上にいるなら先に作業ブランチを作る
- 既定ブランチ以外での `git commit` / `git push` / `gh pr create`（別名 `gh pr new`）/ `gh pr edit` / `gh api` の `/pulls` 書き込み（マージ以外）は、単一コマンドならフックが自動承認する。`/pr` を起動したかどうかは問わない
- **自動承認は単一コマンドに限る**。`git commit` / `git push` / `gh pr create` / `gh pr edit` は必ず **1つずつ独立した Bash 呼び出しで実行**し、`&&` `;` `|` や改行で他のコマンド（`git add` や `git checkout -b` を含む）と繋がない。複合コマンド・コマンド置換（`$( )`）・リダイレクトは自動承認されず、通常の確認ダイアログに落ちる（拒否はされない）。例外は本文を渡す `"$(cat <<'EOF' … EOF\n)"` の定型だけ。オプションの確認（`--help` を含む）なども探りの複合コマンドにせず、単独で実行する
- git commit / git push / gh pr create / gh pr edit は**メインセッションが直接実行**し、サブエージェントへ委譲しない（サブエージェントからの実行はフック入力の `agent_id` で見分けられ、常に拒否される）
- `--no-verify` / `--amend` / force push / `--delete` / 既定ブランチ宛 / 別リポジトリ宛（`-R` / `--repo`）はフックが自動承認しない。force push・リモートブランチの削除・既定ブランチ宛は拒否、`--amend` / `--no-verify` / 宛先を判定できない push は確認ダイアログになる。いずれも使わない
- コミットの直前に、フックがコミットされる差分（`-a` 付きなら `git diff HEAD`、無ければステージ済み）を既知のトークン形式（GitHub / Anthropic / OpenAI / xAI / AWS / Slack / Google / Stripe / npm のキー、秘密鍵ブロック）で検査する。一致があれば自動承認されず、理由にファイル名と形式名が出る。その場合は該当ファイルを add から外すか、ユーザーに確認する
- PR のマージ（`gh pr merge` / `gh api` の `/pulls/N/merge` への PUT / GraphQL の `mergePullRequest`）はこのスキルの範囲外。常に確認ダイアログになり、ユーザーがその PR のマージを明示的に指示したときだけ実行する。自分から提案しない（Codex ではフックが拒否する）
- Claude Code は `PermissionRequest` で自動承認する。Grok は `PermissionRequest` が無いため、自動承認条件を満たさない git 書き込みだけ PreToolUse が ask にする（always-approve でも確認になる）

## 手順

### 0. 検証

プロジェクトの `AGENTS.md` または `CLAUDE.md` に検証コマンド（lint・型チェック・テスト・ビルド等）があれば実行する。通らなければコミットせず、失敗内容を報告して終了する（テストの skip や期待値の書き換えで通さない）。検証コマンドが書かれていなければ「未検証」として先へ進み、報告に明記する。

### 1. 現状把握

以下を確認する：

- `git status` で未コミットの変更・未追跡ファイルを把握。`.env` や鍵・トークンなどの秘密ファイルが含まれていないか確認する
- `git diff` / `git diff --staged` で変更内容を把握
- `git log --oneline -10` でコミットメッセージの文体を把握
- 現在のブランチ（`git branch --show-current`）と、デフォルトブランチ（`git symbolic-ref --short refs/remotes/origin/HEAD` の `origin/` 以降。取得できないときのみ `gh repo view --json defaultBranchRef --jq .defaultBranchRef.name`）
- 未 push のコミット：`git rev-parse --abbrev-ref @{upstream}` が失敗（upstream 未設定）なら全コミットが未 push。成功したら `git log @{upstream}..HEAD --oneline`
- 作業ブランチに既に PR があるか：`gh pr list --head <ブランチ> --state open --json number,url`

未コミットの変更も未 push のコミットもない場合は、PR を作るものがない旨を報告して終了する。

### 2. ブランチ準備

- デフォルトブランチ（main / master）上にいる場合は、変更内容を表す新しいブランチを作成して移動する（例: `feat/xxx`、`fix/xxx`、`docs/xxx`、`chore/xxx`）
- 既に作業ブランチ上ならそのまま使う

### 3. コミット

未コミットの変更は、**後から AI エージェントが `git log` / `git show` / `git blame` で特定の変更へ辿れる単位**に分けてコミットする。作業全体を1コミットにまとめない。

分割の基準:

- **関心ごと**に分ける（例: キーボード設定、マウス設定、エディタ設定、スキル文書）。同じ意図で同時に必要なファイル（設定とその説明ドキュメントなど）は同じコミットに置く
- 実質1関心しかない差分は無理に分割しない
- **単位はファイルまで**。`git add -p` 等で1ファイルの変更を分割しない。1ファイルが複数の関心にまたがる場合は主な関心のコミットにまとめ、そのことを報告に書く
- **順序**は、各コミットがその時点で単体で成り立つよう、依存される側（土台）から先にコミットする。一緒に変えないと壊れるもの（既定ブランチ保護の各層、フックとそのテスト等）は必ず同じコミットにする
- **進め方**: 最初に `git diff --staged --name-only` を確認し、ステージ済みのファイルがあれば `git restore --staged <ファイル>` で外してから（index だけの操作で作業ツリーは変わらない。`--worktree` / `-W` は付けない）、コミットごとに `git add <ファイル…>` → `git commit` を繰り返す。最後に `git status` で取り残しが無いことを確認する
- 今回の作業と無関係な変更が混ざっている場合や分け方に迷う場合は、**AskUserQuestion で**確認する

メッセージ:

- 既存履歴の文体に合わせる（このユーザーは日本語の簡潔な1行が基本）
- そのコミット単体を見ても何が変わったか分かる文言にする（「更新」「修正」だけは不可）
- ハーネスの指示で attribution（`Co-Authored-By:` トレーラー）を付ける場合は、1行要約＋空行＋トレーラーの形で HEREDOC で渡す：

```
git commit -m "$(cat <<'EOF'
<1行要約>

Co-Authored-By: <ハーネスの指示どおり>
EOF
)"
```

### 4. Push と PR 作成

- `git push -u origin <ブランチ名>` で push する（単独の Bash 呼び出し）
- 手順 1 で既に open な PR が**無ければ**、`gh pr create` で PR を作成する（単独の Bash 呼び出し）
  - タイトル：変更内容の要約（日本語）
  - 本文：変更の概要と変更点、コミットの関心ごとの箇条書き。後からエージェントが PR 本文から該当コミットへ辿れるようにする。`--body "$(cat <<'EOF' … EOF\n)"` の HEREDOC で渡す。ハーネスの指示でフッター（`🤖 Generated with …`）を付ける場合は末尾に置く
  - `--base` はデフォルトブランチ。`.github/pull_request_template.md` があればその構成に従う
- 既に open な PR が**あれば**、新規作成せず、push で増えたコミットが説明に反映されるようタイトルと本文を作り直して更新する
  - `gh pr view <番号> --json commits --jq '.commits[].messageHeadline'` で PR に含まれる**全コミット**を GitHub 側から取り（ローカルの `origin/<デフォルトブランチ>` は fetch していないと古く、`git log origin/<デフォルトブランチ>..HEAD` では PR の実際のコミット集合とずれる）、上の `gh pr create` と同じ基準で作り直す（今回分の追記ではなく全体の作り直し。後から目的が増えた PR でもタイトルと食い違わないようにするため）
  - 先に `gh pr view <番号> --json title,body` で現在の内容を読み、/pr が生成していない記述（ユーザーが書いたレビュー依頼・関連 Issue・補足など）があれば作り直した本文にも残す
  - `gh pr edit <番号> --title "<タイトル>" --body "$(cat <<'EOF' … EOF\n)"` で更新する（単独の Bash 呼び出し）

### 5. 報告

作成（既存 PR なら更新）した PR の URL・ブランチ名・コミットの一覧（分け方の意図と、複数の関心にまたがるためまとめたファイルがあればそれ）・検証結果（未検証ならその旨）を簡潔に報告する。

## 注意事項

- force push・`--no-verify`・`--amend`・デフォルトブランチへの直接 push・リモートブランチの削除はしない
- `gh pr merge` はこのスキルの範囲外（ユーザーの明示的な指示があるときのみ。常に確認が入る）
- `gh` が未認証・リモート未設定などで失敗した場合は、勝手に回避策を取らず状況をユーザーに報告する
