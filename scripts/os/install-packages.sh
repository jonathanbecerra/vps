#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
preview_if_requested install-packages "$@"
require_root
detect_os
load_config /etc/vps-setup/host.conf
validate_config
setup_lock
read_packages "$ROOT/config/apt/packages.txt"
begin 'Install packages from config/apt/packages.txt'
progress 'Refresh Ubuntu package list' apt-get update
install_packages "${PACKAGES[@]}"
