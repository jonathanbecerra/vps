#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
preview_if_requested create-deploy-key "$@"
[[ $(uname -s) == Linux ]] || die 'Run this on the Linux host.'
[[ $ROOT == /opt/vps ]] || die 'Run this command from /opt/vps.'
[[ ${REPO:-} =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die 'Set REPO=owner/name.'

owner=${REPO%%/*}
repository=${REPO#*/}
slug=$(printf '%s-%s' "$owner" "$repository" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-')
prefix=${KEY_PREFIX:-jb}
key_name="${prefix}_${slug}_ed25519"
key_dir=${DEPLOY_KEY_DIR:-$HOME/.ssh/deploy-keys}
key_file="$key_dir/$key_name"
host_alias="github-$slug"

install -d -m 0700 "$HOME/.ssh" "$key_dir"
if [[ -e $key_file || -e $key_file.pub ]]; then die "Deploy key already exists: $key_file"; fi
ssh-keygen -q -t ed25519 -C "$REPO read-only deploy key" -f "$key_file" -N ''
chmod 0600 "$key_file"
chmod 0644 "$key_file.pub"

ssh_config="$HOME/.ssh/config"
touch "$ssh_config"
chmod 0600 "$ssh_config"
if ! grep -qF "Host $host_alias" "$ssh_config"; then
  cat >>"$ssh_config" <<EOF

Host $host_alias
    HostName github.com
    User git
    IdentityFile $key_file
    IdentitiesOnly yes
EOF
fi

printf '\nAdd this public key to GitHub as a read-only deploy key for %s:\n' "$REPO"
cat "$key_file.pub"
printf '\nClone through the repository-specific SSH alias:\n'
printf 'git clone git@%s:%s.git\n' "$host_alias" "$REPO"
