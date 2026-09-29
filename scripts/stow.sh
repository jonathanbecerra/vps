#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
preview_if_requested stow-dotfiles "$@"

[[ $EUID != 0 ]] || die 'Run stow.sh as your user, without sudo.'
command -v stow >/dev/null || die 'Install GNU Stow to link dotfiles.'

packages=(bat eza git glow kitty lazydocker lazygit nvim ripgrep tmux zsh)
if (($#)); then packages=("$@"); fi
for package in "${packages[@]}"; do
  [[ -d $ROOT/dotfiles/$package ]] || die "Unknown dotfiles package: $package"
done

progress 'Link dotfiles with GNU Stow' stow --dir="$ROOT/dotfiles" --target="$HOME" "${packages[@]}"
skip_nvm=no
[[ $(uname -s) != Darwin ]] || skip_nvm=yes
NVM_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nvm"
progress 'Create NVM data directory' install -d -m 0700 "$NVM_DIR"
progress 'Set pinned NVM default packages' install -m 0644 "$ROOT/dotfiles/dependencies/nvm/default-packages" "$NVM_DIR/default-packages"
fetch_dotfile_plugins "$skip_nvm"
if command -v bat >/dev/null; then
  progress 'Build Rosé Pine bat theme cache' bat cache --build
elif command -v batcat >/dev/null; then
  progress 'Build Rosé Pine bat theme cache' batcat cache --build
fi
