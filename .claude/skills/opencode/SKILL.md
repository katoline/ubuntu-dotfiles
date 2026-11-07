---
name: opencode
description: Claude Code のセッションから OpenCode を非対話で起動して実装・調査・テストを任せ、結果をレビューする。Claude Code のメインセッションでは常時有効で（サブエージェントとして起動されたら使わない）、実装・複数ファイルの調査・テスト作成と実行・ドキュメント更新が必要になったら明示的な依頼がなくても使う。「OpenCodeに任せて」などの依頼や /opencode 実行時にも使用。Claude Code 専用（OpenCode・Grok など他CLIでは使わない）。
allowed-tools:
  - Bash(bash ~/.claude/skills/opencode/scripts/run.sh:*)
---

# OpenCode に作業を任せる

> **Claude Code 専用。** OpenCode・Codex など他の CLI で読み込んだ場合は使わない（入れ子起動になる）。

OpenCode をサブエージェント代わりに使う。目的は Claude のトークン節約なので、手順は軽く回す。Claude Code の全セッションで常時有効で、実装・調査・テストは明示的な呼出しがなくても委譲する（Claude のサブエージェントは独立レビューだけに使う。`~/.claude/rules/claude.md` の「モデル運用」）。

この Skill の共有ランナーは、委譲時の OpenCode を必ず `delegated-worker` Agent（軽量 worker）で起動する。OpenCode 単体を普通に起動したとき（既定の `build`）とは別物で、単体では対話・Skills・サブ agent・レビュー・PR・worktree の安全な cleanup を通常どおり使う。既存の OpenCode セッションは作成時の Agent を保持するため、単体で通常の体験に戻したいときは Build を選ぶか新しいセッションを開始する。逆に単体 Build の履歴を worker へ流用すると旧ツール定義の情報が残るため、軽量委譲は新規セッションで始め、`--session` は同じ worker タスクの続きに限定する。

## 役割分担

- **Claude**：要件整理・計画・設計・タスク分解・指示・レビュー・最終判断
- **OpenCode（`delegated-worker`）**：それ以外（実装・テスト作成・調査・ドキュメント更新など）。設計判断は渡さない

## 委譲の範囲

- メインセッションで常時有効（サブエージェントとして起動されたら使わない）。オプションは無い（旧 `--session-wide` / `--once` は廃止。指定されても無視して通常どおり委譲する）。
- 委譲する：実装（規模を問わず、レビューで見つかった修正を含む）・複数ファイルにまたがる調査・テストの作成と実行・ドキュメント更新。
- Claude が行う：単なる質問への回答・要件整理・設計・レビュー・最終判断・1〜2ファイルの確認・自明な局所修正（数行）・git の書き込み（`/pr`）・worktree の作成と削除・`docs/` の作業記録のような委譲指示より短く済む記録。
- ユーザーがその作業について「Claude でやって」等と明示したときだけ、委譲せずメインまたは Claude のサブエージェントで行う。
- ホームや全プロジェクトに効く状態ファイル・環境変数・フックは作らない（常時有効は Skill と `~/.claude/rules/claude.md` の指示で実現している）。

## モデル

既定は DeepSeek V4.1 Flash の Free 版（`opencode/deepseek-v4.1-flash-free`、スクリプトの既定値）。利用上限（レート制限・quota）のときだけ、共有ランナーが次の順に1回ずつ自動で切り替える（他のモデルや通常従量課金の `opencode/deepseek-v4.1-flash` へは切り替えない）：

1. `opencode/deepseek-v4.1-flash-free`
2. `opencode/glm-5.3-flash-free`
3. `opencode-go/deepseek-v4.1-flash`
4. `console-anthropic/claude-sonnet-5-5#medium`（OpenCode に登録した Anthropic API キー経由の Claude Sonnet 5.5。従量課金）

Sonnet まで上限なら非0で停止する。停止したら Claude が実装を肩代わりせず、ユーザーに状況を報告して判断を仰ぐ。認証・Privacy の地域拒否・権限拒否・通信・モデル不存在・context length・その他の失敗は切り替えず、その場で停止する。途中まで進んで上限になった場合は、得られた OpenCode セッションを続けて未完了分から再開する。ユーザーが `--model provider/model#variant` を明示した場合は、そのモデルだけで実行し自動切替しない（既定値と同じ文字列でも明示指定を優先）。

Go の利用上限で Go の従量残高を消費せずに Sonnet へ切り替えるには、利用者が Console で Use balance を無効にしておく（Go サブスク枠内に留める前提。設定や認証は読まず変更もしない。権限付与でもない）。

## 手順

1. Claude が計画を立て、OpenCode 向けの自己完結した指示を書く（OpenCode は会話を知らない）。含めるもの：対象ファイル・方針・制約・完了条件・検証コマンド。必要な Skill は Claude が自分で読み、委譲指示には関連する制約だけを含める（親の会話全文や全 Skill を子へコピーしない）。最後に次を添える：
   > 日本語で「変更ファイル／実行した検証と結果／未解決点」の形で簡潔に報告すること。git commit / push / PR 作成・削除・グローバルなインストールはしないこと。
2. 実行する。長くなりうるので Bash は `run_in_background: true` を既定にする。

   ```bash
   bash ~/.claude/skills/opencode/scripts/run.sh --dir /abs/path/to/project <<'EOF'
   ...指示...
   EOF
   ```

   独立した作業が複数あっても、同じ作業ツリーでは1本ずつ流す（並行すると同じファイルを取り合う）。
3. 要約（最終回答・拒否された権限・失敗したツール）を読み、Claude が `git diff` で変更をレビューし、OpenCode の報告にかかわらずプロジェクトの検証コマンドを自分でフォアグラウンド実行して通す（`verify-gate.sh` は OpenCode の編集を検出しない）。見つかった実装修正は `--session <ID>` で OpenCode へ再委譲する（Claude が直してよいのは数行の自明な修正だけ）。
4. ユーザーに報告する：使ったモデル（自動切替した場合は理由・順・最終モデルと各試行のログ）・変更ファイル・検証結果・未解決点（拒否された操作を含む）。

独立レビューは `~/.claude/CLAUDE.md` の「サブエージェント」節に従い、挙動に関わる変更は完了前に新しいコンテキストの opus サブエージェントへ差分と要件だけを渡す（ドキュメントのみ・数行の自明な修正は Claude のレビューで済ませる）。

## 注意

- `--auto` は付けない（ask 規則の rm・git commit・git push 等が自動承認される）。付けなければ ask の操作は自動拒否されるので、必要なら Claude が自分のルールで行う。
- 作業用 worktree の作成・変更・削除と安全な cleanup は Claude（親）が行う。`delegated-worker` に許すのは読み取り専用の `git worktree list` だけで、作成・変更・削除は permission で拒否される。単体の OpenCode は共通ルールの worktree 節に従い、保存と同一内容を確認した通常の `git worktree remove <絶対パス>`（`--force` なし）を使える。
- 独立タスクは新規セッションで始め、`--session <ID>` は同じタスクの小修正だけに使い、履歴が大きくなったら必要な制約・差分・未完了事項だけを新規セッションへ引き継ぐ。
- Claude Code のフックは OpenCode の中では効かない。OpenCode は `CLAUDE.md` を読まず `AGENTS.md` を読むので、`CLAUDE.md` にしかない制約は指示に書く。
- OpenCode の実行中は、同じファイルを Claude が編集しない。
- ランナーの実行中は、同じプロジェクトでの Claude の Stop 通知（`notify.sh`）が抑止される（マーカー `~/.cache/claude-opencode-running/`）。完了を待つためにターンを終えても通知は飛ばず、最終的に作業を終えたときだけ届く。判定は「cwd と `--dir` のパスが重なる、または同じリポジトリの worktree」なので、同じプロジェクトの別セッションや Codex 由来の実行中も抑止される（既知の制約）。
