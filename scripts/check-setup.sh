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

# Dummy tokens only. Check saved values without sourcing an environment file.
ask_secret() {
  local answer
  read -r answer
  printf -v "$1" '%s' "$answer"
}
token_file="$temporary/caddy.env"
: >"$token_file"
configure_cloudflare_token "$token_file" >"$temporary/token-output" 2>&1 <<<'
invalid value
dummy-token_123'
grep -qx 'CLOUDFLARE_API_TOKEN=dummy-token_123' "$token_file" || die 'Token was not saved after retrying invalid input.'
grep -qF "Cloudflare token saved to $token_file" "$temporary/token-output" || die 'Token save omitted its location.'
if grep -q dummy-token "$temporary/token-output"; then die 'Token appeared in setup output.'; fi
for saved in dummy-token_123 '"dummy-token_123"' "'dummy-token_123'" '  dummy-token_123  '; do
  printf 'CLOUDFLARE_API_TOKEN=%s\n' "$saved" >"$token_file"
  cp "$token_file" "$temporary/saved-token"
  configure_cloudflare_token "$token_file" </dev/null >"$temporary/token-output"
  cmp -s "$token_file" "$temporary/saved-token" || die 'Setup replaced an existing token.'
  if grep -q dummy-token "$temporary/token-output"; then die 'Existing token appeared in setup output.'; fi
done
for saved in '' '   ' '""' "''"; do
  printf 'CLOUDFLARE_API_TOKEN=old-dummy-token\nCLOUDFLARE_API_TOKEN=%s\n' "$saved" >"$token_file"
  configure_cloudflare_token "$token_file" >"$temporary/token-output" <<<'dummy-token_123'
  [[ $(tail -n 1 "$token_file") == CLOUDFLARE_API_TOKEN=dummy-token_123 ]] || die 'An empty final token assignment bypassed the prompt.'
done
# shellcheck disable=SC2016
printf 'CLOUDFLARE_API_TOKEN=$(touch %s)\n' "$temporary/token-executed" >"$token_file"
configure_cloudflare_token "$token_file" >"$temporary/token-output" <<<'dummy-token_123'
[[ ! -e $temporary/token-executed ]] || die 'Setup executed token file contents.'

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
fixture_sshd() {
  [[ ${FIXTURE_POLICY_ERROR:-0} == 0 ]] || return 1
  printf '%s\n' "$*" >"$ROOT/policy-args"
  printf 'passwordauthentication %s\nauthenticationmethods %s\n' "${FIXTURE_PASSWORD_AUTH:-yes}" "${FIXTURE_AUTH_METHODS:-any}"
  printf 'pubkeyauthentication %s\n' "${FIXTURE_PUBKEY_AUTH:-yes}"
}
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
  -e 's|/usr/sbin/sshd|fixture_sshd|g' \
  -e "s|/var/lib/vps-setup|$flow/state|g" "$ROOT/setup-vps.sh" >"$flow/setup-vps.sh"
run_flow() {
  printf '%s\n' "$@" >"$flow/answers"
  : >"$flow/trace"
  env SUDO_USER=admin SSH_CONNECTION="${FIXTURE_CONNECTION:-}" bash "$flow/setup-vps.sh" </dev/null >"$flow/output" 2>&1
}
run_flow 1 y
grep -q 'Setup complete' "$flow/output" || die 'Basic did not finish.'
grep -q 'Unchanged' "$flow/output" || die 'Basic misreported SSH hardening.'
if grep -qx ssh "$flow/trace"; then die 'Basic entered the SSH handoff.'; fi
if grep -q fixture-health-details "$flow/output"; then die 'Routine health output was not hidden.'; fi
grep -qx 'ADMIN_USER=admin' "$flow/host.conf" || die 'Basic did not save the account for a later run.'
grep -q '● ● ● ●  Setup complete' "$flow/output" || die 'Basic left its progress unfinished.'
grep -q 'Log out and log back in to activate Zsh and Docker group access.' "$flow/output" || die 'Completion omitted the required fresh login.'
grep -q 'log in again as admin' "$flow/output" || die 'Console login omitted the selected account.'
grep -qF 'ssh -p PORT admin@HOST' "$flow/output" || die 'Basic omitted its login command.'
grep -qF 'ssh-copy-id -i ~/.ssh/id_ed25519.pub -p PORT admin@HOST' "$flow/output" || die 'Basic omitted optional key setup.'
grep -q 'Copying a key does not disable password or root SSH login.' "$flow/output" || die 'Basic confused copying a key with hardening.'
grep -q 'forwarded port shown by make list-vm' "$flow/output" || die 'Completion omitted the VM port reminder.'
if grep -Eq 'Status:|Rerun:' "$flow/output"; then die 'Completion still shows maintenance commands.'; fi
if grep -q 'sudo reboot' "$flow/output"; then die 'Basic showed the confirmed-SSH reboot instruction.'; fi

FIXTURE_PASSWORD_AUTH=no run_flow 1 y
grep -q 'Use your existing SSH authentication' "$flow/output" || die 'Basic ignored disabled password login.'
if grep -Eq 'account password when prompted|ssh-copy-id' "$flow/output"; then die 'Basic offered password login when disabled.'; fi
FIXTURE_AUTH_METHODS=publickey,password run_flow 1 y
if grep -Eq 'account password when prompted|ssh-copy-id' "$flow/output"; then die 'Basic treated multi-factor SSH as password-only access.'; fi
FIXTURE_AUTH_METHODS=password run_flow 1 y
grep -q 'account password when prompted' "$flow/output" || die 'Basic missed an explicit password method.'
if grep -q ssh-copy-id "$flow/output"; then die 'Basic offered key login when only passwords are allowed.'; fi
FIXTURE_AUTH_METHODS='publickey password' run_flow 1 y
grep -q ssh-copy-id "$flow/output" || die 'Basic missed separate password and key login methods.'
FIXTURE_PUBKEY_AUTH=no run_flow 1 y
if grep -q ssh-copy-id "$flow/output"; then die 'Basic offered key login when public-key authentication is disabled.'; fi
FIXTURE_POLICY_ERROR=1 run_flow 1 y
grep -q 'Could not check SSH authentication' "$flow/output" || die 'Completion hid a policy lookup failure.'
if grep -Eq 'account password when prompted|ssh-copy-id' "$flow/output"; then die 'Basic offered password login without a policy check.'; fi
FIXTURE_CONNECTION='192.0.2.10 50000 192.0.2.20 22' run_flow 1 y
grep -q 'Open a fresh SSH connection' "$flow/output" || die 'SSH completion showed console-only instructions.'
grep -q 'Keep this session open until the new login works' "$flow/output" || die 'Completion told the user to close their only working SSH session.'
grep -qF 'user=admin,addr=192.0.2.10,laddr=192.0.2.20,lport=22' "$flow/policy-args" || die 'Password instructions ignored the current connection context.'
if grep -q 'admin@192.0.2.20' "$flow/output"; then die 'Completion assumed the guest address was reachable from the Mac.'; fi

run_flow 2 '' '' y 1 2 1
grep -q 'admin@fixture-host' "$flow/output" || die 'Advanced did not reuse the Basic account and hostname.'
grep -q 'Confirmed / keys only' "$flow/output" || die 'Advanced lost the SSH result.'
grep -qx 'caddy-mode=private' "$flow/trace" || die 'Advanced lost the Caddy choice.'
grep -qx install-dotfiles.sh "$flow/trace" || die 'Advanced skipped dotfiles.'
grep -q '● ● ● ● ●  Setup complete' "$flow/output" || die 'Advanced left its progress unfinished.'
grep -qF 'sudo reboot' "$flow/output" || die 'Confirmed Advanced setup omitted the reboot instruction.'
grep -q 'reconnect with your verified key' "$flow/output" || die 'Advanced omitted the verified-key reminder.'
if grep -Eq 'account password when prompted|ssh-copy-id|admin@HOST|From your Mac|forwarded port|log in again as|Open a fresh SSH connection' "$flow/output"; then
  die 'Confirmed Advanced setup still shows the Basic login tutorial.'
fi
FIXTURE_CONNECTION='192.0.2.10 50000 192.0.2.20 22' run_flow 2 '' '' y 1 1 1
grep -qF 'sudo reboot' "$flow/output" || die 'Advanced over SSH omitted the reboot instruction.'
if grep -q 'Open a fresh SSH connection' "$flow/output"; then die 'Advanced over SSH still shows the Basic footer.'; fi
run_flow 2 '' '' yes 2
if grep -Eq '^(setup.sh|configure.sh|install-dotfiles.sh|shell|show-status.sh)$' "$flow/trace"; then
  die 'Advanced started services or dotfiles after Stop.'
fi
FIXTURE_SSH_RESULT='Not confirmed / rolled back' run_flow 2 '' '' yes 1 1 1
grep -q 'SSH hardening was not confirmed' "$flow/output" || die 'Completion hid unconfirmed SSH.'
if grep -Eq 'reconnect with your verified key|sudo reboot|SSH hardening is confirmed' "$flow/output"; then die 'Rollback claimed a verified key login or instructed a reboot.'; fi
if FIXTURE_HEALTH_STATUS=7 run_flow 1 yes; then
  die 'A failed health check passed setup.'
fi
grep -q fixture-health-details "$flow/output" || die 'Setup hid a failed health check.'
if grep -q 'Setup complete' "$flow/output"; then die 'Setup claimed success after a failure.'; fi
run_flow 2 '' deploy y 1 1 1
grep -qF 'deploy@fixture-host' "$flow/output" || die 'Advanced hard-coded the admin username.'
FIXTURE_SSH_RESULT='Not confirmed / rolled back' run_flow 2 '' deploy y 1 1 1
grep -qF 'ssh -p PORT deploy@HOST' "$flow/output" || die 'Recovery login hard-coded the admin username.'
printf 'SSH receipt/key guards, guided flow fixtures, and setup/VPN previews passed.\n'
