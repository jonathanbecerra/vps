#!/usr/bin/env bash
# shellcheck source=scripts/vm/manage-lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/manage-lib.sh"
parse_vm_args --allow-missing-name "$@"
load_vm_config
preview_if_requested vm-attach
vm_running || die "$VM_NAME is stopped. Start it with make start-vm name=$VM_NAME."
[[ -S $SERIAL_SOCKET ]] || die "Console socket is missing: $SERIAL_SOCKET"
attach_vm_console
