#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
preview_if_requested show-status "$@"
require_root
load_config /etc/vps-setup/host.conf
validate_config
failed=0
begin 'Host status'
hostnamectl
uptime
df -h / /data
free -h
timedatectl show -p NTPSynchronized
note 'Failed systemd units'
systemctl --failed --no-pager
[[ -z $(systemctl --failed --no-legend --plain) ]] || failed=1
services=("$(ssh_service)" docker fail2ban ufw)
[[ $CADDY_MODE == none ]] || services+=(caddy)
for service in "${services[@]}"; do
  if ! systemctl is-active "$service"; then failed=1; fi
done
note 'Firewall and SSH bans'
firewall_status=$(LC_ALL=C ufw status verbose)
printf '%s\n' "$firewall_status"
grep -qx 'Status: active' <<<"$firewall_status" || failed=1
grep -Eq '^Default: deny \(incoming\), allow \(outgoing\), deny \(routed\)$' <<<"$firewall_status" || failed=1
printf '\n'
fail2ban-client status sshd || failed=1
note 'SSH settings in use'
policy=$(/usr/sbin/sshd -T -C "user=$ADMIN_USER,host=$SERVER_HOSTNAME,addr=127.0.0.1")
printf '%s\n' "$policy" | awk '$1 ~ /^(port|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|authenticationmethods|allowusers)$/ {print}'
for rule in 'permitrootlogin no' 'passwordauthentication no' 'kbdinteractiveauthentication no' 'pubkeyauthentication yes' 'authenticationmethods publickey' "allowusers $ADMIN_USER"; do
  grep -qxF "$rule" <<<"$policy" || failed=1
done
if [[ -d /var/lib/vps-setup/ssh-pending ]]; then
  printf 'SSH confirmation is pending.\n'
  systemctl list-timers vps-rollback-ssh.timer --no-pager
  failed=1
fi
note 'Listening ports (host processes)'
ss -tulnp
note 'Docker Compose projects'
docker compose ls
note 'Docker containers'
container_rows=$(docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}')
if [[ -n $container_rows ]]; then
  printf 'NAME\tSTATUS\tPORTS\n%s\n' "$container_rows"
else
  printf 'None running.\n'
fi
mapfile -t container_ids < <(docker ps -q)
if ((${#container_ids[@]})); then
  public_bindings=$(docker inspect "${container_ids[@]}" | jq -r '
    .[] as $container |
    ($container.HostConfig.PortBindings // {}) | to_entries[] |
    .key as $container_port | .value[]? |
    select(.HostIp != "127.0.0.1" and .HostIp != "::1") |
    "\($container.Name) \($container_port) -> \(.HostIp // "*"):\(.HostPort)"
  ')
  if [[ -n $public_bindings ]]; then
    printf 'Docker ports are not bound to loopback:\n%s\n' "$public_bindings"
    failed=1
  fi
fi
if [[ $CADDY_MODE != none ]]; then
  if [[ ! -x /usr/local/bin/caddy || ! -f /etc/caddy/Caddyfile ]]; then
    note 'Caddy is selected but not configured.'
    printf '\tRun:\n\t\tmake setup-host\n'
    failed=1
  else
    /usr/local/bin/caddy validate --config /etc/caddy/Caddyfile || failed=1
    systemctl is-enabled --quiet caddy || failed=1
  fi
fi
if [[ $VPN == tailscale ]]; then
  compose --profile tailscale exec -T tailscale tailscale status || failed=1
elif [[ $VPN == wireguard ]]; then
  wg show wg0 || failed=1
fi
if [[ -f /var/run/reboot-required ]]; then cat /var/run/reboot-required; fi
note 'Check the listening ports above. Only intended services should be public.'
exit "$failed"
