#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
preview_if_requested build-caddy "$@"
begin 'Build Caddy with Cloudflare DNS'
progress 'Verify pinned image locks' bash "$ROOT/scripts/compose/lock-images.sh" verify
progress 'Build the Caddy image' compose --profile caddy build --pull caddy
