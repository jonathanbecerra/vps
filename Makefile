.DEFAULT_GOAL := help
export DRY_RUN HOST STACK
.PHONY: help
.PHONY: check-editor check-repo show-status
.PHONY: install-dotfiles install-packages install-tools setup-host update-system
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
	  '  check-repo          Check scripts and configuration' \
	  '  install-packages    Install Ubuntu packages from config/apt/packages.txt' \
	  '  install-tools       Install pinned tools from config/apt/binaries.tsv' \
	  '  show-status         Show SSH, firewall, services, ports, and disks' \
	  '  update-system       Update Ubuntu packages' \
	  '' \
	  'Caddy:' \
	  '  build-caddy         Build Caddy with the Cloudflare plugin' \
	  '  configure-caddy     Configure Caddy and its site routes' \
	  '  lock-images         Lock images from all included Compose files' \
	  '  verify-images       Check the combined image lock' \
	  '' \
	  'Services:' \
	  '  apply-stack         Apply STACK=caddy or tailscale on this host' \
	  '  configure-services  Configure saved Caddy and VPN choices in order' \
	  '  configure-tailscale Configure only Tailscale' \
	  '  configure-wireguard Configure only WireGuard' \
	  '  login-vpn           Log in to Tailscale or show the WireGuard profile' \
	  '  pull-stack          Pull STACK=tailscale or rebuild Caddy' \
	  '  show-logs           Follow logs for STACK=caddy or tailscale' \
	  '  show-containers     List containers in the combined Compose project' \
	  '  up                  Start configured services and build local images' \
	  '  down                Stop all services in the Compose project' \
	  '  restart             Restart configured services' \
	  '  recreate            Rebuild and recreate configured services' \
	  '' \
	  'Deployment:' \
	  '  deploy-stack        Check, preview, sync, and apply (HOST=... STACK=...)' \
	  '  preview-deploy      Show rsync differences (HOST=...)' \
	  '  sync-repo           Copy the repo with rsync (HOST=...)' \
	  '' \
	  'Local VMs:' \
	  '  create-vm           Create Ubuntu: make create-vm name=lab vcpu=8 memory=16 storage=64' \
	  '  list-vm             Show local VM instances' \
	  '  start-vm            Start and attach; display=gui opens a QEMU window' \
	  '  attach-vm           Attach to the serial console, with no GUI' \
	  '  stop-vm             Shut down the selected VM' \
	  '  teardown-vm         Delete the selected VM and its disk'

setup-host:
	@$(MAKE) --no-print-directory install-tools
	@VPS_NO_CLEAR=1 $(MAKE) --no-print-directory show-status
	@VPS_NO_CLEAR=1 $(MAKE) --no-print-directory install-dotfiles

install-dotfiles:
	@bash scripts/install-dotfiles.sh --reload-shell

check-editor:
	@bash scripts/check-editor.sh

check-repo:
	@bash scripts/check-repo.sh

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
	@bash scripts/lock-images.sh verify

verify-images:
	@bash scripts/lock-images.sh verify

up:
	@bash scripts/manage-compose.sh up

down:
	@bash scripts/manage-compose.sh down

restart:
	@bash scripts/manage-compose.sh restart

recreate:
	@bash scripts/manage-compose.sh recreate

show-containers:
	@bash scripts/manage-compose.sh ps

configure-caddy:
	@bash scripts/run-root.sh scripts/configure-services.sh configure --enable-caddy --caddy-only --reconfigure-caddy

configure-services:
	@bash scripts/run-root.sh scripts/configure-services.sh configure $(if $(vpn),--vpn=$(vpn))

configure-tailscale:
	@bash scripts/run-root.sh scripts/configure-services.sh configure --vpn=tailscale --vpn-only

configure-wireguard:
	@bash scripts/run-root.sh scripts/configure-services.sh configure --vpn=wireguard --vpn-only

apply-stack:
	@bash scripts/apply-stack.sh

login-vpn:
	@bash scripts/configure-services.sh vpn-login

pull-stack:
	@bash scripts/configure-services.sh pull "$$STACK"

show-logs:
	@bash scripts/configure-services.sh logs "$$STACK"

deploy-stack:
	@bash scripts/deploy-stack.sh

preview-deploy:
	@bash scripts/sync-repo.sh plan

sync-repo:
	@bash scripts/sync-repo.sh sync

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
