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
begin 'Set up this Ubuntu box'
[[ -n $mode ]] || ask mode 'Setup? basic or advanced' basic
case $mode in basic | advanced) ;; *) die 'Choose basic or advanced.' ;; esac

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
  note "Basic: keep $ADMIN_USER and $SERVER_HOSTNAME, update Ubuntu, install Docker and host protection, create examples, then install dotfiles."
  note 'SSH authentication and the account password stay as configured.'
  confirm 'Start basic setup?'
  install_base basic
else
  if [[ ! -d /var/lib/vps-setup/ssh-pending ]]; then
    [[ $ADMIN_USER != root ]] || ADMIN_USER='admin'
    ask SERVER_HOSTNAME 'Hostname' "$SERVER_HOSTNAME"
    ask ADMIN_USER 'Admin username' "$ADMIN_USER"
    validate_config
    confirm "Update Ubuntu and set up $ADMIN_USER on $SERVER_HOSTNAME?"
    install_base advanced
  else
    note 'Resume the pending SSH confirmation before making other changes.'
    [[ $ROOT == /opt/vps ]] || die 'Resume with sudo /opt/vps/setup-vps.sh --mode advanced.'
    validate_config
  fi
  ssh_handoff
  ask next 'SSH step finished. Continue with Caddy, VPN, and dotfiles, or stop?' continue
  case $next in continue) ;; stop) exit 0 ;; *) die 'Choose continue or stop.' ;; esac
  ask CADDY_MODE 'Caddy? public, private, or none' "$CADDY_MODE"
  ask VPN 'VPN? tailscale, wireguard, or none' "$VPN"
  validate_config
  setup_lock
  write_caddy_config
  release_setup_lock
  trap - EXIT
fi

# Each installer owns its lock. Do not hold one during another-session handoff.
export DOTFILES_DIR="$ROOT/dotfiles"
bash "$ROOT/scripts/caddy/setup.sh"
bash "$ROOT/scripts/vpn/configure.sh" configure "--vpn=$VPN"
bash "$ROOT/scripts/os/install-dotfiles.sh"
# Keep the SSH handoff on a usable shell until its replacement is configured.
usermod -s "$(command -v zsh)" "$ADMIN_USER"
bash "$ROOT/scripts/os/show-status.sh"
note "Setup finished for $ADMIN_USER on $SERVER_HOSTNAME. Log in again to load the shell and Docker group."
printf '\tCheckout: /opt/vps\n\tRerun: sudo /opt/vps/setup-vps.sh\n'
[[ ! -f /var/run/reboot-required ]] || note 'Ubuntu needs a reboot. Reboot when ready.'
