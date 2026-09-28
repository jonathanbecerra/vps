#!/usr/bin/env bash
# shellcheck source=scripts/vm/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

resolve_vm_name() {
  local config name pid
  local -a existing=() running=()
  for config in "$VM_ROOT"/*/vm.conf; do
    [[ -f $config ]] || continue
    name=$(basename "$(dirname "$config")")
    existing+=("$name")
    if [[ -f $VM_ROOT/$name/qemu.pid ]]; then
      pid=$(<"$VM_ROOT/$name/qemu.pid")
      if [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null &&
        ps -p "$pid" -o command= | grep -q qemu-system-aarch64; then
        running+=("$name")
      fi
    fi
  done

  if ((${#running[@]} == 1)); then
    VM_NAME=${running[0]}
  elif ((${#running[@]} > 1)); then
    die 'More than one VM is running. Pass name= or run make list-vm.'
  elif ((${#existing[@]} == 1)); then
    VM_NAME=${existing[0]}
  elif ((${#existing[@]} > 1)); then
    die 'More than one VM exists. Pass name= or run make list-vm.'
  else
    die 'No VM found. Pass name= or run make list-vm.'
  fi
  set_vm_paths
}

load_vm_config() {
  local key value
  [[ -n $VM_NAME ]] || resolve_vm_name
  [[ -f $VM_DIR/vm.conf ]] || die "VM not found: $VM_NAME (run make create-vm first)."
  while IFS='=' read -r key value || [[ -n $key ]]; do
    case $key in
      image) VM_IMAGE=$value ;;
      vcpu) VM_VCPU=$value ;;
      memory) VM_MEMORY=$value ;;
      storage) VM_STORAGE=$value ;;
      port) VM_PORT=$value ;;
    esac
  done <"$VM_DIR/vm.conf"
  [[ $VM_IMAGE == ubuntu-26.04 && $VM_VCPU =~ ^[1-9][0-9]*$ && $VM_MEMORY =~ ^[1-9][0-9]*$ ]] || die "Bad VM config: $VM_DIR/vm.conf"
  [[ $VM_STORAGE =~ ^[1-9][0-9]*[GgTt]$ && ${VM_PORT:-} =~ ^[0-9]+$ ]] || die "Bad VM config: $VM_DIR/vm.conf"
  BASE_IMAGE="$DISTROS_DIR/$VM_IMAGE/ubuntu-26.04-server-cloudimg-arm64.img"
  export VM_IMAGE VM_VCPU VM_MEMORY VM_STORAGE VM_PORT BASE_IMAGE
}

vm_running() {
  local pid
  [[ -f $PIDFILE ]] || return 1
  pid=$(<"$PIDFILE")
  [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && ps -p "$pid" -o command= | grep -q qemu-system-aarch64
}

attach_vm_console() {
  local terminal_settings
  if [[ -t 0 ]]; then
    terminal_settings=$(stty -g)
    trap 'stty "$terminal_settings"' EXIT
    stty -echo -icanon
    nc -U "$SERIAL_SOCKET"
    local status=$?
    stty "$terminal_settings"
    return "$status"
  fi
  nc -U "$SERIAL_SOCKET"
}
