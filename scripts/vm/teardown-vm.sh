#!/usr/bin/env bash
# shellcheck source=scripts/vm/manage-lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/manage-lib.sh"
parse_vm_args --allow-missing-name "$@"
load_vm_config
preview_if_requested vm-teardown
begin "Remove VM $VM_NAME"
vm_running && die "Stop $VM_NAME before removing it."

if [[ $VM_YES != yes ]]; then
  [[ -t 0 ]] || die 'Use --yes to remove a VM without a prompt.'
  answer=
  read -r -p "Delete $VM_NAME and its disk? Type yes to continue: " answer
  [[ $answer == yes ]] || die 'Cancelled.'
fi

step 'Remove VM files'
rm -rf -- "$VM_DIR"
note "Removed $VM_NAME."
