#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
preview_if_requested configure-services "$@"
[[ $(uname -s) == Linux ]] || die 'Run service commands on the Linux host, or use make apply-stack HOST=... STACK=...'
load_config /etc/vps-setup/host.conf
action=${1:-configure}
stack=${2:-}
caddy_only=no
vpn_only=no
reconfigure_caddy=no
if [[ $action == configure ]]; then
  shift
  while (($#)); do
    case $1 in
      --enable-caddy) CADDY_MODE=docker ;;
      --caddy-only) caddy_only=yes ;;
      --vpn-only) vpn_only=yes ;;
      --reconfigure-caddy) reconfigure_caddy=yes ;;
      --vpn=*) VPN=${1#*=} ;;
      *) die 'Usage: configure-services.sh configure [--enable-caddy] [--vpn=NAME] [--caddy-only|--vpn-only] [--reconfigure-caddy]' ;;
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
    caddy) [[ $CADDY_MODE == docker ]] || die 'Caddy is off. Run make configure-caddy to start it.' ;;
    tailscale) [[ $VPN == "$stack" ]] || die "VPN is set to $VPN. Run make configure-services to change it." ;;
    *) die 'Choose STACK=caddy or tailscale.' ;;
  esac
  if [[ ! -f $ROOT/.local/$stack.env ]]; then
    [[ $stack != caddy ]] || die 'Run make configure-caddy on the host first.'
    die 'Run make configure-services on the host first.'
  fi
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
[[ $ROOT == /opt/vps ]] || die 'Run this command from /opt/vps.'
[[ ! -d /var/lib/vps-setup/ssh-pending ]] || die 'Confirm SSH access before starting services.'
setup_lock
caddy_sites_tmp=
cleanup_services() {
  [[ -z $caddy_sites_tmp ]] || rm -f "$caddy_sites_tmp"
  release_setup_lock
}
trap cleanup_services EXIT
if [[ $caddy_only == no && $VPN == wireguard && -z $WG_ENDPOINT ]]; then
  ask WG_ENDPOINT 'WireGuard public IPv4 address or DNS name'
fi
validate_config
if [[ $vpn_only == no && $CADDY_MODE != docker && -n $(docker ps -q --filter label=com.docker.compose.project=vps-caddy) ]]; then
  die 'Stop Caddy before disabling it.'
fi
if [[ $caddy_only == no && $VPN != tailscale ]] && [[ -n $(docker ps -q --filter label=com.docker.compose.project=vps-tailscale) ]]; then
  die 'Stop Tailscale before choosing another VPN. Keep a public SSH connection open.'
fi
if [[ $caddy_only == no && $VPN != wireguard ]] && systemctl is-active --quiet wg-quick@wg0; then
  die 'Stop WireGuard before choosing another VPN. Keep a public SSH connection open.'
fi
if [[ $caddy_only == no && $VPN == tailscale && ! -c /dev/net/tun ]]; then die '/dev/net/tun is missing. Enable the tun kernel module on this host.'; fi
admin_group=$(id -gn "$ADMIN_USER")
install -d -o "$ADMIN_USER" -g "$admin_group" -m 0700 "$ROOT/.local"
umask 077

caddy_domains=()
caddy_upstreams=()
caddy_pending=no
ask_caddy_site() {
  local site upstream port previous
  site=
  upstream=
  ask site 'Site hostname, e.g. app.example.com'
  ask upstream 'Upstream host:port, or Enter to add later'
  site=${site,,}
  [[ $site =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ && ${#site} -le 253 ]] ||
    die 'Enter a public hostname without a scheme or path.'
  if [[ -n $upstream ]]; then
    [[ $upstream =~ ^[a-zA-Z0-9.-]+:[0-9]{1,5}$ ]] || die 'Enter an upstream as host:port.'
    port=${upstream##*:}
    ((10#$port >= 1 && 10#$port <= 65535)) || die 'Invalid upstream port.'
  fi
  for previous in "${caddy_domains[@]}"; do
    [[ $previous != "$site" ]] || die "That hostname is already listed: $site"
  done
  caddy_domains+=("$site")
  caddy_upstreams+=("$upstream")
}

configure_caddy_sites() {
  local layout index replace=no sites_file="$ROOT/.local/caddy-sites.caddy"
  [[ ! -L $sites_file ]] || die "Use a regular file for $sites_file."
  if [[ $reconfigure_caddy == yes && -e $sites_file ]]; then
    ask replace "Replace the saved routes in $sites_file? This overwrites the current site list" no
    case "$replace" in yes | no) ;; *) die 'Choose yes or no.' ;; esac
  fi
  if [[ -s $sites_file && $replace != yes ]]; then
    if grep -Fq 'example.com' "$sites_file"; then
      caddy_pending=yes
      note "Finish editing $sites_file, then run make configure-services."
      return
    fi
    if ! grep -Eq '^[[:space:]]*(reverse_proxy[[:space:]]+|file_server([[:space:]]|$))' "$sites_file"; then
      caddy_pending=yes
      note "Add a reverse_proxy or file_server site to $sites_file, then run make configure-services."
      return
    fi
    note "Using saved Caddy routes from $sites_file."
    chown "$ADMIN_USER:$admin_group" "$sites_file"
    chmod 0644 "$sites_file"
    return
  fi
  layout=single
  ask layout 'Caddy apps? single or multiple' single
  case "$layout" in
    single) ask_caddy_site ;;
    multiple)
      install -o "$ADMIN_USER" -g "$admin_group" -m 0644 \
        "$ROOT/stacks/caddy/caddy-sites-example.caddy" "$sites_file"
      caddy_pending=yes
      note "Edit $sites_file in vim, replace the example hosts and upstreams, then run make configure-services."
      return
      ;;
    *) die 'Choose single or multiple.' ;;
  esac
  caddy_sites_tmp=$(mktemp "$ROOT/.local/caddy-sites.XXXXXX")
  for index in "${!caddy_domains[@]}"; do
    printf '%s {\n  tls {\n    dns cloudflare {env.CLOUDFLARE_API_TOKEN}\n    propagation_delay 2m\n    resolvers 1.1.1.1\n  }\n' "${caddy_domains[index]}" >>"$caddy_sites_tmp"
    if [[ -n ${caddy_upstreams[index]} ]]; then
      printf '  reverse_proxy %s {\n    header_up -X-Forwarded-For\n  }\n' "${caddy_upstreams[index]}" >>"$caddy_sites_tmp"
    else
      printf '  # Add reverse_proxy host:port or a root and file_server when ready.\n' >>"$caddy_sites_tmp"
      caddy_pending=yes
    fi
    printf '}\n\n' >>"$caddy_sites_tmp"
  done
  chown "$ADMIN_USER:$admin_group" "$caddy_sites_tmp"
  chmod 0644 "$caddy_sites_tmp"
  mv "$caddy_sites_tmp" "$sites_file"
  caddy_sites_tmp=
  if [[ $caddy_pending == yes ]]; then
    note "Add a reverse_proxy or file_server site to $sites_file, then run make configure-services."
  else
    note 'Caddy route saved.'
  fi
}

if [[ $vpn_only == no && $CADDY_MODE != none ]]; then
  step 'Set up Caddy'
  configure_caddy_sites
  if [[ $caddy_pending == no && ! -f $ROOT/.local/caddy.env ]]; then
    install -o "$ADMIN_USER" -g "$admin_group" -m 0600 /dev/null "$ROOT/.local/caddy.env"
  fi
  if [[ $caddy_pending == no ]]; then
    chmod 0600 "$ROOT/.local/caddy.env"
    grep -q '^TZ=' "$ROOT/.local/caddy.env" || printf 'TZ=America/New_York\n' >>"$ROOT/.local/caddy.env"
    sed -i '/^CADDY_SITE=/d; /^CADDY_UPSTREAM=/d' "$ROOT/.local/caddy.env"
  fi
  if [[ $caddy_pending == no ]] && { ! grep -qE '^CLOUDFLARE_API_TOKEN=[a-zA-Z0-9_-]+$' "$ROOT/.local/caddy.env" ||
    grep -Eiq '^CLOUDFLARE_API_TOKEN=placeholder$' "$ROOT/.local/caddy.env"; }; then
    note 'The token needs Zone Read and DNS Edit access to each site zone.'
    token=''
    ask_secret token 'Cloudflare API token'
    [[ $token =~ ^[a-zA-Z0-9_-]+$ && ${token,,} != placeholder ]] || die 'Enter a real Cloudflare API token.'
    sed -i '/^CLOUDFLARE_API_TOKEN=/d' "$ROOT/.local/caddy.env"
    printf '\nCLOUDFLARE_API_TOKEN=%s\n' "$token" >>"$ROOT/.local/caddy.env"
    unset token
  fi
  if [[ $caddy_pending == no ]]; then chown "$ADMIN_USER:$admin_group" "$ROOT/.local/caddy.env"; fi
fi
if [[ $vpn_only == no && $caddy_pending == yes ]] &&
  [[ -n $(docker ps -q --filter label=com.docker.compose.project=vps-caddy) ]]; then
  stack=caddy
  progress 'Stop Caddy until its routes are ready' compose stop caddy
fi

if [[ $caddy_only == no && $VPN != none ]]; then
  if [[ $VPN == tailscale ]]; then
    step 'Set up Tailscale'
    if [[ ! -f $ROOT/.local/tailscale.env ]]; then
      ask_secret token 'Tailscale auth key, or Enter to log in through the browser'
      [[ $token =~ ^[a-zA-Z0-9_-]*$ ]] || die 'That auth key has unexpected characters. Paste the key on its own.'
      printf 'VPN_HOSTNAME=%s\nTS_AUTHKEY=%s\n' "$SERVER_HOSTNAME" "$token" >"$ROOT/.local/tailscale.env"
      unset token
    fi
  fi
fi
step 'Save service choices'
for key in SERVER_HOSTNAME ADMIN_USER CADDY_MODE VPN WG_ENDPOINT INSTALL_FONT SECURITY_UPDATES; do
  printf '%s=%s\n' "$key" "${!key}"
done >/etc/vps-setup/host.conf
chmod 0644 /etc/vps-setup/host.conf
if [[ $vpn_only == no && $CADDY_MODE == docker && $caddy_pending == no ]]; then
  install -d -m 0700 /data/caddy /data/caddy/data /data/caddy/config
  install -d -o "$ADMIN_USER" -g "$admin_group" -m 0755 /data/www/blog
  if [[ ! -e /data/www/blog/index.html ]]; then
    install -o "$ADMIN_USER" -g "$admin_group" -m 0644 \
      "$ROOT/stacks/caddy/www/blog/index.html" /data/www/blog/index.html
  fi
  ufw allow 80/tcp comment 'Caddy HTTP'
  ufw allow 443/tcp comment 'Caddy HTTPS'
  ufw allow 443/udp comment 'Caddy HTTP3'
fi
if [[ $caddy_only == no && $VPN == tailscale ]]; then
  chown "$ADMIN_USER:$admin_group" "$ROOT/.local/tailscale.env"
  chmod 0600 "$ROOT/.local/tailscale.env"
  install -d -m 0700 /data/tailscale
fi
if [[ $vpn_only == no && $CADDY_MODE == docker && $caddy_pending == no ]]; then
  stack=caddy
  apply_stack
fi
if [[ $caddy_only == no && $VPN == tailscale ]]; then
  stack=tailscale
  apply_stack
elif [[ $caddy_only == no && $VPN == wireguard ]]; then
  bash "$ROOT/scripts/install-wireguard.sh"
fi
if [[ $caddy_pending == yes ]]; then
  :
elif [[ $caddy_only == yes ]]; then
  note 'Caddy is up.'
elif [[ $CADDY_MODE == none && $VPN == none ]]; then
  note 'No optional services selected.'
else
  note 'Services are up. Settings and keys are in /opt/vps/.local.'
fi
if [[ $caddy_only == no && $VPN == tailscale ]]; then printf 'Run make login-vpn if Tailscale still needs a login.\n'; fi
