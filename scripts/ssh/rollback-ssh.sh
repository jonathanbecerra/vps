#!/usr/bin/env bash
set -euo pipefail
case ${DRY_RUN:-0} in
  1)
    printf '%s\n' 'Dry run: rollback-ssh' \
      '  Restore the saved sshd_config and VPS include, if a change is pending.' \
      '  $ /usr/sbin/sshd -t' \
      '  $ systemctl reload <ssh-or-sshd>' \
      '  Archive the pending backup after a successful reload.'
    exit 0
    ;;
  0) ;;
  *)
    printf 'DRY_RUN must be 0 or 1.\n' >&2
    exit 1
    ;;
esac
pending=/var/lib/vps-setup/ssh-pending
bootstrap_password_config=/etc/ssh/sshd_config.d/00-bootstrap-password.conf
[[ -d $pending ]] || exit 0
exec 8>/run/vps-ssh.lock
flock 8
[[ -d $pending ]] || exit 0
cp -a "$pending/sshd_config" /etc/ssh/sshd_config
if [[ -f $pending/vps-setup.conf ]]; then
  cp -a "$pending/vps-setup.conf" /etc/ssh/vps-setup.conf
else
  rm -f /etc/ssh/vps-setup.conf
fi
if [[ -f $pending/bootstrap-password.conf ]]; then
  cp -a "$pending/bootstrap-password.conf" "$bootstrap_password_config"
fi
/usr/sbin/sshd -t
service=$(cat "$pending/service")
case "$service" in ssh | sshd) ;; *) exit 1 ;; esac
systemctl reload "$service"
logger -t vps-setup 'Restored the previous SSH configuration.'
mv "$pending" "/var/backups/vps-setup/ssh-rollback-$(date +%Y%m%d-%H%M%S)"
