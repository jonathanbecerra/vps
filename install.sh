#!/bin/sh
# Keep the download entry point POSIX-compatible: curl .../install.sh | sh.
set -eu

install_vps() {
  exec </dev/tty
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
    elevate() { sudo --preserve-env=SSH_CONNECTION "$@"; }
  fi
  if [ -f /opt/vps/setup-vps.sh ]; then
    printf 'Using /opt/vps. Pull updates there before rerunning setup.\n'
    elevate bash /opt/vps/setup-vps.sh "$@"
    return
  fi
  if ! command -v git >/dev/null 2>&1; then
    elevate apt-get -o DPkg::Lock::Timeout=300 update
    elevate apt-get -o DPkg::Lock::Timeout=300 install -y git ca-certificates
  fi
  checkout=$(mktemp -d)
  trap 'rm -rf -- "$checkout"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  printf 'Download VPS and its pinned dotfiles checkout.\n'
  git clone --branch "${VPS_REF:-main}" --recurse-submodules \
    https://github.com/jonathanbecerra/vps.git "$checkout/vps" || {
    printf 'Download failed. A private repository needs an authenticated clone or rsync.\n' >&2
    exit 1
  }
  elevate bash "$checkout/vps/setup-vps.sh" "$@"
}

install_vps "$@"
