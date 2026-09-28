#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
preview_if_requested apply-stack "$@"
case ${STACK:-} in caddy | tailscale) ;; *) die 'Set STACK=caddy or tailscale.' ;; esac
if [[ -z ${HOST:-} ]]; then exec bash "$ROOT/scripts/configure-services.sh" apply "$STACK"; fi
[[ $HOST =~ ^([a-z_][a-z0-9_-]*@)?[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || die 'Set HOST to an SSH alias or user@hostname.'
begin "Apply $STACK on $HOST"
ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes)
step 'Check SSH access and /opt/vps permissions'
ssh "${ssh_options[@]}" "$HOST" 'test "$(id -u)" -ne 0 && test -w /opt/vps' || die 'Use the admin account from setup.'
step 'Apply the stack on the host'
# STACK is restricted to the three names above before it enters a remote shell.
# shellcheck disable=SC2029
ssh "${ssh_options[@]}" "$HOST" "bash /opt/vps/scripts/configure-services.sh apply $STACK"
