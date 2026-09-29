#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"

key_file=
config_file=
while (($#)); do
  case "$1" in
    --key | --config)
      (($# >= 2)) || die "Missing value for $1"
      case "$1" in --key) key_file=$2 ;; --config) config_file=$2 ;; esac
      shift 2
      ;;
    --help | -h)
      printf 'Usage: sudo ./setup-vps.sh [--key PUBLIC_KEY_FILE] [--config HOST.conf]\n'
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
done
preview_if_requested setup-vps --key "$key_file" --config "$config_file"
require_root
detect_os
[[ -t 0 ]] || die 'Run setup in a terminal. It asks for a few choices and the sudo password.'
setup_lock
[[ ! -d /var/lib/vps-setup/ssh-pending ]] || die 'Confirm or roll back the pending SSH change first.'

SERVER_HOSTNAME=$(hostname -s)
ADMIN_USER=${SUDO_USER:-admin}
[[ $ADMIN_USER != root ]] || ADMIN_USER='admin'
CADDY_MODE=none
VPN=none
INSTALL_FONT=yes
SECURITY_UPDATES=yes
[[ ! -f /etc/vps-setup/host.conf ]] || load_config /etc/vps-setup/host.conf
[[ -z $config_file ]] || load_config "$config_file"

begin 'Set up this Ubuntu box'
ask SERVER_HOSTNAME 'Hostname' "$SERVER_HOSTNAME"
ask ADMIN_USER 'Admin username' "$ADMIN_USER"
caddy_default=no
case "$CADDY_MODE" in
  docker) caddy_default=yes ;;
  none) ;;
  *) die 'CADDY_MODE must be docker or none.' ;;
esac
caddy_choice=$caddy_default
ask caddy_choice 'Set up Caddy in Docker? yes or no' "$caddy_default"
case "$caddy_choice" in
  yes) CADDY_MODE=docker ;;
  no) CADDY_MODE=none ;;
  *) die 'Choose yes or no for Caddy.' ;;
esac
ask VPN 'Add a VPN? tailscale, wireguard, or none' "$VPN"
ask INSTALL_FONT 'Install JetBrains Mono Nerd Font? yes or no' "$INSTALL_FONT"
ask SECURITY_UPDATES 'Automatic security updates? yes or no' "$SECURITY_UPDATES"
validate_config
read_setup_packages "$ROOT/config/apt/packages.txt"
export SERVER_HOSTNAME ADMIN_USER

if [[ -z $key_file ]]; then
  key_default=/root/.ssh/authorized_keys
  if id "$ADMIN_USER" &>/dev/null; then
    user_home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
    [[ ! -s $user_home/.ssh/authorized_keys ]] || key_default="$user_home/.ssh/authorized_keys"
  fi
  ask key_file 'Public SSH key file' "$key_default"
fi
[[ -s $key_file ]] || die "No public keys found at $key_file"
command -v ssh-keygen >/dev/null || die 'Install openssh-client or openssh before running setup.'
ssh-keygen -lf "$key_file" >/dev/null || die 'The public key file is invalid.'
while IFS= read -r line || [[ -n $line ]]; do
  [[ -z $line || $line == \#* ]] && continue
  [[ $line =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]] ]] || die 'Use public keys without authorized_keys options. Never supply a private key.'
done <"$key_file"
if id "$ADMIN_USER" &>/dev/null; then
  [[ $(id -u "$ADMIN_USER") -ge 1000 ]] || die 'The admin must be a regular user, not a system account.'
fi
for service in firewalld nftables; do
  if systemctl is-active --quiet "$service"; then die "Stop and review the existing $service firewall before switching to UFW."; fi
done
if command -v snap >/dev/null && snap list docker &>/dev/null; then
  die 'Docker is installed through Snap. Back up its data and remove the snap before rerunning setup.'
fi
if [[ ! -f /etc/vps-setup/host.conf ]] && command -v docker >/dev/null && docker info &>/dev/null; then
  [[ -z $(docker ps -aq) ]] || die 'This host already has containers. Back up and migrate them before first-time provisioning.'
fi

printf '\n%sReview setup%s\n' "$C_CYAN" "$C_RESET"
printf '  %-18s %s\n' 'Hostname' "$SERVER_HOSTNAME"
printf '  %-18s %s\n' 'Admin' "$ADMIN_USER"
if [[ $CADDY_MODE == docker ]]; then caddy_summary=Docker; else caddy_summary=Off; fi
printf '  %-18s %s\n' 'Caddy' "$caddy_summary"
printf '  %-18s %s\n' 'VPN' "$VPN"
printf '  %-18s %s\n' 'JetBrains Mono' "$INSTALL_FONT"
printf '  %-18s %s\n' 'Security updates' "$SECURITY_UPDATES"
printf '  %-18s %s\n' 'Public key' "$key_file"
printf '  Ubuntu, Docker, UFW, and fail2ban will be set up.\n'
printf '  Configure Caddy routes with make configure-caddy; apply VPN choices with make configure-services.\n'
confirm 'Set up this box?'
export VPS_NO_CLEAR=1

# The source may be the authorized_keys file we update below.
saved_keys=$(mktemp)
trap 'rm -f "$saved_keys"; release_setup_lock' EXIT
cp "$key_file" "$saved_keys"

configure_host() {
  # The setup lock belongs to the parent while this function runs under the spinner.
  [[ $BASHPID == "$setup_pid" ]] || trap - EXIT
  step 'Set the hostname'
  hostnamectl set-hostname "$SERVER_HOSTNAME"

  step 'Update Ubuntu and install base packages'
  upgrade_os
  install_packages "${system_packages[@]}"
  # Install system-wide so sudo and new SSH sessions can find it too.
  backup /etc/hosts
  set_hosts_entry /etc/hosts "$SERVER_HOSTNAME"

  step 'Set up the admin account'
  if ! id "$ADMIN_USER" &>/dev/null; then useradd --create-home --shell /bin/zsh "$ADMIN_USER"; fi
  user_home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
  admin_group=$(id -gn "$ADMIN_USER")
  [[ $user_home == /home/* && -d $user_home ]] || die 'Expected the admin home under /home/.'
  install -d -o "$ADMIN_USER" -g "$admin_group" -m 0700 "$user_home/.ssh"
  authorized_keys="$user_home/.ssh/authorized_keys"
  backup "$authorized_keys"
  touch "$authorized_keys"
  merged_keys=$(awk '!seen[$0]++' "$authorized_keys" "$saved_keys")
  # printf restores the final newline even when the old file had none.
  printf '%s\n' "$merged_keys" >"$authorized_keys"
  chown "$ADMIN_USER:$admin_group" "$authorized_keys"
  chmod 0600 "$authorized_keys"
  render "$ROOT/config/sudo/admin" /etc/sudoers.d/90-vps-admin ADMIN_USER
  chmod 0440 /etc/sudoers.d/90-vps-admin
  visudo -cf /etc/sudoers.d/90-vps-admin
  if [[ $(passwd -S "$ADMIN_USER" | awk '{print $2}') != P ]]; then
    note "Set a sudo password for $ADMIN_USER."
    passwd "$ADMIN_USER"
  fi
  usermod -s "$(command -v zsh)" "$ADMIN_USER"
  if [[ ! -e $user_home/.zshrc ]]; then
    install -o "$ADMIN_USER" -g "$admin_group" -m 0644 /dev/null "$user_home/.zshrc"
  fi

  step 'Set up /opt/vps and /data'
  install -d -m 0755 /data /etc/vps-setup /var/lib/vps-setup
  install -d -m 0700 /data/backups /var/backups/vps-setup
  [[ ! -L /opt/vps ]] || die '/opt/vps must be a directory, not a symlink.'
  install -d -o "$ADMIN_USER" -g "$admin_group" -m 0755 /opt/vps
  if [[ $ROOT != /opt/vps ]]; then
    rsync -a --filter="merge $ROOT/.rsyncignore" "$ROOT/" /opt/vps/
  fi
  chown -R "$ADMIN_USER:$admin_group" /opt/vps
  install -d -o "$ADMIN_USER" -g "$admin_group" -m 0700 /opt/vps/.local
  for key in SERVER_HOSTNAME ADMIN_USER CADDY_MODE VPN WG_ENDPOINT INSTALL_FONT SECURITY_UPDATES; do
    printf '%s=%s\n' "$key" "${!key}"
  done >/etc/vps-setup/host.conf
  chmod 0644 /etc/vps-setup/host.conf

  progress 'Install Docker and Compose' bash "$ROOT/scripts/os/install-docker.sh"
  bash "$ROOT/scripts/os/configure-security.sh"
}

setup_pid=$BASHPID
progress "Set up $SERVER_HOSTNAME" configure_host
printf '\n  %s✓%s Hostname and hosts file\n' "$C_GREEN" "$C_RESET"
printf '  %s✓%s Ubuntu packages and updates\n' "$C_GREEN" "$C_RESET"
printf '  %s✓%s Admin account, sudo, and SSH key\n' "$C_GREEN" "$C_RESET"
printf '  %s✓%s /opt/vps and /data\n' "$C_GREEN" "$C_RESET"
printf '  %s✓%s Docker, UFW, fail2ban, and update policy\n' "$C_GREEN" "$C_RESET"

source_repo=$(realpath "$ROOT")
if [[ $source_repo == "/home/$ADMIN_USER/vps" || $source_repo == /root/vps ]]; then
  rm -rf -- "$source_repo"
  note 'The setup repo now lives in /opt/vps. The old checkout was removed.'
fi

printf '\n%sSSH HANDOFF%s\n' "$C_CYAN" "$C_RESET"
printf 'Keep this session open until key access is confirmed.\n'
printf '\n\t%s1.%s In another terminal, log in as %s with the same key:\n' "$C_YELLOW" "$C_RESET" "$ADMIN_USER"
printf '\t\t%scd /opt/vps && make configure-ssh%s\n' "$C_YELLOW" "$C_RESET"
printf '\n\t%s2.%s Open a fresh SSH connection within five minutes:\n' "$C_YELLOW" "$C_RESET"
printf '\t\t%scd /opt/vps && make confirm-ssh%s\n' "$C_YELLOW" "$C_RESET"
printf '\n\t%s3.%s Continue in that confirmed session:\n' "$C_YELLOW" "$C_RESET"
printf '\t\t%scd /opt/vps && make setup-host%s\n' "$C_YELLOW" "$C_RESET"
printf '\t\tReboot when ready.\n'
