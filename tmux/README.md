# tmux

SSH（iPhone）が切れても、PC側のシェルや `claude` / `codex` を残す。本体は Nix（`packages.nix`）。設定は [`home.nix`](../nix/home.nix) が `~/.tmux.conf` へ書き込み可能リンクする。

## ファイル構成

| ファイル | 役割 |
|---|---|
| [`.tmux.conf`](.tmux.conf) | 256色・履歴・マウス。切断でセッションを消さない |

## 動き

iPhone から SSH すると、[`../zsh/.zshrc`](../zsh/.zshrc) が既存セッションへ attach する（無ければ `main` を作る）。GNOME 端末や VSCode 統合端末では起動しない。

切断 = クライアントが離れるだけ。PC が動いていれば `claude` などはそのまま。入り直すと同じ画面に戻る。PC の再起動やスリープでは消える。

回避: `NOTMUX=1 ssh ...`。中で抜けるだけなら `exit`（セッションは残したいときは SSH アプリを閉じる）。
