#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
preview_if_requested check-repo "$@"
cd "$ROOT"
for tool in bash shellcheck shfmt jq zsh; do
  command -v "$tool" >/dev/null || {
    printf 'Install %s to run make check-repo.\n' "$tool" >&2
    exit 1
  }
done
files=(setup-vps.sh scripts/*.sh scripts/vm/*.sh)
for file in "${files[@]}"; do bash -n "$file"; done
shellcheck -x "${files[@]}"
shfmt -d -i 2 -ci "${files[@]}"
for file in config/zsh/zshrc config/zsh/p10k.zsh; do zsh -n "$file"; done
jq -e . config/docker/daemon.json config/nvim/lazy-lock.json >/dev/null
bash scripts/vm/list-vm.sh >/dev/null
docker_key_fingerprint=$(tr -d '[:space:]' <config/docker/docker-key-fingerprint.txt)
[[ $docker_key_fingerprint =~ ^[[:xdigit:]]{40}$ ]] || die 'Docker key fingerprint must be 40 hexadecimal characters.'
if command -v docker >/dev/null || command -v docker-compose >/dev/null; then
  find_compose
  for stack in caddy tailscale; do
    jq -e 'all(.services[];
      if .build then all(.build.args[]; test("@sha256:[a-f0-9]{64}$"))
      else .image | test("@sha256:[a-f0-9]{64}$") end
    )' "stacks/$stack/compose.lock.json" >/dev/null
    "${COMPOSE[@]}" --env-file .env.example -f "stacks/$stack/compose.yaml" \
      -f "stacks/$stack/compose.lock.json" config --quiet
  done
else
  printf 'Skipping Compose checks. Install Docker Compose to run them.\n'
fi
printf 'Syntax, formatting, and config checks passed.\n'
