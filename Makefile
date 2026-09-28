.DEFAULT_GOAL := help
export DRY_RUN
.PHONY: help check-editor install-dotfiles install-packages install-tools setup-host

help:
	@printf '%s\n' \
	  'First boot:' \
	  '  Run ./setup-vps.sh as root on the Ubuntu box' \
	  '  ./setup-vps.sh --help' \
	  '' \
	  'Host tools:' \
	  '  setup-host          Install tools, link configs, and enter zsh' \
	  '  install-dotfiles    Link configs and enter zsh' \
	  '  check-editor        Load pinned Neovim plugins in a temporary directory' \
	  '  install-packages    Install Ubuntu packages from config/apt/packages.txt' \
	  '  install-tools       Install pinned tools from config/apt/binaries.tsv'

setup-host:
	@$(MAKE) --no-print-directory install-tools
	@$(MAKE) --no-print-directory install-dotfiles

install-dotfiles:
	@bash scripts/install-dotfiles.sh --reload-shell

check-editor:
	@bash scripts/check-editor.sh

install-packages:
	@bash scripts/run-root.sh scripts/install-packages.sh

install-tools:
	@bash scripts/run-root.sh scripts/install-tools.sh
