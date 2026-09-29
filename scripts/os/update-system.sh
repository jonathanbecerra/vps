#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
preview_if_requested update-system "$@"
require_root
detect_os
[[ ! -d /var/lib/vps-setup/ssh-pending ]] || die 'Confirm the pending SSH change first.'
setup_lock
begin 'Update Ubuntu'
confirm 'Update OS packages? Some services may restart.'
upgrade_os
note 'Ubuntu packages are up to date. Tools and images keep their pinned versions.'
if [[ -f /var/run/reboot-required ]]; then cat /var/run/reboot-required; fi
