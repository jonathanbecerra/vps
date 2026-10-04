#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
preview_if_requested configure-services "$@"
[[ $(uname -s) == Linux ]] || die 'Run service commands on the Linux host, or use make apply-stack HOST=... STACK=tailscale'
load_config /etc/vps-setup/host.conf
action=${1:-configure}
stack=${2:-}
if [[ $action == configure ]]; then
  shift
  while (($#)); do
    case $1 in
      --vpn-only) ;;
      --vpn=*) VPN=${1#*=} ;;
      *) die 'Usage: configure-services.sh configure [--vpn=NAME] [--vpn-only]' ;;
    esac
    shift
  done
fi
validate_config

check_stack() {
  [[ $stack == tailscale ]] || die 'Choose STACK=tailscale.'
  [[ $VPN == tailscale ]] || die "VPN is set to $VPN. Run make configure-services to change it."
  [[ -f $ROOT/.local/tailscale.env ]] || die 'Run make configure-services on the host first.'
  [[ -f $ROOT/stacks/compose.lock.yaml ]] || die 'Run make lock-images first.'
}

apply_tailscale() {
  check_stack
  remove_legacy_compose tailscale
  progress 'Check Tailscale compose file' compose --profile tailscale config --quiet
  progress 'Verify pinned Tailscale image' bash "$ROOT/scripts/compose/lock-images.sh" verify
  progress 'Start Tailscale' compose --profile tailscale up -d --no-build --wait --wait-timeout 90 tailscale
  step 'Check Tailscale container'
  compose --profile tailscale ps tailscale
}

case "$action" in
  apply)
    apply_tailscale
    exit 0
    ;;
  pull)
    check_stack
    progress 'Verify pinned Tailscale image' bash "$ROOT/scripts/compose/lock-images.sh" verify
    progress 'Pull Tailscale image' compose --profile tailscale pull tailscale
    exit 0
    ;;
  logs)
    check_stack
    compose --profile tailscale logs --tail 100 --follow tailscale
    exit 0
    ;;
  vpn-login)
    if [[ $VPN == wireguard ]]; then
      [[ -s $ROOT/.local/wireguard-client.conf ]] || die 'Configure WireGuard first.'
      note "Import $ROOT/.local/wireguard-client.conf in the WireGuard app on the client."
      exit 0
    fi
    stack=tailscale
    check_stack
    compose --profile tailscale exec tailscale tailscale up --accept-dns=false
    exit 0
    ;;
  configure) ;;
  *) die 'Usage: configure-services.sh configure|apply|pull|logs|vpn-login [STACK]' ;;
esac

require_root
detect_os
[[ $ROOT == /opt/vps ]] || die 'Run this command from /opt/vps.'
[[ ! -d /var/lib/vps-setup/ssh-pending ]] || die 'Confirm SSH access before starting services.'
setup_lock
trap release_setup_lock EXIT

if [[ $VPN == wireguard && -z $WG_ENDPOINT ]]; then ask WG_ENDPOINT 'WireGuard public IPv4 address or DNS name'; fi
validate_config
if [[ $VPN != tailscale ]] && {
  [[ -n $(docker ps -q --filter label=com.docker.compose.project=vps --filter label=com.docker.compose.service=tailscale) ]] ||
    [[ -n $(docker ps -q --filter label=com.docker.compose.project=vps-tailscale --filter label=com.docker.compose.service=tailscale) ]]
}; then
  die 'Stop Tailscale before choosing another VPN. Keep a public SSH connection open.'
fi
if [[ $VPN != wireguard ]] && systemctl is-active --quiet wg-quick@wg0; then
  die 'Stop WireGuard before choosing another VPN. Keep a public SSH connection open.'
fi
if [[ $VPN == tailscale && ! -c /dev/net/tun ]]; then die '/dev/net/tun is missing. Enable the tun kernel module on this host.'; fi

admin_group=$(id -gn "$ADMIN_USER")
install -d -o "$ADMIN_USER" -g "$admin_group" -m 0700 "$ROOT/.local"
umask 077
if [[ $VPN == tailscale && ! -f $ROOT/.local/tailscale.env ]]; then
  token=
  ask_secret token 'Tailscale auth key, or press Enter to log in through the browser'
  [[ $token =~ ^[a-zA-Z0-9_-]*$ ]] || die 'That auth key has unexpected characters. Paste the key on its own.'
  printf 'VPN_HOSTNAME=%s\nTS_AUTHKEY=%s\n' "$SERVER_HOSTNAME" "$token" >"$ROOT/.local/tailscale.env"
  unset token
fi
for key in SERVER_HOSTNAME ADMIN_USER VPN WG_ENDPOINT SECURITY_UPDATES; do
  printf '%s=%s\n' "$key" "${!key}"
done >/etc/vps-setup/host.conf
chmod 0644 /etc/vps-setup/host.conf

if [[ $VPN == tailscale ]]; then
  chown "$ADMIN_USER:$admin_group" "$ROOT/.local/tailscale.env"
  chmod 0600 "$ROOT/.local/tailscale.env"
  install -d -m 0700 /data/tailscale
elif [[ $VPN == wireguard ]]; then
  bash "$ROOT/scripts/os/install-wireguard.sh"
fi

if [[ $VPN == tailscale ]]; then
  stack=tailscale
  apply_tailscale
else
  note 'No VPN selected.'
fi
