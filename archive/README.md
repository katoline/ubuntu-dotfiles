# archive（休止中の CLI 設定）

使っていない CLI の設定を、将来また使うときのために残しておく場所。ここにあるファイルは**配布・導入・検証の対象外**（`ai/install.sh`・`nix/home.nix`・`nix/merge-cli-config.py`・`bootstrap.sh`・`.claude/tests/run.sh`・`verify-gate.sh` のどれも参照しない）。

## 休止中の CLI

| CLI | 休止日 | 理由 |
|---|---|---|
| Grok CLI（xAI） | 2026-11-08 | 現在使っていないため。配布・導入・テストの対象から外した |
| Devin CLI | 2026-11-08 | 同上 |

## ファイルの元の配置

| いまの場所 | 元の場所 | 配布先（休止前） |
|---|---|---|
| `archive/grok/config.toml` | `grok/config.toml` | `~/.grok/config.toml`（`nix/home.nix` の書き込み可能リンク） |
| `archive/grok/README.md` | `grok/README.md` | — （内部のリンクは元の場所を前提に書かれている） |
| `archive/grok/ai-grok.md` | `ai/grok.md` | `~/.grok/AGENTS.md`（`ai/install.sh` が `ai/core.md` と連結生成） |
| `archive/devin/config.json` | `devin/config.json` | `~/.config/devin/config.json`（`nix/merge-cli-config.py` が実ファイルへマージ） |
| `archive/devin/ai-devin.md` | `ai/devin.md` | `~/.config/devin/AGENTS.md`（`ai/install.sh` が連結生成） |

完全な旧状態は commit `c3ed3df`（休止直前の origin/main）にある。下の断片で足りないときは `git show c3ed3df:<path>` で取り出す（例: `git show c3ed3df:nix/home.nix`、`git show c3ed3df:bootstrap.sh`）。

## そのまま残しているもの

共通フックの Grok 互換コードは消していない（エージェントのコンテキストを消費せず、復元時にそのまま使えるため）。

- `.claude/hooks/pr-mode.sh`・`.claude/hooks/notify.sh` の `GROK_HOOK_EVENT` 分岐（camelCase の stdin・トップレベル `decision` の出力）
- `.claude/tests/test-grok-compat.sh` と `.claude/tests/lib.sh` の `payload_grok`・`run_hook_grok`（`run.sh` から引き続き実行される）

## ホーム側に残るもの

休止前に配布したホーム側のファイルは、リポジトリの変更だけでは消えない。エージェントは消さないので、不要ならユーザーが手で消す。

- `~/.grok/AGENTS.md`・`~/.config/devin/AGENTS.md`（`ai/install.sh` が生成した実ファイル。今後は更新されず古い内容のまま残る）
- `~/.config/devin/config.json`（`merge-cli-config.py` が作った実ファイル。org_id などのローカル状態を含む）
- `~/.grok/config.toml`（home-manager 管理のリンク。次の `home-manager switch` で旧世代の管理リンクとして外れる見込みだが、Grok がリンクを実ファイルで置き換えていた場合などは残る）

## 復元手順

以下は削除する前の実際のコード。Grok だけ・Devin だけを戻すこともできる。

### 1. ファイルを戻す

```bash
git mv archive/grok/config.toml grok/config.toml
git mv archive/grok/README.md grok/README.md
git mv archive/grok/ai-grok.md ai/grok.md
git mv archive/devin/config.json devin/config.json
git mv archive/devin/ai-devin.md ai/devin.md
```

### 2. `ai/install.sh`（グローバル指示の連結生成）

`generate_file "OpenCode" …` の後に戻す（元は OpenCode → Grok → Codex → Devin の順）。

```bash
generate_file "Grok" "$SCRIPT_DIR/grok.md" "$HOME/.grok/AGENTS.md" || failed="$failed ~/.grok/AGENTS.md"
generate_file "Devin" "$SCRIPT_DIR/devin.md" "$HOME/.config/devin/AGENTS.md" || failed="$failed ~/.config/devin/AGENTS.md"
```

冒頭コメントの一覧と完了メッセージも戻す。

```bash
#     Grok         … ~/.grok/AGENTS.md を連結生成
#     Codex        … ~/.codex/AGENTS.md を連結生成
#     Devin        … ~/.config/devin/AGENTS.md を連結生成
# - 連結生成した4つは ai/*.md を編集したら再実行が必要（home-manager switch 時にも自動実行される）
```

```bash
echo "配布が完了しました。OpenCode / Grok / Codex / Devin は連結生成なので、ai/*.md を編集したら再実行してください。"
```

### 3. `nix/home.nix`

`home.file` の `.gitconfig` の後に Grok の設定リンクを戻す。

```nix
    # Grok CLI の設定。grok 自身もこのファイルへ書き込むため、書き込み可能
    # リンクにして変更をリポジトリ側へ取り込む（VSCode設定と同じ方式）。
    # force = true は既存実体ファイルの置き換え用。Grok がリンクを実体で
    # 置き換えた場合は、下の captureGrokConfigWrites が switch 直前に取り込む
    ".grok/config.toml" = {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/grok/config.toml";
      force = true;
    };
```

`installEditorExtensions` の後に activation を戻す。

```nix
  # Grok が ~/.grok/config.toml のシンボリックリンクを実体ファイルで置き換えた
  # 場合、home.file の force=true がリンクに戻す前に実体側をリポジトリへ取り込む
  home.activation.captureGrokConfigWrites = lib.hm.dag.entryBefore [ "writeBoundary" ] ''
    dest="$HOME/.grok/config.toml"
    src="${dotfilesPath}/grok/config.toml"
    if [ -f "$dest" ] && [ ! -L "$dest" ] && [ -f "$src" ] && [ "$dest" -nt "$src" ]; then
      if ! cmp -s "$src" "$dest"; then
        run cp "$dest" "$src"
        echo "Grok config.toml の実体変更をリポジトリへ取り込みました"
      fi
    fi
  '';
```

コメントも戻す（Devin の設定は home.file のリンクではなく `mergeCliConfigs` が実ファイルにする）。

```nix
    # Devin config.json も mergeCliConfigs で実ファイルにして org_id 等を残す。
```

```nix
  # 宣言した値だけを上書きし、trust・trusted_hash・desktop のランタイム・org_id は
```

```nix
  # Claude Code はリンク、include を持たない Grok / Codex / Devin は連結生成。
```

### 4. `nix/merge-cli-config.py`（Devin の設定マージ）

`generate()` の `files` に戻す。`"json"` の種類（素の JSON を再帰マージ）の処理は残してあるので、この 1 行だけでよい。

```python
        (repo / "devin/config.json", home / ".config/devin/config.json", "json"),
```

`.claude/tests/test-cli-config-merge.sh` の Devin のケース（org_id の保持・旧リンクの移行・最後のファイルが不正なときに何も書かない）は `git show c3ed3df:.claude/tests/test-cli-config-merge.sh` から戻す。休止中に足した `test_paused_devin_config_untouched` は消す。

### 5. `bootstrap.sh`（導入ステップ）

ステップ番号を `N/16` に振り直し、冒頭の手順一覧（Grok は 12、Devin は 16）と、sudo・AI CLI の対象番号のコメント（`9〜11・14`、`8・12・15・16`）も戻す。

Google Chrome の後（OpenCode の前）:

```bash
echo "==> 12/16 Grok CLI を確認"
if ! command -v grok >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/grok" ]; then
  echo "Grok CLI をインストールします（公式インストーラー・自動更新あり）"
  install_cli "Grok CLI" https://x.ai/cli/install.sh "" bash
else
  echo "既にインストール済みのためスキップします"
fi
```

Codex の後（`FAILED_CLIS` の一覧表示の前）:

```bash
echo "==> 16/16 Devin CLI を確認"
if ! command -v devin >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/devin" ]; then
  echo "Devin CLI をインストールします（最後に初期設定ウィザード devin setup が起動する）"
  # ウィザードの中断・失敗で bootstrap 全体を止めない
  install_cli "Devin CLI" https://cli.devin.ai/install.sh \
    "導入または初期設定が完了しませんでした。devin --version で導入を確認し、必要なら devin setup を実行してください" bash
else
  echo "既にインストール済みのためスキップします"
fi
```

### 6. `.claude/tests`

`run.sh` の JSON 構文チェック対象に `devin/config.json` を戻す。

```bash
for j in "$CLAUDE_DIR/settings.json" "$REPO_DIR"/opencode/*.json "$REPO_DIR/codex/hooks.json" "$REPO_DIR/devin/config.json"; do
```

`test-ai-install.sh` の D 節に設定との整合の検査を戻す（A〜C・E・F 節の grok / devin を含むループも `git show c3ed3df:.claude/tests/test-ai-install.sh` を見て戻す。休止中に足した A09〜A13 は消す）。

```bash
# Grok は Claude 側の指示ファイルを読まない（読むと ~/.grok/AGENTS.md と二重になる）。
# skills / hooks は共有するので false にしない
GROK_TOML="$(cd "$TESTS_DIR/../.." && pwd)/grok/config.toml"
compat=$(sed -n '/^\[compat\.claude\]/,/^\[/p' "$GROK_TOML" | grep -E '^[a-z]+ *=' | tr -d ' ' | paste -sd, -)
report D04-grok-rules-off yes "$(has "$compat" 'rules=false')" "$compat"
report D05-grok-agents-off yes "$(has "$compat" 'agents=false')" "$compat"
report D06-grok-skills-kept no "$(has "$compat" 'skills=false')" "$compat"
report D07-grok-hooks-kept no "$(has "$compat" 'hooks=false')" "$compat"
# Devin も Claude のルールを読み込まない
DEVIN_JSON="$(cd "$TESTS_DIR/../.." && pwd)/devin/config.json"
report D08-devin-claude-off false "$(jq -r '.read_config_from.claude' "$DEVIN_JSON" 2>/dev/null)" ""
```

### 7. `.claude/hooks/verify-gate.sh` の分類

`devin/*` を run.sh の対象に戻す（冒頭コメントの `devin/**` も）。`grok/` はもともと分類していない。

```bash
    ai/* | codex/* | devin/* | opencode/setup.sh | opencode/*.json | opencode/plugins/* | opencode/hooks/*) printf 'run.sh\t%s\n' "$top" ;;
```

`test-verify-gate.sh` の `run.sh $W/repo/devin/config.json` のケースも戻す。

### 8. ドキュメントと配布

README 類（`README.md`・`ai/README.md`・`AGENTS.md`・`nix/README.md`・`.claude/README.md` など）の Grok / Devin の記述を `git show c3ed3df:<path>` と見比べて戻す。そのあと `bash .claude/tests/run.sh` と `nix eval --raw .#homeConfigurations.ubuntu.activationPackage.drvPath` を通し、`bash ai/install.sh` で配布、`home-manager switch` を実行する。CLI 本体は `bootstrap.sh` の該当ステップか公式インストーラーで入れる。
