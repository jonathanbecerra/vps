#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
preview_if_requested build-caddy "$@"
require_root
[[ $ROOT == /opt/vps ]] || die 'Run this command from /opt/vps.'
command -v docker >/dev/null || die 'Install Docker before building Caddy.'
docker info >/dev/null || die 'Docker is not ready.'

begin 'Build Caddy with Cloudflare DNS'
note 'Docker build output follows; this may take several minutes on a Raspberry Pi.'
temporary=$(mktemp -d)
container=
cleanup_build() {
  [[ -z $container ]] || docker rm "$container" >/dev/null 2>&1 || true
  rm -rf "$temporary"
}
trap cleanup_build EXIT

progress 'Build the Caddy binary' --interactive docker build --progress=plain --pull --target builder \
  --tag vps-caddy-builder:2.11.4 "$ROOT/build/caddy"
container=$(docker create vps-caddy-builder:2.11.4)
progress 'Copy the Caddy binary' docker cp "$container:/usr/bin/caddy" "$temporary/caddy"
install -m 0755 "$temporary/caddy" /usr/local/bin/caddy
if ! /usr/local/bin/caddy list-modules | grep -Fxq dns.providers.cloudflare; then
  die 'The Caddy binary does not contain the Cloudflare DNS module.'
fi
note 'Cloudflare DNS module is installed.'
