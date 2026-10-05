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

# Exercise the real guide with inert host operations and file-backed answers.
flow="$temporary/flow"
mkdir -p "$flow/scripts/"{os,ssh,caddy,vpn}
cp "$ROOT/scripts/lib.sh" "$flow/scripts/lib.sh"
cat >>"$flow/scripts/lib.sh" <<'FIXTURE'
require_root() { :; }
detect_os() { :; }
migrate_legacy_config() { :; }
setup_lock() { :; }
release_setup_lock() { :; }
write_caddy_config() { printf 'caddy-mode=%s\n' "$CADDY_MODE" >>"$ROOT/trace"; }
hostname() { printf 'fixture-host\n'; }
usermod() { printf 'shell\n' >>"$ROOT/trace"; }
ask() {
  local reply
  read -r reply
  printf -v "$1" '%s' "${reply:-${3:-}}"
}
VPS_HOST_CONFIG="$ROOT/host.conf"
VPS_CONFIG_DIR="$ROOT"
CADDY_CONFIG="$ROOT/caddy.conf"
FIXTURE
cat >"$flow/scripts/os/install-base.sh" <<'FIXTURE'
install_base() {
  printf 'base=%s\n' "$1" >>"$ROOT/trace"
  write_host_config
}
FIXTURE
cat >"$flow/scripts/ssh/handoff.sh" <<'FIXTURE'
ssh_handoff() {
  printf 'ssh\n' >>"$ROOT/trace"
  ssh_result=${FIXTURE_SSH_RESULT:-Confirmed / keys only}
}
FIXTURE
for script in caddy/setup vpn/configure os/install-dotfiles os/show-status; do
  cat >"$flow/scripts/$script.sh" <<'FIXTURE'
#!/usr/bin/env bash
printf '%s\n' "${0##*/}" >>"$ROOT/trace"
if [[ $0 == */show-status.sh ]]; then
  printf 'fixture-health-details\n'
  exit "${FIXTURE_HEALTH_STATUS:-0}"
fi
FIXTURE
done
sed -e "s|/dev/tty|$flow/answers|g" \
  -e "s|/var/lib/vps-setup|$flow/state|g" "$ROOT/setup-vps.sh" >"$flow/setup-vps.sh"
run_flow() {
  printf '%s\n' "$@" >"$flow/answers"
  : >"$flow/trace"
  env SUDO_USER=admin bash "$flow/setup-vps.sh" </dev/null >"$flow/output" 2>&1
}
run_flow 1 y
grep -q 'Setup complete' "$flow/output" || die 'Basic did not finish.'
grep -q 'Unchanged' "$flow/output" || die 'Basic misreported SSH hardening.'
if grep -qx ssh "$flow/trace"; then die 'Basic entered the SSH handoff.'; fi
if grep -q fixture-health-details "$flow/output"; then die 'Routine health output was not hidden.'; fi
grep -qx 'ADMIN_USER=admin' "$flow/host.conf" || die 'Basic did not save the account for a later run.'
run_flow 2 '' '' y 1 2 1
grep -q 'admin@fixture-host' "$flow/output" || die 'Advanced did not reuse the Basic account and hostname.'
grep -q 'Confirmed / keys only' "$flow/output" || die 'Advanced lost the SSH result.'
grep -qx 'caddy-mode=private' "$flow/trace" || die 'Advanced lost the Caddy choice.'
grep -qx install-dotfiles.sh "$flow/trace" || die 'Advanced skipped dotfiles.'
run_flow 2 '' '' yes 2
if grep -Eq '^(setup.sh|configure.sh|install-dotfiles.sh|shell|show-status.sh)$' "$flow/trace"; then
  die 'Advanced started services or dotfiles after Stop.'
fi
FIXTURE_SSH_RESULT='Not confirmed / rolled back' run_flow 2 '' '' yes 1 1 1
grep -q 'SSH hardening was not confirmed' "$flow/output" || die 'Completion hid unconfirmed SSH.'
if FIXTURE_HEALTH_STATUS=7 run_flow 1 yes; then
  die 'A failed health check passed setup.'
fi
grep -q fixture-health-details "$flow/output" || die 'Setup hid a failed health check.'
if grep -q 'Setup complete' "$flow/output"; then die 'Setup claimed success after a failure.'; fi
printf 'SSH receipt/key guards, guided flow fixtures, and setup/VPN previews passed.\n'
