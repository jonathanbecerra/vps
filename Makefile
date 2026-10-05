.DEFAULT_GOAL := help
export DRY_RUN HOST STACK
DOTFILES_DIR ?= $(CURDIR)/dotfiles
export DOTFILES_DIR
.PHONY: help setup
.PHONY: check-editor check-repo show-status
.PHONY: install-dotfiles reload-zsh stow-dotfiles install-packages setup-host update-system
.PHONY: refresh-dotfiles restore-dotfiles
.PHONY: confirm-ssh configure-ssh rollback-ssh
.PHONY: build-caddy configure-vpn vpn-login lock-tailscale verify-tailscale deploy-tailscale deploy-key
.PHONY: deploy-stack preview-deploy sync-repo
.PHONY: attach-vm create-vm list-vm start-vm stop-vm teardown-vm

help:
	@printf '%s\n' \
	  'First boot:' \
	  '  setup               Guided basic or advanced Ubuntu setup' \
	  '  ./install.sh --help' \
	  '  DRY_RUN=1 make <command> previews a command without changing the host' \
	  '' \
	  'SSH setup:' \
	  '  confirm-ssh         Confirm from a fresh SSH connection' \
	  '  configure-ssh       Require key-only SSH; starts a five-minute rollback' \
	  '  rollback-ssh        Restore a pending SSH change' \
	  '' \
	  'Host tools:' \
	  '  check-editor        Load pinned Neovim plugins in a temporary directory' \
	  '  check-repo          Check scripts and configuration' \
	  '  install-dotfiles    Install or update the user environment on Linux or macOS' \
	  '  reload-zsh          Start a fresh login shell after dotfiles changes' \
	  '  stow-dotfiles       Link portable dotfiles packages with scripts/stow.sh' \
	  '  refresh-dotfiles    Preview a config reset; action=apply backs up the listed paths' \
	  '  restore-dotfiles    Restore a dotfiles backup (backup=/path)' \
	  '  install-packages    Install Ubuntu host packages from config/apt/packages.txt' \
	  '  setup-host          Synchronize time, install the host, selected Caddy role, and show status' \
	  '  show-status         Show SSH, firewall, services, ports, and disks' \
	  '  update-system       Update Ubuntu packages' \
	  '' \
	  'Caddy:' \
	  '  build-caddy         Rebuild the native Caddy binary with Cloudflare DNS' \
	  '' \
	  'VPN:' \
	  '  configure-vpn       Save and apply the Tailscale or WireGuard choice' \
	  '  vpn-login           Log in to Tailscale or show the WireGuard profile' \
	  '' \
	  'Tailscale stack:' \
	  '  deploy-tailscale    Apply the pinned Tailscale stack locally or to HOST' \
	  '  lock-tailscale      Update the Tailscale image lock' \
	  '  verify-tailscale    Check the Tailscale image lock' \
	  '' \
	  'Deployment:' \
	  '  deploy-key          Create a deploy key for REPO=example' \
	  '  deploy-stack        Check, preview, sync, and apply Tailscale (HOST=...)' \
	  '  preview-deploy      Show rsync differences (HOST=...)' \
	  '  sync-repo           Copy the repo with rsync (HOST=...)' \
	  '' \
	  'Local VMs:' \
	  '  create-vm           Create Ubuntu: make create-vm name=lab vcpu=8 memory=16 storage=64' \
	  '  list-vm             Show local VM instances' \
	  '  start-vm            Start and attach (display=gui or display=console)' \
	  '  attach-vm           Attach to the serial console' \
	  '  stop-vm             Shut down the selected VM' \
	  '  teardown-vm         Delete the selected VM and its disk'

setup:
	@sh ./install.sh $(if $(mode),--mode $(mode))

setup-host:
	@bash scripts/root.sh scripts/os/sync-time.sh
	@$(MAKE) --no-print-directory install-packages
	@bash scripts/root.sh scripts/caddy/setup.sh
	@VPS_NO_CLEAR=1 $(MAKE) --no-print-directory show-status

install-dotfiles:
	@bash scripts/os/install-dotfiles.sh --reload-shell

reload-zsh:
	@printf '\033[<u\033[=0;1u'
	@exec env -u ZDOTDIR zsh -l

stow-dotfiles:
	@bash scripts/stow.sh

refresh-dotfiles:
	@bash scripts/refresh-dotfiles.sh $(or $(action),plan) $(if $(paths),--extra-paths "$(paths)")

restore-dotfiles:
	@bash scripts/refresh-dotfiles.sh restore "$(backup)"

check-editor:
	@bash scripts/os/check-editor.sh

check-repo:
	@bash scripts/check.sh

# Confirm from a fresh key login before the rollback timer expires.
configure-ssh:
	@bash scripts/root.sh scripts/ssh/configure-ssh.sh harden

confirm-ssh:
	@bash scripts/root.sh scripts/ssh/configure-ssh.sh confirm

rollback-ssh:
	@bash scripts/root.sh scripts/ssh/rollback-ssh.sh

show-status:
	@bash scripts/root.sh scripts/os/show-status.sh

update-system:
	@bash scripts/root.sh scripts/os/update-system.sh

install-packages:
	@bash scripts/root.sh scripts/os/install-packages.sh

build-caddy:
	@bash scripts/root.sh scripts/caddy/build.sh

lock-tailscale:
	@bash scripts/vpn/lock-tailscale.sh lock
	@bash scripts/vpn/lock-tailscale.sh verify

verify-tailscale:
	@bash scripts/vpn/lock-tailscale.sh verify

configure-vpn:
	@bash scripts/root.sh scripts/vpn/configure.sh configure $(if $(vpn),--vpn=$(vpn))

deploy-tailscale:
	@STACK=tailscale bash scripts/vpn/deploy-tailscale.sh

vpn-login:
	@bash scripts/vpn/configure.sh vpn-login

deploy-key:
	@REPO='$(REPO)' DEPLOY_KEY_DIR='$(DEPLOY_KEY_DIR)' bash scripts/deploy/deploy-key.sh

deploy-stack:
	@STACK=tailscale bash scripts/deploy/deploy-stack.sh

preview-deploy:
	@bash scripts/deploy/sync-repo.sh plan

sync-repo:
	@bash scripts/deploy/sync-repo.sh sync

create-vm: export VM_PASSWORD = $(password)
create-vm: export VM_PASSWORD_SET = $(if $(filter undefined,$(origin password)),no,yes)
create-vm:
	@bash scripts/vm/create-vm.sh $(if $(name),--name="$(name)") $(if $(image),--image="$(image)") $(if $(vcpu),--vcpu="$(vcpu)") $(if $(memory),--memory="$(memory)") $(if $(storage),--storage="$(storage)")

list-vm:
	@bash scripts/vm/list-vm.sh

attach-vm:
	@bash scripts/vm/attach-vm.sh $(if $(name),--name="$(name)")

start-vm:
	@bash scripts/vm/start-vm.sh $(if $(name),--name="$(name)") $(if $(display),--display="$(display)")

stop-vm:
	@bash scripts/vm/stop-vm.sh $(if $(name),--name="$(name)")

teardown-vm:
	@bash scripts/vm/teardown-vm.sh $(if $(name),--name="$(name)") $(if $(yes),--yes)
