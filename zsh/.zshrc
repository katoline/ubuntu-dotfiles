# SSH（iPhone）では tmux に入る。切断しても claude / codex などが残る。
# ローカルGNOME・VSCode統合端末では起動しない。回避は NOTMUX=1。
# p10k instant prompt より前（exec するので出力はしない）
if [[ -o interactive && -t 1 && -z "${TMUX:-}" && -n "${SSH_CONNECTION:-}" && -z "${NOTMUX:-}" && -z "${TERM_PROGRAM:-}" ]] && command -v tmux >/dev/null 2>&1; then
  if tmux has-session 2>/dev/null; then
    exec tmux attach
  else
    exec tmux new-session -s main
  fi
fi

# Powerlevel10k instant prompt（zshrc内で最も早い段階に置くこと）
# ここより前にコンソール出力するコードを置かないこと（キャッシュ・チェックサム系コマンド以外）
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# claude / codex は ~/.local/bin。GUIログインは ~/.profile が通すが、
# zsh の SSH ログインは .profile を読まないのでここで足す（重複は避ける）
if [[ -d "$HOME/.local/bin" && ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  export PATH="$HOME/.local/bin:$PATH"
fi

# Oh My Zsh 本体（bootstrap.shが ~/.oh-my-zsh へ導入する。あえてNix管理外）
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"
plugins=(git)

# 未導入環境でも壊れないようにガードする
[[ -d $ZSH ]] && source "$ZSH/oh-my-zsh.sh"

# Oh My Zshが LESS=-R を設定してしまい、`git branch` 等の短い出力でも
# 全画面のページャーが開いて終了時に消える挙動になるため上書きする。
# -F: 1画面に収まる出力はページャーを開かずそのまま表示
# -R: 色エスケープをそのまま通す
# -X: ページャー終了時に画面を復元しない（出力が残る）
export LESS='-FRX'

# Powerlevel10kの設定（zsh/.p10k.zsh をリポジトリで管理。macOS風の最小構成）
[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh

# direnv: .envrc のあるディレクトリで devShell を自動ON/OFF（nix/home.nix で導入）
if command -v direnv >/dev/null 2>&1; then
  eval "$(direnv hook zsh)"
fi

# opencode
export PATH="$HOME/.opencode/bin:$PATH"
