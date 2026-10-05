#!/usr/bin/env bash
# Sourced by scripts/setup.sh. Interactive work stays in the foreground.
install_base() {
  local mode=$1 source_repo=$ROOT admin_group user_home authorized_keys merged_keys service
  validate_config
  read_packages "$ROOT/config/apt/packages.txt"
  if id "$ADMIN_USER" &>/dev/null; then
    [[ $(id -u "$ADMIN_USER") -ge 1000 && $(id -u "$ADMIN_USER") -lt 65534 ]] || die 'The admin must be a regular user.'
  fi
  for service in firewalld nftables; do
    if systemctl is-active --quiet "$service"; then die "Review the existing $service firewall before switching to UFW."; fi
  done
  if command -v snap >/dev/null && snap list docker &>/dev/null; then
    die 'Docker is installed through Snap. Back up its data and migrate it before setup.'
  fi
  if [[ ! -f $VPS_HOST_CONFIG ]] && command -v docker >/dev/null && docker info &>/dev/null; then
    [[ -z $(docker ps -aq) ]] || die 'This host already has containers. Review their migration before first-time provisioning.'
  fi
  if [[ $ROOT != /opt/vps && -e /opt/vps/install.sh ]]; then
    die 'An installation already exists. Sync or pull updates there, then run /opt/vps/install.sh.'
  fi
  [[ ! -f $ROOT/.git ]] || die 'Use a regular clone or a code-only rsync, not a linked Git worktree.'
  [[ -f $ROOT/dotfiles/scripts/install.sh ]] || die 'Initialize the dotfiles submodule before setup: git submodule update --init --recursive'
  setup_lock
  step 'Update Ubuntu and install host packages'
  upgrade_os
  install_packages "${PACKAGES[@]}"
  if [[ $mode == advanced ]]; then
    hostnamectl set-hostname "$SERVER_HOSTNAME"
    backup /etc/hosts
    set_hosts_entry /etc/hosts "$SERVER_HOSTNAME"
    if ! id "$ADMIN_USER" &>/dev/null; then useradd --create-home --shell /bin/bash "$ADMIN_USER"; fi
    note "Set the password for $ADMIN_USER. It remains available for sudo and console recovery after SSH hardening."
    passwd "$ADMIN_USER"
  fi
  user_home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
  admin_group=$(id -gn "$ADMIN_USER")
  [[ $user_home == /home/* && -d $user_home ]] || die 'Expected the admin home under /home/.'
  install -d -o "$ADMIN_USER" -g "$admin_group" -m 0700 "$user_home/.ssh"
  authorized_keys="$user_home/.ssh/authorized_keys"
  if [[ -n $key_file ]]; then
    backup "$authorized_keys"
    touch "$authorized_keys"
    merged_keys=$(awk '!seen[$0]++' "$authorized_keys" "$key_file")
    printf '%s\n' "$merged_keys" >"$authorized_keys"
    chown "$ADMIN_USER:$admin_group" "$authorized_keys"
    chmod 0600 "$authorized_keys"
  fi
  export ADMIN_USER SERVER_HOSTNAME
  render "$ROOT/config/sudo/admin" /etc/sudoers.d/90-vps-admin ADMIN_USER
  chmod 0440 /etc/sudoers.d/90-vps-admin
  progress 'Check sudo access' visudo -cf /etc/sudoers.d/90-vps-admin
  step 'Keep the project under /opt/vps'
  install -d -m 0755 /data /etc/caddy "$VPS_CONFIG_DIR" /var/lib/vps-setup
  install -d -m 0700 /data/backups /var/backups/vps-setup
  [[ ! -L /opt/vps ]] || die '/opt/vps must be a directory, not a symlink.'
  install -d -o "$ADMIN_USER" -g "$admin_group" -m 0755 /opt/vps
  if [[ $ROOT != /opt/vps ]]; then
    # Retain Git and its submodule metadata when the source is a clone.
    rsync -a --include='/.git/***' --include='/dotfiles/.git' \
      --filter="merge $ROOT/.rsyncignore" "$ROOT/" /opt/vps/
  fi
  chown -R "$ADMIN_USER:$admin_group" /opt/vps
  install -d -o "$ADMIN_USER" -g "$admin_group" -m 0700 /opt/vps/.local
  ROOT=/opt/vps
  export ROOT
  write_host_config
  write_caddy_config
  progress 'Install Docker and Compose' bash "$ROOT/scripts/os/install-docker.sh"
  progress 'Configure UFW, fail2ban, and host protection' bash "$ROOT/scripts/os/configure-security.sh"
  release_setup_lock
  trap - EXIT
  [[ $source_repo == /opt/vps ]] || note 'Project installed at /opt/vps.'
}
