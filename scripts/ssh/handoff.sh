#!/usr/bin/env bash
# Sourced by setup-vps.sh. Only configure-ssh writes a confirmation receipt.
valid_public_keys() {
  [[ -f $1 ]] && ! grep -q 'PRIVATE KEY' "$1" && ssh-keygen -lf "$1" >/dev/null 2>&1
}

ssh_handoff_state() {
  local state_dir=$1 attempt=$2 pending_id
  # Confirmation renames the pending directory. Read once to avoid that race.
  if pending_id=$(cat "$state_dir/ssh-pending/id" 2>/dev/null); then
    if [[ $pending_id == "$attempt" ]]; then
      printf 'pending\n'
    else
      printf 'changed\n'
    fi
  elif [[ -f $state_dir/ssh-confirmed && $(<"$state_dir/ssh-confirmed") == "$attempt" ]]; then
    printf 'confirmed\n'
  elif [[ -d $state_dir/ssh-pending ]]; then
    printf 'changed\n'
  else
    printf 'rolled-back\n'
  fi
}

wait_for_ssh_confirmation() {
  local state_dir=$1 attempt=$2 deadline=$3 boot_id=$4 uptime remaining reply state
  [[ $deadline =~ ^[0-9]+$ ]] || die 'Invalid SSH rollback deadline.'
  while :; do
    state=$(ssh_handoff_state "$state_dir" "$attempt")
    case $state in
      confirmed)
        printf '\r\033[KSSH confirmed from the other session.\n'
        return 0
        ;;
      rolled-back)
        printf '\r\033[KSSH settings were restored.\n'
        return 1
        ;;
      changed) die 'The pending SSH attempt changed. Stop and check access before rerunning setup.' ;;
    esac
    read -r uptime _ </proc/uptime || die 'Cannot read the SSH rollback clock.'
    remaining=$((deadline - ${uptime%%.*}))
    if ((remaining <= 0)) || [[ $boot_id != "$(cat /proc/sys/kernel/random/boot_id)" ]]; then
      # Also handles resuming after a reboot, when a transient timer is gone.
      /usr/local/sbin/vps-rollback-ssh || die 'SSH rollback failed. Stop and restore access before continuing.'
      continue
    fi
    printf '\r\033[KSSH rollback in %02d:%02d. Confirm in the new session. Press s to stop. ' "$((remaining / 60))" "$((remaining % 60))"
    reply=
    if read -rsn 1 -t 1 reply; then
      case $reply in
        s | S)
          printf '\nStopped. The independent rollback timer is still armed.\n'
          exit 0
          ;;
        *) ;; # Local input only rechecks the receipt; it never confirms SSH.
      esac
    fi
  done
}

ssh_handoff() {
  local user_home key_path ready choice policy address port attempt deadline boot_id
  local state_dir=/var/lib/vps-setup
  user_home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
  key_path="$user_home/.ssh/authorized_keys"
  address=HOST port=22
  if [[ -n ${SSH_CONNECTION:-} ]]; then
    read -r _ _ address port <<<"$SSH_CONNECTION"
  fi
  if [[ ! -d /var/lib/vps-setup/ssh-pending ]]; then
    if ! valid_public_keys "$key_path"; then
      note 'Copy a public key from another terminal. Keep this setup session open.'
      # Do not weaken an existing managed key-only policy to replace a lost key.
      if ! grep -qxF 'Include /etc/ssh/vps-setup.conf' /etc/ssh/sshd_config; then
        set_sshd_password_auth yes
        systemctl reload "$(ssh_service)"
      fi
      policy=$(/usr/sbin/sshd -T -C "user=$ADMIN_USER,host=$SERVER_HOSTNAME,addr=127.0.0.1")
      if ! grep -qx 'passwordauthentication yes' <<<"$policy" || ! grep -qx 'authenticationmethods any' <<<"$policy"; then
        note 'An existing SSH policy still blocks passwords. Use the current admin session or console to copy the public key.'
      fi
      printf '\tOn your Mac, substitute your key and reachable host/forwarded port:\n'
      printf '\tssh-copy-id -i ~/.ssh/gh_ed25519.pub -p %s %s@%s\n' "$port" "$ADMIN_USER" "$address"
      printf '\tDestination: %s\n' "$key_path"
      while ! valid_public_keys "$key_path"; do
        ask ready 'Press Enter after copying the public key, or type stop' check
        if [[ $ready == stop ]]; then
          printf '%sStopped before SSH hardening. Temporary password access may still be enabled.%s\n' "$C_RED" "$C_RESET"
          exit 0
        fi
      done
    fi
    note "Public key found for $ADMIN_USER. Next, verify a fresh key login."
    bash "$ROOT/scripts/ssh/configure-ssh.sh" harden --from-setup
  fi
  while :; do
    [[ -f $state_dir/ssh-pending/id && -f $state_dir/ssh-pending/deadline && -f $state_dir/ssh-pending/boot-id ]] ||
      die 'No current guided SSH handoff. Check access, then rerun setup. For an older pending change, use make confirm-ssh or make rollback-ssh.'
    attempt=$(<"$state_dir/ssh-pending/id")
    deadline=$(<"$state_dir/ssh-pending/deadline")
    boot_id=$(<"$state_dir/ssh-pending/boot-id")
    printf '\n\tIn another terminal, open a NEW key-only connection:\n'
    printf '\tssh -t -o ControlMaster=no -o ControlPath=none -o PreferredAuthentications=publickey -i ~/.ssh/gh_ed25519 -p %s %s@%s\n' "$port" "$ADMIN_USER" "$address"
    printf '\tInside that connection:\n\tcd /opt/vps\n\tmake confirm-ssh\n\n'
    if wait_for_ssh_confirmation "$state_dir" "$attempt" "$deadline" "$boot_id"; then return 0; fi
    printf '%sSSH IS NOT CONFIRMED. The previous SSH settings are in effect.%s\n' "$C_RED" "$C_RESET"
    ask choice 'Retry the five-minute handoff, continue without hardening, or stop? retry/continue/stop' stop
    case $choice in
      retry) bash "$ROOT/scripts/ssh/configure-ssh.sh" harden --from-setup ;;
      continue)
        [[ ! -d /var/lib/vps-setup/ssh-pending ]] || die 'Rollback has not finished. Do not continue yet.'
        printf '%sCONTINUING WITHOUT CONFIRMED SSH HARDENING. Password or root access may still be enabled.%s\n' "$C_RED" "$C_RESET"
        return 0
        ;;
      stop) exit 0 ;;
      *) die 'Choose retry, continue, or stop.' ;;
    esac
  done
}
