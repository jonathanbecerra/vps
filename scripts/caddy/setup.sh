#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
preview_if_requested setup-caddy "$@"
require_root
detect_os
[[ $ROOT == /opt/vps ]] || die 'Run this command from /opt/vps.'
[[ ! -d /var/lib/vps-setup/ssh-pending ]] || die 'Confirm SSH access before configuring services.'
load_config /etc/vps-setup/host.conf
validate_config
setup_lock

caddy_user=caddy
if ! getent group "$caddy_user" >/dev/null; then groupadd --system "$caddy_user"; fi
if ! id "$caddy_user" >/dev/null 2>&1; then
  useradd --system --gid "$caddy_user" --home-dir /var/lib/caddy --shell /usr/sbin/nologin "$caddy_user"
fi
install -d -o root -g "$caddy_user" -m 0755 /etc/caddy /etc/caddy/sites-available /etc/caddy/sites-enabled
install -d -o caddy -g caddy -m 0750 /var/lib/caddy /var/log/caddy /run/caddy
install -d -o root -g root -m 0755 /var/www
if [[ ! -f /etc/caddy/Caddyfile ]] || ! cmp -s "$ROOT/config/caddy/Caddyfile" /etc/caddy/Caddyfile; then
  [[ ! -e /etc/caddy/Caddyfile ]] || backup /etc/caddy/Caddyfile
  install -m 0644 "$ROOT/config/caddy/Caddyfile" /etc/caddy/Caddyfile
fi
if [[ ! -f /etc/systemd/system/caddy.service ]] || ! cmp -s "$ROOT/config/caddy/caddy.service" /etc/systemd/system/caddy.service; then
  [[ ! -e /etc/systemd/system/caddy.service ]] || backup /etc/systemd/system/caddy.service
  install -m 0644 "$ROOT/config/caddy/caddy.service" /etc/systemd/system/caddy.service
fi

site_file=/etc/caddy/sites-available/example.com.caddy
if ! compgen -G '/etc/caddy/sites-enabled/*.caddy' >/dev/null; then
  install -d -o "$ADMIN_USER" -g "$caddy_user" -m 0755 /var/www/example.com /var/www/example.com/errors
  install -o "$ADMIN_USER" -g "$caddy_user" -m 0644 \
    "$ROOT/config/caddy/www/index.html" /var/www/example.com/index.html
  for status in 404 500; do
    install -o "$ADMIN_USER" -g "$caddy_user" -m 0644 \
      "$ROOT/config/caddy/www/errors/$status.html" "/var/www/example.com/errors/$status.html"
  done
  [[ ! -e $site_file ]] || backup "$site_file"
  cat >"$site_file" <<'EOF'
:80 {
  import security
  root * /var/www/example.com

  handle_errors {
    rewrite * /errors/{err.status_code}.html
    file_server
  }

  file_server {
    hide .git .git/* .env .env.* *.pem *.key *.log
  }
}
EOF
  chown root:"$caddy_user" "$site_file"
  chmod 0644 "$site_file"
  ln -sfn ../sites-available/example.com.caddy /etc/caddy/sites-enabled/example.com.caddy
fi

step 'Build and install Caddy'
bash "$ROOT/scripts/caddy/build.sh"
step 'Validate the Caddy configuration'
/usr/local/bin/caddy validate --config /etc/caddy/Caddyfile
systemctl daemon-reload
ufw allow 80/tcp comment 'Caddy HTTP'
ufw allow 443/tcp comment 'Caddy HTTPS'
ufw allow 443/udp comment 'Caddy HTTP3'

mapfile -t legacy_ids < <(docker ps -q --filter label=com.docker.compose.service=caddy)
if ((${#legacy_ids[@]})); then
  note 'Stopping the old Caddy container before starting the service.'
  docker update --restart=no "${legacy_ids[@]}" >/dev/null
  docker stop "${legacy_ids[@]}" >/dev/null
fi

sed -i '/^CADDY_MODE=/d' /etc/vps-setup/host.conf
printf 'CADDY_MODE=service\n' >>/etc/vps-setup/host.conf
systemctl enable caddy
if systemctl is-active --quiet caddy; then
  systemctl reload caddy
else
  systemctl start caddy
fi
systemctl is-active --quiet caddy || die 'Caddy did not start.'
note 'Caddy is running with the example site at /var/www/example.com.'
