#!/usr/bin/env bash
# Local fixtures only. This does not configure SSH or any host services.
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=scripts/ssh/handoff.sh
source "$ROOT/scripts/ssh/handoff.sh"
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT

[[ $(ssh_handoff_state "$temporary" current) == rolled-back ]] || die 'Missing state was treated as confirmation.'
printf 'previous\n' >"$temporary/ssh-confirmed"
[[ $(ssh_handoff_state "$temporary" current) == rolled-back ]] || die 'Accepted an old confirmation.'
printf 'current\n' >"$temporary/ssh-confirmed"
wait_for_ssh_confirmation "$temporary" current 0 fixture-boot >/dev/null || die 'Did not recognize the matching receipt.'
mkdir "$temporary/ssh-pending"
printf 'current\n' >"$temporary/ssh-pending/id"
[[ $(ssh_handoff_state "$temporary" current) == pending ]] || die 'A receipt bypassed a pending handoff.'
[[ $(ssh_handoff_state "$temporary" another) == changed ]] || die 'Accepted another pending attempt.'
mv "$temporary/ssh-pending" "$temporary/rolled-back"
if wait_for_ssh_confirmation "$temporary" another 0 fixture-boot >/dev/null; then
  die 'Rollback was treated as confirmation.'
fi

ssh-keygen -q -t ed25519 -N '' -C fixture -f "$temporary/key"
valid_public_keys "$temporary/key.pub" || die 'Rejected a valid public key.'
if valid_public_keys "$temporary/key"; then die 'Accepted a private key as authorized_keys.'; fi
printf 'not a key\n' >"$temporary/invalid"
if valid_public_keys "$temporary/invalid"; then die 'Accepted an invalid key.'; fi

basic=$(DRY_RUN=1 bash "$ROOT/setup-vps.sh" --mode basic)
advanced=$(DRY_RUN=1 bash "$ROOT/setup-vps.sh" --mode advanced)
grep -q 'Keep the current non-root account' <<<"$basic" || die 'Basic no longer preserves identity.'
if grep -q 'passwd\|vps-rollback-ssh' <<<"$basic"; then die 'Basic changed SSH or a password.'; fi
grep -q 'live countdown' <<<"$advanced" || die 'Advanced is missing the SSH handoff.'
grep -q 'install dotfiles as the admin user' <<<"$advanced" || die 'Advanced is missing dotfiles.'
if DRY_RUN=1 bash "$ROOT/setup-vps.sh" --mode invalid >/dev/null 2>&1; then die 'Accepted an invalid mode.'; fi
STACK=tailscale DRY_RUN=1 bash "$ROOT/scripts/vpn/lock-tailscale.sh" verify >/dev/null
vpn=$(DRY_RUN=1 bash "$ROOT/scripts/vpn/configure.sh" configure --vpn=tailscale)
grep -q 'up -d --no-build' <<<"$vpn" || die 'VPN preview did not include starting Tailscale.'
printf 'SSH receipt/key guards and basic, advanced, and VPN previews passed.\n'
