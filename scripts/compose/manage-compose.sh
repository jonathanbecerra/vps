#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
action=${1:?Choose up, down, restart, recreate, or ps}
case "$action" in up | down | restart | recreate | ps) ;; *) die 'Choose up, down, restart, recreate, or ps.' ;; esac
preview_if_requested "compose-$action" "$@"
[[ $(uname -s) == Linux ]] || die 'Run this command on the Linux host.'
load_config /etc/vps-setup/host.conf
validate_config
[[ $ROOT == /opt/vps ]] || die 'Run this command from /opt/vps.'
begin 'Docker Compose'

profiles=()
[[ $VPN != tailscale ]] || profiles+=(--profile tailscale)
services=$(compose "${profiles[@]}" config --services)
if [[ $action != down && $action != ps && -z $services ]]; then
  die 'No Docker services are enabled. Configure Tailscale or add an application stack first.'
fi

case "$action" in
  up | recreate)
    progress 'Verify pinned service images' bash "$ROOT/scripts/compose/lock-images.sh" verify
    if [[ $action == up ]]; then
      progress 'Start enabled services' compose "${profiles[@]}" up -d --build
    else
      progress 'Rebuild and recreate services' compose "${profiles[@]}" up -d --build --force-recreate --remove-orphans
    fi
    ;;
  down)
    progress 'Stop the Compose project' compose --profile tailscale down
    remove_legacy_compose tailscale
    ;;
  restart) progress 'Restart enabled services' compose "${profiles[@]}" restart ;;
  ps)
    step 'Containers in the Compose project'
    compose --profile tailscale ps -a
    ;;
esac
