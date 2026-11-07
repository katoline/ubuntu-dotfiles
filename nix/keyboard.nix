{ lib, ... }:
{
  # GNOMEのキーボード設定をdconfで宣言管理する。
  # 「Windowsの初期状態と同じ」挙動にする：
  #   - JIS配列（日本語キーボード）
  #   - 半角/全角キーでIME切り替え（ibus-mozcのデフォルト挙動。
  #     MozcのキーマップはMS-IME準拠が初期値のため追加設定は不要）
  #   - CapsLock単押しでも日本語⇄英数を切り替え。下記カスタムxkb設定で
  #     CapsLock単押しを半角/全角キー（Zenkaku_Hankaku）として送出し、
  #     MozcがIMEのON/OFFトグルとして処理する（OFF側は直接入力「A」）。
  #     jpレイアウト既定のEisu_toggleのままだとMozcは半角英数
  #     コンポジション「_A」（変換候補が出るモード）に切り替えてしまう
  #     ため差し替えている。Shift+CapsLockは従来どおりCaps Lock
  #   - CapsLock/Ctrl入れ替えなどのキー入れ替えはしない
  #   - キーリピートの初回遅延は180ms、リピート間隔は20ms
  #     （Backspaceなどを押し続けたときに素早く連続入力する）
  # 注: ibus-mozc本体はNix管理外（apt install ibus-mozc で導入する）。
  # GNOMEとのIME統合はシステム側にある方がトラブルが少ないため
  dconf.settings = {
    "org/gnome/desktop/input-sources" = {
      # 先頭が既定の入力ソース。mozc-jpを既定にし、
      # ibus-mozc未導入の環境でもJIS配列が使えるようxkbのjpも残す
      sources = [
        (lib.hm.gvariant.mkTuple [ "ibus" "mozc-jp" ])
        (lib.hm.gvariant.mkTuple [ "xkb" "jp" ])
      ];
      # custom:caps_zenkaku は下記 ~/.config/xkb で定義するカスタムオプション。
      # CapsLock単押しを大文字ロックなしの半角/全角キーにする。
      # 明示宣言により、GUIから設定されたキー入れ替え（ctrl:nocaps・
      # caps:none等）も次回switch時に打ち消される
      xkb-options = [ "custom:caps_zenkaku" ];
    };

    # キーリピート。Backspaceなどを押し続けた際の待ち時間と削除間隔を
    # 短くし、押しっぱなしで素早く連続入力できるようにする。
    # uint32 必須（素の整数だと型不一致）。GUI から変えた値は次回
    # switch でここに戻る
    "org/gnome/desktop/peripherals/keyboard" = {
      delay = lib.hm.gvariant.mkUint32 180;
      repeat-interval = lib.hm.gvariant.mkUint32 20;
      repeat = true;
    };

    # 変換中プレビューをアプリへ埋め込まない。既定の true だと VSCode 統合
    # ターミナルの xterm.js が Mozc の未確定文字（ｋ・ｎ）を確定扱いし、
    # Claude Code などの TUI で「この」が「ｋこｎこのこの」になる。
    # false にするとプリエディットはカーソル付近のフローティング窓に出る。
    # 確定した文字列だけが PTY へ送られる。ibus 再起動は不要（即反映）
    "desktop/ibus/general" = {
      embed-preedit-text = false;
    };
  };

  # libxkbcommonのユーザー設定（~/.config/xkb。GNOME Waylandが読む）。
  # なぜ必要か: gnome-shellはUI表記用にロケールのレイアウトを連結するため、
  # キーマップは常に複数レイアウト（この構成ではjp,jp）でコンパイルされる。
  # ところがxkbルール上、compat/japan（Eisu_toggleで大文字ロックさせない
  # 定義）は単一レイアウト時にしか適用されない（rules/evdevの
  # 「* jp = complete+japan」は複数レイアウト構成にマッチしない）。
  # その結果 compat/basic の汎用ルール「Any+Lock → LockMods(Lock)」が
  # 発動し、CapsLock単押しでIME切り替えと同時に大文字ロックが掛かって
  # しまう。ここで <CAPS> に明示的な actions を与えて interp を封じる。
  # 注: Group2（ロケール用付加レイアウト）は実行時グループ1固定のため
  # 定義不要。X11セッションではユーザーxkb設定は読まれない（Wayland前提）
  xdg.configFile."xkb/rules/evdev".text = ''
    ! option = symbols
      custom:caps_zenkaku = +custom(caps_zenkaku)

    ! include %S/evdev
  '';
  xdg.configFile."xkb/symbols/custom".text = ''
    // CapsLock単押し = Zenkaku_Hankaku（MozcのIME ON/OFFトグル。
    //   ロック動作なし。Eisu_toggleにしないのは、Mozcが半角英数
    //   コンポジション「_A」に入って変換候補が出てしまうため）
    // Shift+CapsLock = Caps Lock（JIS標準どおり維持）
    partial modifier_keys
    xkb_symbols "caps_zenkaku" {
        replace key <CAPS> {
            type[Group1] = "TWO_LEVEL",
            symbols[Group1] = [ Zenkaku_Hankaku, Caps_Lock ],
            actions[Group1] = [ NoAction(), LockMods(modifiers=Lock) ]
        };
    };
  '';

  # Mozcのibusエンジン設定。layoutを"jp"に固定する。
  # 既定値の "default" は「現在のxkbレイアウトを維持」の意味で、
  # gnome-shellはこれをxkbレイアウトとして解決できず何もしないため、
  # ログイン直後にmozc-jpが選ばれるとシステム既定（/etc/default/keyboard
  # のus）のまま固定される。usレイアウトではCapsLockがEisu_toggleに
  # ならず（半角/全角キーも送出されず）、IME切り替えが一切効かない。
  # 変更の反映には `ibus write-cache; ibus restart`（または再ログイン）が必要
  xdg.configFile."mozc/ibus_config.textproto" = {
    # mozcが初回起動時に自動生成した実体ファイルを置き換えるため
    force = true;
    text = ''
      engines {
        name : "mozc-jp"
        longname : "Mozc"
        layout : "jp"
      }
    '';
  };
}
