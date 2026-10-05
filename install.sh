#!/bin/sh
# One entry point for a checkout or curl .../install.sh | sh.
set -eu

case ${1:-} in
  --help | -h)
    printf 'Usage: ./install.sh [--mode basic|advanced] [--key PUBLIC_KEY_FILE] [--config HOST.conf]\n'
    exit 0
    ;;
esac
case ${DRY_RUN:-0} in
  0 | 1) ;;
  *)
    printf 'DRY_RUN must be 0 or 1.\n' >&2
    exit 1
    ;;
esac

install_vps() {
  if [ "${DRY_RUN:-0}" != 1 ] && [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ "${VPS_NO_CLEAR:-0}" != 1 ]; then
    printf '\033[H\033[2J'
  fi
  checkout=''
  if [ -f "$0" ]; then
    checkout=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
  fi
  if [ -z "$checkout" ] || [ ! -f "$checkout/scripts/setup.sh" ]; then
    checkout=/opt/vps
    if [ -f "$checkout/install.sh" ]; then
      printf 'Using /opt/vps. Pull updates there before rerunning setup.\n'
      [ -f "$checkout/scripts/setup.sh" ] || {
        printf 'Update /opt/vps first, then run /opt/vps/install.sh.\n' >&2
        exit 1
      }
    fi
  fi
  if [ "${DRY_RUN:-0}" = 1 ]; then
    [ -f "$checkout/scripts/setup.sh" ] || {
      printf 'Clone the project before running a dry run. No files were downloaded.\n' >&2
      exit 1
    }
    bash "$checkout/scripts/setup.sh" "$@"
    return
  fi
  [ "$(uname -s)" = Linux ] || {
    printf 'Run this on the Ubuntu box.\n' >&2
    exit 1
  }
  # shellcheck source=/dev/null
  . /etc/os-release
  [ "$ID" = ubuntu ] || {
    printf 'This installer supports Ubuntu.\n' >&2
    exit 1
  }
  if [ "$(id -u)" -eq 0 ]; then
    elevate() { "$@"; }
  else
    elevate() { sudo -p 'VPS setup needs sudo. Password for %p: ' --preserve-env=SSH_CONNECTION "$@"; }
  fi
  if [ ! -f "$checkout/scripts/setup.sh" ]; then
    if ! command -v git >/dev/null 2>&1; then
      elevate apt-get -o DPkg::Lock::Timeout=300 update
      elevate apt-get -o DPkg::Lock::Timeout=300 install -y git ca-certificates
    fi
    download=$(mktemp -d)
    trap 'rm -rf -- "$download"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    printf 'Download VPS and its pinned dotfiles checkout.\n'
    checkout="$download/vps"
    git clone --quiet --branch "${VPS_REF:-main}" --recurse-submodules \
      https://github.com/jonathanbecerra/vps.git "$checkout" || {
      printf 'Download failed. A private repository needs an authenticated clone or rsync.\n' >&2
      exit 1
    }
  fi
  elevate env VPS_NO_CLEAR=1 bash "$checkout/scripts/setup.sh" "$@"
}

# Restore the pipe after prompts finish so sh reaches EOF and exits.
# A permanent `exec </dev/tty` leaves a piped shell waiting for more commands.
if [ "${DRY_RUN:-0}" = 1 ]; then
  install_vps "$@"
else
  install_vps "$@" </dev/tty
fi
