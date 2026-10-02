#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
preview_if_requested sync-time "$@"
require_root
detect_os
setup_lock
begin 'Synchronize system clock'
ensure_time_sync
timedatectl status --no-pager
