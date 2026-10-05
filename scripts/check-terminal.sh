#!/usr/bin/env bash
# Local fixtures only: no package installs, downloads, or host configuration.
export NO_COLOR=1
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
grep -qxF 'Start setup? [y/N]' "$temporary/prompts" || die 'Confirmation is indented or missing its safe default.'
phase 3 4 Dotfiles >"$temporary/phase"
grep -q '3/4  Dotfiles' "$temporary/phase" || die 'Phase heading lost its position or label.'
phase 4 4 'Setup complete' complete >"$temporary/phase"
grep -q '● ● ● ●  Setup complete' "$temporary/phase" || die 'Completion did not finish every phase.'
if grep -q '[◉○]' "$temporary/phase"; then die 'Completion still shows an unfinished phase.'; fi
if grep -q '4/4' "$temporary/phase"; then die 'Completion still shows the stage count.'; fi

# Replace only machine paths. Exercise the entry point without host changes.
mkdir -p "$temporary/bin" "$temporary/installed/scripts" "$temporary/local checkout/scripts"
printf 'ID=ubuntu\n' >"$temporary/os-release"
cat >"$temporary/setup.sh" <<'FIXTURE'
#!/bin/sh
[ "$#" = 2 ] && [ "$1" = --mode ] && [ "$2" = basic ] || exit 81
printf '%s\n' "$0" >"$BOOTSTRAP_FIXTURE/guide-path"
if [ "${DRY_RUN:-0}" = 1 ]; then
  printf 'Preview only.\n'
  exit 0
fi
[ "${VPS_NO_CLEAR:-}" = 1 ] || exit 83
read -r answer
[ "$answer" = ready ] || exit 82
printf 'Setup finished.\n'
exit "${FIXTURE_RESULT:-0}"
FIXTURE
cat >"$temporary/bin/uname" <<'FIXTURE'
#!/bin/sh
printf 'uname\n' >>"$BOOTSTRAP_FIXTURE/trace"
printf 'Linux\n'
FIXTURE
cat >"$temporary/bin/id" <<'FIXTURE'
#!/bin/sh
printf 'id\n' >>"$BOOTSTRAP_FIXTURE/trace"
printf '%s\n' "${FIXTURE_UID:-0}"
FIXTURE
cat >"$temporary/bin/sudo" <<'FIXTURE'
#!/bin/sh
[ "$1" = -p ] || exit 84
shift 2
[ "$1" = --preserve-env=SSH_CONNECTION ] || exit 85
shift
[ "${SSH_CONNECTION:-}" = '192.0.2.10 50000 192.0.2.20 22' ] || exit 86
printf 'sudo\n' >>"$BOOTSTRAP_FIXTURE/trace"
exec "$@"
FIXTURE
cat >"$temporary/bin/git" <<'FIXTURE'
#!/bin/sh
printf 'git %s\n' "$*" >>"$BOOTSTRAP_FIXTURE/trace"
for destination do :; done
mkdir -p "$destination/scripts"
cp "$BOOTSTRAP_FIXTURE/setup.sh" "$destination/scripts/setup.sh"
FIXTURE
cat >"$temporary/bin/mktemp" <<'FIXTURE'
#!/bin/sh
exec /usr/bin/mktemp -d "$BOOTSTRAP_FIXTURE/download.XXXXXX"
FIXTURE
chmod +x "$temporary/bin/"*
sed -e "s|/etc/os-release|$temporary/os-release|g" \
  -e "s|/opt/vps|$temporary/installed|g" \
  -e "s|/dev/tty|$temporary/terminal|g" "$ROOT/install.sh" >"$temporary/install.sh"
cp "$temporary/install.sh" "$temporary/local checkout/install.sh"
cp "$temporary/setup.sh" "$temporary/local checkout/scripts/setup.sh"
chmod +x "$temporary/local checkout/install.sh"
# The mock installer consumes 'ready'. A leaked stdin consumes 'exit 93' as code
# after setup, reproducing the silent hang without an actual blocking terminal.
printf 'ready\nexit 93\n' >"$temporary/terminal"
run_bootstrap() {
  local launch=$1
  shift
  : >"$temporary/trace"
  case $launch in
    pipe)
      cat "$temporary/install.sh" | env PATH="$temporary/bin:$PATH" BOOTSTRAP_FIXTURE="$temporary" \
        "$shell" -s -- "$@"
      ;;
    local)
      env PATH="$temporary/bin:$PATH" BOOTSTRAP_FIXTURE="$temporary" \
        "$shell" "$temporary/local checkout/install.sh" "$@" </dev/null
      ;;
  esac
}
for shell in /bin/sh /bin/dash; do
  [[ -x $shell ]] || continue
  for existing in no yes; do
    if [[ $existing == yes ]]; then
      cp "$temporary/install.sh" "$temporary/installed/install.sh"
      cp "$temporary/setup.sh" "$temporary/installed/scripts/setup.sh"
    fi
    for launch in pipe local; do
      run_bootstrap "$launch" --mode basic >"$temporary/bootstrap" || die "$launch $shell did not finish (existing checkout: $existing)."
      grep -q 'Setup finished.' "$temporary/bootstrap" || die 'Bootstrap did not run setup.'
      if [[ $launch == local ]]; then
        grep -qxF "$temporary/local checkout/scripts/setup.sh" "$temporary/guide-path" || die 'Local install used another checkout.'
      elif [[ $existing == yes ]]; then
        grep -qxF "$temporary/installed/scripts/setup.sh" "$temporary/guide-path" || die 'Piped install ignored the installed checkout.'
      else
        grep -q '^git clone --quiet --branch main --recurse-submodules ' "$temporary/trace" || die 'Piped install did not download main with dotfiles.'
      fi
      if [[ $launch == local || $existing == yes ]] && grep -q '^git ' "$temporary/trace"; then
        die 'Bootstrap downloaded an unnecessary checkout.'
      fi
      if FIXTURE_RESULT=7 run_bootstrap "$launch" --mode basic >"$temporary/bootstrap"; then
        die 'Bootstrap swallowed a setup failure.'
      else
        [[ $? == 7 ]] || die 'Bootstrap changed the failure status.'
      fi
      if compgen -G "$temporary/download.*" >/dev/null; then die 'Bootstrap left its temporary download behind.'; fi
    done
  done
  FIXTURE_UID=1000 SSH_CONNECTION='192.0.2.10 50000 192.0.2.20 22' run_bootstrap local --mode basic >"$temporary/bootstrap"
  grep -qx sudo "$temporary/trace" || die 'Local install did not request sudo for a regular user.'
  # Help and dry runs need neither a terminal nor root, even on the Mac.
  for launch in pipe local; do
    run_bootstrap "$launch" --help >"$temporary/bootstrap"
    grep -qF 'Usage: ./install.sh' "$temporary/bootstrap" || die 'Install help is missing.'
    [[ ! -s $temporary/trace ]] || die 'Help performed host operations.'
    DRY_RUN=1 run_bootstrap "$launch" --mode basic >"$temporary/bootstrap"
    grep -q 'Preview only.' "$temporary/bootstrap" || die 'Install did not forward the dry run.'
    [[ ! -s $temporary/trace ]] || die 'Dry run performed host operations.'
  done
  rm -f "$temporary/installed/scripts/setup.sh"
  if run_bootstrap pipe --mode basic >"$temporary/bootstrap" 2>&1; then die 'Bootstrap accepted an outdated installed checkout.'; fi
  grep -q 'Update .* first' "$temporary/bootstrap" || die 'Bootstrap did not explain how to update an old checkout.'
  [[ ! -s $temporary/trace ]] || die 'Bootstrap changed the host before rejecting an old checkout.'
  rm -f "$temporary/installed/install.sh"
  if DRY_RUN=1 run_bootstrap pipe --mode basic >"$temporary/bootstrap" 2>&1; then die 'Dry run downloaded a missing checkout.'; fi
  [[ ! -s $temporary/trace ]] || die 'Dry run without a checkout performed host operations.'
done
printf 'Menu, progress, and local/piped installer checks passed.\n'
