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
files=(setup-vps.sh scripts/*.sh scripts/os/*.sh scripts/ssh/*.sh scripts/compose/*.sh scripts/deploy/*.sh scripts/vm/*.sh dotfiles/tmux/.config/tmux/choose-session.sh)
for file in "${files[@]}"; do bash -n "$file"; done
shellcheck -x "${files[@]}"
shfmt -d -i 2 -ci "${files[@]}"
for file in dotfiles/zsh/.zshenv dotfiles/zsh/.p10k.zsh dotfiles/zsh/.config/zsh/.zshrc dotfiles/zsh/.config/zsh/aliases.zsh; do zsh -n "$file"; done
jq -e . config/docker/daemon.json dotfiles/glow/.config/glow/styles/rose-pine.json dotfiles/nvim/.config/nvim/lazy-lock.json dotfiles/dependencies/nvim/package.json dotfiles/dependencies/nvim/package-lock.json >/dev/null
git config --file dotfiles/git/.config/git/config --list >/dev/null
bash scripts/vm/list-vm.sh >/dev/null
docker_key_fingerprint=$(tr -d '[:space:]' <config/docker/docker-key-fingerprint.txt)
[[ $docker_key_fingerprint =~ ^[[:xdigit:]]{40}$ ]] || die 'Docker key fingerprint must be 40 hexadecimal characters.'
grep -Eq '^FROM docker.io/library/caddy:[^[:space:]]+@sha256:[a-f0-9]{64} AS builder$' stacks/caddy/Dockerfile ||
  die 'Pin the Caddy builder image digest in stacks/caddy/Dockerfile.'
grep -Eq '^FROM docker.io/library/caddy:[^[:space:]]+@sha256:[a-f0-9]{64}$' stacks/caddy/Dockerfile ||
  die 'Pin the Caddy runtime image digest in stacks/caddy/Dockerfile.'
if { command -v docker >/dev/null && docker compose version >/dev/null 2>&1; } || command -v docker-compose >/dev/null; then
  find_compose
  grep -Eq '@sha256:[a-f0-9]{64}$' stacks/compose.lock.yaml || die 'Compose lock needs image digests.'
  "${COMPOSE[@]}" --env-file .env.example -f stacks/compose.yaml --profile caddy --profile tailscale \
    -f stacks/compose.lock.yaml config --quiet
else
  printf 'Skipping Compose checks. Install Docker Compose to run them.\n'
fi
printf 'Syntax, formatting, and config checks passed.\n'
