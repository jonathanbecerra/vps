#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
preview_if_requested install-dotfiles "$@"
reload_shell=no
while (($#)); do
  case $1 in --reload-shell) reload_shell=yes ;; *) die 'Usage: install-dotfiles.sh [--reload-shell]' ;; esac
  shift
done
[[ $EUID != 0 ]] || die 'Run make install-dotfiles as your admin user, without sudo.'
[[ $(uname -s) == Linux ]] || die 'This installs dotfiles on the Linux host.'
clear_screen
export VPS_NO_CLEAR=1

install_config() {
  local data_dir relative repository commit destination
  data_dir=${XDG_DATA_HOME:-$HOME/.local/share}
  install -d -m 0700 "$HOME/.config" "$HOME/.local/state/vps-backups"
  while IFS=$'\t' read -r relative repository commit; do
    [[ -z $relative || $relative == \#* ]] && continue
    destination="$data_dir/$relative"
    if [[ -d $destination/.git && $(git -C "$destination" rev-parse HEAD) == "$commit" ]]; then
      continue
    fi
    [[ ! -e $destination || -d $destination/.git ]] || die "Not a git checkout: $destination"
    if [[ ! -d $destination/.git ]]; then
      progress "Clone $relative" git clone -q --filter=blob:none "$repository" "$destination"
    fi
    progress "Fetch $relative" git -C "$destination" fetch -q --depth 1 "$repository" "$commit"
    git -C "$destination" checkout -q --detach FETCH_HEAD
  done <"$ROOT/config/zsh/plugins.tsv"

  link_config() {
    local source=$1 destination=$2
    [[ -L $destination && $(readlink "$destination") == "$source" ]] && return 0
    if [[ -e $destination || -L $destination ]]; then
      mv "$destination" "$HOME/.local/state/vps-backups/$(basename "$destination")-$(date +%Y%m%d-%H%M%S)-$$"
    fi
    ln -s "$source" "$destination"
  }
  link_config "$ROOT/config/zsh/zshrc" "$HOME/.zshrc"
  link_config "$ROOT/config/zsh/p10k.zsh" "$HOME/.p10k.zsh"
  link_config "$ROOT/config/nvim" "$HOME/.config/nvim"
  link_config "$ROOT/config/tmux/tmux.conf" "$HOME/.tmux.conf"
  rm -f "$HOME/.bash_history" "$HOME/.bash_logout" "$HOME/.bashrc"
  # Deja generates a file that zsh sources on startup.
  deja init zsh >/dev/null
  progress 'Restore Neovim plugins' nvim --headless '+Lazy! restore' +qa
}

progress 'Install shell and editor config' install_config
printf '  %s✓%s Pinned zsh plugins and shell integration\n' "$C_GREEN" "$C_RESET"
printf '  %s✓%s Zsh, Neovim, and tmux config\n' "$C_GREEN" "$C_RESET"
printf '  %s✓%s Neovim plugins\n' "$C_GREEN" "$C_RESET"
printf '\nStarting zsh. Reload tmux with tmux source-file ~/.tmux.conf.\n'
[[ $reload_shell != yes ]] || exec zsh
