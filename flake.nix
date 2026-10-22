{
  description = "Ubuntu environment (home-manager standalone)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # Node.js とその共有ライブラリは、セキュリティ修正済みの入力から供給する。
    nodejs-nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable-small";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nodejs-nixpkgs,
      home-manager,
    }:
    let
      # このマシンのユーザー名。新しいマシンでは bootstrap.sh が
      # 実際のユーザー名に自動で書き換える（手動で編集してもよい）
      username = "peipou";
      # このリポジトリの実体パス。
      # .claude/ や zsh/ への「書き込み可能なリンク」を張るために使う。
      # クローン先は bootstrap.sh が ~/Dev/kaishi/ubuntu-dotfiles に統一する
      dotfilesPath = "/home/${username}/Dev/kaishi/ubuntu-dotfiles";
      # CPUアーキテクチャ。ARM環境（Raspberry Pi等）では "aarch64-linux" に変更する
      system = "x86_64-linux";
      nodejsPkgs = import nodejs-nixpkgs { inherit system; };
      # Node本体の更新だけでは共有c-ares/SQLiteが古いままになるため、修正版を固定する。
      secureCares =
        if nodejsPkgs.lib.versionAtLeast nodejsPkgs.c-ares.version "1.34.9" then
          nodejsPkgs.c-ares
        else
          nodejsPkgs.c-ares.overrideAttrs (_: {
            version = "1.34.9";
            src = nodejsPkgs.fetchurl {
              url = "https://github.com/c-ares/c-ares/releases/download/v1.34.9/c-ares-1.34.9.tar.gz";
              hash = "sha256-k2S3ChLrWaBoMPtIjZNX+QEA3/DZiyPqNZOhg9Q+by8=";
            };
          });
      secureSqlite =
        if nodejsPkgs.lib.versionAtLeast nodejsPkgs.sqlite.version "3.53.4" then
          nodejsPkgs.sqlite
        else
          nodejsPkgs.sqlite.overrideAttrs (_: {
            version = "3.53.4";
            src = nodejsPkgs.fetchurl {
              url = "https://sqlite.org/2026/sqlite-src-3530400.zip";
              hash = "sha256-0Y+hWux02MF+FGP4YQla3AG1rRkCVqy0+R0i8DaNIys=";
            };
            docsrc = nodejsPkgs.fetchurl {
              url = "https://sqlite.org/2026/sqlite-doc-3530400.zip";
              hash = "sha256-odD13ldIXQYnlu1+Z9r/B1i1DQAAGg8jOiwVqvQLvcg=";
            };
          });
      # Nodeだけの依存を差し替える。PythonやPlaywright等の固定は変えない。
      secureSlim = nodejsPkgs.nodejs-slim_26.override {
        callPackage = path: args: nodejsPkgs.callPackage path (args // {
          c-ares = secureCares;
          sqlite = secureSqlite;
        });
      };
      secureNode =
        assert nodejsPkgs.lib.versionAtLeast secureSlim.version "26.12.1";
        nodejsPkgs.nodejs_26.override { nodejs-slim = secureSlim; };
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays = [
          (_: prev: {
            nodejs_26 = secureNode;
            pnpm = prev.pnpm.override { nodejs-slim = secureNode; };
          })
        ];
      };
      # CLI 設定のマージとテストで同じ Python・依存を使う。
      cliConfigPython = pkgs.python3.withPackages (ps: [ ps.tomlkit ]);
    in
    {
      packages.${system} = {
        cli-config-python = cliConfigPython;
        nodejs-security = secureNode;
      };

      # マシン（ホスト名）に依存しない固定の構成名。
      # 適用時は `--flake <リポジトリ>#ubuntu` と明示的に指定する
      homeConfigurations."ubuntu" = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        extraSpecialArgs = { inherit username dotfilesPath cliConfigPython; };
        modules = [
          ./nix/home.nix
          ./nix/packages.nix
          ./nix/keyboard.nix
          ./nix/desktop.nix
        ];
      };
    };
}
