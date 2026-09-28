.DEFAULT_GOAL := help
export DRY_RUN HOST STACK
.PHONY: help apply-stack build-caddy check-editor confirm-ssh configure-services configure-ssh install-dotfiles install-packages install-tools login-vpn lock-images pull-stack rollback-ssh setup-host show-logs show-status update-system verify-images

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
	  '  update-system       Update Ubuntu packages' \
	  '' \
	  'Caddy:' \
	  '  build-caddy         Build Caddy with the Cloudflare plugin' \
	  '  lock-images         Save pinned Caddy image digests' \
	  '  verify-images       Check the saved container image digests' \
	  '' \
	  'Services:' \
	  '  configure-services  Apply the saved Caddy and VPN choices' \
	  '  apply-stack         Apply STACK=caddy or tailscale on this host' \
	  '  login-vpn           Log in to Tailscale or show the WireGuard profile' \
	  '  pull-stack          Pull STACK=tailscale or rebuild Caddy' \
	  '  show-logs           Follow logs for STACK=caddy or tailscale'

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

build-caddy:
	@bash scripts/build-caddy.sh

lock-images:
	@bash scripts/lock-images.sh lock

verify-images:
	@bash scripts/lock-images.sh verify

configure-services:
	@bash scripts/run-root.sh scripts/configure-services.sh configure $(if $(caddy),--caddy=$(caddy)) $(if $(vpn),--vpn=$(vpn))

apply-stack:
	@bash scripts/apply-stack.sh

login-vpn:
	@bash scripts/configure-services.sh vpn-login

pull-stack:
	@bash scripts/configure-services.sh pull "$$STACK"

show-logs:
	@bash scripts/configure-services.sh logs "$$STACK"
