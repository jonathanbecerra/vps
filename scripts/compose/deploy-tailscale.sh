#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
preview_if_requested deploy-tailscale "$@"
case ${STACK:-} in tailscale) ;; *) die 'This command only deploys Tailscale.' ;; esac
if [[ -z ${HOST:-} ]]; then exec bash "$ROOT/scripts/compose/configure-services.sh" apply "$STACK"; fi
[[ $HOST =~ ^([a-z_][a-z0-9_-]*@)?[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || die 'Set HOST to an SSH alias or user@hostname.'
begin "Deploy Tailscale to $HOST"
ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes)
step 'Check SSH access and /opt/vps permissions'
ssh "${ssh_options[@]}" "$HOST" 'test "$(id -u)" -ne 0 && test -w /opt/vps' || die 'Use the admin account from setup.'
step 'Apply the Tailscale stack on the host'
# STACK is restricted to tailscale before it enters a remote shell.
# shellcheck disable=SC2029
ssh "${ssh_options[@]}" "$HOST" "bash /opt/vps/scripts/compose/configure-services.sh apply $STACK"
