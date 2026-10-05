#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
export DRY_RUN=1
command=${1:?Choose a command to preview}
shift

ARCH=${ARCH:-$(uname -m)}
[[ $ARCH != arm64 ]] || ARCH=aarch64
SERVER_HOSTNAME='vps-preview'
ADMIN_USER='admin'
CADDY_MODE='none'
VPN='none'
SECURITY_UPDATES='yes'
if [[ -z ${HOST:-} && -r $VPS_HOST_CONFIG ]]; then load_config "$VPS_HOST_CONFIG"; fi
key_file='<public-key-file>'
mode=basic
if [[ $command == setup-vps ]]; then
  while (($#)); do
    (($# >= 2)) || die "Missing value for $1"
    case "$1" in
      --config) [[ -z $2 ]] || load_config "$2" ;;
      --key) [[ -z $2 ]] || key_file=$2 ;;
      --mode) mode=$2 ;;
      *) die "Unknown option: $1" ;;
    esac
    shift 2
  done
fi
validate_config
printf '\nDry run: %s (Ubuntu, %s)\n' "$command" "$ARCH"
printf 'Planned steps only. Prompts and host checks run when DRY_RUN=0.\n'

copy_config() { printf '  %s -> %s\n' "$ROOT/config/$1" "$2"; }

preview_docker() {
  note 'Remove installed conflicting Docker packages; keep /var/lib/docker.'
  run apt-get remove -y '<installed-conflicts>'
  run curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o '<temporary-key>'
  run gpg --batch --show-keys --with-colons '<temporary-key>'
  note 'Install only if the primary fingerprint matches config/docker/docker-key-fingerprint.txt.'
  run install -m 0644 '<temporary-key>' /etc/apt/keyrings/docker.asc
  copy_config docker/docker.sources /etc/apt/sources.list.d/docker.sources
  apt_update
  install_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  note 'Merge Docker defaults, validate them, and restart Docker if changed.'
  copy_config docker/daemon.json /etc/docker/daemon.json
  run dockerd --validate --config-file '<merged-config>'
  run systemctl enable --now docker
  run usermod -aG docker "$ADMIN_USER"
  run docker info
  run docker compose version
}

preview_security() {
  note 'Keep existing firewall rules and allow all detected SSH listeners first.'
  run ufw default deny incoming
  run ufw default allow outgoing
  run ufw default deny routed
  run ufw allow '<detected-ssh-port>/tcp'
  run ufw logging low
  run ufw --force enable
  run systemctl enable --now ufw
  copy_config fail2ban/sshd.local /etc/fail2ban/jail.d/90-vps-sshd.local
  run fail2ban-client -t
  run systemctl enable --now fail2ban
  run systemctl restart fail2ban
  copy_config sysctl/90-vps.conf /etc/sysctl.d/90-vps.conf
  run sysctl -p /etc/sysctl.d/90-vps.conf
  if [[ $SECURITY_UPDATES == yes ]]; then
    install_packages unattended-upgrades
    copy_config apt/20auto-upgrades /etc/apt/apt.conf.d/20auto-upgrades
    copy_config apt/52vps-unattended-upgrades /etc/apt/apt.conf.d/52vps-unattended-upgrades
    run systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
  else
    copy_config apt/20manual-upgrades /etc/apt/apt.conf.d/20auto-upgrades
  fi
}

preview_image_locks() {
  local operation=$1 lock="$ROOT/stacks/compose.lock.yaml"
  note "Use a temporary lock under $ROOT/.image-lock.XXXXXX and remove it when done."
  run docker compose --env-file "$ROOT/.env.example" -f "$ROOT/stacks/compose.yaml" \
    --profile tailscale \
    config --lock-image-digests --output '<temporary-directory>/compose.lock.yaml'
  if [[ $operation == lock ]]; then
    run docker compose --env-file "$ROOT/.env.example" -f "$ROOT/stacks/compose.yaml" \
      -f '<temporary-directory>/compose.lock.yaml' --profile tailscale config --quiet
    run chmod 0644 '<temporary-directory>/compose.lock.yaml'
    run mv '<temporary-directory>/compose.lock.yaml' "$lock"
  else
    run cmp -s "$lock" '<temporary-directory>/compose.lock.yaml'
    run diff -u "$lock" '<temporary-directory>/compose.lock.yaml'
    note 'Stop if the saved lock is missing or differs.'
    run docker compose --env-file "$ROOT/.env.example" -f "$ROOT/stacks/compose.yaml" \
      -f "$lock" --profile tailscale config --quiet
  fi
  run rm -rf '<temporary-directory>'
}

preview_caddy_build() {
  note 'Build the native Caddy binary with the Cloudflare DNS module through the pinned builder image.'
  run docker build --pull --target builder --tag vps-caddy-builder:2.11.4 "$ROOT/build/caddy"
  run docker create vps-caddy-builder:2.11.4
  run docker cp '<builder-container>:/usr/bin/caddy' '<temporary-directory>/caddy'
  run install -m 0755 '<temporary-directory>/caddy' /usr/local/bin/caddy
}

preview_legacy_compose() {
  local legacy_stack=$1
  note "If the old vps-$legacy_stack project exists, stop it before using the combined project."
  run docker compose --env-file /opt/vps/.env.example \
    --env-file "/opt/vps/.local/$legacy_stack.env" --project-name "vps-$legacy_stack" \
    -f "/opt/vps/stacks/$legacy_stack/compose.yaml" --profile "$legacy_stack" down
}

preview_stack() {
  case "$stack" in tailscale) ;; *) die 'Set STACK=tailscale.' ;; esac
  compose=(docker compose --env-file /opt/vps/.env.example
    --env-file /opt/vps/.local/tailscale.env
    -f /opt/vps/stacks/compose.yaml -f /opt/vps/stacks/compose.lock.yaml --profile "$stack")
  case "$action" in
    apply)
      preview_legacy_compose "$stack"
      run "${compose[@]}" config --quiet
      preview_image_locks verify
      run "${compose[@]}" up -d --no-build --wait --wait-timeout 90 "$stack"
      run "${compose[@]}" ps
      ;;
    vpn-login) run "${compose[@]}" exec tailscale tailscale up --accept-dns=false ;;
  esac
}

case "$command" in
  vm-create)
    note "Create $VM_NAME ($VM_IMAGE) with $VM_VCPU vCPU, ${VM_MEMORY} GiB RAM, and $VM_STORAGE storage."
    note "The disk and VM state live in $VM_DIR; the downloaded image stays in $DISTROS_DIR."
    if [[ ${VM_PASSWORD_SET:-no} == yes && -n ${VM_PASSWORD:-} ]]; then
      note 'Hash the supplied admin password and enable SSH password login.'
    else
      note 'Use password if the prompt is left blank. Hash it and enable SSH password login.'
    fi
    note "Write cloud-init from $ROOT/config/vm/seed.yaml. No SSH key is seeded."
    run mkdir -p "$VM_DIR"
    run hdiutil makehybrid -o "$SEED_ISO" "$SEED" -iso -joliet -default-volume-name cidata
    run cp /opt/homebrew/share/qemu/edk2-arm-vars.fd "$VARS"
    run qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$DISK" "$VM_STORAGE"
    note 'Save the image, CPU, memory, storage, and allocated SSH port in vm.conf.'
    ;;
  vm-start)
    note "Start existing VM $VM_NAME in the background; logs and pid go under $VM_DIR."
    if [[ $VM_DISPLAY == gui ]]; then
      display=(-display cocoa)
      devices=(-device virtio-gpu-pci -device virtio-keyboard-pci -device virtio-mouse-pci)
    else
      display=(-display none)
      devices=()
    fi
    qemu_args=(
      -machine 'virt,accel=hvf' -cpu host -smp "$VM_VCPU" -m "${VM_MEMORY}G"
      -drive "if=pflash,format=raw,readonly=on,file=/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
      -drive "if=pflash,format=raw,file=$VARS" -drive "if=none,file=$DISK,format=qcow2,id=disk"
      -device 'virtio-blk-pci,drive=disk' -drive "if=none,file=$SEED_ISO,format=raw,readonly=on,id=seed"
      -device 'virtio-blk-pci,drive=seed' -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$VM_PORT-:22"
      -device 'virtio-net-pci,netdev=net0' "${display[@]}" "${devices[@]}"
      -serial "unix:$SERIAL_SOCKET,server=on,wait=off"
      -monitor "unix:$MONITOR,server=on,wait=off"
    )
    if [[ $VM_DISPLAY == gui ]]; then
      note 'Open a QEMU Cocoa window. Ubuntu writes the server console to tty1.'
      run nohup qemu-system-aarch64 "${qemu_args[@]}" -pidfile "$PIDFILE"
      note "Redirect stdout and stderr to $VM_DIR/qemu.log."
    else
      run qemu-system-aarch64 "${qemu_args[@]}" -daemonize -pidfile "$PIDFILE" -D "$VM_DIR/qemu.log"
      note 'Attach to the serial console with direct key input. Ctrl-C disconnects without stopping the VM.'
      run nc -U "$SERIAL_SOCKET"
    fi
    ;;
  vm-attach)
    note "Attach to the running serial console for $VM_NAME with direct key input. Ctrl-C disconnects only."
    run nc -U "$SERIAL_SOCKET"
    ;;
  vm-stop)
    note "Ask $VM_NAME to shut down through its QEMU monitor."
    run nc -U "$MONITOR" '<system_powerdown>'
    ;;
  vm-teardown)
    note "Stop first if $VM_NAME is running. Remove this VM's state after confirmation."
    run rm -rf -- "$VM_DIR"
    ;;
  setup-vps)
    case $mode in basic | advanced) ;; *) die 'Choose basic or advanced.' ;; esac
    note "Setup mode: $mode."
    read_packages "$ROOT/config/apt/packages.txt"
    upgrade_os
    install_packages "${PACKAGES[@]}"
    if [[ $mode == advanced ]]; then
      note 'Ask for hostname and admin username, then set the password in the foreground.'
      run hostnamectl set-hostname "$SERVER_HOSTNAME"
      run useradd --create-home --shell /bin/bash "$ADMIN_USER"
      run passwd "$ADMIN_USER"
    else
      note 'Keep the current non-root account, hostname, password, and SSH authentication.'
    fi
    note 'Keep the project and any Git metadata at /opt/vps; preserve the source checkout.'
    copy_config sudo/admin /etc/sudoers.d/90-vps-admin
    preview_docker
    preview_security
    if [[ $mode == advanced ]]; then
      note "Wait for a valid key in the admin authorized_keys file. Optional source: $key_file."
      run systemd-run --unit=vps-rollback-ssh --on-active=5m --timer-property=AccuracySec=1s /usr/local/sbin/vps-rollback-ssh
      note 'Require a fresh key login and make confirm-ssh in the new session. Show a live countdown.'
      note 'Read the confirmation receipt for this attempt. Timeout restores SSH, then offers retry, continue without hardening, or stop.'
      note 'After confirmation, offer continue or stop. Continuing asks for Caddy and VPN choices.'
    else
      note 'Caddy and VPN stay off. No SSH handoff is performed.'
    fi
    run install -d -m 0755 /var/www/ohmstack.net/errors /var/app/hono.ohmstack.net
    note 'Apply the selected Caddy/VPN settings, then install dotfiles as the admin user and show status.'
    run sudo -H -u "$ADMIN_USER" bash /opt/vps/dotfiles/scripts/install.sh
    run usermod -s /bin/zsh "$ADMIN_USER"
    ;;
  install-docker) preview_docker ;;
  install-packages)
    read_packages "$ROOT/config/apt/packages.txt"
    note 'Install Ubuntu packages from config/apt/packages.txt.'
    apt_update
    install_packages "${PACKAGES[@]}"
    ;;
  install-wireguard)
    note 'Install WireGuard, make a server key and one client profile, and bring up wg0.'
    apt_update
    install_packages wireguard
    run wg genkey
    run wg pubkey
    copy_config wireguard/server.conf /etc/wireguard/wg0.conf
    copy_config wireguard/client.conf /opt/vps/.local/wireguard-client.conf
    run chmod 0600 /etc/wireguard/wg0.conf /opt/vps/.local/wireguard-client.conf
    run ufw allow 51820/udp comment WireGuard
    run ufw allow in on wg0 from 10.66.0.0/24 comment WireGuard-clients
    run systemctl enable --now wg-quick@wg0
    ;;
  build-caddy) preview_caddy_build ;;
  setup-caddy)
    case $CADDY_MODE in
      none)
        note 'Caddy is disabled; provision /var/www/ohmstack.net and /var/app/hono.ohmstack.net without enabling either site.'
        run install -d -m 0755 /var/www/ohmstack.net/errors /var/app/hono.ohmstack.net
        ;;
      public)
        note 'Install native Caddy with the Cloudflare DNS module for public ingress.'
        note 'Provision both examples, enable the ohmstack.net file-server site, and apply UFW rules for 80/443.'
        preview_caddy_build
        run install -d -m 0755 /etc/caddy /etc/caddy/sites-available /etc/caddy/sites-enabled
        run install -d -m 0755 /var/www/ohmstack.net/errors /var/app/hono.ohmstack.net
        run ufw allow 80/tcp comment 'Caddy HTTP'
        run ufw allow 443/tcp comment 'Caddy HTTPS'
        run ufw allow 443/udp comment 'Caddy HTTP3'
        run systemctl enable caddy
        run systemctl restart caddy
        ;;
      private)
        note 'Install native Caddy with the Cloudflare DNS module for private ingress.'
        note 'Provision both examples, enable hono.ohmstack.net, copy the Hono app to /var/app/hono.ohmstack.net, bind it to loopback:3000, and allow Caddy only on the private interface.'
        note 'Ask for a Cloudflare DNS token if /etc/caddy/caddy.env does not have one.'
        preview_caddy_build
        run install -d -m 0755 /etc/caddy /etc/caddy/sites-available /etc/caddy/sites-enabled /var/www/ohmstack.net/errors /var/app/hono.ohmstack.net
        run docker compose -f /var/app/hono.ohmstack.net/compose.yaml up -d --build
        run ufw allow in on '<private-interface>' to any port 80 proto tcp comment 'Caddy HTTP (private)'
        run ufw allow in on '<private-interface>' to any port 443 proto tcp comment 'Caddy HTTPS (private)'
        run systemctl enable caddy
        run systemctl restart caddy
        ;;
    esac
    ;;
  lock-tailscale) preview_image_locks lock ;;
  verify-tailscale) preview_image_locks verify ;;
  configure-security) preview_security ;;
  install-dotfiles) exec bash "${DOTFILES_DIR:-$ROOT/dotfiles}/scripts/install.sh" "$@" ;;
  stow-dotfiles) exec bash "${DOTFILES_DIR:-$ROOT/dotfiles}/scripts/stow.sh" "$@" ;;
  refresh-dotfiles) exec bash "${DOTFILES_DIR:-$ROOT/dotfiles}/scripts/refresh.sh" "$@" ;;
  deploy-key)
    [[ ${REPO:-} =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die 'Set REPO=example.'
    note 'Create one Ed25519 key at ~/.ssh/deploy-keys/<repo>/id_ed25519 and a matching github-* SSH alias.'
    note 'Add its public key to the GitHub repository as read-only, then clone through that alias.'
    ;;
  configure-ssh)
    case ${1:-harden} in
      harden)
        note "Require a key login as $ADMIN_USER. Back up SSH config and arm rollback before editing."
        run systemd-run --unit=vps-rollback-ssh --on-active=5m --timer-property=AccuracySec=1s /usr/local/sbin/vps-rollback-ssh
        copy_config ssh/sshd.conf /etc/ssh/vps-setup.conf
        note 'Put that include first in sshd_config. Check effective key-only policy for admin and root.'
        run /usr/sbin/sshd -t
        run systemctl reload '<ssh-or-sshd>'
        ;;
      confirm)
        note 'Require a fresh public-key login in the SSH journal, a different connection, and an unexpired deadline.'
        note 'Recheck the effective policy and write a receipt for this attempt.'
        run systemctl stop vps-rollback-ssh.timer
        note 'Archive the pending SSH backup after confirmation.'
        ;;
      *) die 'Choose harden or confirm.' ;;
    esac
    ;;
  configure-vpn)
    action=${1:-configure}
    shift || true
    stack=${STACK:-}
    if [[ $action == configure ]]; then
      while (($#)); do
        case $1 in
          --vpn=*) VPN=${1#*=} ;;
          *) die 'Usage: make configure-vpn vpn=NAME' ;;
        esac
        shift
      done
      validate_config
      note "Configure the saved VPN setting: $VPN. Caddy is installed by make setup-host."
      if [[ $VPN == tailscale ]]; then
        note 'Check /dev/net/tun, save the auth key in /opt/vps/.local/tailscale.env, and start the pinned Tailscale image.'
        run install -d -m 0700 /data/tailscale
        stack=tailscale
        action=apply
        preview_stack
      elif [[ $VPN == wireguard ]]; then
        WG_ENDPOINT=${WG_ENDPOINT:-203.0.113.10}
        note 'Ask for the public endpoint, install WireGuard, create one client profile, and start wg-quick@wg0.'
        apt_update
        install_packages wireguard
        copy_config wireguard/server.conf /etc/wireguard/wg0.conf
        copy_config wireguard/client.conf /opt/vps/.local/wireguard-client.conf
        run ufw allow 51820/udp comment WireGuard
        run ufw allow in on wg0 from 10.66.0.0/24 comment WireGuard-clients
        run systemctl enable --now wg-quick@wg0
      else
        note 'No VPN selected.'
      fi
    elif [[ $action == vpn-login && $VPN == none ]]; then
      note 'No VPN selected. Configure Tailscale or WireGuard first.'
    elif [[ $action == vpn-login && $VPN == wireguard ]]; then
      note 'Import /opt/vps/.local/wireguard-client.conf in the WireGuard app on the client.'
    else
      case "$action" in apply | vpn-login) ;; *) die 'Unknown VPN action.' ;; esac
      [[ $action != vpn-login ]] || stack=$VPN
      preview_stack
    fi
    ;;
  deploy-stack | sync-repo | deploy-tailscale)
    if [[ $command == deploy-stack ]]; then
      [[ ${HOST:-} =~ ^([a-z_][a-z0-9_-]*@)?[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || die 'Set HOST to your SSH alias or user@hostname.'
      case "${STACK:-}" in tailscale) ;; *) die 'Set STACK=tailscale.' ;; esac
      note "Deploy $STACK to $HOST. DRY_RUN=1 skips checks that need the host."
      make check-repo
      make preview-deploy
      make sync-repo
      make deploy-tailscale
      exit 0
    fi
    if [[ $command == deploy-tailscale ]]; then
      action=apply
      stack=${STACK:-}
      case "$stack" in tailscale) ;; *) die 'Set STACK=tailscale.' ;; esac
      if [[ -z ${HOST:-} ]]; then
        preview_stack
        exit 0
      fi
    else
      action=${1:-plan}
      case "$action" in plan | sync) ;; *) die 'Choose plan or sync.' ;; esac
    fi
    [[ ${HOST:-} =~ ^([a-z_][a-z0-9_-]*@)?[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || die 'Set HOST to an SSH alias or user@hostname.'
    run ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$HOST" 'test "$(id -u)" -ne 0 && test -w /opt/vps'
    if [[ $action == apply ]]; then
      run ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$HOST" "bash /opt/vps/scripts/vpn/configure.sh apply $stack"
      note "On $HOST:"
      preview_stack
    else
      options=(-acz --delete-after --itemize-changes --filter="merge $ROOT/.rsyncignore")
      [[ $action != plan ]] || options+=(--dry-run)
      run rsync "${options[@]}" -e 'ssh -o BatchMode=yes -o StrictHostKeyChecking=yes' "$ROOT/" "$HOST:/opt/vps/"
      note 'File differences require make preview-deploy HOST=... without DRY_RUN=1.'
    fi
    ;;
  show-status)
    run hostnamectl
    run uptime
    run df -h / /data
    run free -h
    run timedatectl show -p NTPSynchronized
    run systemctl --failed --no-pager
    run ufw status verbose
    run fail2ban-client status sshd
    run /usr/sbin/sshd -T -C "user=$ADMIN_USER,host=$SERVER_HOSTNAME,addr=127.0.0.1"
    run ss -tulnp
    run docker compose ls
    run docker ps
    note 'Verify UFW is active with deny incoming, allow outgoing, and deny routed policies.'
    note 'Check SSH, Docker port bindings, fail2ban, selected services, pending rollback, and reboot status.'
    ;;
  sync-time)
    service=$(time_sync_service || printf '%s' systemd-timesyncd)
    note "Start $service and wait for NTPSynchronized=yes."
    run systemctl enable --now "$service"
    run systemctl restart "$service"
    run timedatectl show -p NTPSynchronized --value
    ;;
  update-system)
    note 'Require SSH confirmation first. Ask before upgrading. Reboot separately when ready.'
    upgrade_os
    ;;
  check-repo)
    note 'Check Bash syntax, ShellCheck, shfmt, zsh syntax, JSON, and Compose files.'
    run shellcheck -x "$ROOT/setup-vps.sh" "$ROOT"/scripts/*.sh "$ROOT"/scripts/vm/*.sh
    run shfmt -d -i 2 -ci "$ROOT/setup-vps.sh" "$ROOT"/scripts/*.sh "$ROOT"/scripts/vm/*.sh
    ;;
  check-editor)
    note 'Download the pinned Neovim build and plugins into temporary XDG directories.'
    note 'Verify the download checksum, restore pinned plugins, then remove the temporary files.'
    run nvim --headless '+Lazy! restore' +qa
    ;;
  *) die "No preview for $command" ;;
esac
