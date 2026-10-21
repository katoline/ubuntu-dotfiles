---
name: opencode
description: Codex から OpenCode へ、ユーザーが明示的に求めた作業を非対話で委譲する。$opencode や「OpenCodeに任せて」「OpenCodeに作業させて」「OpenCodeを起動して」などの依頼で使用。`--session-wide` 指定中は以後の実装も委譲する。Codex 専用の入口で、OpenCode・Grok 自身では使わない。
---

# OpenCode に作業を任せる（Codex）

> **Codex 専用。** OpenCode 自身や Grok では使わない（入れ子起動になる）。Claude 用の `.claude/skills/opencode/SKILL.md` は Claude 専用のガードを含むため全体を読まず、共有ランナーだけを使う。

この Skill の共有ランナーは、委譲時の OpenCode を必ず `delegated-worker` Agent（軽量 worker）で起動する。OpenCode 単体を普通に起動したとき（既定の `build`）とは別物で、単体では対話・Skills・サブ agent・レビュー・PR・worktree の安全な cleanup を通常どおり使う。既存の OpenCode セッションは作成時の Agent を保持するため、単体で通常の体験に戻したいときは Build を選ぶか新しいセッションを開始する。逆に単体 Build の履歴を worker へ流用すると旧ツール定義の情報が残るため、軽量委譲は新規セッションで始め、`--session` は同じ worker タスクの続きに限定する。

## 役割分担

- **Codex**：要件整理・設計・タスク分解・指示・レビュー・最終判断
- **OpenCode（`delegated-worker`）**：実装・調査・検証・ドキュメント更新など。設計判断は渡さない

## 委譲の範囲（親会話の状態）

- オプションなし：継続指定がまだ有効でない通常状態では、今回の依頼だけを委譲する。`--session-wide` 中は `--once` または明示的な解除まで、オプションなしの依頼も含めて以後の実装を委譲し続ける。
- `--session-wide`：現在の親会話で、以後の実装をすべて OpenCode へ委譲する。
- `--once`：継続指定を解除し、今回の依頼だけを委譲する。
- 継続指定は親会話の状態として持ち、compact 要約に「OpenCode 委譲：有効（`--session-wide`）/ 無効」を残す。ホームや全プロジェクトに効く設定ファイル・環境変数・フックは作らず、別チャットへ持ち越さない（新しい会話では無効から始まる）。
- 継続指定中は、明示的なスキル呼出しがなくても実装を委譲する。単なる質問・要件整理・設計・レビューは Codex が行い、解除後は通常の担当へ戻す。
- 継続指定中の実装修正は、レビューで見つかったものを含めて規模を問わずすべて OpenCode へ再委譲する。Codex 自身が実装を直してよいのは継続指定が無効のときだけ。
- これらは親スキルが解釈するオプションで、共有ランナーには渡さない。ランナーの `--session <ID>` は OpenCode セッション再開用で別物。

## モデル

- 既定は共有ランナーの `opencode/deepseek-v4.1-flash-free`（DeepSeek V4.1 Flash の Free 版）。利用上限（レート制限・quota）のときだけ、ランナーが次の順に1回ずつ自動で切り替える（他のモデルや通常従量課金の `opencode/deepseek-v4.1-flash` へは切り替えない）：
  1. `opencode/deepseek-v4.1-flash-free`
  2. `opencode/glm-5.3-flash-free`
  3. `opencode-go/deepseek-v4.1-flash`
- Go まで上限なら非0で停止する。認証・Privacy の地域拒否・権限拒否・通信・モデル不存在・context length・その他の失敗は切り替えず、その場で停止する。途中まで進んで上限になった場合は、得られた OpenCode セッションを続けて未完了分から再開する。
- ユーザーが `--model provider/model#variant` を明示した場合は、そのモデルだけで実行し自動切替しない（既定値と同じ文字列でも明示指定を優先）。
- Go の利用上限後に従量残高を消費しないためには、利用者が Console で Use balance を無効にしておく（Go サブスク枠内に留める前提。設定や認証は読まず変更もしない。権限付与でもない）。
- Codex 本体のモデル設定は変更しない。

## 手順

1. Codex が計画を立て、OpenCode 向けの自己完結した指示を書く（OpenCode は会話を知らない）。対象ファイル・方針・制約・完了条件・検証コマンドを含める。必要な Skill は Codex が自分で読み、委譲指示には関連する制約だけを含める（親の会話全文や全 Skill を子へコピーしない）。Codex の承認・sandbox・フックは OpenCode 内のツールに引き継がれないため、必要なら制約（触れてよい範囲、削除・commit / push / PR 作成の禁止、sudo やグローバルインストールの禁止など）も明記する。最後に添える：
   > 日本語で「変更ファイル／実行した検証と結果／未解決点」の形で簡潔に報告すること。git commit / push / PR 作成・削除・グローバルなインストールはしないこと。
2. `exec_command` などで実行する。`yield_time_ms` を短めに指定し、返された `session_id` を `write_stdin` で待つ。60秒以上黙らない。Claude 専用の `run_in_background` などの引数は使わない。委譲範囲のオプション（`--session-wide` / `--once`）はこのスキルが解釈し、`run.sh` には渡さない。

   ```bash
   bash ~/.claude/skills/opencode/scripts/run.sh --dir /abs/path/to/project --title 'codex: 作業名' <<'EOF'
   ...指示...
   EOF
   ```

   独立した作業が複数あっても、同じ作業ツリーでは1本ずつ逐次実行する（並行すると同じファイルを取り合う）。
3. 要約（最終回答・拒否された権限・失敗したツール）を読み、Codex が `git diff` で変更をレビューして検証コマンドを通す。継続指定（`--session-wide`）が有効な間は、見つかった実装修正を規模を問わずすべて `--session <ID>` で OpenCode へ再委譲する。継続指定が無効のときだけ、小さな直しは Codex が直接行ってよく、まとまった量は `--session <ID>` で再依頼する。
4. ユーザーに報告する：使ったモデル（自動切替した場合は理由・順・最終モデルと各試行のログ）・変更ファイル・検証結果・未解決点（拒否された操作を含む）。継続指定の有無も必要に応じて伝える。

## 注意

- `--auto` は付けない（ask 規則の rm・git commit・git push 等が自動承認される）。
- 作業用 worktree の作成・変更・削除と安全な cleanup は Codex（親）が行う。`delegated-worker` に許すのは読み取り専用の `git worktree list` だけで、作成・変更・削除は permission で拒否される。単体の OpenCode は共通ルールの worktree 節に従い、保存と同一内容を確認した通常の `git worktree remove <絶対パス>`（`--force` なし）を使える。
- `--session-wide` はその会話内の委譲範囲を指す指定で、OpenCode の履歴を親と共有する意味ではない。独立タスクは新規セッションで始め、`--session <ID>` は同じタスクの小修正だけに使い、履歴が大きくなったら必要な制約・差分・未完了事項だけを新規セッションへ引き継ぐ。
- 拒否された操作は別の書き方やツールで迂回しない。必要なら理由を示し、ユーザーに手動実行を依頼する。
- OpenCode の実行中は、同じファイルを Codex が編集しない。
