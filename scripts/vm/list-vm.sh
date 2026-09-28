#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"

root="$HOME/.local/share/vps-lab"
printf '%s%-22s %-14s %-7s %-7s %-9s %-7s %s%s\n' \
  "$C_CYAN" NAME IMAGE CPU MEMORY STORAGE STATE SSH "$C_RESET"
for config in "$root"/*/vm.conf; do
  [[ -f $config ]] || continue
  name=$(basename "$(dirname "$config")")
  image='' vcpu='' memory='' storage='' port=''
  while IFS='=' read -r key value; do
    case $key in
      image) image=$value ;;
      vcpu) vcpu=$value ;;
      memory) memory=$value ;;
      storage) storage=$value ;;
      port) port=$value ;;
    esac
  done <"$config"
  state=stopped
  pidfile="$root/$name/qemu.pid"
  if [[ -f $pidfile ]]; then
    pid=$(<"$pidfile")
    if [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && ps -p "$pid" -o command= | grep -q qemu-system-aarch64; then
      state=running
    fi
  fi
  printf '%-22s %-14s %-7s %-7s %-9s %-7s %s\n' "$name" "$image" "$vcpu" "${memory}G" "$storage" "$state" "$port"
done
