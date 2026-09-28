#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
preview_if_requested configure-services "$@"
[[ $(uname -s) == Linux ]] || die 'Run service commands on the Linux host, or use make apply-stack HOST=... STACK=...'
load_config /etc/vps-setup/host.conf
action=${1:-configure}
stack=${2:-}
if [[ $action == configure ]]; then
  shift
  while (($#)); do
    case $1 in
      --caddy=*) CADDY_MODE=${1#*=} ;;
      --vpn=*) VPN=${1#*=} ;;
      *) die 'Usage: configure-services.sh configure [--caddy=docker|none] [--vpn=NAME]' ;;
    esac
    shift
  done
fi
validate_config
begin 'Configure services'
export VPS_NO_CLEAR=1

compose() {
  docker compose --env-file "$ROOT/.local/$stack.env" \
    -f "$ROOT/stacks/$stack/compose.yaml" -f "$ROOT/stacks/$stack/compose.lock.json" "$@"
}

check_stack() {
  case "$stack" in
    caddy) [[ $CADDY_MODE == docker ]] || die 'Caddy is off. Run make configure-services caddy=docker to start it.' ;;
    tailscale) [[ $VPN == "$stack" ]] || die "VPN is set to $VPN. Run make configure-services to change it." ;;
    *) die 'Choose STACK=caddy or tailscale.' ;;
  esac
  [[ -f $ROOT/.local/$stack.env ]] || die 'Run make configure-services on the host first.'
  [[ -f $ROOT/stacks/$stack/compose.lock.json ]] || die "Run make lock-images STACK=$stack first."
}

apply_stack() {
  check_stack
  progress "Check $stack compose file" compose config --quiet
  if [[ $stack == caddy ]]; then
    progress 'Build Caddy with Cloudflare DNS' bash "$ROOT/scripts/build-caddy.sh"
    progress 'Validate Caddy configuration' compose run --rm --no-deps caddy caddy validate --config /etc/caddy/Caddyfile
  else
    progress 'Verify pinned Tailscale image' env STACK="$stack" bash "$ROOT/scripts/lock-images.sh" verify
  fi
  if [[ $stack == caddy ]]; then
    progress 'Start Caddy' compose up -d --no-build --force-recreate --wait --wait-timeout 90
  else
    progress 'Start Tailscale' compose up -d --no-build --wait --wait-timeout 90
  fi
  # --wait checks containers, not VPN enrollment or upstream reachability.
  step "Check $stack container"
  compose ps
}

case "$action" in
  apply)
    check_stack
    apply_stack
    exit 0
    ;;
  pull)
    check_stack
    if [[ $stack == caddy ]]; then
      progress 'Build Caddy with Cloudflare DNS' bash "$ROOT/scripts/build-caddy.sh"
    else
      progress 'Verify pinned Tailscale image' env STACK="$stack" bash "$ROOT/scripts/lock-images.sh" verify
      progress 'Pull Tailscale image' compose pull
    fi
    exit 0
    ;;
  logs)
    check_stack
    compose logs --tail 100 --follow
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
    compose exec tailscale tailscale up --accept-dns=false
    exit 0
    ;;
  configure) ;;
  *) die 'Usage: configure-services.sh configure|apply|pull|logs|vpn-login [STACK]' ;;
esac

require_root
detect_os
[[ $ROOT == /opt/vps ]] || die 'Run make configure-services from /opt/vps.'
[[ ! -d /var/lib/vps-setup/ssh-pending ]] || die 'Confirm SSH access before starting services.'
setup_lock
if [[ $VPN == wireguard && -z $WG_ENDPOINT ]]; then
  ask WG_ENDPOINT 'WireGuard public IPv4 address or DNS name'
fi
validate_config
if [[ $CADDY_MODE != docker && -n $(docker ps -q --filter label=com.docker.compose.project=vps-caddy) ]]; then
  die 'Stop Docker Caddy before turning it off.'
fi
if [[ $VPN != tailscale ]] && [[ -n $(docker ps -q --filter label=com.docker.compose.project=vps-tailscale) ]]; then
  die 'Stop Tailscale before choosing another VPN. Keep a public SSH connection open.'
fi
if [[ $VPN != wireguard ]] && systemctl is-active --quiet wg-quick@wg0; then
  die 'Stop WireGuard before choosing another VPN. Keep a public SSH connection open.'
fi
if [[ $VPN == tailscale && ! -c /dev/net/tun ]]; then die '/dev/net/tun is missing. Enable the tun kernel module on this host.'; fi
step 'Save service choices'
for key in SERVER_HOSTNAME ADMIN_USER CADDY_MODE VPN WG_ENDPOINT INSTALL_FONT SECURITY_UPDATES; do
  printf '%s=%s\n' "$key" "${!key}"
done >/etc/vps-setup/host.conf
chmod 0644 /etc/vps-setup/host.conf
admin_group=$(id -gn "$ADMIN_USER")
install -d -o "$ADMIN_USER" -g "$admin_group" -m 0700 "$ROOT/.local"
umask 077

if [[ $CADDY_MODE != none ]]; then
  step 'Set up Docker Caddy'
  if [[ ! -f $ROOT/.local/caddy.env ]]; then
    ask CADDY_SITE 'Domain, e.g. app.example.com'
    ask CADDY_UPSTREAM 'Send traffic to host:port' '127.0.0.1:8080'
    [[ $CADDY_SITE =~ ^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$ ]] || die 'Enter a domain name without a scheme or path.'
    [[ $CADDY_UPSTREAM =~ ^[a-zA-Z0-9.-]+:[0-9]{1,5}$ ]] || die 'Enter an upstream as host:port.'
    upstream_port=${CADDY_UPSTREAM##*:}
    ((10#$upstream_port >= 1 && 10#$upstream_port <= 65535)) || die 'Invalid upstream port.'
    printf 'CADDY_SITE=%s\nCADDY_UPSTREAM=%s\n' "$CADDY_SITE" "$CADDY_UPSTREAM" >"$ROOT/.local/caddy.env"
  fi
  chmod 0600 "$ROOT/.local/caddy.env"
  if ! grep -qE '^CLOUDFLARE_API_TOKEN=[a-zA-Z0-9_-]+$' "$ROOT/.local/caddy.env" ||
    grep -Eiq '^CLOUDFLARE_API_TOKEN=placeholder$' "$ROOT/.local/caddy.env"; then
    note 'The Cloudflare token needs Zone Read and DNS Edit for this domain.'
    token=''
    ask_secret token 'Cloudflare API token'
    [[ $token =~ ^[a-zA-Z0-9_-]+$ && ${token,,} != placeholder ]] || die 'Enter a real Cloudflare API token, or choose Caddy none.'
    sed -i '/^CLOUDFLARE_API_TOKEN=/d' "$ROOT/.local/caddy.env"
    printf '\nCLOUDFLARE_API_TOKEN=%s\n' "$token" >>"$ROOT/.local/caddy.env"
    unset token
  fi
  chown "$ADMIN_USER:$admin_group" "$ROOT/.local/caddy.env"
  install -d -m 0700 /data/caddy /data/caddy/data /data/caddy/config
  ufw allow 80/tcp comment 'Caddy HTTP'
  ufw allow 443/tcp comment 'Caddy HTTPS'
  ufw allow 443/udp comment 'Caddy HTTP3'
fi

if [[ $VPN != none ]]; then
  if [[ $VPN == tailscale ]]; then
    step 'Set up Tailscale'
    if [[ ! -f $ROOT/.local/tailscale.env ]]; then
      ask_secret token 'Tailscale auth key, or Enter to log in through the browser'
      [[ $token =~ ^[a-zA-Z0-9_-]*$ ]] || die 'That auth key has unexpected characters. Paste the key on its own.'
      printf 'VPN_HOSTNAME=%s\nTS_AUTHKEY=%s\n' "$SERVER_HOSTNAME" "$token" >"$ROOT/.local/tailscale.env"
      unset token
    fi
    chown "$ADMIN_USER:$admin_group" "$ROOT/.local/tailscale.env"
    chmod 0600 "$ROOT/.local/tailscale.env"
    install -d -m 0700 /data/tailscale
  fi
fi
if [[ $CADDY_MODE == docker ]]; then
  stack=caddy
  apply_stack
fi
if [[ $VPN == tailscale ]]; then
  stack=tailscale
  apply_stack
elif [[ $VPN == wireguard ]]; then
  bash "$ROOT/scripts/install-wireguard.sh"
fi
if [[ $CADDY_MODE == none && $VPN == none ]]; then
  note 'No optional services selected.'
else
  note 'Services are up. Settings and keys are in /opt/vps/.local.'
fi
if [[ $VPN == tailscale ]]; then printf 'Run make login-vpn if Tailscale still needs a login.\n'; fi
