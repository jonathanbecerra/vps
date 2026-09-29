#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
preview_if_requested sync-repo "$@"
action=${1:-plan}
target=${HOST:-}
case "$action" in plan | sync) ;; *) die 'Usage: sync-repo.sh plan|sync' ;; esac
[[ $target =~ ^([a-z_][a-z0-9_-]*@)?[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || die 'Set HOST to an SSH alias or user@hostname. Set ports and keys in ~/.ssh/config.'
command -v rsync >/dev/null || die 'Install rsync on your laptop first.'
ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes)
if [[ $action == plan ]]; then
  begin "Preview files for $target"
else
  begin "Sync files to $target"
fi
step 'Check SSH access and /opt/vps permissions'
ssh "${ssh_options[@]}" "$target" 'test "$(id -u)" -ne 0 && test -w /opt/vps' || die 'Use the admin account from setup. It needs write access to /opt/vps.'
options=(-acz --delete-after --itemize-changes --filter="merge $ROOT/.rsyncignore")
[[ $action != plan ]] || options+=(--dry-run)
step 'Compare the target and local files'
rsync "${options[@]}" -e 'ssh -o BatchMode=yes -o StrictHostKeyChecking=yes' "$ROOT/" "$target:/opt/vps/"
if [[ $action == sync ]]; then note 'Synced. Run make apply-stack HOST=... STACK=... to apply a stack.'; fi
