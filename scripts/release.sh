#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")/.."

die() {
  printf '%s\n' "$*" >&2
  exit 1
}
action=${1:-}
release_version=${VERSION:-${version:-}}
[[ $release_version =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
  die 'Set VERSION=MAJOR.MINOR.PATCH without a v prefix.'
case ${DRY_RUN:-0} in 0 | 1) ;; *) die 'DRY_RUN must be 0 or 1.' ;; esac
command -v git-cliff >/dev/null || die 'Install git-cliff before releasing.'

case $action in
  notes)
    git-cliff --unreleased --tag "$release_version"
    exit
    ;;
  publish) ;;
  *) die 'Usage: release.sh notes|publish' ;;
esac

[[ $(git branch --show-current) == main ]] || die 'Release from main.'
[[ -z $(git status --porcelain) ]] || die 'Commit or remove local changes before releasing.'
command -v gh >/dev/null || die 'Install GitHub CLI before releasing.'
gh auth status >/dev/null 2>&1 || die 'Log in with gh auth login before releasing.'
remote_main=$(git ls-remote --heads origin main) || die 'Could not read origin/main.'
remote_main=${remote_main%%$'\t'*}
[[ $remote_main == "$(git rev-parse HEAD)" ]] || die 'Push main before releasing.'

local_object=$(git rev-parse -q --verify "refs/tags/$release_version" 2>/dev/null || true)
local_commit=$(git rev-parse -q --verify "refs/tags/$release_version^{}" 2>/dev/null || true)
remote_tags=$(git ls-remote --tags origin "refs/tags/$release_version" "refs/tags/$release_version^{}") ||
  die 'Could not read remote tags.'
remote_object=$(awk -v ref="refs/tags/$release_version" '$2 == ref { print $1 }' <<<"$remote_tags")
remote_commit=$(awk -v ref="refs/tags/$release_version^{}" '$2 == ref { print $1 }' <<<"$remote_tags")
remote_commit=${remote_commit:-$remote_object}
[[ -z $local_commit || $local_commit == "$(git rev-parse HEAD)" ]] || die 'The local tag points to another commit.'
[[ -z $remote_commit || $remote_commit == "$(git rev-parse HEAD)" ]] || die 'The remote tag points to another commit.'
[[ -z $local_object || -z $remote_object || $local_object == "$remote_object" ]] ||
  die 'The local and remote tags differ.'
previous=$(git tag --merged HEAD --list --sort=-version:refname |
  grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | grep -vxF "$release_version" | head -n 1 || true)
if [[ -n $previous ]]; then
  IFS=. read -r major minor patch <<<"$release_version"
  IFS=. read -r old_major old_minor old_patch <<<"$previous"
  ((major > old_major || major == old_major && minor > old_minor || major == old_major && minor == old_minor && patch > old_patch)) ||
    die "Choose a version newer than $previous."
fi
if release_url=$(gh release view "$release_version" --json url --jq .url 2>/dev/null); then
  printf 'Already published: %s\n' "$release_url"
  exit
fi

notes_file=$(mktemp)
trap 'rm -f -- "$notes_file"' EXIT
if [[ -n $local_object ]]; then
  git-cliff --current --tag-pattern "^${release_version//./\\.}$" >"$notes_file"
else
  git-cliff --unreleased --tag "$release_version" >"$notes_file"
fi
grep -Eq '^[[:space:]]*- ' "$notes_file" || die 'No release notes remain after filtering commits.'

if [[ ${DRY_RUN:-0} == 1 ]]; then
  cat "$notes_file"
  printf 'Would tag, push, and publish %s.\n' "$release_version"
  exit
fi
[[ -n $local_object ]] || git tag -a "$release_version" -m "$release_version"
[[ -n $remote_object ]] || git push origin "refs/tags/$release_version"
gh release create "$release_version" --verify-tag --fail-on-no-commits \
  --title "$release_version" --notes-file "$notes_file"
