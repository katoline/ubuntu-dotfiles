# VSCode / Cursor 共通設定

VSCodeとCursorの設定の**実体**を置くディレクトリ。CursorはVSCodeのフォークで設定ファイルの形式・配置が同じため、両エディタでここの同一ファイルを共有する。

適用は [nix/home.nix](../nix/home.nix) が担い、各エディタのUserディレクトリ（`~/.config/{Code,Cursor}/User/`）からここへの**書き込み可能なシンボリックリンク**を張る。そのため、どちらのエディタのUIから設定を変更してもこのディレクトリのファイルに直接書き込まれ、git差分として現れる。

## ファイル構成

| ファイル | 役割 |
|---|---|
| [`settings.json`](settings.json) | エディタ設定の実体（両エディタで共有） |
| [`keybindings.json`](keybindings.json) | キーバインドの実体（両エディタで共有） |
| [`code`](code) | VSCode起動ラッパー（Linux IME二重入力対策）。`home.nix` が `~/.local/bin/code` へリンクし、ドック起動用 desktop もこれを呼ぶ |
| [`extensions.txt`](extensions.txt) | 導入する拡張機能のIDリスト（1行1ID、`#` で始まる行はコメント）。 |
| [`install-extensions.sh`](install-extensions.sh) | `extensions.txt` の拡張機能をVSCode/Cursorへ導入するスクリプト。`home-manager switch` 時にhome-manager activationから自動実行される |

## 仕組みと設計理由

- エディタ本体はNix管理外。VSCode は `bootstrap.sh` が snap（`code --classic`）で導入し、Cursor は使う場合のみ手動導入。そのためhome-managerの `programs.vscode` モジュール（Nix製VSCodeの導入が前提）は使わず、設定ファイルは `mkOutOfStoreSymlink`、拡張機能はactivationスクリプトで管理する
- リンクは書き込み可能。home-manager標準のstore管理だと設定が読み取り専用になり、エディタのUIから変更できなくなるため、`~/.zshrc` と同じ方式を採る
- 拡張機能は「ファイル」ではなく「インストール状態」なのでリンクでは管理できない。`install-extensions.sh` がリストとの差分だけをインストールする。エディタ本体が未導入ならそのエディタをスキップし、次回のswitchで冪等にリトライされる
- activation環境のPATHに依存しないよう、CLIは既知の絶対パス候補（deb版 `/usr/bin/code`・snap版 `/snap/bin/code`・`~/.local/bin/cursor` 等）を先に探し、見つからなければ `command -v` にフォールバックする
- キーバインドはmacOS版dotfilesをLinux向けに差し替えている。カーソル移動は Vim 風の `alt+h/j/k/l`（左/下/上/右。Shift併用で選択）。Linuxのメニューニーモニック（`alt+h` がヘルプ等）と衝突するため、`settings.json` で `window.enableMenuBarMnemonics` と `window.customMenuBarAltFocus` を無効化している。チャット新規作成は Linux 既定の `ctrl+l` のまま（macOSの `cmd+l` 相当。Super+LはGNOMEの画面ロック）。統合ターミナルのコピー/ペーストは `ctrl+c` / `ctrl+v`（Linux既定の `ctrl+shift+c/v` を他アプリと揃える。`ctrl+c` は選択中のみコピーし、未選択時はSIGINT。選択中にコマンドを止める用途で `ctrl+shift+c` はコピーを外して SIGINT を送る）。Claude Code / Codex などの TUI 改行は `shift+enter` を ESC+CR（`sendSequence`）に差し替える（統合ターミナル既定は Enter も Shift+Enter も CR のみで、TUI の「改行」と「送信」が区別できない）。移動キーは `textInputFocus && !terminalFocus` に限定し、Claude Code などのTUIへキーを渡す
- `settings.json` の `terminal.integrated.enableKittyKeyboardProtocol` は `false`。VS Code 1.109以降はKitty Keyboard Protocolが既定ONで、xterm.jsがpress/releaseを二重送信し、TUIで1キーが2文字入るため
- `terminal.integrated.gpuAcceleration` は `off`。AMD（Lucienne）+ Wayland で統合ターミナルの描画欠け・ちらつきを避ける。`mouseWheelScrollSensitivity` は `3`（既定 1 より速いホイール）
- ウィンドウボタンは GNOME と同じ左上・一段。`settings.json` の `window.titleBarStyle` / `menuStyle` / `menuBarVisibility` をセットで指定する。理由と注意は下記「ウィンドウボタン（左上・一段）」
- 統合ターミナルの日本語IME（Claude Code などのTUIで「この」が「ｋこｎこのこの」になる問題）は下記「統合ターミナルの日本語IME」。効く本体は ibus の `embed-preedit-text = false`（[`nix/keyboard.nix`](../nix/keyboard.nix)）。Kitty・local echo・起動ラッパーは補助

## ウィンドウボタン（左上・一段）

GNOME 全体の閉じる/最小化/最大化は [`nix/desktop.nix`](../nix/desktop.nix) の `button-layout = "close,minimize,maximize:"` で左上にしている。VSCode / Cursor は Linux 既定の **custom タイトルバー**がこの dconf を無視し、ボタンを右上に描く。

そのため [`settings.json`](settings.json) では次の3つをセットで指定する。どれか欠けると「右上に戻る」か「タイトルバーとメニューが二段になり縦が潰れる」。

| 設定 | 値 | 役割 |
|---|---|---|
| `window.titleBarStyle` | `native` | OS のタイトルバーを使い、GNOME と同じ左上配置にする |
| `window.menuStyle` | `custom` | native タイトルバーでも compact メニューを有効にする |
| `window.menuBarVisibility` | `compact` | 「ファイル / 編集 / …」をタイトル直下の二段目から外し、アクティビティバー上部のハンバーガーへ移す |

制約:

- Linux の custom タイトルバーはボタン位置が右固定。左上にするには native にするしかない
- `titleBarStyle` だけ native にするとメニューが二段目になり、コード領域の縦が狭くなる
- `menuBarVisibility: compact` は `titleBarStyle` が native かつ `menuStyle` が inherit / native だと無視されて classic（二段）に戻る
- 反映にはエディタの**完全再起動**が必要（ウィンドウの Reload では足りない）。`home-manager switch` は不要

## 統合ターミナルの日本語IME（Claude Code 等のTUI）

VSCode の統合ターミナルで Claude Code などのTUIを開き、Mozc で「この」と打つと「ｋこｎこのこの」になる。変換中プレビュー（全角の `ｋ`・`ｎ`）と確定文字が両方 PTY へ送られ、画面を打ち直す TUI がそれを確定済みとして積むため。

**効いた対策**は ibus 側。[`nix/keyboard.nix`](../nix/keyboard.nix) が `desktop/ibus/general` の `embed-preedit-text` を `false` にする。変換中はカーソル付近のフローティング窓、確定した文字列だけが入力へ入る。即反映（ibus 再起動不要）。GUI から true に戻すと次回 `home-manager switch` で false に戻るので、true に戻さない。

エディタ本体のインライン下線はフローティングに変わる。TUI で満足に打てる方を優先している。

補助（これだけでは直らなかった）:

| 場所 | 内容 |
|---|---|
| `terminal.integrated.enableKittyKeyboardProtocol: false` | 英字の press/release 二重送信を止める |
| `terminal.integrated.localEchoEnabled: "off"` | TUI への入力先読みを止める |
| [`code`](code) ラッパー | snap の `electron-launch` が `GDK_BACKEND=wayland` と `--ozone-platform=x11` を同時に立て、GTK の wayland IM と Chromium の X11/XIM が二重になる。snap 同梱 GTK に `im-ibus.so` が無いので `DISABLE_WAYLAND=1`・`GDK_BACKEND=x11`・`GTK_IM_MODULE=xim` を付けて本体を exec する。`home.nix` が `~/.local/bin/code` とドック用 `code_code.desktop` を張る。反映には VSCode の完全再起動が必要 |

## よくある操作

### 設定・キーバインドの変更

エディタのUIから変更するだけ。git差分として現れるので確認してコミットする。適用コマンドは不要。

### 拡張機能の追加

エディタからインストールし、`extensions.txt` へIDを追記する。次回の `home-manager switch` でもう片方のエディタと新しいマシンに自動導入される。

### 拡張機能の削除

エディタからアンインストールし、`extensions.txt` から該当行を削除する。**リストから消しても既存環境からは自動でアンインストールされない**（新しい環境に入らなくなるだけ）。

## 注意

- 設定は両エディタで完全共有。片方だけに効かせる運用は想定していない（必要なら `home.nix` の `editorUserFiles` を分割する）
- `home.nix` 側の `force = true` は初回適用時に既存の実体ファイルをリンクへ置き換えるためのもの。別のマシンへ初適用する際、そのマシン固有の設定があれば先にこのディレクトリへ取り込んでおくこと
- このディレクトリのファイルはflake評価時には読まれず、適用時に絶対パスで参照されるだけ。追加・変更に `git add` は不要だが、新しいマシンへ配るにはコミットとpushが必要（`bootstrap.sh` はGitHub上のmainをクローンするため）
- `bootstrap.sh` の初回 `home-manager switch`（ステップ5）は VSCode の snap 導入（ステップ10）より先なので、その時点では拡張機能インストールはスキップされる。bootstrap 完了後にもう一度 `home-manager switch` すれば入る。Cursor は bootstrap 対象外なので、本体を入れたあとの switch で冪等にリトライされる
