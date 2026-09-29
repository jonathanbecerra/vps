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
  local data_dir node_version tools_dir locksum locksum_file pnpm_spec pnpm_version pnpm_path
  data_dir=${XDG_DATA_HOME:-$HOME/.local/share}
  install -d -m 0700 "$HOME/.config" "$HOME/.local/state/vps-backups"
  fetch_dotfile_plugins

  export NVM_DIR="$data_dir/nvm"
  install -d -m 0700 "$NVM_DIR"
  progress 'Set pinned NVM default packages' install -m 0644 "$ROOT/dotfiles/dependencies/nvm/default-packages" "$NVM_DIR/default-packages"
  # .nvmrc is not installed yet. Skip nvm's source-time auto-use until Node is installed.
  source "$NVM_DIR/nvm.sh" --no-use || die "Could not load nvm from $NVM_DIR."
  node_version=$(<"$ROOT/.nvmrc")
  [[ $node_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Invalid Node version in .nvmrc.'
  progress "Install Node.js $node_version with nvm" nvm install "$node_version" --skip-default-packages
  progress "Set Node.js $node_version as the nvm default" nvm alias default "$node_version"
  progress "Select Node.js $node_version" nvm use --silent "$node_version"
  pnpm_spec=$(<"$ROOT/dotfiles/dependencies/nvm/default-packages")
  [[ $pnpm_spec =~ ^pnpm@[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Invalid pinned NVM default package.'
  pnpm_version=${pnpm_spec#pnpm@}
  pnpm_path=$(command -v pnpm || true)
  if [[ $pnpm_path != "$NVM_DIR/versions/node/v$node_version/bin/pnpm" ]] ||
    [[ $(pnpm --version 2>/dev/null || true) != "$pnpm_version" ]]; then
    progress "Install pnpm $pnpm_version with nvm-managed Node.js" npm install --global "$pnpm_spec"
  fi

  tools_dir="$data_dir/nvim/tools"
  install -d -m 0700 "$tools_dir"
  install -m 0644 "$ROOT/dotfiles/dependencies/nvim/package.json" "$tools_dir/package.json"
  install -m 0644 "$ROOT/dotfiles/dependencies/nvim/package-lock.json" "$tools_dir/package-lock.json"
  locksum=$(sha256sum "$tools_dir/package.json" "$tools_dir/package-lock.json" | sha256sum)
  locksum=${locksum%% *}
  locksum_file="$tools_dir/package-lock.sha256"
  if [[ ! -f $locksum_file || $(<"$locksum_file") != "$locksum" ||
  ! -x $tools_dir/node_modules/.bin/bash-language-server ||
  ! -x $tools_dir/node_modules/.bin/yaml-language-server ||
  ! -x $tools_dir/node_modules/.bin/vscode-json-language-server ||
  ! -x $tools_dir/node_modules/.bin/stylua ]]; then
    progress 'Install Neovim language servers and formatter' npm --prefix "$tools_dir" ci --no-audit --no-fund
    printf '%s\n' "$locksum" >"$locksum_file"
  fi

  link_config() {
    local source=$1 destination=$2
    [[ -L $destination && $(readlink "$destination") == "$source" ]] && return 0
    if [[ -e $destination || -L $destination ]]; then
      mv "$destination" "$HOME/.local/state/vps-backups/$(basename "$destination")-$(date +%Y%m%d-%H%M%S)-$$"
    fi
    ln -s "$source" "$destination"
  }
  link_config "$ROOT/dotfiles/zsh/.zshenv" "$HOME/.zshenv"
  link_config "$ROOT/dotfiles/zsh/.p10k.zsh" "$HOME/.p10k.zsh"
  link_config "$ROOT/dotfiles/zsh/.config/zsh" "$HOME/.config/zsh"
  link_config "$ROOT/dotfiles/nvim/.config/nvim" "$HOME/.config/nvim"
  link_config "$ROOT/dotfiles/tmux/.config/tmux" "$HOME/.config/tmux"
  link_config "$ROOT/dotfiles/tmux/.tmux.conf" "$HOME/.tmux.conf"
  link_config "$ROOT/dotfiles/git/.config/git" "$HOME/.config/git"
  link_config "$ROOT/dotfiles/eza/.config/eza" "$HOME/.config/eza"
  link_config "$ROOT/dotfiles/glow/.config/glow" "$HOME/.config/glow"
  link_config "$ROOT/dotfiles/lazydocker/.config/lazydocker" "$HOME/.config/lazydocker"
  link_config "$ROOT/dotfiles/lazygit/.config/lazygit" "$HOME/.config/lazygit"
  link_config "$ROOT/dotfiles/ripgrep/.config/ripgrep" "$HOME/.config/ripgrep"
  link_config "$ROOT/dotfiles/bat/.config/bat" "$HOME/.config/bat"
  if command -v bat >/dev/null; then
    progress 'Build Rosé Pine bat theme cache' bat cache --build
  elif command -v batcat >/dev/null; then
    progress 'Build Rosé Pine bat theme cache' batcat cache --build
  fi
  # Deja generates a file that zsh sources on startup.
  deja init zsh >/dev/null
  progress 'Restore Neovim plugins' nvim --headless '+Lazy! restore' +qa
}

progress 'Install shell and editor config' install_config
printf '  %s✓%s Pinned shell tools and plugins\n' "$C_GREEN" "$C_RESET"
printf '  %s✓%s Stow-compatible shell, editor, terminal, and Git config\n' "$C_GREEN" "$C_RESET"
printf '  %s✓%s Node.js %s and Neovim language tools\n' "$C_GREEN" "$C_RESET" "$(<"$ROOT/.nvmrc")"
printf '  %s✓%s Neovim plugins and schemas\n' "$C_GREEN" "$C_RESET"
printf '\nStarting zsh. Reload tmux with tmux source-file ~/.tmux.conf.\n'
[[ $reload_shell != yes ]] || exec zsh
