#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
preview_if_requested install-tools "$@"
require_root
detect_os
load_config /etc/vps-setup/host.conf
validate_config
setup_lock
clear_screen
read_setup_packages "$ROOT/config/apt/packages.txt"
progress 'Install selected tools and font' bash "$ROOT/scripts/install-binaries.sh" "${binary_packages[@]}"
for tool in "${binary_packages[@]}"; do
  printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$tool"
done
