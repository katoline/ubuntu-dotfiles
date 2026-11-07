{ pkgs, ... }:
{
  # CLIツールはすべてnixpkgsで管理する。
  # バージョンは flake.lock で固定され、新しいマシンでも同一バージョンが入る。
  # 更新したいときは `nix flake update` → `home-manager switch`
  home.packages = with pkgs; [
    # バージョン管理
    git
    gh
    vim # gitconfigの diff.tool = vimdiff に必要

    # JavaScript / Node.js
    nodejs_26
    pnpm

    # コンテナ・インフラ
    docker # dockerクライアントCLI（Docker Engine本体はaptで導入する。nix/README.md参照）
    docker-compose
    supabase-cli
    # 注: Claude Code / OpenCode / Codex CLIは意図的にNix管理外。
    # 各公式インストーラーで導入する（Claude Code / Codex は自動更新、
    # OpenCode は公式配布バイナリ。bootstrap.sh が担当）

    # ユーティリティ
    jq
    tmux # iPhone SSH 切断後も claude / codex 等を残す。zshrc が SSH 時だけ attach

    # フォント。Powerlevel10kのアイコン・区切り記号の描画に必要なNerd Font。
    # Ubuntu標準ターミナルと同じ細い字幅を保つためUbuntuMonoのNerd Font版を使う
    # （fontconfigへの反映は home.nix の fonts.fontconfig.enable が担う）
    nerd-fonts.ubuntu-mono
  ];
}
