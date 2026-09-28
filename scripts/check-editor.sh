#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
preview_if_requested check-editor "$@"
begin 'Check Neovim config'
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
export XDG_CONFIG_HOME="$temporary/config" XDG_DATA_HOME="$temporary/data"
export XDG_STATE_HOME="$temporary/state" XDG_CACHE_HOME="$temporary/cache"
mkdir -p "$XDG_CONFIG_HOME/nvim" "$XDG_DATA_HOME/nvim/lazy"
cp "$ROOT/config/nvim/lazy-lock.json" "$XDG_CONFIG_HOME/nvim/lazy-lock.json"
read -r repository commit < <(awk -F '\t' '$1 == "nvim/lazy/lazy.nvim" { print $2, $3 }' "$ROOT/config/zsh/plugins.tsv")
progress 'Clone lazy.nvim' git clone -q --filter=blob:none "$repository" "$XDG_DATA_HOME/nvim/lazy/lazy.nvim"
progress 'Fetch pinned lazy.nvim commit' git -C "$XDG_DATA_HOME/nvim/lazy/lazy.nvim" fetch -q --depth 1 "$repository" "$commit"
git -C "$XDG_DATA_HOME/nvim/lazy/lazy.nvim" checkout -q --detach FETCH_HEAD
case "$(uname -s)" in
  Linux) architecture=$(uname -m) ;;
  Darwin) architecture="macos-$(uname -m)" ;;
  *)
    printf 'Editor checks support Linux and macOS.\n' >&2
    exit 1
    ;;
esac
# Use the pinned build without replacing the installed editor.
read -r url checksum member < <(awk -F '\t' -v arch="$architecture" '$1 == "nvim" && $2 == arch {print $3, $4, $5}' "$ROOT/config/apt/binaries.tsv")
progress 'Download pinned Neovim' curl -fsSL --retry 3 "$url" -o "$temporary/nvim.tar.gz"
if [[ $(uname -s) == Linux ]]; then
  printf '%s  %s\n' "$checksum" "$temporary/nvim.tar.gz" | sha256sum -c >/dev/null
else
  printf '%s  %s\n' "$checksum" "$temporary/nvim.tar.gz" | shasum -a 256 -c >/dev/null
fi
tar -xzf "$temporary/nvim.tar.gz" -C "$temporary"
export PATH="$temporary/$member/bin:$PATH"
progress 'Restore Neovim plugins' nvim --headless -u "$ROOT/config/nvim/init.lua" '+Lazy! restore' +qa
progress 'Check Lualine config' nvim --headless -u "$ROOT/config/nvim/init.lua" '+lua vim.wait(2500)' \
  '+lua assert(vim.fn.exists(":LualineNotices") == 0, "lualine reported configuration notices")' +qa
