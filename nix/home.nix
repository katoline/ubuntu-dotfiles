{
  config,
  lib,
  pkgs,
  username,
  dotfilesPath,
  cliConfigPython,
  ...
}:
let
  # VSCode / Cursor は設定ファイルの形式・配置が同じ（CursorはVSCodeのフォーク）ため、
  # 両エディタとも vscode/ 配下の同一ファイルへの「書き込み可能なリンク」にする。
  # どちらのUIから変更しても同じ実体に書き込まれ、git差分として現れる。
  # エディタ本体はNix管理外（apt/snap等で手動導入）なので、programs.vscode
  # モジュール（Nix製VSCodeの導入が前提）は使わない。
  # force = true は初回適用時に既存の実体ファイルをリンクへ置き換えるために必要
  # （既存の内容はリポジトリへ取り込み済み）
  editorUserFiles = app: {
    ".config/${app}/User/keybindings.json" = {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/vscode/keybindings.json";
      force = true;
    };
    ".config/${app}/User/settings.json" = {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/vscode/settings.json";
      force = true;
    };
  };

  # ~/Dev 配下の作業用ルートディレクトリ。唯一の定義は .claude/dev-roots（1 行 1 パス、~/ 始まり。
  # guard-destructive.sh の削除許可ルートと同じファイルを読む）。新しいマシンでも同じ配置で作業を
  # 始められるようにする（中身の各リポジトリは対象外）。flake は git 追跡ファイルしか読めないので、
  # dev-roots を変更したら git add すること
  # 読み方（# 以降を落とす・前後の空白を除く・末尾の / を落とす・~/ 始まりの行だけ採る）は
  # guard-destructive.sh とテスト（DR / DC）と揃えてある
  devDirs = map (m: "${config.home.homeDirectory}/${lib.removeSuffix "/" (lib.removePrefix "~/" (lib.head m))}")
    (lib.filter (m: m != null)
      (map (l: builtins.match "[[:space:]]*(~/[^#]*[^#[:space:]])[[:space:]]*(#.*)?" l)
        (lib.splitString "\n" (builtins.readFile ../.claude/dev-roots))));
in
{
  home.username = username;
  home.homeDirectory = "/home/${username}";

  # home-managerの互換バージョン（変更しない）
  home.stateVersion = "25.05";

  # home-manager自身をhome-managerで管理する。
  # これにより2回目以降は `home-manager switch` コマンドが使えるようになる
  programs.home-manager.enable = true;

  # Nixで導入したフォント（packages.nixのnerd-fonts）をfontconfigに認識させる
  fonts.fontconfig.enable = true;

  # GNOME端末の見た目。フォントはNerd Font（Powerlevel10kのアイコン描画に必要）、
  # 配色はmacOSターミナル「Pro」風の黒背景・白文字。ANSIカラーはApple純正だと
  # 黒背景で青・黄が沈んで読めないため、黒背景用に設計された
  # VS Code Dark+ 系の視認性の高いパレットを使う。
  # UUIDはUbuntuが標準で配布する既定プロファイルのもので、マシン間で共通。
  # GUIでプロファイルを作り直した場合はUUIDが変わるのでこの設定は効かなくなる
  dconf.settings."org/gnome/terminal/legacy/profiles:/:b1dcc9dd-5262-4d8d-a863-c897e6d979b9" = {
    use-system-font = false;
    font = "UbuntuMono Nerd Font Mono 10";
    use-theme-colors = false;
    background-color = "#000000";
    foreground-color = "#F2F2F2";
    # Ubuntu既定の 80x24 より広いサイズ
    default-size-columns = 120;
    default-size-rows = 30;
    bold-color-same-as-fg = true;
    bold-is-bright = true;
    audible-bell = false;
    # 黒背景のまま 20% 透過。use-theme-transparency を切らないと
    # テーマ側の透過設定に上書きされる
    use-theme-transparency = false;
    use-transparent-background = true;
    background-transparency-percent = 20;
    palette = [
      "#000000" # black
      "#CD3131" # red
      "#0DBC79" # green
      "#E5E510" # yellow
      "#2472C8" # blue
      "#BC3FBC" # magenta
      "#11A8CD" # cyan
      "#E5E5E5" # white
      "#666666" # bright black
      "#F14C4C" # bright red
      "#23D18B" # bright green
      "#F5F543" # bright yellow
      "#3B8EEA" # bright blue
      "#D670D6" # bright magenta
      "#29B8DB" # bright cyan
      "#FFFFFF" # bright white
    ];
  };

  # ~/.zshrc はリポジトリ実体への「書き込み可能なリンク」にする。
  # home-manager標準のstore管理だと読み取り専用になり、
  # リポジトリ側を直接編集して即反映という現在の運用ができなくなるため
  home.file = {
    ".zshrc".source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/zsh/.zshrc";
    # bashが対話起動されたらzshへ引き継ぐ（bashは使わない運用）。
    # force = true はUbuntu標準の実体 ~/.bashrc をリンクへ置き換えるために必要
    ".bashrc" = {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/zsh/.bashrc";
      force = true;
    };
    # Powerlevel10kの設定（macOS風の最小構成）。
    # force = true は `p10k configure` が実体ファイルを生成してリンクを
    # 上書きしてしまった場合に、次回switchでリンクへ戻すため
    ".p10k.zsh" = {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/zsh/.p10k.zsh";
      force = true;
    };
    # tmux。force = true は壊れた store リンクや既存実体を置き換えるため
    ".tmux.conf" = {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/tmux/.tmux.conf";
      force = true;
    };
    # git設定。force = true は既存の実体ファイル ~/.gitconfig をリンクへ
    # 置き換えるために必要。user.name / user.email はリポジトリに含めず、
    # 各PCで手動配置する ~/.gitconfig.local（git管理外）から include される
    ".gitconfig" = {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/git/.gitconfig";
      force = true;
    };
    # Grok CLI の設定。grok 自身もこのファイルへ書き込むため、書き込み可能
    # リンクにして変更をリポジトリ側へ取り込む（VSCode設定と同じ方式）。
    # force = true は既存実体ファイルの置き換え用。Grok がリンクを実体で
    # 置き換えた場合は、下の captureGrokConfigWrites が switch 直前に取り込む
    ".grok/config.toml" = {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/grok/config.toml";
      force = true;
    };
    # config.toml / hooks.json は下の mergeCliConfigs が実ファイルとして生成する。
    # フックスクリプトと旧プロンプトは個別リンクを維持する。
    ".codex/hooks/guard.sh" = {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/codex/hooks/guard.sh";
      force = true;
    };
    ".codex/hooks/harness.sh" = {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/codex/hooks/harness.sh";
      force = true;
    };
    ".codex/prompts/pr.md" = {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/codex/prompts/pr.md";
      force = true;
    };
    # Codex 専用の入口は従来の探索先 ~/.codex/skills へ隔離する。ディレクトリ単位で
    # 個別リンクし、ユーザーが追加した別スキルは home-manager の対象にしない
    ".codex/skills/pr" = {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/codex/skills/pr";
      force = true;
    };
    ".codex/skills/readme" = {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/codex/skills/readme";
      force = true;
    };
    ".codex/skills/nix-setup" = {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/codex/skills/nix-setup";
      force = true;
    };
    ".codex/skills/git-pull" = {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/codex/skills/git-pull";
      force = true;
    };
    ".codex/skills/clean-branches" = {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/codex/skills/clean-branches";
      force = true;
    };
    ".codex/skills/opencode" = {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/codex/skills/opencode";
      force = true;
    };
    # Devin config.json も mergeCliConfigs で実ファイルにして org_id 等を残す。
    # OpenCode のグローバル設定。permission・CLI設定・通知plugin・コマンド・Skillを
    # リポジトリ実体への書き込み可能リンクにして、変更をdotfilesで管理する。
    # グローバル指示は ai/install.sh が ~/.config/opencode/AGENTS.md を連結生成する。
    # V2 は CLAUDE.md にフォールバックせず instructions の参照も未対応なので、AGENTS.md を維持する。
    ".config/opencode/opencode.json" = {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/opencode/opencode.json";
      force = true;
    };
    ".config/opencode/cli.json" = {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/opencode/cli.json";
      force = true;
    };
    ".config/opencode/plugins/mobile-notify.js" = {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/opencode/plugins/mobile-notify.js";
      force = true;
    };
    ".config/opencode/plugins/usage-footer" = {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/opencode/plugins/usage-footer";
      force = true;
    };
    ".config/opencode/commands/pr.md" = {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/opencode/commands/pr.md";
      force = true;
    };
    ".config/opencode/commands/readme.md" = {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/opencode/commands/readme.md";
      force = true;
    };
    ".config/opencode/commands/clean-branches.md" = {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/opencode/commands/clean-branches.md";
      force = true;
    };
    ".config/opencode/commands/nix-setup.md" = {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/opencode/commands/nix-setup.md";
      force = true;
    };
    ".config/opencode/commands/git-pull.md" = {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/opencode/commands/git-pull.md";
      force = true;
    };
    ".config/opencode/commands/code-review.md" = {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/opencode/commands/code-review.md";
      force = true;
    };
    ".config/opencode/agents/code-review.md" = {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/opencode/agents/code-review.md";
      force = true;
    };
    ".config/opencode/agents/pr.md" = {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/opencode/agents/pr.md";
      force = true;
    };
    ".config/opencode/skills/pr/SKILL.md" = {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/opencode/skills/pr/SKILL.md";
      force = true;
    };
    # VSCode 起動ラッパー。snap の electron-launch が GDK_BACKEND=wayland と
    # --ozone-platform=x11 を同時に立て、IME が二重になって TUI へ変換中プレビュー
    # が漏れるのを、DISABLE_WAYLAND=1 + GDK_BACKEND=x11 + GTK_IM_MODULE=xim で一本化する。
    # ~/.local/bin は PATH 上 /snap/bin より前。本体はラッパーが /snap/bin/code を exec する
    ".local/bin/code" = {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/vscode/code";
    };
  }
  // editorUserFiles "Code" # VSCode
  // editorUserFiles "Cursor";

  # .claude/dev-roots の各ディレクトリを activation 時に用意する（既にあれば何もしない）。
  # bootstrap.sh の初回適用でも 2回目以降の home-manager switch でも走る。
  # activation の PATH は最小構成なので mkdir は coreutils のフルパスで呼ぶ。
  # 作業ディレクトリは作れて当然なので失敗時は switch を止める
  # （claude-notify の soft fail とは意図的に非対称）
  home.activation.createDevDirs = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArgs devDirs}
  '';

  # 拡張機能は「ファイル」ではなく「インストール状態」なのでリンクでは管理できない。
  # vscode/extensions.txt のIDリストを activation 時に VSCode / Cursor へ流し込む。
  # リストから消しても既存環境からはアンインストールされない
  # （新規環境に入らなくなるだけ）
  home.activation.installEditorExtensions = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run /bin/bash ${dotfilesPath}/vscode/install-extensions.sh
  '';

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

  # 旧世代の home.file リンクを先に実ファイルにする。linkGeneration は実ファイルを
  # 旧管理リンクとして削除しないので、リンク先や外部ツールの保存内容を引き継げる。
  # リポジトリの旧設定を更新する前の移行手順は codex/README.md を参照。
  home.activation.detachCliConfigLinks = lib.hm.dag.entryBetween [ "linkGeneration" ] [ "writeBoundary" ] ''
    run ${cliConfigPython}/bin/python3 ${dotfilesPath}/nix/merge-cli-config.py \
      --repo ${lib.escapeShellArg dotfilesPath} --home "$HOME" --detach-only
  '';

  # 宣言した値だけを上書きし、trust・trusted_hash・desktop のランタイム・org_id は
  # ホーム側へ残す。外部ツールが実ファイルを更新してもリポジトリへは取り込まない。
  home.activation.mergeCliConfigs = lib.hm.dag.entryAfter [ "linkGeneration" "detachCliConfigLinks" ] ''
    run ${cliConfigPython}/bin/python3 ${dotfilesPath}/nix/merge-cli-config.py \
      --repo ${lib.escapeShellArg dotfilesPath} --home "$HOME"
  '';

  # OpenCodeが設定保存時にシンボリックリンクを実体ファイルで置き換えた場合、
  # home.file の force=true でリンクを戻す前に新しい内容をリポジトリへ取り込む。
  home.activation.captureOpenCodeConfigWrites = lib.hm.dag.entryBefore [ "writeBoundary" ] ''
    for name in opencode.json cli.json; do
      dest="$HOME/.config/opencode/$name"
      src="${dotfilesPath}/opencode/$name"
      if [ -f "$dest" ] && [ ! -L "$dest" ] && [ -f "$src" ] && [ "$dest" -nt "$src" ]; then
        if ! ${pkgs.diffutils}/bin/cmp -s "$src" "$dest"; then
          run ${pkgs.coreutils}/bin/cp "$dest" "$src"
          echo "OpenCode $name の実体変更をリポジトリへ取り込みました"
        fi
      fi
    done
  '';

  # ~/.claude 配下のリンクは既存の setup.sh に委譲する。
  # setup.sh は「リンクが実体ファイルで上書きされた場合に実体側を
  # リポジトリへ取り込んでからリンクし直す」セルフヒーリングを持ち、
  # home-managerの宣言管理では再現できないため、あえて移行しない
  # setup.sh は配布対象を「git が知るファイル」に限定するため git を PATH に通す
  # （activation の PATH は最小構成で git が無い）
  home.activation.linkClaudeConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run env PATH="${pkgs.git}/bin:$PATH" /bin/bash ${dotfilesPath}/.claude/setup.sh
  '';

  # 全CLI共通のグローバル指示（ai/core.md + ai/<cli>.md）を各CLIへ配布する。
  # Claude Code はリンク、include を持たない Grok / Codex / Devin は連結生成。
  # setup.sh が ~/.claude の古いリンクを掃除した後に走らせる（順序が逆だと
  # ~/.claude/CLAUDE.md の新しいリンクを切れリンクとして消される可能性がある）
  home.activation.linkAiInstructions = lib.hm.dag.entryAfter [ "linkClaudeConfig" ] ''
    run /bin/bash ${dotfilesPath}/ai/install.sh
  '';

  # OpenSSH サーバーと Tailscale。システムサービスなので Nix では入れず setup.sh に委譲する。
  # bootstrap.sh からも同じスクリプトを実行する。switch 中は TTY が無く sudo できないので、
  # 入っていれば確認だけで終わる（未導入なら警告を出して switch は止めない）
  home.activation.ensureSshTailscale = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run /bin/bash ${dotfilesPath}/ssh-tailscale/setup.sh \
      || echo "警告: OpenSSH / Tailscale の確認に失敗しました（ssh-tailscale/README.md）"
  '';

  # direnv: .envrc のあるプロジェクトディレクトリに cd した瞬間、
  # そのプロジェクトの flake.nix devShell を自動で有効化/無効化する。
  # nix-direnv は devShell の評価結果をキャッシュして即座に切り替えるための拡張
  # （direnvrc の配線も home-manager が自動生成する）。
  # zsh へのフックは ~/.zshrc が mkOutOfStoreSymlink 管理（home-manager 非管理）のため
  # enableZshIntegration では注入されず、zsh/.zshrc に直接記述している
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # 既定ブラウザを Google Chrome にする（Dock先頭・bootstrap導入と揃える）。
  # xdg-open や GNOME のリンク開きが Firefox（Ubuntu既定snap）に流れないようにする。
  # force = true は Ubuntu が既に作っている実体をリンクへ置き換えるために必要。
  # mimeApps は ~/.config と ~/.local/share/applications の両方に書く
  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "text/html" = "google-chrome.desktop";
      "x-scheme-handler/http" = "google-chrome.desktop";
      "x-scheme-handler/https" = "google-chrome.desktop";
      "x-scheme-handler/about" = "google-chrome.desktop";
      "x-scheme-handler/unknown" = "google-chrome.desktop";
    };
  };
  xdg.configFile."mimeapps.list".force = true;
  xdg.dataFile."applications/mimeapps.list".force = true;

  # ドック／アプリ一覧からの起動は PATH を見ないため、snap の desktop を
  # ユーザー側で上書きしてラッパー経由にする。ID は snap と同じ code_code.desktop
  xdg.dataFile."applications/code_code.desktop".text = ''
    [Desktop Entry]
    X-SnapInstanceName=code
    Name=Visual Studio Code
    Comment=Code Editing. Redefined.
    GenericName=Text Editor
    X-SnapAppName=code
    X-SnapCommonID=code.desktop
    Exec=${config.home.homeDirectory}/.local/bin/code --force-user-env %F
    Icon=/snap/code/current/meta/gui/vscode.png
    Type=Application
    StartupNotify=false
    StartupWMClass=Code
    Categories=TextEditor;Development;IDE;
    MimeType=application/x-code-workspace;
    Actions=new-empty-window;
    Keywords=vscode;

    [Desktop Action new-empty-window]
    Name=New Empty Window
    Name[ja]=新しい空のウィンドウ
    X-SnapAppName=code
    X-SnapCommonID=code.desktop
    Exec=${config.home.homeDirectory}/.local/bin/code --force-user-env --new-window %F
    Icon=/snap/code/current/meta/gui/vscode.png
  '';
  xdg.dataFile."applications/code_code-url-handler.desktop".text = ''
    [Desktop Entry]
    X-SnapInstanceName=code
    Name=Visual Studio Code - URL Handler
    Comment=Code Editing. Redefined.
    GenericName=Text Editor
    X-SnapAppName=code
    X-SnapCommonID=code.desktop
    Exec=${config.home.homeDirectory}/.local/bin/code --force-user-env --open-url %U
    Icon=/snap/code/current/meta/gui/vscode.png
    Type=Application
    NoDisplay=true
    StartupNotify=true
    Categories=Utility;TextEditor;Development;IDE;
    MimeType=x-scheme-handler/vscode;
    Keywords=vscode;
  '';

  # iPhoneプッシュ通知の送信スクリプト（claude-notify/send-push.mjs）は
  # web-push に依存するため、node_modules を activation 時に用意する。
  # node_modules はリポジトリ管理外（.gitignore）なので、新しいUbuntuマシンでも
  # `home-manager switch` だけで送信できる状態になる。
  # pnpm は実行に node を要するので PATH に nodejs を通す。
  # オフライン等でインストールに失敗しても switch 全体は失敗させない
  home.activation.installClaudeNotifyDeps = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${pkgs.bash}/bin/bash -c '
      export PATH="${pkgs.nodejs_26}/bin:$PATH"
      cd "${dotfilesPath}/claude-notify" &&
        "${pkgs.pnpm}/bin/pnpm" install --frozen-lockfile
    ' || echo "警告: claude-notify の依存インストールに失敗しました（iPhone通知は無効のまま。ネットワーク接続後に手動で 'cd ${dotfilesPath}/claude-notify && pnpm install' を実行してください）"
  '';

  # gh は ~/.config/gh/config.yml を自分で書き換えるツールなのでファイルリンクでは
  # 管理せず、activation で `gh alias set` を実行して co: pr checkout のエイリアスを
  # 冪等に設定する。--clobber は既存エイリアスがあっても上書きして冪等にするため。
  # gh未導入やネットワーク不通でも switch を止めない
  home.activation.setGhAlias = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${pkgs.gh}/bin/gh alias set co "pr checkout" --clobber \
      || echo "警告: gh のエイリアス設定に失敗しました（gh未導入またはネットワーク不通の可能性）"
  '';
}
