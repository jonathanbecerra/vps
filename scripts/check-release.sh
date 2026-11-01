#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
command -v git-cliff >/dev/null || {
  printf 'Skipping release checks. Install git-cliff to run them.\n'
  exit 0
}
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
work="$temporary/work"
mkdir -p "$work/scripts" "$temporary/bin"
cp "$root/Makefile" "$root/cliff.toml" "$work/"
cp "$root/scripts/release.sh" "$work/scripts/"
git init -q --bare "$temporary/origin.git"
git -C "$work" init -q -b main
git -C "$work" config user.name Fixture
git -C "$work" config user.email fixture@example.invalid
git -C "$work" remote add origin "$temporary/origin.git"
git -C "$work" add Makefile cliff.toml scripts/release.sh
git -C "$work" commit -qm 'feat: initial release'
git -C "$work" tag -a 0.1.0 -m 0.1.0
git -C "$work" push -q origin main 0.1.0
printf 'change\n' >"$work/change"
git -C "$work" add change
git -C "$work" commit -qm 'fix: useful correction'

cat >"$temporary/bin/gh" <<'FIXTURE'
#!/usr/bin/env bash
case "$1 $2" in
  'auth status') exit 0 ;;
  'release view')
    [[ -f $RELEASE_FIXTURE/published-$3 ]] || exit 1
    printf 'https://example.invalid/release\n'
    ;;
  'release create')
    release_tag=$3
    while (($#)); do
      if [[ $1 == --notes-file ]]; then
        grep -q 'Useful correction' "$2" || exit 90
        break
      fi
      shift
    done
    if [[ ${GH_FAIL_ONCE:-0} == 1 && ! -f $RELEASE_FIXTURE/failed-once ]]; then
      touch "$RELEASE_FIXTURE/failed-once"
      exit 92
    fi
    printf 'create\n' >>"$RELEASE_FIXTURE/gh-trace"
    touch "$RELEASE_FIXTURE/published-$release_tag"
    ;;
  *) exit 91 ;;
esac
FIXTURE
chmod +x "$temporary/bin/gh"

release_make() {
  PATH="$temporary/bin:$PATH" RELEASE_FIXTURE="$temporary" make --no-print-directory -s -C "$work" "$@"
}
if release_make release VERSION=0.1.1 >"$temporary/output" 2>&1; then
  printf 'Release accepted unpushed main.\n' >&2
  exit 1
fi
git -C "$work" push -q origin main
if release_make release VERSION=0.0.9 >"$temporary/output" 2>&1; then
  printf 'Release accepted an older version.\n' >&2
  exit 1
fi
release_make release-notes VERSION=0.1.1 >"$temporary/output"
grep -q 'Useful correction' "$temporary/output"
DRY_RUN=1 release_make release VERSION=0.1.1 >"$temporary/output"
grep -q 'Would tag, push, and publish 0.1.1.' "$temporary/output"
if git -C "$work" show-ref --verify --quiet refs/tags/0.1.1; then
  printf 'Dry run created a tag.\n' >&2
  exit 1
fi
if GH_FAIL_ONCE=1 release_make release VERSION=0.1.1 >"$temporary/output" 2>&1; then
  printf 'Release ignored a GitHub publishing failure.\n' >&2
  exit 1
fi
[[ $(git -C "$work" rev-parse 0.1.1^{}) == $(git -C "$work" rev-parse HEAD) ]]
git -C "$work" ls-remote --exit-code origin refs/tags/0.1.1 >/dev/null
release_make release VERSION=0.1.1 >"$temporary/output"
[[ $(<"$temporary/gh-trace") == create ]]
release_make release VERSION=0.1.1 >"$temporary/output"
[[ $(<"$temporary/gh-trace") == create ]]
printf 'maintenance\n' >"$work/maintenance"
git -C "$work" add maintenance
git -C "$work" commit -qm 'chore: update maintenance files'
git -C "$work" push -q origin main
if release_make release VERSION=0.1.2 >"$temporary/output" 2>&1; then
  printf 'Release published empty notes.\n' >&2
  exit 1
fi
if git -C "$work" show-ref --verify --quiet refs/tags/0.1.2; then
  printf 'Empty notes created a tag.\n' >&2
  exit 1
fi
if release_make release VERSION=0.1.0 >"$temporary/output" 2>&1; then
  printf 'Release reused a tag pointing to another commit.\n' >&2
  exit 1
fi
printf 'Release preview, published-main guard, tag recovery, and notes checks passed.\n'
