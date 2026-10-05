#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
preview_if_requested check-repo "$@"
cd "$ROOT"
DOTFILES_ROOT=${DOTFILES_DIR:-$ROOT/dotfiles}
[[ ! -e config/apt/binaries.tsv ]] || die 'Pinned user binaries belong under dotfiles/apt.'
for tool in bash shellcheck shfmt jq zsh; do
  command -v "$tool" >/dev/null || {
    printf 'Install %s to run make check-repo.\n' "$tool" >&2
    exit 1
  }
done
files=(install.sh scripts/*.sh scripts/os/*.sh scripts/ssh/*.sh scripts/caddy/*.sh scripts/vpn/*.sh scripts/deploy/*.sh scripts/vm/*.sh)
for file in "${files[@]}"; do bash -n "$file"; done
shellcheck -x "${files[@]}"
shfmt -d -i 2 -ci "${files[@]}"
jq -e . config/docker/daemon.json >/dev/null
if [[ -d $DOTFILES_ROOT ]]; then
  for file in "$DOTFILES_ROOT/zsh/.zshenv" "$DOTFILES_ROOT/zsh/.p10k.zsh" \
    "$DOTFILES_ROOT/zsh/.config/zsh/.zprofile" "$DOTFILES_ROOT/zsh/.config/zsh/.zshrc" \
    "$DOTFILES_ROOT/zsh/.config/zsh/aliases.zsh"; do zsh -n "$file"; done
  jq -e . "$DOTFILES_ROOT/glow/.config/glow/styles/rose-pine.json" \
    "$DOTFILES_ROOT/nvim/.config/nvim/lazy-lock.json" \
    "$DOTFILES_ROOT/deps/nvim/package.json" \
    "$DOTFILES_ROOT/deps/nvim/package-lock.json" >/dev/null
  git config --file "$DOTFILES_ROOT/git/.config/git/config" --list >/dev/null
  awk -F '\t' '$1 !~ /^#/ && NF != 5 { exit 1 }' "$DOTFILES_ROOT/apt/binaries.tsv" || die 'Invalid dotfiles binary manifest.'
else
  printf 'Skipping optional dotfiles checks.\n'
fi
bash scripts/vm/list-vm.sh >/dev/null
docker_key_fingerprint=$(tr -d '[:space:]' <config/docker/docker-key-fingerprint.txt)
[[ $docker_key_fingerprint =~ ^[[:xdigit:]]{40}$ ]] || die 'Docker key fingerprint must be 40 hexadecimal characters.'
grep -Eq '^FROM docker.io/library/caddy:[^[:space:]]+@sha256:[a-f0-9]{64} AS builder$' build/caddy/Dockerfile ||
  die 'Pin the Caddy builder image digest in build/caddy/Dockerfile.'
if { command -v docker >/dev/null && docker compose version >/dev/null 2>&1; } || command -v docker-compose >/dev/null; then
  find_compose
  grep -Eq '@sha256:[a-f0-9]{64}$' stacks/compose.lock.yaml || die 'Compose lock needs image digests.'
  "${COMPOSE[@]}" --env-file .env.example -f stacks/compose.yaml --profile tailscale \
    -f stacks/compose.lock.yaml config --quiet
else
  printf 'Skipping Compose checks. Install Docker Compose to run them.\n'
fi
bash scripts/check-setup.sh
bash scripts/check-terminal.sh
printf 'Syntax, formatting, and config checks passed.\n'
