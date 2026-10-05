#!/usr/bin/env bash
# Local fixtures only: no package installs, downloads, or host configuration.
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT

progress 'Quiet success' printf 'routine output\n' >"$temporary/success"
grep -q 'Done: Quiet success' "$temporary/success" || die 'Missing progress completion.'
if grep -q 'routine output' "$temporary/success"; then die 'Successful progress leaked routine output.'; fi
if progress 'Failing step' bash -c 'echo failure-detail >&2; exit 7' >"$temporary/failure" 2>&1; then
  die 'A failed step passed.'
else
  [[ $? == 7 ]] || die 'Lost the failed command status.'
fi
grep -q failure-detail "$temporary/failure" || die 'Failure details were hidden.'
progress 'Caddy build' --interactive printf 'live build output\n' >"$temporary/live"
grep -q 'live build output' "$temporary/live" || die 'Interactive build output was hidden.'
if LC_ALL=C grep -q $'\033' "$temporary/success"; then die 'Progress wrote terminal escapes to a pipe.'; fi

# Feed menu answers without requiring a terminal in automated checks.
ask() {
  local reply
  printf '%s\n' "$2" >>"$temporary/prompts"
  read -r reply
  printf -v "$1" '%s' "${reply:-$3}"
}
choice=''
choose choice Setup basic basic 'Keep identity' advanced 'Configure SSH' >"$temporary/menu" 2>&1 <<<'invalid
2'
[[ $choice == advanced ]] || die 'Menu did not retry or accept a number.'
choose choice Setup basic basic 'Keep identity' advanced 'Configure SSH' >/dev/null <<<''
[[ $choice == basic ]] || die 'Menu did not keep the default.'
choose choice Setup basic basic 'Keep identity' advanced 'Configure SSH' >/dev/null <<<'advanced'
[[ $choice == advanced ]] || die 'Menu did not accept a name.'
grep -q 'Select setup' "$temporary/prompts" || die 'Menu is missing the short selection prompt.'
for answer in y Y yes YES; do
  confirm 'Start setup?' >/dev/null <<<"$answer"
done
for answer in '' n N no NO; do
  if (confirm 'Start setup?' <<<"$answer") >/dev/null 2>&1; then die 'Confirmation accepted No or the default.'; fi
done
confirm 'Start setup?' >/dev/null 2>&1 <<<'invalid
y'
grep -qF '[y/N]' "$temporary/prompts" || die 'Confirmation does not show its safe default.'
phase 3 4 Dotfiles >"$temporary/phase"
grep -q '3/4  Dotfiles' "$temporary/phase" || die 'Phase heading lost its position or label.'

# Replace only machine paths. The real bootstrap function and its redirection run.
mkdir -p "$temporary/bin" "$temporary/installed"
printf 'ID=ubuntu\n' >"$temporary/os-release"
cat >"$temporary/setup-vps.sh" <<'FIXTURE'
#!/bin/sh
[ "$*" = '--mode basic' ] || exit 81
[ "${VPS_NO_CLEAR:-}" = 1 ] || exit 83
read -r answer
[ "$answer" = ready ] || exit 82
printf 'Setup finished.\n'
exit "${FIXTURE_RESULT:-0}"
FIXTURE
cat >"$temporary/bin/uname" <<'FIXTURE'
#!/bin/sh
printf 'Linux\n'
FIXTURE
cat >"$temporary/bin/id" <<'FIXTURE'
#!/bin/sh
printf '0\n'
FIXTURE
cat >"$temporary/bin/git" <<'FIXTURE'
#!/bin/sh
for destination do :; done
mkdir -p "$destination"
cp "$BOOTSTRAP_FIXTURE/setup-vps.sh" "$destination/setup-vps.sh"
FIXTURE
cat >"$temporary/bin/mktemp" <<'FIXTURE'
#!/bin/sh
exec /usr/bin/mktemp -d "$BOOTSTRAP_FIXTURE/download.XXXXXX"
FIXTURE
chmod +x "$temporary/bin/"*
sed -e "s|/etc/os-release|$temporary/os-release|g" \
  -e "s|/opt/vps|$temporary/installed|g" \
  -e "s|/dev/tty|$temporary/terminal|g" "$ROOT/install.sh" >"$temporary/install.sh"
# The mock installer consumes 'ready'. A leaked stdin consumes 'exit 93' as code
# after setup, reproducing the silent hang without an actual blocking terminal.
printf 'ready\nexit 93\n' >"$temporary/terminal"
for shell in /bin/sh /bin/dash; do
  [[ -x $shell ]] || continue
  for existing in no yes; do
    if [[ $existing == yes ]]; then cp "$temporary/setup-vps.sh" "$temporary/installed/setup-vps.sh"; fi
    if ! cat "$temporary/install.sh" | env PATH="$temporary/bin:$PATH" BOOTSTRAP_FIXTURE="$temporary" \
      "$shell" -s -- --mode basic >"$temporary/bootstrap"; then
      die "Piped $shell did not finish cleanly (existing checkout: $existing)."
    fi
    grep -q 'Setup finished.' "$temporary/bootstrap" || die 'Bootstrap did not run setup.'
    if cat "$temporary/install.sh" | env PATH="$temporary/bin:$PATH" BOOTSTRAP_FIXTURE="$temporary" FIXTURE_RESULT=7 \
      "$shell" -s -- --mode basic >"$temporary/bootstrap"; then
      die 'Bootstrap swallowed a setup failure.'
    else
      [[ $? == 7 ]] || die 'Bootstrap changed the failure status.'
    fi
  done
  rm -f "$temporary/installed/setup-vps.sh"
done
printf 'Menu, progress, and piped installer checks passed.\n'
