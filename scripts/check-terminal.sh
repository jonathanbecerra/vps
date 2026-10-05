#!/usr/bin/env bash
# Local fixtures only: no package installs, downloads, or host configuration.
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT

# Replace only machine paths. The real bootstrap function and its redirection run.
mkdir -p "$temporary/bin" "$temporary/installed"
printf 'ID=ubuntu\n' >"$temporary/os-release"
cat >"$temporary/setup-vps.sh" <<'FIXTURE'
#!/bin/sh
[ "$*" = '--mode basic' ] || exit 81
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
printf 'Piped installer checks passed.\n'
