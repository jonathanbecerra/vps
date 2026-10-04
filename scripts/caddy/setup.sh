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

if [[ $CADDY_MODE == none ]]; then
  note 'Caddy is disabled for this host.'
  exit 0
fi

caddy_user=caddy
if ! getent group "$caddy_user" >/dev/null; then groupadd --system "$caddy_user"; fi
if ! id "$caddy_user" >/dev/null 2>&1; then
  useradd --system --gid "$caddy_user" --home-dir /var/lib/caddy --shell /usr/sbin/nologin "$caddy_user"
fi
admin_group=$(id -gn "$ADMIN_USER")
install -d -o root -g "$caddy_user" -m 0755 /etc/caddy /etc/caddy/sites-available /etc/caddy/sites-enabled
install -d -o caddy -g caddy -m 0750 /var/lib/caddy /var/log/caddy /run/caddy
install -d -o root -g root -m 0755 /var/www /var/app
if [[ ! -e /etc/caddy/caddy.env ]]; then
  install -o root -g "$caddy_user" -m 0640 /dev/null /etc/caddy/caddy.env
fi
if [[ ! -f /etc/caddy/Caddyfile ]] || ! cmp -s "$ROOT/config/caddy/Caddyfile" /etc/caddy/Caddyfile; then
  [[ ! -e /etc/caddy/Caddyfile ]] || backup /etc/caddy/Caddyfile
  install -m 0644 "$ROOT/config/caddy/Caddyfile" /etc/caddy/Caddyfile
fi
if [[ ! -f /etc/systemd/system/caddy.service ]] || ! cmp -s "$ROOT/config/caddy/caddy.service" /etc/systemd/system/caddy.service; then
  [[ ! -e /etc/systemd/system/caddy.service ]] || backup /etc/systemd/system/caddy.service
  install -m 0644 "$ROOT/config/caddy/caddy.service" /etc/systemd/system/caddy.service
fi

setup_hono() {
  local app_dir=/var/app/hono
  [[ -e "$app_dir/compose.yaml" ]] || {
    install -d -o "$ADMIN_USER" -g "$admin_group" -m 0755 "$app_dir"
    cp -a "$ROOT/examples/hono/." "$app_dir/"
    chown -R "$ADMIN_USER:$admin_group" "$app_dir"
  }
  find_compose
  progress 'Build and start Hono example' --interactive "${COMPOSE[@]}" \
    -f "$app_dir/compose.yaml" up -d --build
}

if [[ $CADDY_MODE == public ]]; then
  if ! compgen -G '/etc/caddy/sites-enabled/*.caddy' >/dev/null; then
    site_file=/etc/caddy/sites-available/example.com.caddy
    install -d -o "$ADMIN_USER" -g "$caddy_user" -m 0755 /var/www/example.com /var/www/example.com/errors
    install -o "$ADMIN_USER" -g "$caddy_user" -m 0644 \
      "$ROOT/config/caddy/www/example.com/index.html" /var/www/example.com/index.html
    for status in 404 500; do
      install -o "$ADMIN_USER" -g "$caddy_user" -m 0644 \
        "$ROOT/config/caddy/www/example.com/errors/$status.html" "/var/www/example.com/errors/$status.html"
    done
    install -o root -g "$caddy_user" -m 0644 \
      "$ROOT/config/caddy/sites/example.com.caddy" "$site_file"
    ln -sfn "../sites-available/$(basename "$site_file")" "/etc/caddy/sites-enabled/$(basename "$site_file")"
  fi
else
  if ! compgen -G '/etc/caddy/sites-enabled/*.caddy' >/dev/null; then
    site_file=/etc/caddy/sites-available/hono.ohmstack.net.caddy
    install -o root -g "$caddy_user" -m 0644 \
      "$ROOT/config/caddy/sites/hono.ohmstack.net.caddy" "$site_file"
    ln -sfn "../sites-available/$(basename "$site_file")" "/etc/caddy/sites-enabled/$(basename "$site_file")"
  fi
  if [[ -e /etc/caddy/sites-enabled/hono.ohmstack.net.caddy ]]; then setup_hono; fi
fi

step 'Build and install Caddy'
bash "$ROOT/scripts/caddy/build.sh"
step 'Validate the Caddy configuration'
/usr/local/bin/caddy validate --config /etc/caddy/Caddyfile
systemctl daemon-reload
if [[ $CADDY_MODE == public ]]; then
  ufw allow 80/tcp comment 'Caddy HTTP'
  ufw allow 443/tcp comment 'Caddy HTTPS'
  ufw allow 443/udp comment 'Caddy HTTP3'
else
  private_interface=$(ip -o route show default | awk 'NR == 1 {print $5}')
  [[ -n $private_interface ]] || die 'Cannot identify the private network interface for Caddy.'
  ufw allow in on "$private_interface" to any port 80 proto tcp comment 'Caddy HTTP (private)'
  ufw allow in on "$private_interface" to any port 443 proto tcp comment 'Caddy HTTPS (private)'
fi

mapfile -t legacy_ids < <(docker ps -q --filter label=com.docker.compose.service=caddy)
if ((${#legacy_ids[@]})); then
  note 'Stopping the old Caddy container before starting the service.'
  docker update --restart=no "${legacy_ids[@]}" >/dev/null
  docker stop "${legacy_ids[@]}" >/dev/null
fi

systemctl enable caddy
if systemctl is-active --quiet caddy; then
  systemctl reload caddy
else
  systemctl start caddy
fi
systemctl is-active --quiet caddy || die 'Caddy did not start.'
if [[ $CADDY_MODE == public ]]; then
  note 'Caddy is running with the example site at /var/www/example.com.'
elif [[ -e /etc/caddy/sites-enabled/hono.ohmstack.net.caddy ]]; then
  note 'Caddy is running privately with hono.ohmstack.net backed by /var/app/hono.'
else
  note 'Caddy is running privately with the existing site configuration.'
fi
