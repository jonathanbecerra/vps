# Dotfiles

From the VPS repository root, use `make stow-dotfiles`; `DRY_RUN=1 make stow-dotfiles` previews links. The packages here use Rosé Pine, including Glow and the `mat` shortcut, with Iris directories in eza and a local Powerlevel10k prompt.

Neovim uses lazy.nvim as its plugin manager, with a mini.starter start screen; it is a small custom config, not the LazyVim distribution.

Homebrew tools live in `brew/Brewfile`; NVM and Neovim manifests and pinned plugins live in `dependencies/`. From the VPS repository root, run `brew bundle --file=dotfiles/brew/Brewfile`; from a standalone dotfiles checkout, run `brew bundle --file=brew/Brewfile`. Then run `nvm install`; NVM reads pnpm from `dependencies/nvm/default-packages`. Set Git identity and signing locally with `git config --global`.
