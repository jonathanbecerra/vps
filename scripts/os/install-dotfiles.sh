#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
if [[ $EUID == 0 && ${DRY_RUN:-0} != 1 ]]; then
  # shellcheck source=scripts/lib.sh
  source "$root/scripts/lib.sh"
  load_config "$VPS_HOST_CONFIG"
  validate_config
  exec sudo -H -u "$ADMIN_USER" env -u DOTFILES_TARGET -u ZDOTDIR -u XDG_CONFIG_HOME -u XDG_DATA_HOME \
    -u XDG_STATE_HOME -u XDG_CACHE_HOME bash "${DOTFILES_DIR:-$root/dotfiles}/scripts/install.sh" "$@"
fi
exec bash "${DOTFILES_DIR:-$root/dotfiles}/scripts/install.sh" "$@"
