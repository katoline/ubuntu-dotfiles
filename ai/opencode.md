# OpenCode 固有の補足

- 通常起動（既定の `build`）では、Claude Code / Codex と同じメイン担当として対話・Skills・サブエージェント・質問・レビュー・PR・worktree の安全な cleanup を使う。`delegated-worker` Agent で起動された場合だけ、その Agent の `system` と `permissions` に従う
- `delegated-worker` は親セッション（Claude Code / Codex）から委譲された実装・調査・検証担当で、Skill の選択・ユーザーへの質問・子への再委譲・Git の書き込み（commit / push / PR）・worktree の変更はできない。拒否された操作や判断に迷う点は、回避せず親へ返す
- Claude Code の Hooks・`settings.json` は OpenCode では動かない。代わりに `opencode/plugins/shared-harness.js` が共通の `guard-destructive.sh`・`pr-mode.sh`・`verify-gate.sh`・`completion-gate.sh` を permission とセッションのイベントへ接続している
- OpenCode の認証情報は読まない・リポジトリに保存しない

# モデル運用（OpenCode 単体）

メインセッション（`build` / `plan`）向け。サブエージェントや `delegated-worker` として起動されたら本節は使わず、与えられた指示を実行する。委譲の原則は共通ルールの「サブエージェント」。モデルは `opencode.json` で設定済みなので、メインのモデルを自分で変えない。

- **メイン（Claude Opus 5.5・medium）**：要件整理・設計・分解・指示・レビュー・最終判断。1〜2ファイルの確認と自明な局所修正は自分で行ってよい
- **`general` サブエージェント（DeepSeek V4.1 Flash Free）**：実装・テスト作成と実行・ドキュメント更新・複数ファイルにまたがる調査は、ユーザーの明示的な依頼がなくても委譲する
- **`explore` サブエージェント（DeepSeek V4.1 Flash Free）**：読み取りだけの所在調査
- **`code-review` サブエージェント（メインと同じ Opus 5.5・medium）**：独立レビューだけに使う。差分と要件だけを渡す（`/code-review` も同じ Agent）

運用：

- サブエージェントが利用上限（レート制限・quota）で失敗したときだけ、同じ指示で `subagent` ツールの `model` に `opencode/deepseek-v4.1-flash` を指定して1回だけ再実行する（ユーザーが指定した切替先なので、この場合は `model` を設定してよい）。それ以外の失敗（認証・権限拒否・モデル不存在・context length 等）では切り替えない
- 切替先も上限になったとき、またはサブエージェントが使えないときは、メインで実装を肩代わりせず状況を報告してユーザーに判断を仰ぐ。ユーザーが「メインでやって」等とその作業に明示したときだけメインで行う
- 同じ作業ツリーで同じファイルを触る作業は並列に投げない
- サブエージェントの報告した検証結果は鵜呑みにせず、変更後にプロジェクトの検証コマンドをメインがフォアグラウンドで実行し直す

# ハーネスの挙動（OpenCode 単体）

- Git：既定ブランチへの commit / push、force push、削除系、`--no-verify` は拒否される。既定ブランチ以外の commit・push・PR の作成と更新（単一コマンド）は plugin が自動許可する。`gh pr merge` は permission 上 ask だが、ユーザーがその PR のマージを明示的に指示したときだけ実行する。サブエージェントと `delegated-worker` の Git 書き込みは拒否される
- 検証ゲート：dotfiles の検証対象を編集したターンは、検証コマンド（同じ worktree の repo root で `bash .claude/tests/run.sh` / `nix eval --raw .#…` の直接形）が成功するまで、終了時に1回だけ自動で再開して検証を促す。cd・複合コマンドでは解除されない
- 完了チェック：ファイルを変更したターンの終了時に、共通ルール「作業の進め方（PDCA）」の Check を促して再開する（1ターン3回まで。検証待ちが残っているターンは検証ゲートを優先）。促されたら確認結果を報告に書き、未達があれば直してから終える
- `/pr` Command 本文を受け取ったこと自体、またはユーザー発言の先頭トークンが `@pr` であること（コード表記・引用符で囲まれていても同じ）を明示起動として扱い、再確認・拒否せず `pr` Skill を最後まで実行して PR の作成・更新か失敗理由を報告する（本文中で言及しただけなら起動扱いにしない）
