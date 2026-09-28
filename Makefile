.DEFAULT_GOAL := help
export DRY_RUN
.PHONY: help check-editor confirm-ssh configure-ssh install-dotfiles install-packages install-tools rollback-ssh setup-host show-status update-system

help:
	@printf '%s\n' \
	  'First boot:' \
	  '  Run ./setup-vps.sh as root on the Ubuntu box' \
	  '  ./setup-vps.sh --help' \
	  '' \
	  'SSH setup:' \
	  '  configure-ssh       Require key-only SSH; rollback starts in five minutes' \
	  '  confirm-ssh         Confirm from a fresh SSH connection' \
	  '  rollback-ssh        Restore a pending SSH change' \
	  '' \
	  'Host tools:' \
	  '  setup-host          Install tools, link configs, and enter zsh' \
	  '  install-dotfiles    Link configs and enter zsh' \
	  '  check-editor        Load pinned Neovim plugins in a temporary directory' \
	  '  install-packages    Install Ubuntu packages from config/apt/packages.txt' \
	  '  install-tools       Install pinned tools from config/apt/binaries.tsv' \
	  '  show-status         Show SSH, firewall, services, ports, and disks' \
	  '  update-system       Update Ubuntu packages'

setup-host:
	@$(MAKE) --no-print-directory install-tools
	@VPS_NO_CLEAR=1 $(MAKE) --no-print-directory show-status
	@VPS_NO_CLEAR=1 $(MAKE) --no-print-directory install-dotfiles

install-dotfiles:
	@bash scripts/install-dotfiles.sh --reload-shell

check-editor:
	@bash scripts/check-editor.sh

# Confirm from a fresh key login before the rollback timer expires.
configure-ssh:
	@bash scripts/run-root.sh scripts/configure-ssh.sh harden

confirm-ssh:
	@bash scripts/run-root.sh scripts/configure-ssh.sh confirm

rollback-ssh:
	@bash scripts/run-root.sh scripts/rollback-ssh.sh

show-status:
	@bash scripts/run-root.sh scripts/show-status.sh

update-system:
	@bash scripts/run-root.sh scripts/update-system.sh

install-packages:
	@bash scripts/run-root.sh scripts/install-packages.sh

install-tools:
	@bash scripts/run-root.sh scripts/install-tools.sh
