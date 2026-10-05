#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/scripts/lib.sh"
mode='' key_file='' config_file='' next=''
while (($#)); do
  case $1 in
    --mode | --key | --config)
      (($# >= 2)) || die "Missing value for $1"
      case $1 in --mode) mode=$2 ;; --key) key_file=$2 ;; --config) config_file=$2 ;; esac
      shift 2
      ;;
    --help | -h)
      printf 'Usage: sudo ./setup-vps.sh [--mode basic|advanced] [--key PUBLIC_KEY_FILE] [--config HOST.conf]\n'
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
done
[[ -z $mode || $mode == basic || $mode == advanced ]] || die 'Choose basic or advanced.'
preview_if_requested setup-vps --mode "${mode:-basic}" --key "$key_file" --config "$config_file"
require_root
detect_os
[[ -t 0 ]] || exec </dev/tty
export VPS_NO_CLEAR=1
panel 'VPS / Ubuntu setup'
printf '  Docker, host protection, and dotfiles. Ctrl-C stops setup.\n'
[[ -n $mode ]] || choose mode 'Setup mode' basic \
  basic 'Keep this account, hostname, and SSH settings' \
  advanced 'Set the account, verify key-only SSH, choose services'
setup_started=$SECONDS
ssh_result='Unchanged'

SERVER_HOSTNAME=$(hostname -s)
ADMIN_USER=${SUDO_USER:-root}
VPN=none SECURITY_UPDATES=yes
migrate_legacy_config
[[ ! -f $VPS_HOST_CONFIG ]] || load_config "$VPS_HOST_CONFIG"
load_caddy_config
saved_admin=$ADMIN_USER
if [[ -d /var/lib/vps-setup/ssh-pending && (-n $config_file || -n $key_file) ]]; then
  die 'Finish the pending SSH handoff before changing setup inputs.'
fi
[[ -z $config_file ]] || load_config "$config_file"
# shellcheck source=scripts/os/install-base.sh
source "$ROOT/scripts/os/install-base.sh"
# shellcheck source=scripts/ssh/handoff.sh
source "$ROOT/scripts/ssh/handoff.sh"
[[ -z $key_file ]] || valid_public_keys "$key_file" || die 'Pass a public key file, never a private key.'

trap 'printf "\nSetup stopped. Completed host changes remain; any armed SSH rollback still runs.\n"; exit 130' INT
trap 'exit 143' TERM HUP
if [[ $mode == basic ]]; then
  ADMIN_USER=${SUDO_USER:-root}
  [[ $ADMIN_USER != root ]] || die 'Basic needs an existing regular user. Log in as that user and use sudo, or choose advanced.'
  [[ ! -f $VPS_HOST_CONFIG || $saved_admin == "$ADMIN_USER" ]] || die "This host belongs to $saved_admin. Use that account or choose advanced."
  [[ $CADDY_MODE == none && $VPN == none ]] || die 'This host already has Caddy or a VPN. Choose advanced to review those settings.'
  [[ ! -d /var/lib/vps-setup/ssh-pending ]] || die 'Confirm or roll back the pending SSH change first.'
  SERVER_HOSTNAME=$(hostname -s)
  CADDY_MODE=none VPN=none
  panel 'Review / basic'
  field Account "$ADMIN_USER (keep password)"
  field Hostname "$SERVER_HOSTNAME (keep)"
  field SSH 'Keep current authentication'
  field Services 'Caddy off / VPN off / both examples created'
  field Install 'Ubuntu updates, Docker, UFW, fail2ban, dotfiles'
  confirm 'Start basic setup?'
  panel '1/4 / Ubuntu and host protection'
  install_base basic
else
  if [[ ! -d /var/lib/vps-setup/ssh-pending ]]; then
    panel 'Account and hostname'
    [[ $ADMIN_USER != root ]] || ADMIN_USER='admin'
    ask SERVER_HOSTNAME 'Hostname' "$SERVER_HOSTNAME"
    ask ADMIN_USER 'Admin username' "$ADMIN_USER"
    validate_config
    confirm "Update Ubuntu and set up $ADMIN_USER on $SERVER_HOSTNAME?"
    panel '1/5 / Ubuntu and account'
    install_base advanced
  else
    note 'Resume the pending SSH confirmation before making other changes.'
    [[ $ROOT == /opt/vps ]] || die 'Resume with sudo /opt/vps/setup-vps.sh --mode advanced.'
    validate_config
  fi
  panel '2/5 / Verify SSH access'
  ssh_handoff
  choose next 'SSH step finished' continue \
    continue 'Set up services and install dotfiles' \
    stop 'Keep completed changes; leave services and dotfiles for later'
  if [[ $next == stop ]]; then
    note 'Stopped after SSH. Services and dotfiles were not changed.'
    printf '\tRerun: sudo /opt/vps/setup-vps.sh --mode advanced\n'
    exit 0
  fi
  choose CADDY_MODE 'Caddy' "$CADDY_MODE" \
    none 'Off; create both examples without starting them' \
    private 'LAN HTTPS with Cloudflare DNS; start the Hono API' \
    public 'Public HTTP/HTTPS ports; start the static HTTP example'
  choose VPN 'VPN' "$VPN" \
    none 'No VPN' tailscale 'Tailscale container' wireguard 'WireGuard service'
  validate_config
  setup_lock
  write_caddy_config
  release_setup_lock
  trap - EXIT
fi

# Each installer owns its lock. Do not hold one during another-session handoff.
export DOTFILES_DIR="$ROOT/dotfiles"
if [[ $mode == basic ]]; then panel '2/4 / Examples'; else panel '3/5 / Services and examples'; fi
bash "$ROOT/scripts/caddy/setup.sh"
bash "$ROOT/scripts/vpn/configure.sh" configure "--vpn=$VPN"
if [[ $mode == basic ]]; then panel '3/4 / Dotfiles'; else panel '4/5 / Dotfiles'; fi
bash "$ROOT/scripts/os/install-dotfiles.sh"
# Keep the SSH handoff on a usable shell until its replacement is configured.
usermod -s "$(command -v zsh)" "$ADMIN_USER"
if [[ $mode == basic ]]; then panel '4/4 / Health check'; else panel '5/5 / Health check'; fi
progress 'Check services, firewall, and listening ports' bash "$ROOT/scripts/os/show-status.sh"
panel 'Setup complete'
field Account "$ADMIN_USER@$SERVER_HOSTNAME"
field SSH "$ssh_result"
field Caddy "$CADDY_MODE"
field VPN "$VPN"
field Checkout /opt/vps
field Elapsed "$(((SECONDS - setup_started) / 60))m $(((SECONDS - setup_started) % 60))s"
if [[ $ssh_result == Unchanged ]]; then
  printf '%s  SSH authentication was left unchanged; Basic does not harden SSH.%s\n' "$C_YELLOW" "$C_RESET"
elif [[ $ssh_result != Confirmed* ]]; then
  printf '%s  SSH hardening was not confirmed. Review access before exposing this host.%s\n' "$C_RED" "$C_RESET"
fi
printf '\n  Log in again to load Zsh and the Docker group.\n'
printf '\tStatus: cd /opt/vps && make show-status\n\tRerun: sudo /opt/vps/setup-vps.sh\n'
[[ ! -f /var/run/reboot-required ]] || note 'Ubuntu needs a reboot. Reboot when ready.'
