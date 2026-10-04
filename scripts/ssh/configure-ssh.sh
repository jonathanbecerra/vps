#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
preview_if_requested configure-ssh "$@"
require_root
setup_lock
load_config /etc/vps-setup/host.conf
validate_config
pending=/var/lib/vps-setup/ssh-pending
bootstrap_password_config=/etc/ssh/sshd_config.d/00-bootstrap-password.conf
action=${1:-}
[[ ${SUDO_USER:-} == "$ADMIN_USER" ]] || die "Run this through sudo from $ADMIN_USER's SSH session."
[[ -n ${SSH_CONNECTION:-} ]] || die 'Use make configure-ssh or make confirm-ssh from an SSH session.'
read -r client_ip client_port server_ip server_port <<<"$SSH_CONNECTION"
[[ -n $client_ip && -n $client_port && -n $server_ip && -n $server_port ]] || die 'Invalid SSH connection information.'
begin 'Configure SSH access'

check_effective() {
  local user settings rule
  /usr/sbin/sshd -t
  for user in "$ADMIN_USER" root; do
    settings=$(/usr/sbin/sshd -T -C "user=$user,host=$SERVER_HOSTNAME,addr=$client_ip,laddr=$server_ip,lport=$server_port")
    for rule in 'permitrootlogin no' 'passwordauthentication no' 'kbdinteractiveauthentication no' 'pubkeyauthentication yes' 'authenticationmethods publickey' "allowusers $ADMIN_USER"; do
      grep -qxF "$rule" <<<"$settings" || die "SSH has an override for $user: expected '$rule'."
    done
  done
}

case "$action" in
  harden)
    [[ ! -d $pending ]] || die 'An SSH change is already pending. Confirm it from a new session or wait for rollback.'
    /usr/sbin/sshd -t
    user_home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
    ssh-keygen -lf "$user_home/.ssh/authorized_keys" >/dev/null
    confirm 'Turn off root and password SSH login? Keep this session open.'
    step 'Arm the five-minute rollback'
    install -d -m 0700 "$pending" /var/backups/vps-setup
    cp -a /etc/ssh/sshd_config "$pending/sshd_config"
    [[ ! -e /etc/ssh/vps-setup.conf ]] || cp -a /etc/ssh/vps-setup.conf "$pending/vps-setup.conf"
    [[ ! -f $bootstrap_password_config ]] || cp -a "$bootstrap_password_config" "$pending/bootstrap-password.conf"
    install -d -m 0700 "$pending/sshd-files"
    : >"$pending/sshd-password-files"
    while IFS= read -r file; do
      [[ -f $file ]] || continue
      relative=${file#/etc/ssh/}
      printf '%s\n' "$file" >>"$pending/sshd-password-files"
      install -D -m 0644 "$file" "$pending/sshd-files/$relative"
    done < <(sshd_password_files)
    ssh_service >"$pending/service"
    printf '%s\n' "$SSH_CONNECTION" >"$pending/connection"
    install -m 0755 "$ROOT/scripts/ssh/rollback-ssh.sh" /usr/local/sbin/vps-rollback-ssh
    trap 'result=$?; if ((result != 0)); then /usr/local/sbin/vps-rollback-ssh || true; fi; release_setup_lock' EXIT
    systemctl stop vps-rollback-ssh.timer vps-rollback-ssh.service 2>/dev/null || true
    systemctl reset-failed vps-rollback-ssh.service 2>/dev/null || true
    systemd-run --unit=vps-rollback-ssh --on-active=5m --timer-property=AccuracySec=1s /usr/local/sbin/vps-rollback-ssh
    export ADMIN_USER
    step 'Require key-only SSH'
    render "$ROOT/config/ssh/sshd.conf" /etc/ssh/vps-setup.conf ADMIN_USER
    # The first SSH setting wins, so this goes before cloud-init's config.
    sed -i '\|^Include /etc/ssh/vps-setup.conf$|d' /etc/ssh/sshd_config
    sed -i '1i Include /etc/ssh/vps-setup.conf' /etc/ssh/sshd_config
    step 'Disable password SSH access in the cloud-init settings'
    set_sshd_password_auth no
    rm -f /etc/ssh/sshd_config.d/00-bootstrap-password.conf
    step 'Check the effective SSH settings'
    check_effective
    progress 'Reload SSH' systemctl reload "$(cat "$pending/service")"
    note 'SSH now requires keys. Rollback runs in five minutes unless access is confirmed.'
    printf 'Keep this session open. Start a fresh SSH connection, then run:\n'
    printf '  cd /opt/vps && make confirm-ssh\n'
    printf 'Do not reboot until that passes.\n'
    ;;
  confirm)
    [[ -d $pending ]] || die 'No pending SSH change. It may already have rolled back.'
    [[ $(cat "$pending/connection") != "$SSH_CONNECTION" ]] || die 'Confirm from a new SSH connection. Disable SSH connection sharing for that login.'
    exec 8>/run/vps-ssh.lock
    flock 8
    [[ -d $pending ]] || die 'The rollback already ran. Run make configure-ssh again.'
    step 'Check the fresh SSH connection'
    check_effective
    step 'Cancel the rollback timer'
    systemctl stop vps-rollback-ssh.timer
    # If the timer already fired, its script rechecks pending after acquiring our lock.
    mv "$pending" "/var/backups/vps-setup/ssh-confirmed-$(date +%Y%m%d-%H%M%S)"
    note 'SSH confirmed. Rollback is cancelled; root and password logins are off.'
    ;;
  *) die 'Usage: configure-ssh.sh harden|confirm' ;;
esac
