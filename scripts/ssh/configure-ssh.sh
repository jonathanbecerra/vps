#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
preview_if_requested configure-ssh "$@"
require_root
setup_lock
load_config "$VPS_HOST_CONFIG"
validate_config
pending=/var/lib/vps-setup/ssh-pending
bootstrap_password_config=/etc/ssh/sshd_config.d/00-bootstrap-password.conf
action=${1:-}
if [[ $action != harden || ${2:-} != --from-setup ]]; then
  [[ ${SUDO_USER:-} == "$ADMIN_USER" ]] || die "Run this through sudo from $ADMIN_USER's SSH session."
  [[ -n ${SSH_CONNECTION:-} ]] || die 'Use make configure-ssh or make confirm-ssh from an SSH session.'
fi
read -r client_ip client_port server_ip server_port <<<"${SSH_CONNECTION:-127.0.0.1 0 127.0.0.1 22}"
[[ -n $client_ip && -n $client_port && -n $server_ip && -n $server_port ]] || die 'Invalid SSH connection information.'
begin 'Configure SSH access'
# Serialize hardening, confirmation, and the independent rollback service.
exec 8>/run/vps-ssh.lock
flock 8

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
    [[ ${2:-} == --from-setup ]] || confirm 'Turn off root and password SSH login? Keep this session open.'
    step 'Arm the five-minute rollback'
    install -d -m 0700 /var/lib/vps-setup /var/backups/vps-setup
    prepared=$(mktemp -d /var/lib/vps-setup/ssh-stage.XXXXXX)
    trap 'rm -rf -- "$prepared"; release_setup_lock' EXIT
    cp -a /etc/ssh/sshd_config "$prepared/sshd_config"
    [[ ! -e /etc/ssh/vps-setup.conf ]] || cp -a /etc/ssh/vps-setup.conf "$prepared/vps-setup.conf"
    [[ ! -f $bootstrap_password_config ]] || cp -a "$bootstrap_password_config" "$prepared/bootstrap-password.conf"
    install -d -m 0700 "$prepared/sshd-files"
    : >"$prepared/sshd-password-files"
    while IFS= read -r file; do
      [[ -f $file ]] || continue
      relative=${file#/etc/ssh/}
      printf '%s\n' "$file" >>"$prepared/sshd-password-files"
      install -D -m 0644 "$file" "$prepared/sshd-files/$relative"
    done < <(sshd_password_files)
    ssh_service >"$prepared/service"
    printf '%s\n' "${SSH_CONNECTION:-console}" >"$prepared/connection"
    printf '%s-%s\n' "$(date +%s)" "$$" >"$prepared/id"
    date +%s >"$prepared/armed-at"
    read -r uptime _ </proc/uptime
    printf '%s\n' "$((${uptime%%.*} + 300))" >"$prepared/deadline"
    cat /proc/sys/kernel/random/boot_id >"$prepared/boot-id"
    install -m 0755 "$ROOT/scripts/ssh/rollback-ssh.sh" /usr/local/sbin/vps-rollback-ssh
    # A pending directory always contains a complete, restorable backup.
    mv "$prepared" "$pending"
    trap 'result=$?; flock -u 8; if ((result != 0)); then /usr/local/sbin/vps-rollback-ssh || true; fi; release_setup_lock' EXIT
    systemctl stop vps-rollback-ssh.timer vps-rollback-ssh.service 2>/dev/null || true
    systemctl reset-failed vps-rollback-ssh.service 2>/dev/null || true
    systemd-run --unit=vps-rollback-ssh --on-active=5m --timer-property=AccuracySec=1s /usr/local/sbin/vps-rollback-ssh 8>&- 9>&-
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
    if [[ ${2:-} != --from-setup ]]; then
      printf 'Keep this session open. Start a fresh SSH connection, then run:\n'
      printf '\tcd /opt/vps\n\tmake confirm-ssh\n'
    fi
    printf 'Do not reboot until SSH is confirmed.\n'
    ;;
  confirm)
    [[ -d $pending ]] || die 'No pending SSH change. It may already have rolled back.'
    [[ $(cat "$pending/connection") != "$SSH_CONNECTION" ]] || die 'Confirm from a new SSH connection. Disable SSH connection sharing for that login.'
    step 'Check the fresh SSH connection'
    check_effective
    if [[ -f $pending/armed-at ]]; then
      auth_log=$(journalctl -b -t sshd -t sshd-session --since "@$(cat "$pending/armed-at")" --no-pager -o cat)
      grep -Fq "Accepted publickey for $ADMIN_USER from $client_ip port $client_port " <<<"$auth_log" ||
        die 'No fresh public-key login found for this connection. Open a new SSH connection with connection sharing disabled.'
    fi
    if [[ -f $pending/deadline ]]; then
      read -r uptime _ </proc/uptime
      [[ $(cat "$pending/boot-id") == "$(cat /proc/sys/kernel/random/boot_id)" && ${uptime%%.*} -lt $(cat "$pending/deadline") ]] ||
        die 'The confirmation window expired. Return to setup and retry after rollback.'
    fi
    step 'Cancel the rollback timer'
    systemctl stop vps-rollback-ssh.timer
    if [[ -f $pending/id ]]; then
      install -m 0600 "$pending/id" /var/lib/vps-setup/ssh-confirmed.new
      mv /var/lib/vps-setup/ssh-confirmed.new /var/lib/vps-setup/ssh-confirmed
    fi
    # If the timer already fired, its script rechecks pending after acquiring our lock.
    mv "$pending" "/var/backups/vps-setup/ssh-confirmed-$(date +%Y%m%d-%H%M%S)-$$"
    note 'SSH confirmed. Rollback is cancelled; root and password logins are off.'
    ;;
  *) die 'Usage: configure-ssh.sh harden|confirm' ;;
esac
