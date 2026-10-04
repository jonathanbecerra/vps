#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
action=${1:-lock}
case "$action" in lock | verify) ;; *) die 'Use lock-images.sh lock|verify.' ;; esac
[[ -z ${STACK:-} ]] || die 'Image locks cover every included service; run without STACK.'
preview_if_requested "${action}-images" "$@"
find_compose
begin "$action container image lock"
temporary=$(mktemp -d "$ROOT/.image-lock.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
locked="$temporary/compose.lock.yaml"

step 'Resolve image digests from the included Compose files'
progress 'Resolve image digests' "${COMPOSE[@]}" --env-file "$ROOT/.env.example" \
  -f "$ROOT/stacks/compose.yaml" --profile tailscale \
  config --lock-image-digests --output "$locked"

lock="$ROOT/stacks/compose.lock.yaml"
if [[ $action == lock ]]; then
  "${COMPOSE[@]}" --env-file "$ROOT/.env.example" -f "$ROOT/stacks/compose.yaml" \
    -f "$locked" --profile tailscale config --quiet
  chmod 0644 "$locked"
  mv "$locked" "$lock"
  note 'Updated stacks/compose.lock.yaml.'
else
  [[ -f $lock ]] || die 'Missing stacks/compose.lock.yaml. Run make lock-images.'
  if ! cmp -s "$lock" "$locked"; then
    diff -u "$lock" "$locked" || true
    die 'The image lock changed. Review it, then run make lock-images.'
  fi
  note 'Image lock matches.'
  "${COMPOSE[@]}" --env-file "$ROOT/.env.example" -f "$ROOT/stacks/compose.yaml" \
    -f "$lock" --profile tailscale config --quiet
fi
