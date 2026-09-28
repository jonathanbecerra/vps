#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"

parse_vm_args() {
  local allow_missing_name=no
  if [[ ${1:-} == --allow-missing-name ]]; then
    allow_missing_name=yes
    shift
  fi
  VM_NAME=
  VM_NAME_SET=no
  VM_IMAGE=ubuntu
  VM_VCPU=4
  VM_MEMORY=8
  VM_STORAGE=32G
  VM_DISPLAY=console
  VM_YES=no

  while (($#)); do
    case $1 in
      --name=*)
        VM_NAME=${1#*=}
        VM_NAME_SET=yes
        ;;
      --name)
        shift
        (($#)) || die 'Missing value for --name.'
        VM_NAME=$1
        VM_NAME_SET=yes
        ;;
      --image=*) VM_IMAGE=${1#*=} ;;
      --image)
        shift
        (($#)) || die 'Missing value for --image.'
        VM_IMAGE=$1
        ;;
      --vcpu=*) VM_VCPU=${1#*=} ;;
      --vcpu)
        shift
        (($#)) || die 'Missing value for --vcpu.'
        VM_VCPU=$1
        ;;
      --memory=*) VM_MEMORY=${1#*=} ;;
      --memory)
        shift
        (($#)) || die 'Missing value for --memory.'
        VM_MEMORY=$1
        ;;
      --storage=*) VM_STORAGE=${1#*=} ;;
      --storage)
        shift
        (($#)) || die 'Missing value for --storage.'
        VM_STORAGE=$1
        ;;
      --display=*) VM_DISPLAY=${1#*=} ;;
      --display)
        shift
        (($#)) || die 'Missing value for --display.'
        VM_DISPLAY=$1
        ;;
      --yes) VM_YES=yes ;;
      *) die "Unknown VM option: $1" ;;
    esac
    shift
  done

  if [[ $VM_NAME_SET == yes ]]; then
    [[ $VM_NAME =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die 'Use a name with lowercase letters, numbers, and hyphens.'
  else
    [[ $allow_missing_name == yes ]] || die 'Pass --name using lowercase letters, numbers, and hyphens.'
  fi
  case $VM_IMAGE in
    ubuntu | ubuntu-26.04) VM_IMAGE=ubuntu-26.04 ;;
    *) die 'Only --image=ubuntu is set up.' ;;
  esac
  [[ $VM_VCPU =~ ^[1-9][0-9]*$ ]] || die 'Use a positive number for --vcpu.'
  [[ $VM_MEMORY =~ ^[1-9][0-9]*$ ]] || die 'Use memory in whole GiB, like --memory=16.'
  [[ $VM_STORAGE =~ ^[1-9][0-9]*([GgTt])?$ ]] || die 'Use storage in GiB or TiB, like --storage=64.'
  [[ $VM_STORAGE =~ [GgTt]$ ]] || VM_STORAGE+=G
  case $VM_DISPLAY in
    console | terminal) VM_DISPLAY=console ;;
    gui | window) VM_DISPLAY=gui ;;
    *) die 'Use --display=console or --display=gui.' ;;
  esac

  VM_ROOT="$HOME/.local/share/vps-lab"
  DISTROS_DIR=${DISTROS_DIR:-$HOME/Developer/distros}
  set_vm_paths
  export VM_NAME VM_NAME_SET VM_IMAGE VM_VCPU VM_MEMORY VM_STORAGE VM_DISPLAY VM_ROOT DISTROS_DIR VM_DIR BASE_IMAGE DISK SEED SEED_ISO VARS PIDFILE MONITOR SERIAL_SOCKET DISPLAY_MODE VM_YES
}

set_vm_paths() {
  VM_DIR="$VM_ROOT/$VM_NAME"
  BASE_IMAGE="$DISTROS_DIR/$VM_IMAGE/ubuntu-26.04-server-cloudimg-arm64.img"
  DISK="$VM_DIR/disk.qcow2"
  SEED="$VM_DIR/seed"
  SEED_ISO="$VM_DIR/seed.iso"
  VARS="$VM_DIR/edk2-vars.fd"
  PIDFILE="$VM_DIR/qemu.pid"
  MONITOR="$VM_DIR/monitor.sock"
  SERIAL_SOCKET="$VM_DIR/console.sock"
  DISPLAY_MODE="$VM_DIR/display.mode"
}

allocate_vm_port() {
  local port file reserved
  for ((port = 2222; port < 2300; port++)); do
    reserved=no
    for file in "$VM_ROOT"/*/vm.conf; do
      [[ -f $file ]] || continue
      [[ $(awk -F= '$1 == "port" {print $2}' "$file") != "$port" ]] || reserved=yes
    done
    [[ $reserved == yes ]] && continue
    nc -z -w 1 127.0.0.1 "$port" >/dev/null 2>&1 && continue
    export VM_PORT=$port
    return 0
  done
  die 'No free SSH port found between 2222 and 2299.'
}

qemu_path() {
  command -v "$1" >/dev/null || die 'Install QEMU with Homebrew first.'
}
