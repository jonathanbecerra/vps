#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
preview_if_requested configure-security "$@"
require_root
detect_os
load_config /etc/vps-setup/host.conf
validate_config

begin 'Configure firewall and login protection'
step 'Set firewall rules'
systemctl enable --now ssh
/usr/sbin/sshd -t
# Preserve existing rules, including the port for this SSH session.
backup /etc/default/ufw
sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
ufw default deny incoming
ufw default allow outgoing
ufw default deny routed
while IFS= read -r port; do
  [[ $port =~ ^[0-9]+$ && $port -ge 1 && $port -le 65535 ]] || die 'Could not determine an SSH port.'
  ufw allow "$port/tcp" comment 'SSH'
done < <(ssh_ports)
ufw logging low
ufw --force enable
systemctl enable --now ufw

step 'Set up fail2ban and kernel settings'
SSH_PORTS=$(ssh_ports | paste -sd, -)
export SSH_PORTS
render "$ROOT/config/fail2ban/sshd.local" /etc/fail2ban/jail.d/90-vps-sshd.local SSH_PORTS
fail2ban-client -t
systemctl enable fail2ban
systemctl restart fail2ban
backup /etc/sysctl.d/90-vps.conf
install -m 0644 "$ROOT/config/sysctl/90-vps.conf" /etc/sysctl.d/90-vps.conf
sysctl -p /etc/sysctl.d/90-vps.conf

if [[ $SECURITY_UPDATES == yes ]]; then
  install_packages unattended-upgrades
  step 'Enable automatic security updates'
  for file in 20auto-upgrades 52vps-unattended-upgrades; do
    backup "/etc/apt/apt.conf.d/$file"
    install -m 0644 "$ROOT/config/apt/$file" "/etc/apt/apt.conf.d/$file"
  done
  systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
else
  step 'Leave automatic updates off'
  backup /etc/apt/apt.conf.d/20auto-upgrades
  install -m 0644 "$ROOT/config/apt/20manual-upgrades" /etc/apt/apt.conf.d/20auto-upgrades
fi
