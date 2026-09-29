.DEFAULT_GOAL := help
export DRY_RUN HOST STACK
.PHONY: help
.PHONY: check-editor check-repo show-status
.PHONY: install-dotfiles stow-dotfiles install-packages install-tools setup-host update-system
.PHONY: confirm-ssh configure-ssh rollback-ssh
.PHONY: apply-stack build-caddy configure-caddy configure-services configure-tailscale configure-wireguard login-vpn pull-stack show-logs verify-images
.PHONY: down lock-images recreate restart show-containers up
.PHONY: deploy-stack preview-deploy sync-repo
.PHONY: attach-vm create-vm list-vm start-vm stop-vm teardown-vm

help:
	@printf '%s\n' \
	  'First boot:' \
	  '  Run ./setup-vps.sh as root on the Ubuntu box' \
	  '  ./setup-vps.sh --help' \
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
	  '  install-dotfiles    Link configs and enter zsh' \
	  '  stow-dotfiles       Link portable dotfiles packages with scripts/stow.sh' \
	  '  install-packages    Install Ubuntu packages from config/apt/packages.txt' \
	  '  install-tools       Install pinned tools from config/apt/binaries.tsv' \
	  '  setup-host          Install tools, show status, link configs, and enter zsh' \
	  '  show-status         Show SSH, firewall, services, ports, and disks' \
	  '  update-system       Update Ubuntu packages' \
	  '' \
	  'Caddy:' \
	  '  build-caddy         Build Caddy with the Cloudflare plugin' \
	  '  configure-caddy     Configure Caddy and its site routes' \
	  '' \
	  'VPN:' \
	  '  configure-services  Apply saved Caddy and VPN settings in order' \
	  '  configure-tailscale Configure only Tailscale' \
	  '  configure-wireguard Configure only WireGuard' \
	  '  login-vpn           Log in to Tailscale or show the WireGuard profile' \
	  '' \
	  'Compose:' \
	  '  apply-stack         Apply STACK=caddy or tailscale on this host' \
	  '  down                Stop containers in the combined Compose project' \
	  '  lock-images         Update the lock for images in all included Compose files' \
	  '  pull-stack          Pull STACK=tailscale or rebuild Caddy' \
	  '  recreate            Rebuild and recreate configured services' \
	  '  restart             Restart configured services' \
	  '  show-containers     List containers in the combined Compose project' \
	  '  show-logs           Follow logs for STACK=caddy or tailscale' \
	  '  up                  Start configured services and build local images' \
	  '  verify-images       Check the combined image lock' \
	  '' \
	  'Deployment:' \
	  '  deploy-stack        Check, preview, sync, and apply (HOST=... STACK=...)' \
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

setup-host:
	@$(MAKE) --no-print-directory install-tools
	@VPS_NO_CLEAR=1 $(MAKE) --no-print-directory show-status
	@VPS_NO_CLEAR=1 $(MAKE) --no-print-directory install-dotfiles

install-dotfiles:
	@bash scripts/os/install-dotfiles.sh --reload-shell

stow-dotfiles:
	@bash scripts/stow.sh

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

install-tools:
	@bash scripts/root.sh scripts/os/install-tools.sh

build-caddy:
	@bash scripts/compose/build-caddy.sh

lock-images:
	@bash scripts/compose/lock-images.sh lock
	@bash scripts/compose/lock-images.sh verify

verify-images:
	@bash scripts/compose/lock-images.sh verify

up:
	@bash scripts/compose/manage-compose.sh up

down:
	@bash scripts/compose/manage-compose.sh down

restart:
	@bash scripts/compose/manage-compose.sh restart

recreate:
	@bash scripts/compose/manage-compose.sh recreate

show-containers:
	@bash scripts/compose/manage-compose.sh ps

configure-caddy:
	@bash scripts/root.sh scripts/compose/configure-services.sh configure --enable-caddy --caddy-only --reconfigure-caddy

configure-services:
	@bash scripts/root.sh scripts/compose/configure-services.sh configure $(if $(vpn),--vpn=$(vpn))

configure-tailscale:
	@bash scripts/root.sh scripts/compose/configure-services.sh configure --vpn=tailscale --vpn-only

configure-wireguard:
	@bash scripts/root.sh scripts/compose/configure-services.sh configure --vpn=wireguard --vpn-only

apply-stack:
	@bash scripts/compose/apply-stack.sh

login-vpn:
	@bash scripts/compose/configure-services.sh vpn-login

pull-stack:
	@bash scripts/compose/configure-services.sh pull "$$STACK"

show-logs:
	@bash scripts/compose/configure-services.sh logs "$$STACK"

deploy-stack:
	@bash scripts/deploy/deploy-stack.sh

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
