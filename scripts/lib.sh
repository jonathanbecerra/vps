#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export ROOT
WG_ENDPOINT=
C_RESET='' C_CYAN='' C_GREEN='' C_RED='' C_YELLOW=''
if [[ -t 1 && -z ${NO_COLOR+x} && ${TERM:-dumb} != dumb ]]; then
  C_RESET=$'\033[0m'
  C_CYAN=$'\033[36m'
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  # Used by setup handoff text in scripts that source this library.
  # shellcheck disable=SC2034
  C_YELLOW=$'\033[33m'
fi
if [[ $(uname -s) == Linux && ${DRY_RUN:-0} != 1 ]]; then
  export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
fi
trap 'printf "Stopped at %s:%s. See the error above.\n" "${BASH_SOURCE[0]}" "$LINENO" >&2' ERR

die() {
  printf '%sError:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
  exit 1
}
note() { printf '\n%s%s%s\n' "$C_CYAN" "$*" "$C_RESET"; }

clear_screen() {
  if [[ ${DRY_RUN:-0} != 1 && ${VPS_NO_CLEAR:-0} != 1 && -t 1 && ${TERM:-dumb} != dumb ]]; then
    printf '\033[H\033[2J'
  fi
}

begin() {
  clear_screen
  note "$1"
}

step() { printf '\n%s›%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }

progress() {
  local label=$1 log status frame=0 pid
  # Braille frames work in the terminals used for SSH and the local console.
  local -a frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴')
  shift
  if [[ ${DRY_RUN:-0} == 1 ]]; then
    run "$@"
    return
  fi
  log=$(mktemp)
  if [[ ! -t 1 || ${TERM:-dumb} == dumb ]]; then
    if "$@" >"$log" 2>&1; then
      rm -f "$log"
      printf 'Done: %s\n' "$label"
    else
      status=$?
      printf 'Failed: %s\n' "$label" >&2
      cat "$log" >&2
      rm -f "$log"
      return "$status"
    fi
    return 0
  fi

  "$@" >"$log" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r\033[K%s%s%s %s' "$C_CYAN" "${frames[frame]}" "$C_RESET" "$label"
    sleep 0.12
    frame=$(((frame + 1) % ${#frames[@]}))
  done
  if wait "$pid"; then
    printf '\r\033[K%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$label"
    rm -f "$log"
  else
    status=$?
    printf '\r\033[K%s✗%s %s\n' "$C_RED" "$C_RESET" "$label" >&2
    cat "$log" >&2
    rm -f "$log"
    return "$status"
  fi
}

setup_lock() {
  exec 9>/run/vps-setup.lock
  flock -n 9 || die 'Another setup step is running.'
  trap release_setup_lock EXIT
}

release_setup_lock() {
  flock -u 9 || true
}

case ${DRY_RUN:-0} in 0 | 1) ;; *) die 'DRY_RUN must be 0 or 1.' ;; esac

preview_if_requested() {
  [[ ${DRY_RUN:-0} == 1 ]] || return 0
  exec bash "$ROOT/scripts/preview.sh" "$@"
}

run() {
  if [[ ${DRY_RUN:-0} == 1 ]]; then
    printf '  $'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

require_root() {
  [[ $(uname -s) == Linux ]] || die 'Run this on the Linux box.'
  [[ $EUID == 0 ]] || die 'Run this with sudo.'
  [[ -d /run/systemd/system ]] || die 'This needs systemd running.'
}

detect_os() {
  # shellcheck source=/dev/null
  source /etc/os-release
  [[ $ID == ubuntu ]] || die "Found $ID. This setup supports Ubuntu."
  [[ -n ${VERSION_CODENAME:-} ]] || die 'No distro codename in /etc/os-release.'
  case "$(uname -m)" in
    x86_64 | aarch64) ARCH=$(uname -m) ;;
    *) die 'Use a 64-bit OS, x86_64 or aarch64.' ;;
  esac
  export ARCH VERSION_CODENAME
}

ask() {
  local variable=$1 label=$2 default=${3:-} reply
  [[ -t 0 ]] || die 'Run this in a terminal. Use ssh -t for a remote command.'
  read -r -p "$label${default:+ [$default]}: " reply
  printf -v "$variable" '%s' "${reply:-$default}"
}

confirm() {
  local answer
  ask answer "$1 Type yes" no
  [[ $answer == yes ]] || die 'Cancelled.'
}

ask_secret() {
  local variable=$1 label=$2 reply
  [[ -t 0 ]] || die 'Run this from a terminal so the key stays hidden.'
  read -rs -p "$label: " reply
  printf '\n'
  printf -v "$variable" '%s' "$reply"
}

# shellcheck disable=SC2034
find_compose() {
  if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
  elif command -v docker-compose >/dev/null; then
    COMPOSE=(docker-compose)
  else
    die 'Install Docker Compose first.'
  fi
}

# The shared project replaces the older per-service Compose projects.
remove_legacy_compose() {
  local stack=$1 env_file legacy_project="vps-$1"
  local -a env_args=(--env-file "$ROOT/.env.example")
  case "$stack" in caddy | tailscale) ;; *) die 'Choose Caddy or Tailscale.' ;; esac
  [[ -n $(docker ps -aq --filter "label=com.docker.compose.project=$legacy_project") ]] || return 0
  find_compose
  env_file="$ROOT/.local/$stack.env"
  [[ ! -f $env_file ]] || env_args+=(--env-file "$env_file")
  progress "Move $stack into the combined Compose project" "${COMPOSE[@]}" \
    "${env_args[@]}" --project-name "$legacy_project" -f "$ROOT/stacks/$stack/compose.yaml" \
    --profile "$stack" down
}

compose() {
  local env_file
  local -a env_args=(--env-file "$ROOT/.env.example")
  find_compose
  for env_file in "$ROOT/.local/caddy.env" "$ROOT/.local/tailscale.env"; do
    [[ ! -f $env_file ]] || env_args+=(--env-file "$env_file")
  done
  "${COMPOSE[@]}" "${env_args[@]}" -f "$ROOT/stacks/compose.yaml" \
    -f "$ROOT/stacks/compose.lock.yaml" "$@"
}

load_config() {
  local file=$1 key value
  [[ -f $file ]] || die "Config not found: $file"
  while IFS='=' read -r key value || [[ -n $key ]]; do
    [[ -z $key || $key == \#* ]] && continue
    case "$key" in
      SERVER_HOSTNAME | ADMIN_USER | CADDY_MODE | VPN | WG_ENDPOINT | SECURITY_UPDATES)
        printf -v "$key" '%s' "$value"
        ;;
      INSTALL_FONT) ;; # Legacy host configs carried this dotfiles setting.
      SERVICES_CONFIGURED) ;;
      *) die "Unknown config key: $key" ;;
    esac
  done <"$file"
}

validate_config() {
  [[ ${SERVER_HOSTNAME:-} =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die 'Use a short hostname, lowercase letters, numbers, and hyphens.'
  [[ ${ADMIN_USER:-} =~ ^[a-z_][a-z0-9_-]{0,30}$ && $ADMIN_USER != root ]] || die 'Pick a regular Linux username, not root.'
  case "${CADDY_MODE:-}" in docker | none) ;; *) die 'CADDY_MODE must be docker or none.' ;; esac
  case "${VPN:-}" in tailscale | wireguard | none) ;; *) die 'VPN must be tailscale, wireguard, or none.' ;; esac
  if [[ $VPN == wireguard && -n $WG_ENDPOINT ]]; then
    [[ $WG_ENDPOINT =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$ && $WG_ENDPOINT != *..* ]] ||
      die 'Set WG_ENDPOINT to a public IPv4 address or DNS name.'
  fi
  case "${SECURITY_UPDATES:-}" in yes | no) ;; *) die 'Use yes or no for SECURITY_UPDATES.' ;; esac
}

read_packages() {
  local file=$1 package
  PACKAGES=()
  [[ -f $file ]] || die "Package list not found: $file"
  while IFS= read -r package || [[ -n $package ]]; do
    package=${package%%#*}
    package="${package#"${package%%[![:space:]]*}"}"
    package="${package%"${package##*[![:space:]]}"}"
    [[ -z $package ]] && continue
    [[ $package =~ ^[a-z0-9][a-z0-9+._-]*$ ]] || die "Invalid package name: $package"
    PACKAGES+=("$package")
  done <"$file"
}

install_packages() {
  (($#)) || return 0
  ensure_time_sync
  progress 'Install Ubuntu packages' env DEBIAN_FRONTEND=noninteractive apt-get \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y --no-install-recommends "$@"
}

time_sync_service() {
  local service
  for service in systemd-timesyncd chrony chronyd ntpsec ntp openntpd; do
    [[ $(systemctl show -p LoadState --value "$service.service" 2>/dev/null) == loaded ]] || continue
    printf '%s\n' "$service"
    return 0
  done
  return 1
}

ensure_time_sync() {
  local synchronized attempt service
  [[ ${TIME_SYNC_READY:-0} == 1 ]] && return 0
  command -v timedatectl >/dev/null || die 'Install systemd before installing Ubuntu packages.'
  command -v systemctl >/dev/null || die 'Install systemd before installing Ubuntu packages.'
  synchronized=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
  if [[ $synchronized == yes ]]; then
    TIME_SYNC_READY=1
    return 0
  fi
  service=$(time_sync_service || true)
  if [[ -z $service && ${DRY_RUN:-0} != 1 ]]; then
    die 'No NTP service is installed. Install systemd-timesyncd or chrony, then retry.'
  fi
  service=${service:-systemd-timesyncd}
  if [[ ${DRY_RUN:-0} == 1 ]]; then
    run systemctl enable --now "$service"
    run systemctl restart "$service"
    TIME_SYNC_READY=1
    return 0
  fi
  progress "Start Ubuntu time synchronization ($service)" systemctl enable --now "$service"
  progress "Restart Ubuntu time synchronization ($service)" systemctl restart "$service"
  attempt=0
  while ((attempt < 15)); do
    attempt=$((attempt + 1))
    synchronized=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
    if [[ $synchronized == yes ]]; then
      TIME_SYNC_READY=1
      return 0
    fi
    sleep 2
  done
  die "Ubuntu time is not synchronized. Check $service and run make sync-time."
}

apt_update() {
  local label=${1:-Refresh Ubuntu package list}
  ensure_time_sync
  progress "$label" apt-get update
}

upgrade_os() {
  apt_update
  progress 'Apply Ubuntu updates' env DEBIAN_FRONTEND=noninteractive apt-get \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade -y
}

backup() {
  [[ -e $1 || -L $1 ]] || return 0
  local destination
  destination="/var/backups/vps-setup/$(date +%Y%m%d-%H%M%S)-$$$1"
  install -d -m 0700 "$(dirname "$destination")"
  cp -a "$1" "$destination"
}

render() {
  local source=$1 destination=$2 temporary
  shift 2
  temporary=$(mktemp)
  # Limit substitution so literal dollars in config files survive.
  # shellcheck disable=SC2016
  envsubst "$(printf '${%s} ' "$@")" <"$source" >"$temporary"
  backup "$destination"
  install -D -m 0644 "$temporary" "$destination"
  rm -f "$temporary"
}

ssh_service() {
  if systemctl is-active --quiet ssh.service; then printf 'ssh\n'; else printf 'sshd\n'; fi
}

ssh_ports() {
  local socket
  {
    /usr/sbin/sshd -T | awk '$1 == "port" {print $2}'
    # Socket activation can listen on a different port than sshd_config.
    for socket in ssh.socket sshd.socket; do
      if systemctl is-active --quiet "$socket"; then
        systemctl show "$socket" -p Listen --value | awk '{for (i=1; i<=NF; i++) if ($(i+1) == "(Stream)") {sub(/^.*:/, "", $i); print $i}}'
      fi
    done
    if [[ -n ${SSH_CONNECTION:-} ]]; then printf '%s\n' "${SSH_CONNECTION##* }"; fi
  } | sort -un
}

set_hosts_entry() {
  local file=$1 hostname=$2 temporary
  temporary=$(mktemp)
  awk -v hostname="$hostname" '
    $1 == "127.0.1.1" { if (!seen++) print "127.0.1.1\t" hostname; next }
    { print }
    END { if (!seen) print "127.0.1.1\t" hostname }
  ' "$file" >"$temporary"
  cat "$temporary" >"$file"
  rm -f "$temporary"
}
