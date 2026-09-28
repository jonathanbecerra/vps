#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
action=${1:-lock}
case "$action" in lock | verify) ;; *) die 'Use lock-images.sh lock|verify.' ;; esac
preview_if_requested "${action}-images" "$@"
find_compose
begin "$action container image locks"
stacks=(caddy)
if [[ -n ${STACK:-} ]]; then
  case "$STACK" in caddy) stacks=("$STACK") ;; *) die 'Set STACK=caddy.' ;; esac
fi
temporary=$(mktemp -d "$ROOT/.image-lock.XXXXXX")
trap 'rm -rf "$temporary"' EXIT

for stack in "${stacks[@]}"; do
  source_file="$ROOT/stacks/$stack/compose.yaml"
  # Compose skips local builds, so resolve Caddy's two FROM images separately.
  if [[ $stack == caddy ]]; then source_file="$ROOT/stacks/caddy/images.yaml"; fi
  lock="$ROOT/stacks/$stack/compose.lock.json"
  step "Resolve $stack image versions"
  progress "Resolve $stack image digests" "${COMPOSE[@]}" --env-file "$ROOT/.env.example" -f "$source_file" \
    config --lock-image-digests --output "$temporary/locked.yaml"
  "${COMPOSE[@]}" --env-file "$ROOT/.env.example" -f "$source_file" -f "$temporary/locked.yaml" \
    config --format json >"$temporary/resolved.json"
  if [[ $stack == caddy ]]; then
    jq -S '{services: {caddy: {build: {args: {
      CADDY_BUILDER_IMAGE: .services.builder.image,
      CADDY_RUNTIME_IMAGE: .services.runtime.image
    }}}}}' "$temporary/resolved.json" >"$temporary/$stack.json"
  else
    jq -S '{services: (.services | map_values({image: .image}))}' "$temporary/resolved.json" >"$temporary/$stack.json"
  fi
  if [[ $action == lock ]]; then
    chmod 0644 "$temporary/$stack.json"
    mv "$temporary/$stack.json" "$lock"
    note "Locked $stack."
  else
    [[ -f $lock ]] || die "Missing $stack lock. Run make lock-images STACK=$stack."
    if ! cmp -s "$lock" "$temporary/$stack.json"; then
      diff -u "$lock" "$temporary/$stack.json" || true
      die "$stack images changed. Review the diff, then run make lock-images STACK=$stack."
    fi
    note "$stack lock matches."
  fi
  "${COMPOSE[@]}" --env-file "$ROOT/.env.example" -f "$ROOT/stacks/$stack/compose.yaml" -f "$lock" config --quiet
done
