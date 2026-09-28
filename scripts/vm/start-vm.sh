#!/usr/bin/env bash
# shellcheck source=scripts/vm/manage-lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/manage-lib.sh"
parse_vm_args --allow-missing-name "$@"
load_vm_config
preview_if_requested vm-start
begin "Start VM $VM_NAME"
qemu_path qemu-system-aarch64
[[ -f $DISK && -f $SEED_ISO && -f $VARS ]] || die "VM files are missing: $VM_DIR"

if vm_running; then
  running_display=console
  [[ ! -f $DISPLAY_MODE ]] || running_display=$(<"$DISPLAY_MODE")
  if [[ $VM_DISPLAY == gui ]]; then
    [[ $running_display == gui ]] || die "Already running with --display=console. Stop it before starting the QEMU window."
    note "$VM_NAME is already running in the QEMU window."
    exit 0
  fi
  note "$VM_NAME is already running; attaching."
  attach_vm_console
  exit 0
fi
[[ ! -f $PIDFILE ]] || rm -f "$PIDFILE"
[[ ! -S $SERIAL_SOCKET ]] || rm -f "$SERIAL_SOCKET"

display=(-display none)
devices=()
if [[ $VM_DISPLAY == gui ]]; then
  display=(-display cocoa)
  devices=(-device virtio-gpu-pci -device virtio-keyboard-pci -device virtio-mouse-pci)
fi

qemu_args=(
  -machine 'virt,accel=hvf' -cpu host -smp "$VM_VCPU" -m "${VM_MEMORY}G"
  -drive 'if=pflash,format=raw,readonly=on,file=/opt/homebrew/share/qemu/edk2-aarch64-code.fd'
  -drive "if=pflash,format=raw,file=$VARS"
  -drive "if=none,file=$DISK,format=qcow2,id=disk" -device 'virtio-blk-pci,drive=disk'
  -drive "if=none,file=$SEED_ISO,format=raw,readonly=on,id=seed" -device 'virtio-blk-pci,drive=seed'
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$VM_PORT-:22" -device 'virtio-net-pci,netdev=net0'
  "${display[@]}" "${devices[@]}"
  -serial "unix:$SERIAL_SOCKET,server=on,wait=off"
  -monitor "unix:$MONITOR,server=on,wait=off"
)

step "Launch QEMU in $VM_DISPLAY mode"
if [[ $VM_DISPLAY == gui ]]; then
  nohup qemu-system-aarch64 "${qemu_args[@]}" -pidfile "$PIDFILE" \
    </dev/null >>"$VM_DIR/qemu.log" 2>&1 &
  qemu_pid=$!
  printf '%s\n' "$qemu_pid" >"$PIDFILE"
else
  qemu-system-aarch64 "${qemu_args[@]}" \
    -daemonize -pidfile "$PIDFILE" -D "$VM_DIR/qemu.log"
fi

sleep 1
vm_running || die 'VM did not start; check qemu.log.'
printf '%s\n' "$VM_DISPLAY" >"$DISPLAY_MODE"
if [[ $VM_DISPLAY == gui ]]; then
  printf '%s is up in a QEMU window (pid %s). Use make attach-vm to open the serial console here.\n' \
    "$VM_NAME" "$(<"$PIDFILE")"
  exit 0
fi
command -v ssh-keyscan >/dev/null || die 'ssh-keyscan is required to wait for the console.'
wait_for_ssh() {
  local attempt
  for ((attempt = 0; attempt < 60; attempt++)); do
    ssh-keyscan -T 1 -p "$VM_PORT" 127.0.0.1 2>/dev/null | grep -q 'ssh-' && return 0
    vm_running || die 'VM stopped during boot; check qemu.log.'
    sleep 1
  done
}
progress 'Wait for Ubuntu to finish booting' wait_for_ssh
if ! ssh-keyscan -T 1 -p "$VM_PORT" 127.0.0.1 2>/dev/null | grep -q 'ssh-'; then
  note 'Ubuntu is still starting; attaching anyway.'
fi
note 'Press Enter if the login prompt is not visible.'
note "$VM_NAME is up (pid $(<"$PIDFILE"))."
attach_vm_console
