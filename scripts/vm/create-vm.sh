#!/usr/bin/env bash
# shellcheck source=scripts/vm/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
parse_vm_args "$@"
preview_if_requested vm-create
begin "Create VM $VM_NAME"
qemu_path qemu-img
command -v hdiutil >/dev/null || die 'hdiutil is required on macOS.'
[[ -f $BASE_IMAGE ]] || die "Image not found: $BASE_IMAGE"
[[ ! -e $DISK ]] || die "VM already exists: $VM_NAME"
if [[ ${VM_PASSWORD_SET:-no} == yes ]]; then
  vm_password=${VM_PASSWORD:-password}
else
  step 'Set the admin password'
  vm_password=
  ask_secret vm_password 'Admin password (Enter for password)'
  if [[ -n $vm_password ]]; then
    password_check=
    ask_secret password_check 'Repeat admin password'
    [[ $vm_password == "$password_check" ]] || die 'Passwords did not match.'
  else
    vm_password=password
  fi
fi

password_is_default=no
[[ $vm_password != password ]] || password_is_default=yes
command -v brew >/dev/null || die 'Homebrew is required.'
openssl=$(brew --prefix openssl@3)/bin/openssl
[[ -x $openssl ]] || die 'Install OpenSSL 3 with brew install openssl@3.'
password_hash=$(printf '%s\n' "$vm_password" | "$openssl" passwd -6 -stdin)
ssh_pwauth=true
lock_passwd=false
unset vm_password password_check VM_PASSWORD VM_PASSWORD_SET

allocate_vm_port
umask 077
step 'Write cloud-init seed'
mkdir -p "$VM_DIR"
mkdir -p "$SEED"
sed -e "s|__VM_NAME__|$VM_NAME|" -e "s|__PASSWORD_HASH__|$password_hash|" \
  -e "s|__SSH_PWAUTH__|$ssh_pwauth|" -e "s|__LOCK_PASSWD__|$lock_passwd|" \
  "$ROOT/config/vm/seed.yaml" >"$SEED/user-data"
unset password_hash
printf 'instance-id: vps-lab-%s\nlocal-hostname: %s\n' "$VM_NAME" "$VM_NAME" >"$SEED/meta-data"
hdiutil makehybrid -o "$SEED_ISO" "$SEED" -iso -joliet -default-volume-name cidata >/dev/null
cp /opt/homebrew/share/qemu/edk2-arm-vars.fd "$VARS"
progress 'Create the VM disk' qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$DISK" "$VM_STORAGE"
step 'Save VM settings'
printf 'image=%s\nvcpu=%s\nmemory=%s\nstorage=%s\nport=%s\n' \
  "$VM_IMAGE" "$VM_VCPU" "$VM_MEMORY" "$VM_STORAGE" "$VM_PORT" >"$VM_DIR/vm.conf"
printf 'Created %s.\n\n' "$VM_NAME"
printf '  CPU       %s vCPU\n' "$VM_VCPU"
printf '  Memory    %s GiB\n' "$VM_MEMORY"
printf '  Disk      %s\n' "$VM_STORAGE"
printf '  User      admin\n'
if [[ $password_is_default == yes ]]; then
  printf '  Password  password (default)\n'
else
  printf '  Password  set\n'
fi
printf '  SSH       127.0.0.1:%s (password login on)\n' "$VM_PORT"
printf '\nStart: make start-vm name=%s display=gui\n' "$VM_NAME"
