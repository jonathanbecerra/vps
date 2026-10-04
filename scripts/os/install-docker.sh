#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
preview_if_requested install-docker "$@"
require_root
detect_os
load_config "$VPS_HOST_CONFIG"
validate_config
begin 'Install Docker and Compose'
ensure_time_sync
conflicting=()
for package in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
  if [[ $(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true) == 'install ok installed' ]]; then
    conflicting+=("$package")
  fi
done
if ((${#conflicting[@]})); then
  wait_for_apt
  progress 'Remove conflicting Docker packages' apt-get remove -y "${conflicting[@]}"
fi
install -d -m 0755 /etc/apt/keyrings
key_file=$(mktemp)
progress 'Download Docker signing key' curl --fail --silent --show-error --location --retry 3 \
  https://download.docker.com/linux/ubuntu/gpg -o "$key_file"
expected_fingerprint=$(tr -d '[:space:]' <"$ROOT/config/docker/docker-key-fingerprint.txt")
actual_fingerprint=$(gpg --batch --show-keys --with-colons "$key_file" |
  awk -F: '$1 == "pub" {primary=1; next} primary && $1 == "fpr" && !printed {print $10; printed=1}')
[[ $actual_fingerprint == "$expected_fingerprint" ]] || die 'Docker signing key fingerprint does not match.'
install -m 0644 "$key_file" /etc/apt/keyrings/docker.asc
rm -f "$key_file"
# An old docker.list can conflict with the new repo signing key.
if [[ -f /etc/apt/sources.list.d/docker.list ]]; then
  backup /etc/apt/sources.list.d/docker.list
  mv /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/docker.list.disabled
fi
DEB_ARCH=$(dpkg --print-architecture)
export DEB_ARCH
render "$ROOT/config/docker/docker.sources" /etc/apt/sources.list.d/docker.sources VERSION_CODENAME DEB_ARCH
apt_update 'Refresh Docker package list'
install_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
step 'Configure Docker'
install -d -m 0755 /etc/docker
backup /etc/docker/daemon.json
temporary=$(mktemp)
if [[ -f /etc/docker/daemon.json ]]; then
  jq -s '.[0] + .[1]' /etc/docker/daemon.json "$ROOT/config/docker/daemon.json" >"$temporary"
else
  cp "$ROOT/config/docker/daemon.json" "$temporary"
fi
dockerd --validate --config-file "$temporary"
if ! cmp -s "$temporary" /etc/docker/daemon.json; then
  install -m 0644 "$temporary" /etc/docker/daemon.json
  systemctl restart docker
fi
rm -f "$temporary"
systemctl enable --now docker
usermod -aG docker "$ADMIN_USER"
docker info >/dev/null
docker compose version
