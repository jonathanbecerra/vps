#!/usr/bin/env bash
# shellcheck source=scripts/vm/manage-lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/manage-lib.sh"
parse_vm_args --allow-missing-name "$@"
load_vm_config
preview_if_requested vm-stop
begin "Stop VM $VM_NAME"

if ! vm_running; then
  [[ ! -f $PIDFILE ]] || rm -f "$PIDFILE"
  printf '%s is already stopped.\n' "$VM_NAME"
  exit 0
fi

if [[ -S $MONITOR ]]; then
  step 'Ask Ubuntu to shut down'
  printf 'system_powerdown\n' | nc -U "$MONITOR" >/dev/null 2>&1 || true
else
  die 'QEMU monitor is unavailable; stop the VM from its QEMU window.'
fi

wait_for_shutdown() {
  local attempt
  for ((attempt = 0; attempt < 30; attempt++)); do
    vm_running || return 0
    sleep 1
  done
  return 1
}
if progress 'Wait for Ubuntu to shut down' wait_for_shutdown; then
  note "$VM_NAME stopped."
else
  die "Shutdown requested; $VM_NAME is still running."
fi
