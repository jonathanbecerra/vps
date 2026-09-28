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
INSTALL_FONT='yes'
SECURITY_UPDATES='yes'
CADDY_ONLY=no
VPN_ONLY=no
RECONFIGURE_CADDY=no
if [[ -z ${HOST:-} && -r /etc/vps-setup/host.conf ]]; then load_config /etc/vps-setup/host.conf; fi
key_file='<public-key-file>'
if [[ $command == setup-vps ]]; then
  while (($#)); do
    (($# >= 2)) || die "Missing value for $1"
    case "$1" in
      --config) [[ -z $2 ]] || load_config "$2" ;;
      --key) [[ -z $2 ]] || key_file=$2 ;;
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
  run apt-get update
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

preview_binaries() {
  local requested tool arch url checksum _member destination found
  for requested in "$@"; do
    found=no
    while IFS=$'\t' read -r tool arch url checksum _member; do
      [[ $tool == "$requested" && ($arch == "$ARCH" || $arch == all) ]] || continue
      found=yes
      case "$tool" in
        nvim) destination='/opt/neovim/<version> (linked at /usr/local/bin/nvim)' ;;
        jetbrains-mono) destination=/usr/local/share/fonts/jetbrains-mono ;;
        *) destination="/usr/local/bin/$tool" ;;
      esac
      printf '  %s -> %s\n    %s\n    SHA256 %s; skip if already installed at this version.\n' "$tool" "$destination" "$url" "$checksum"
    done <"$ROOT/config/apt/binaries.tsv"
    [[ $found == yes ]] || die "No pinned binary for $requested on $ARCH"
  done
}

preview_image_locks() {
  local operation=$1 lock="$ROOT/stacks/compose.lock.yaml"
  note "Use a temporary lock under $ROOT/.image-lock.XXXXXX and remove it when done."
  run docker compose --env-file "$ROOT/.env.example" -f "$ROOT/stacks/compose.yaml" \
    --profile caddy --profile tailscale \
    config --lock-image-digests --output '<temporary-directory>/compose.lock.yaml'
  if [[ $operation == lock ]]; then
    run docker compose --env-file "$ROOT/.env.example" -f "$ROOT/stacks/compose.yaml" \
      -f '<temporary-directory>/compose.lock.yaml' --profile caddy --profile tailscale config --quiet
    run chmod 0644 '<temporary-directory>/compose.lock.yaml'
    run mv '<temporary-directory>/compose.lock.yaml' "$lock"
  else
    run cmp -s "$lock" '<temporary-directory>/compose.lock.yaml'
    run diff -u "$lock" '<temporary-directory>/compose.lock.yaml'
    note 'Stop if the saved lock is missing or differs.'
    run docker compose --env-file "$ROOT/.env.example" -f "$ROOT/stacks/compose.yaml" \
      -f "$lock" --profile caddy --profile tailscale config --quiet
  fi
  run rm -rf '<temporary-directory>'
}

preview_caddy_build() {
  preview_image_locks verify
  run docker compose --env-file "$ROOT/.env.example" --profile caddy \
    -f "$ROOT/stacks/compose.yaml" -f "$ROOT/stacks/compose.lock.yaml" build --pull caddy
}

preview_legacy_compose() {
  local legacy_stack=$1
  note "If the old vps-$legacy_stack project exists, stop it before using the combined project."
  run docker compose --env-file /opt/vps/.env.example \
    --env-file "/opt/vps/.local/$legacy_stack.env" --project-name "vps-$legacy_stack" \
    -f "/opt/vps/stacks/$legacy_stack/compose.yaml" --profile "$legacy_stack" down
}

preview_stack() {
  case "$stack" in caddy | tailscale) ;; *) die 'Set STACK=caddy or tailscale.' ;; esac
  compose=(docker compose --env-file /opt/vps/.env.example
    --env-file /opt/vps/.local/caddy.env --env-file /opt/vps/.local/tailscale.env
    -f /opt/vps/stacks/compose.yaml -f /opt/vps/stacks/compose.lock.yaml --profile "$stack")
  case "$action" in
    apply)
      preview_legacy_compose "$stack"
      run "${compose[@]}" config --quiet
      if [[ $stack == caddy ]]; then
        preview_caddy_build
        run "${compose[@]}" run --rm --no-deps caddy caddy validate --config /etc/caddy/Caddyfile
      else
        preview_image_locks verify
      fi
      if [[ $stack == caddy ]]; then
        run "${compose[@]}" up -d --no-build --force-recreate --wait --wait-timeout 90 "$stack"
      else
        run "${compose[@]}" up -d --no-build --wait --wait-timeout 90 "$stack"
      fi
      run "${compose[@]}" ps
      ;;
    pull)
      if [[ $stack == caddy ]]; then
        preview_caddy_build
      else
        preview_image_locks verify
        run "${compose[@]}" pull "$stack"
      fi
      ;;
    logs) run "${compose[@]}" logs --tail 100 --follow ;;
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
    read_setup_packages "$ROOT/config/apt/packages.txt"
    note "Setup values: hostname=$SERVER_HOSTNAME, admin=$ADMIN_USER, Caddy=$CADDY_MODE, VPN=$VPN."
    note "JetBrains Mono=$INSTALL_FONT, automatic security updates=$SECURITY_UPDATES."
    note 'Choose Caddy yes or no during setup; run make configure-caddy to add its routes.'
    note 'Run make configure-services to apply the saved service choices.'
    printf '  Validate %s and config/apt/packages.txt; check for existing containers and firewalls.\n' "$key_file"
    note 'One setup run sets the hostname, updates Ubuntu, creates the admin, copies the repo, installs Docker, and configures UFW, fail2ban, and security updates.'
    run hostnamectl set-hostname "$SERVER_HOSTNAME"
    upgrade_os
    install_packages "${system_packages[@]}"
    note 'Back up /etc/hosts and set its 127.0.1.1 entry. Create the admin if missing.'
    run useradd --create-home --shell /bin/zsh "$ADMIN_USER"
    printf '  Merge public keys into /home/%s/.ssh/authorized_keys (0600).\n' "$ADMIN_USER"
    copy_config sudo/admin /etc/sudoers.d/90-vps-admin
    run visudo -cf /etc/sudoers.d/90-vps-admin
    note 'Prompt for a sudo password if the account has none.'
    run usermod -s /bin/zsh "$ADMIN_USER"
    run install -d -m 0755 /data /etc/vps-setup /var/lib/vps-setup
    run install -d -m 0700 /data/backups /var/backups/vps-setup
    note "Copy the repo to /opt/vps, owned by $ADMIN_USER. Remove the temporary home checkout after setup succeeds."
    note 'Pinned tools and the selected font install later with make setup-host.'
    preview_docker
    preview_security
    note 'SSH HANDOFF'
    printf 'Keep this session open until key access is confirmed.\n'
    printf '\n\t%s1.%s In another terminal, log in as %s with the same key:\n' "$C_YELLOW" "$C_RESET" "$ADMIN_USER"
    printf '\t\t%scd /opt/vps && make configure-ssh%s\n' "$C_YELLOW" "$C_RESET"
    printf '\n\t%s2.%s Open a fresh SSH connection within five minutes:\n' "$C_YELLOW" "$C_RESET"
    printf '\t\t%scd /opt/vps && make confirm-ssh%s\n' "$C_YELLOW" "$C_RESET"
    printf '\n\t%s3.%s Continue in that confirmed session:\n' "$C_YELLOW" "$C_RESET"
    printf '\t\t%scd /opt/vps && make setup-host%s\n' "$C_YELLOW" "$C_RESET"
    printf '\t\tReboot when ready.\n'
    ;;
  install-docker) preview_docker ;;
  install-packages)
    read_setup_packages "$ROOT/config/apt/packages.txt"
    note 'Install Ubuntu packages from config/apt/packages.txt.'
    run apt-get update
    install_packages "${system_packages[@]}"
    ;;
  install-wireguard)
    note 'Install WireGuard, make a server key and one client profile, and bring up wg0.'
    run apt-get update
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
  lock-images) preview_image_locks lock "${STACK:-all}" ;;
  verify-images) preview_image_locks verify "${STACK:-all}" ;;
  configure-security) preview_security ;;
  install-tools)
    read_setup_packages "$ROOT/config/apt/packages.txt"
    note 'Install the selected tools and font in one run.'
    printf '  %s\n' "${binary_packages[*]}"
    preview_binaries "${binary_packages[@]}"
    ;;
  install-binaries) preview_binaries "$@" ;;
  install-dotfiles)
    note 'Fetch the pinned commits in config/zsh/plugins.tsv into ~/.local/share.'
    note 'Back up existing dotfiles to ~/.local/state/vps-backups before linking.'
    run rm -f "/home/$ADMIN_USER/.bash_history" "/home/$ADMIN_USER/.bash_logout" "/home/$ADMIN_USER/.bashrc"
    copy_config zsh/zshrc "/home/$ADMIN_USER/.zshrc"
    copy_config zsh/p10k.zsh "/home/$ADMIN_USER/.p10k.zsh"
    printf '  Use the pinned Catppuccin Rainbow Mocha preset from /home/%s/.local/share/zsh/catppuccin-powerlevel10k-themes.\n' "$ADMIN_USER"
    copy_config nvim "/home/$ADMIN_USER/.config/nvim"
    copy_config tmux/tmux.conf "/home/$ADMIN_USER/.tmux.conf"
    run deja init zsh
    run nvim --headless '+Lazy! restore' +qa
    [[ ${1:-} != --reload-shell ]] || note 'Enter zsh after installing the dotfiles.'
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
        note 'Require a different SSH connection as the admin and recheck the effective SSH policy.'
        run systemctl stop vps-rollback-ssh.timer
        note 'Archive the pending SSH backup after confirmation.'
        ;;
      *) die 'Choose harden or confirm.' ;;
    esac
    ;;
  configure-services)
    action=${1:-configure}
    shift || true
    stack=${STACK:-}
    if [[ $action == configure ]]; then
      while (($#)); do
        case $1 in
          --enable-caddy) CADDY_MODE=docker ;;
          --caddy-only) CADDY_ONLY=yes ;;
          --vpn-only) VPN_ONLY=yes ;;
          --reconfigure-caddy) RECONFIGURE_CADDY=yes ;;
          --vpn=*) VPN=${1#*=} ;;
          *) die 'Usage: configure-services.sh configure [--enable-caddy] [--vpn=NAME] [--caddy-only|--vpn-only] [--reconfigure-caddy]' ;;
        esac
        shift
      done
      validate_config
      if [[ $CADDY_ONLY == yes ]]; then
        note 'Configure Caddy only. Leave saved VPN settings alone.'
      elif [[ $VPN_ONLY == yes ]]; then
        note "Configure $VPN only. Leave saved Caddy settings alone."
      else
        note "Configure saved services in order: Caddy=$CADDY_MODE, VPN=$VPN."
      fi
      note 'Check for conflicting services. Stop if a mode change would leave one running.'
      if [[ $VPN_ONLY == no && $CADDY_MODE != none ]]; then
        if [[ $RECONFIGURE_CADDY == yes ]]; then
          note 'If the route file exists, ask before replacing it. Yes starts the route setup again; no keeps the saved routes.'
        fi
        note 'Choose one app or multiple apps on first setup. Single-app upstream is optional.'
        note 'Multiple apps copy stacks/caddy/caddy-sites-example.caddy to /opt/vps/.local/caddy-sites.caddy for editing.'
        note 'Run make configure-services after editing routes to apply them.'
        note 'Ask for a Cloudflare token with Zone Read and DNS Edit access to the site zones.'
        note 'Reject placeholder token input before starting Caddy.'
        note 'Save the hidden token in /opt/vps/.local/caddy.env with mode 0600.'
        note 'Set TZ=America/New_York in the Caddy env file if it has no TZ value.'
        note 'Only open the firewall and start Caddy after routes are ready.'
        note 'Stop an already running Caddy container if the replacement routes still need editing.'
        note 'Create /data/www/blog and keep the blog files there; Caddy reads them from /srv/blog.'
        run install -d -m 0700 /data/caddy /data/caddy/data /data/caddy/config
        run install -d -o "$ADMIN_USER" -g '<admin-primary-group>' -m 0755 /data/www/blog
        if [[ ! -e /data/www/blog/index.html ]]; then
          note 'Copy the starter blog page if /data/www/blog/index.html does not exist.'
          run install -o "$ADMIN_USER" -g '<admin-primary-group>' -m 0644 \
            "$ROOT/stacks/caddy/www/blog/index.html" /data/www/blog/index.html
        fi
        for port in 80/tcp 443/tcp 443/udp; do run ufw allow "$port"; done
      fi
      if [[ $CADDY_ONLY == no && $VPN != none ]]; then
        if [[ $VPN == tailscale ]]; then
          note 'Check /dev/net/tun. Ask for a Tailscale key if no env file exists; Enter can use browser login.'
          note 'Save /opt/vps/.local/tailscale.env with mode 0600.'
          run install -d -m 0700 /data/tailscale
        else
          WG_ENDPOINT=${WG_ENDPOINT:-203.0.113.10}
          note 'Ask for the public IPv4 address or DNS name clients can reach.'
          note 'Install wireguard, generate one client profile, open UDP 51820, and start wg-quick@wg0.'
          note 'Save /opt/vps/.local/wireguard-client.conf with mode 0600.'
          run apt-get update
          install_packages wireguard
          copy_config wireguard/server.conf /etc/wireguard/wg0.conf
          copy_config wireguard/client.conf /opt/vps/.local/wireguard-client.conf
          run ufw allow 51820/udp comment WireGuard
          run ufw allow in on wg0 from 10.66.0.0/24 comment WireGuard-clients
          run systemctl enable --now wg-quick@wg0
          note 'Preview uses 203.0.113.10; enter the real endpoint when prompted.'
        fi
      fi
      note 'Save choices in /etc/vps-setup/host.conf.'
      action=apply
      if [[ $VPN_ONLY == no && $CADDY_MODE == docker ]]; then
        stack=caddy
        preview_stack
      fi
      if [[ $CADDY_ONLY == no && $VPN == tailscale ]]; then
        stack=$VPN
        preview_stack
      fi
    elif [[ $action == vpn-login && $VPN == none ]]; then
      note 'No VPN selected. Configure Tailscale or WireGuard first.'
    elif [[ $action == vpn-login && $VPN == wireguard ]]; then
      note 'Import /opt/vps/.local/wireguard-client.conf in the WireGuard app on the client.'
    else
      case "$action" in apply | pull | logs | vpn-login) ;; *) die 'Unknown service action.' ;; esac
      [[ $action != vpn-login ]] || stack=$VPN
      preview_stack
    fi
    ;;
  deploy-stack | sync-repo | apply-stack)
    if [[ $command == deploy-stack ]]; then
      [[ ${HOST:-} =~ ^([a-z_][a-z0-9_-]*@)?[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || die 'Set HOST to your SSH alias or user@hostname.'
      case "${STACK:-}" in caddy | tailscale) ;; *) die 'Set STACK=caddy or tailscale.' ;; esac
      note "Deploy $STACK to $HOST. DRY_RUN=1 skips checks that need the host."
      make check-repo
      make preview-deploy
      make sync-repo
      make apply-stack
      exit 0
    fi
    if [[ $command == apply-stack ]]; then
      action=apply
      stack=${STACK:-}
      case "$stack" in caddy | tailscale) ;; *) die 'Set STACK=caddy or tailscale.' ;; esac
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
      run ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$HOST" "bash /opt/vps/scripts/configure-services.sh apply $stack"
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
    note 'Check SSH, Docker, UFW, fail2ban, selected services, pending rollback, and reboot status.'
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
