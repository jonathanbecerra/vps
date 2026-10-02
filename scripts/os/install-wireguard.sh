#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
preview_if_requested install-wireguard "$@"
require_root
detect_os
load_config /etc/vps-setup/host.conf
validate_config
[[ $VPN == wireguard ]] || die 'Choose WireGuard with make configure-services first.'
[[ -n $WG_ENDPOINT ]] || die 'Set a public endpoint with make configure-services vpn=wireguard first.'
[[ $ROOT == /opt/vps ]] || die 'Run this from /opt/vps.'

begin 'Set up WireGuard'
apt_update
install_packages wireguard
install -d -m 0700 /etc/wireguard "$ROOT/.local"
chmod 0700 /etc/wireguard

server_config=/etc/wireguard/wg0.conf
client_config="$ROOT/.local/wireguard-client.conf"
if [[ ! -f $server_config ]]; then
  WG_SERVER_PRIVATE_KEY=$(wg genkey)
  WG_SERVER_PUBLIC_KEY=$(printf '%s' "$WG_SERVER_PRIVATE_KEY" | wg pubkey)
  WG_CLIENT_PRIVATE_KEY=$(wg genkey)
  WG_CLIENT_PUBLIC_KEY=$(printf '%s' "$WG_CLIENT_PRIVATE_KEY" | wg pubkey)
  export WG_SERVER_PRIVATE_KEY WG_SERVER_PUBLIC_KEY WG_CLIENT_PRIVATE_KEY WG_CLIENT_PUBLIC_KEY WG_ENDPOINT
  render "$ROOT/config/wireguard/server.conf" "$server_config" WG_SERVER_PRIVATE_KEY WG_CLIENT_PUBLIC_KEY
  chmod 0600 "$server_config"
  render "$ROOT/config/wireguard/client.conf" "$client_config" WG_CLIENT_PRIVATE_KEY WG_SERVER_PUBLIC_KEY WG_ENDPOINT
  chown "$ADMIN_USER:$(id -gn "$ADMIN_USER")" "$client_config"
  chmod 0600 "$client_config"
elif [[ ! -s $client_config ]]; then
  die "WireGuard is already configured, but $client_config is missing. Restore it from backup before continuing."
fi

step 'Open the WireGuard firewall rules'
ufw allow 51820/udp comment 'WireGuard'
ufw allow in on wg0 from 10.66.0.0/24 comment 'WireGuard clients'
progress 'Start WireGuard' systemctl enable --now wg-quick@wg0
wg show wg0
note "WireGuard is up. Import $client_config on the client."
