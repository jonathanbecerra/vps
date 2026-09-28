#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
preview_if_requested deploy-stack "$@"
[[ -n ${HOST:-} ]] || die 'Set HOST to your SSH alias.'
case "${STACK:-}" in caddy | tailscale) ;; *) die 'Set STACK=caddy or tailscale.' ;; esac
cd "$ROOT"
begin "Deploy $STACK to $HOST"
export VPS_NO_CLEAR=1
step 'Check shell and configuration'
make check-repo
step 'Preview files to sync'
make preview-deploy
step 'Sync files'
make sync-repo
step 'Apply the stack'
make apply-stack
