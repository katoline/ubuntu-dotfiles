# iPhoneからUbuntuへSSH（Tailscale）

自宅のUbuntuに、iPhoneからSSHで入る。ルーターのポート開放はせず、**Tailscale + SSH** でつなぐ。インターネットに22番ポートを公開しない。

導入はリポジトリ README の適用コマンドに任せる（新しいマシンは `bootstrap.sh`、このPCは `home-manager switch`）。どちらも [`setup.sh`](setup.sh) を実行する。

## ファイル構成

| ファイル | 役割 |
|---|---|
| [`setup.sh`](setup.sh) | OpenSSH サーバーと Tailscale を冪等に導入する。bootstrap と `home-manager switch` の両方から呼ばれる |
| [`README.md`](README.md) | iPhone側の接続手順 |

OpenSSH も Tailscale デーモンもシステムサービスなので Nix では管理しない。

---

## Ubuntu側（このPCでは完了している）

`home-manager switch` または `bootstrap.sh` で入る。未ログインのときだけ、ターミナルで:

```zsh
sudo tailscale up
```

表示されたURLをブラウザで開き、**iPhoneと同じアカウント**（Google / Apple / Microsoft）でログインする。

接続先の確認:

```zsh
whoami
tailscale ip -4
tailscale status
```

- `whoami` → Termius の Username
- `tailscale ip -4` の `100.` で始まる番号 → Termius の Address（**これを使う**。`192.168.` やホスト名は使わない）
- `tailscale status` に iPhone が出ていれば、両方同じアカウントでオンライン

このリポジトリの GNOME 設定（[`nix/desktop.nix`](../nix/desktop.nix)）は AC 電源時の自動スリープを切っている。スリープすると外出先から入れない。

---

## いちばん多い失敗

iPhoneのSSHアプリは Tailscale の名前解決を使わないことがある。**Address には必ず `tailscale ip -4` の `100.` で始まる番号を入れる。** マシン名や `*.ts.net` だと「ホストが見つからない」「タイムアウト」になりやすい。

もう一つ多いのは、Termius が **SSH ID / 鍵** を使おうとしてパスワード欄が空のまま接続すること。最初はパスワードだけにする。

---

## iPhone：Tailscale（先にやる）

Ubuntuより **先に** Tailscale をオンにする。Termius を先に開いてもつながらない。

1. App Store で **Tailscale** を入れる（白い背景に黒いひし形のアイコン）
2. 開いて、Ubuntuと同じアカウントでログインする
3. 「VPN構成の追加」と出たら **許可** → iPhoneのパスコード
4. 画面のスイッチをオンにする。オンならステータスバーに **VPN** と出る
5. 端末一覧に Ubuntu が出ているか確認する（名前は `tailscale status` の左のマシン名）。灰色・Offline なら、PC側で `tailscale status` を見る。PCがスリープしていないか
6. 他のVPN（会社VPN、DNSアプリのVPN、iCloud Private Relay で繋がらない場合）は切る。iOSのVPNは同時に1つだけ

Tailscale の画面に Ubuntu が見えないときは、アカウントが違う。一度ログアウトして、Ubuntuで `tailscale status` に出ているアカウントで入り直す。

---

## iPhone：Termiusで接続する（ここをそのまま入力）

1. App Store で **Termius** を入れる
2. 起動する。アカウント作成を求められても、**無料のまま**進んでよい（Hosts は作れる）
3. 初回に「ローカルネットワーク」の許可が出たら **許可**。出なかったら iPhoneの **設定 → Termius → ローカルネットワーク** をオン
4. 下のタブ **Hosts**（ホスト）を開く
5. 右上または中央の **+** → **New Host**（新規ホスト）
6. Ubuntuで控えた値を入力する（番号や名前はリポジトリに書かない）

| 欄 | 値 | 注意 |
|---|---|---|
| Alias / Label（任意） | 自分用の名前 | 何でもよい |
| **Address / Host** | `tailscale ip -4` の結果 | **これだけは必須。** `192.168.` もマシン名も `*.ts.net` も入れない |
| Port | `22` | 空なら 22 のまま |
| **Username** | `whoami` の結果 | `root` やメールアドレスではない。Ubuntuのログイン名 |
| **Password** | Ubuntuにログインするときのパスワード | 下の「鍵」は触らない |
| SSH ID / Key / Certificate | **使わない・空** | ここを選ぶとパスワードでは入れない |

7. 右上の **Save**（保存）
8. 保存したホストを **タップ** して接続する
9. 「Are you sure you want to continue connecting?」や指紋（fingerprint）の確認が出たら **Continue / Accept / 信頼**
10. パスワードを求められたら、もう一度 Ubuntu のログインパスワード

黒い画面にプロンプトが出れば成功。SSH では自動で tmux に入る。アプリを閉じても PC 側の `claude` などは動き続け、入り直すと同じ画面に戻る（詳細は [`../tmux/README.md`](../tmux/README.md)）。

### つながらないときに Termius で見ること

接続ログや赤いエラーの文言で切り分ける。

| 表示 | 原因 | やること |
|---|---|---|
| Timed out / タイムアウト / Host is unreachable | Tailscaleがオフ、Addressが違う、PCがスリープ | Tailscaleで Ubuntu がオンラインか。Address が `tailscale ip -4` と同じか。PCの電源 |
| Could not resolve hostname / ホスト名を解決できない | 名前を入れている | Address を `tailscale ip -4` の番号に変える |
| Permission denied / Authentication failed / 認証失敗 | ユーザー名かパスワード、または鍵の取り違え | Username が `whoami` か。Password にUbuntuのログインパスワード。Key / SSH ID を外す |
| Connection refused | SSHサーバーが落ちている | PCで `systemctl is-active ssh` が `active` か |
| 会社Wi-Fiだけダメ | そのネットがVPNを遮断 | iPhoneのWi-Fiを切ってモバイル回線で試す |

まだダメなら Termius 側の回避を試す。

1. iPhone **設定 → Termius → ローカルネットワーク** をオン
2. Termius → **Profile → Settings → Sessions** で **Experimental Connection Process** をオン
3. Termius → Settings の **Post-Quantum Key Exchange** があればオフ

---

## 家にいるうちに確認する順番

1. iPhoneのTailscaleで Ubuntu が見える
2. 同じWi-Fiのまま、Termiusの Address に `tailscale ip -4` の番号を入れてつなぐ
3. iPhoneのWi-Fiを切り、モバイル回線だけにする
4. TailscaleがVPN表示のまま、同じ番号でもう一度入れる

3〜4まで通れば、外出先でも同じ操作。

---

## SSH鍵にする（つながってからでよい）

最初はパスワードで十分。常用するなら:

1. Termius で Ed25519 鍵を作る（Keychain）
2. 公開鍵をコピーする
3. Ubuntuで `~/.ssh/authorized_keys` に1行追加し `chmod 600 ~/.ssh/authorized_keys`
4. **鍵で入れることを確認してから**、必要なら `PasswordAuthentication no`

今のセッションを切らずに、別の接続で鍵が入ることを確認する。入れなくなると復旧が面倒。

---

## ファイアウォール（任意）

`setup.sh` は UFW を有効化しない。有効化するなら SSH を先に許可する。

```zsh
sudo ufw allow OpenSSH
sudo ufw allow in on tailscale0
sudo ufw enable
```

---

## Ubuntuでの状態確認

```zsh
tailscale status
tailscale ip -4
systemctl is-active ssh tailscaled
```

---

## やらない方がいいこと

- ルーターでポート22をインターネットに開放する
- root のパスワードログインを残す
- 鍵で入れる確認前に `PasswordAuthentication no` にする
- Termius の Address に LAN の `192.168.` を入れて外出先で使う
