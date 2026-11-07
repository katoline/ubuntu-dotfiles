# zsh / ターミナル設定

Oh My Zsh + Powerlevel10k の設定実体。適用は [nix/home.nix](../nix/home.nix) が担い、`~/.zshrc` / `~/.bashrc` / `~/.p10k.zsh` へ書き込み可能なシンボリックリンクを張る。Oh My Zsh 本体とテーマはあえてNix管理外で、[bootstrap.sh](../bootstrap.sh) が `~/.oh-my-zsh` へ導入する。

## ファイル構成

| ファイル | 役割 |
|---|---|
| [`.zshrc`](.zshrc) | SSH時の tmux attach、Oh My Zsh の起動、`~/.local/bin` を PATH へ（SSHでも claude / codex を見つける）、`LESS=-FRX`、p10k の読み込み、direnv フック |
| [`.p10k.zsh`](.p10k.zsh) | Powerlevel10k の見た目（macOS風の最小構成。手書き） |
| [`.bashrc`](.bashrc) | 対話bashを即zshへ `exec` する引き継ぎ用 |

## プロンプト（Powerlevel10k）

macOS標準ターミナルの `user@host dir %` に寄せた、左側のみ・1行・背景色なしのコンパクトな見た目。

| 要素 | 内容 |
|---|---|
| context | `user@host` を常時表示（無色） |
| dir | カレントは最後の1階層のみ（ホームは `~`）。色は黒背景でも読める明るい青（256色の39） |
| vcs | ブランチ名のみ。クリーンは緑、変更ありは黄、コンフリクトは赤。マーカー（`●` / `?`）は出さない |
| prompt_char | macOSと同じ `%`（直前コマンド成功で緑・失敗で赤） |

`p10k configure` は使わない（ウィザードが `~/.p10k.zsh` を実体ファイルで上書きする）。見た目を変えるときはリポジトリの `.p10k.zsh` を直接編集する。home-manager 側は `force = true` なので、上書きされても次回 switch でリンクに戻る。

## SSH（iPhone）でも claude / codex を使う

`claude` と `codex` は `~/.local/bin` にある。GNOME端末はグラフィカルログイン時の `~/.profile` でこのPATHを継承するが、zsh は SSH ログインで `.profile` を読まない。そのため iPhone から入ると `command not found: claude` になる。`.zshrc` が `~/.local/bin` を PATH に足す。新しいSSHセッションから有効（既存セッションは `source ~/.zshrc` か再接続）。

Claude Code などは全画面TUIなので、スマホの狭い画面・特殊キー不足では操作しづらい。つながったあとに `claude` と打てば起動はする。

iPhone の SSH は [`../tmux/README.md`](../tmux/README.md) により自動で tmux に入る。切れて入り直すと、動いていた `claude` などの画面に戻る。

## direnv連携

`.zshrc` の末尾で、`direnv` が入っていれば `direnv hook zsh` を評価する（未導入環境でもエラーにならないよう `command -v` でガード）。direnv本体（nix-direnv含む）は [`../nix/home.nix`](../nix/home.nix) の home-manager 設定で導入している。`~/.zshrc` は `mkOutOfStoreSymlink` 管理のため `enableZshIntegration` ではフックを注入できない。

## bashからの引き継ぎ

bashは使わない運用。ログインシェルがbashのままの環境（`chsh` 未実行）や `bash` を対話起動したときは `.bashrc` が zsh へ `exec` する。どうしてもbashが必要なときは `NO_ZSH=1 bash`。

## 反映方法

```zsh
source ~/.zshrc
```

リンクは書き込み可能なので、このディレクトリを編集すれば新しいシェルから即反映される。home-manager switch はリンクを張り直すときだけ必要。
