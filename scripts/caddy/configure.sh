#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
preview_if_requested configure-caddy "$@"
require_root
detect_os
[[ $ROOT == /opt/vps ]] || die 'Run this command from /opt/vps.'
[[ ! -d /var/lib/vps-setup/ssh-pending ]] || die 'Confirm SSH access before configuring Caddy.'
load_config /etc/vps-setup/host.conf
validate_config
setup_lock

site=
site_type=
upstream=
token=
ask site 'Site hostname, e.g. example.com'
site=${site,,}
[[ $site =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ && ${#site} -le 253 ]] ||
  die 'Enter a public hostname without a scheme or path.'
ask site_type 'Site type: static or docker' static
case "$site_type" in
  static | docker) ;;
  *) die 'Choose static or docker.' ;;
esac
if [[ $site_type == docker ]]; then
  ask upstream 'Docker upstream host:port, e.g. 127.0.0.1:3000'
  [[ $upstream =~ ^[a-zA-Z0-9.-]+:[0-9]{1,5}$ ]] || die 'Enter an upstream as host:port.'
  port=${upstream##*:}
  ((10#$port >= 1 && 10#$port <= 65535)) || die 'Invalid upstream port.'
fi

caddy_user=caddy
if ! getent group "$caddy_user" >/dev/null; then groupadd --system "$caddy_user"; fi
if ! id "$caddy_user" >/dev/null 2>&1; then
  useradd --system --gid "$caddy_user" --home-dir /var/lib/caddy --shell /usr/sbin/nologin "$caddy_user"
fi
install -d -o root -g "$caddy_user" -m 0755 /etc/caddy /etc/caddy/sites-available /etc/caddy/sites-enabled
install -d -o caddy -g caddy -m 0750 /var/lib/caddy /var/log/caddy /run/caddy
install -d -o root -g root -m 0755 /var/www
install -d -o "$ADMIN_USER" -g "$caddy_user" -m 0755 "/var/www/$site" "/var/www/$site/errors"
install -m 0644 "$ROOT/config/caddy/Caddyfile" /etc/caddy/Caddyfile
install -m 0644 "$ROOT/config/caddy/caddy.service" /etc/systemd/system/caddy.service

if [[ ! -f /etc/caddy/caddy.env ]] || ! grep -qE '^CLOUDFLARE_API_TOKEN=[a-zA-Z0-9_-]+$' /etc/caddy/caddy.env; then
  note 'The token needs Zone Read and DNS Edit access to the site zone.'
  ask_secret token 'Cloudflare API token'
  [[ $token =~ ^[a-zA-Z0-9_-]+$ && ${token,,} != placeholder ]] || die 'Enter a real Cloudflare API token.'
  printf 'CLOUDFLARE_API_TOKEN=%s\n' "$token" >/etc/caddy/caddy.env
  unset token
fi
chown root:"$caddy_user" /etc/caddy/caddy.env
chmod 0640 /etc/caddy/caddy.env

site_file="/etc/caddy/sites-available/$site.caddy"
if [[ -e $site_file || -L $site_file ]]; then backup "$site_file"; fi
{
  printf '%s {\n' "$site"
  printf '\timport security\n'
  printf '\ttls {\n\t\tdns cloudflare {env.CLOUDFLARE_API_TOKEN}\n\t\tpropagation_delay 2m\n\t\tresolvers 1.1.1.1\n\t}\n'
  printf '\troot * /var/www/%s\n' "$site"
  printf '\thandle_errors {\n\t\trewrite * /errors/{err.status_code}.html\n\t\tfile_server\n\t}\n'
  if [[ $site_type == static ]]; then
    printf '\tfile_server {\n\t\thide .git .git/* .env .env.* *.pem *.key *.log\n\t}\n'
  else
    printf '\treverse_proxy %s {\n\t\theader_up -X-Forwarded-For\n\t}\n' "$upstream"
  fi
  printf '}\n'
} >"$site_file"
chown root:"$caddy_user" "$site_file"
chmod 0644 "$site_file"
ln -sfn "../sites-available/$site.caddy" "/etc/caddy/sites-enabled/$site.caddy"

for status in 403 404 500 502; do
  if [[ ! -e /var/www/$site/errors/$status.html ]]; then
    install -o "$ADMIN_USER" -g "$caddy_user" -m 0644 /dev/null "/var/www/$site/errors/$status.html"
    printf '<!doctype html>\n<html lang="en"><meta charset="utf-8"><title>%s</title><h1>%s</h1><p>The requested page is unavailable.</p>\n' \
      "$status" "$status" >"/var/www/$site/errors/$status.html"
  fi
done

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
note "Caddy is running. Site $site is enabled at /etc/caddy/sites-enabled/$site.caddy."
