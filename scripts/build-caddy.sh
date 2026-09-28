#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
preview_if_requested build-caddy "$@"
find_compose
begin 'Build Caddy with Cloudflare DNS'
progress 'Verify pinned Caddy images' env STACK=caddy bash "$ROOT/scripts/lock-images.sh" verify
progress 'Build the Caddy image' "${COMPOSE[@]}" --env-file "$ROOT/.env.example" \
  -f "$ROOT/stacks/caddy/compose.yaml" -f "$ROOT/stacks/caddy/compose.lock.json" build --pull caddy
