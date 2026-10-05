#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
preview_if_requested setup-caddy "$@"
require_root
detect_os
[[ $ROOT == /opt/vps ]] || die 'Run this command from /opt/vps.'
[[ ! -d /var/lib/vps-setup/ssh-pending ]] || die 'Confirm SSH access before configuring services.'
load_config "$VPS_HOST_CONFIG"
validate_config
setup_lock

clear_caddy_ufw_rules() {
  local rule
  local -a rules=()
  mapfile -t rules < <(
    ufw status numbered |
      sed -nE '/# Caddy (HTTP|HTTPS|HTTP3)/s/^[[:space:]]*\[[[:space:]]*([0-9]+)\].*/\1/p' |
      sort -rn
  )
  for rule in "${rules[@]}"; do
    ufw --force delete "$rule" >/dev/null
  done
}

disable_bootstrap_site() {
  local link=$1 target
  [[ -L $link ]] || return 0
  target=$(readlink "$link")
  [[ $target == "../sites-available/${link##*/}" ]] || return 0
  rm -f -- "$link"
}

if [[ ! -f $CADDY_CONFIG ]]; then
  [[ $CADDY_MODE != public ]] || CADDY_MODE=private
  ask CADDY_MODE 'Caddy role? public, private, or none' "$CADDY_MODE"
  validate_config
  write_caddy_config
fi

if [[ -f $VPS_HOST_CONFIG ]] && grep -Eq '^[[:space:]]*CADDY_MODE=' "$VPS_HOST_CONFIG"; then
  backup "$VPS_HOST_CONFIG"
  sed -Ei '/^[[:space:]]*CADDY_MODE=/d' "$VPS_HOST_CONFIG"
fi

admin_group=$(id -gn "$ADMIN_USER")
install -d -o "$ADMIN_USER" -g "$admin_group" -m 0755 \
  /var/www/ohmstack.net /var/www/ohmstack.net/errors /var/app/hono.ohmstack.net

ensure_static_example() {
  [[ -f /var/www/ohmstack.net/index.html ]] || install -o "$ADMIN_USER" -g "$admin_group" -m 0644 \
    "$ROOT/config/caddy/www/ohmstack.net/index.html" /var/www/ohmstack.net/index.html
  for status in 404 500; do
    [[ -f /var/www/ohmstack.net/errors/$status.html ]] || install -o "$ADMIN_USER" -g "$admin_group" -m 0644 \
      "$ROOT/config/caddy/www/ohmstack.net/errors/$status.html" "/var/www/ohmstack.net/errors/$status.html"
  done
}

ensure_hono_app() {
  local app_dir=/var/app/hono.ohmstack.net
  [[ -e "$app_dir/compose.yaml" ]] || {
    cp -a "$ROOT/build/hono/." "$app_dir/"
    chown -R "$ADMIN_USER:$admin_group" "$app_dir"
  }
}

ensure_static_example
ensure_hono_app

if [[ $CADDY_MODE == none ]]; then
  clear_caddy_ufw_rules
  disable_bootstrap_site /etc/caddy/sites-enabled/example.com.caddy
  disable_bootstrap_site /etc/caddy/sites-enabled/ohmstack.net.caddy
  disable_bootstrap_site /etc/caddy/sites-enabled/hono.ohmstack.net.caddy
  if [[ $(systemctl show -p LoadState --value caddy.service) != not-found ]]; then
    progress 'Disable Caddy' systemctl disable --now caddy
  fi
  note 'Caddy is disabled for this host.'
  exit 0
fi

caddy_user=caddy
if ! getent group "$caddy_user" >/dev/null; then groupadd --system "$caddy_user"; fi
if ! id "$caddy_user" >/dev/null 2>&1; then
  useradd --system --gid "$caddy_user" --home-dir /var/lib/caddy --shell /usr/sbin/nologin "$caddy_user"
fi
install -d -o root -g "$caddy_user" -m 0755 /etc/caddy /etc/caddy/sites-available /etc/caddy/sites-enabled
install -d -o caddy -g caddy -m 0750 /var/lib/caddy /var/log/caddy /run/caddy
install -d -o root -g root -m 0755 /var/www /var/app
if [[ ! -e /etc/caddy/caddy.env ]]; then
  install -o root -g "$caddy_user" -m 0640 /dev/null /etc/caddy/caddy.env
fi
if [[ $CADDY_MODE == private ]]; then
  configure_cloudflare_token /etc/caddy/caddy.env
else
  note 'Cloudflare token file: /etc/caddy/caddy.env. Public mode does not prompt for a token.'
fi
if [[ ! -f /etc/caddy/Caddyfile ]] || ! cmp -s "$ROOT/config/caddy/Caddyfile" /etc/caddy/Caddyfile; then
  [[ ! -e /etc/caddy/Caddyfile ]] || backup /etc/caddy/Caddyfile
  install -m 0644 "$ROOT/config/caddy/Caddyfile" /etc/caddy/Caddyfile
fi
if [[ ! -f /etc/systemd/system/caddy.service ]] || ! cmp -s "$ROOT/config/caddy/caddy.service" /etc/systemd/system/caddy.service; then
  [[ ! -e /etc/systemd/system/caddy.service ]] || backup /etc/systemd/system/caddy.service
  install -m 0644 "$ROOT/config/caddy/caddy.service" /etc/systemd/system/caddy.service
fi

start_hono() {
  local app_dir=/var/app/hono.ohmstack.net
  find_compose
  progress 'Build and start Hono example' "${COMPOSE[@]}" \
    -f "$app_dir/compose.yaml" up -d --build
}

if [[ $CADDY_MODE == public ]]; then
  disable_bootstrap_site /etc/caddy/sites-enabled/hono.ohmstack.net.caddy
  disable_bootstrap_site /etc/caddy/sites-enabled/example.com.caddy
  if ! compgen -G '/etc/caddy/sites-enabled/*.caddy' >/dev/null; then
    site_file=/etc/caddy/sites-available/ohmstack.net.caddy
    [[ -e $site_file ]] || install -o root -g "$caddy_user" -m 0644 \
      "$ROOT/config/caddy/sites/ohmstack.net.caddy" "$site_file"
    ln -sfn "../sites-available/$(basename "$site_file")" "/etc/caddy/sites-enabled/$(basename "$site_file")"
  fi
else
  disable_bootstrap_site /etc/caddy/sites-enabled/example.com.caddy
  disable_bootstrap_site /etc/caddy/sites-enabled/ohmstack.net.caddy
  site_file=/etc/caddy/sites-available/hono.ohmstack.net.caddy
  [[ -e $site_file ]] || install -o root -g "$caddy_user" -m 0644 \
    "$ROOT/config/caddy/sites/hono.ohmstack.net.caddy" "$site_file"
  ln -sfn "../sites-available/$(basename "$site_file")" "/etc/caddy/sites-enabled/$(basename "$site_file")"
  start_hono
fi

step 'Build and install Caddy'
bash "$ROOT/scripts/caddy/build.sh"
progress 'Validate the Caddy configuration' validate_caddy
systemctl daemon-reload
clear_caddy_ufw_rules
if [[ $CADDY_MODE == public ]]; then
  progress 'Allow public HTTP' ufw allow 80/tcp comment 'Caddy HTTP'
  progress 'Allow public HTTPS' ufw allow 443/tcp comment 'Caddy HTTPS'
  progress 'Allow public HTTP/3' ufw allow 443/udp comment 'Caddy HTTP3'
else
  private_interface=$(ip -o route show default | awk 'NR == 1 {print $5}')
  [[ -n $private_interface ]] || die 'Cannot identify the private network interface for Caddy.'
  progress "Allow HTTP on $private_interface" ufw allow in on "$private_interface" to any port 80 proto tcp comment 'Caddy HTTP (private)'
  progress "Allow HTTPS on $private_interface" ufw allow in on "$private_interface" to any port 443 proto tcp comment 'Caddy HTTPS (private)'
fi

mapfile -t legacy_ids < <(docker ps -q --filter label=com.docker.compose.service=caddy)
if ((${#legacy_ids[@]})); then
  note 'Stopping the old Caddy container before starting the service.'
  docker update --restart=no "${legacy_ids[@]}" >/dev/null
  docker stop "${legacy_ids[@]}" >/dev/null
fi

progress 'Enable Caddy at boot' systemctl enable caddy
# Setup can replace the binary, unit, or environment, which requires a restart.
progress 'Start Caddy' systemctl restart caddy
systemctl is-active --quiet caddy || die 'Caddy did not start.'
if [[ $CADDY_MODE == public ]]; then
  note 'Caddy is running with the example site at /var/www/ohmstack.net.'
elif [[ -e /etc/caddy/sites-enabled/hono.ohmstack.net.caddy ]]; then
  note 'Caddy is running privately with hono.ohmstack.net backed by /var/app/hono.ohmstack.net.'
else
  note 'Caddy is running privately with the existing site configuration.'
fi
