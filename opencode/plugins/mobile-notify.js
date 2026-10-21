// OpenCode からは claude-notify の通知を送信しない。
// 既存の home-manager リンク（~/.config/opencode/plugins/mobile-notify.js）と
// プラグイン id との互換のために、無効化した入口として残す。
export default {
  id: "ubuntu-dotfiles.mobile-notify",
  setup() {},
};
