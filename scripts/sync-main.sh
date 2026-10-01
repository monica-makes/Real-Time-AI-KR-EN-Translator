#!/bin/bash
# Rebuilds `main` from `debug-prototyping`: the same app, with every debug option and demo stripped
# out (scripts/strip_debug.py). Work and commit on debug-prototyping, then run this; never commit
# to main directly, or the next sync replaces it.
#
#   scripts/sync-main.sh             # main = debug-prototyping's tip, stripped
#   scripts/sync-main.sh <commit>    # main = that debug-prototyping commit, stripped
#
# It strips in a temporary worktree, so this checkout and its uncommitted changes are untouched.
# Each sync commit's parents are main's previous commit and the debug-prototyping commit it was
# made from, so `git log main` shows where every sync came from. SYNC_MAIN_TRAILER, if set, is
# appended to the commit message. Doesn't push.
set -euo pipefail

source_ref="${1:-debug-prototyping}"
cd "$(git rev-parse --show-toplevel)"

source_commit="$(git rev-parse --verify --quiet "$source_ref^{commit}")" ||
  { echo "sync-main: no commit $source_ref" >&2; exit 1; }
main_commit="$(git rev-parse --verify main^{commit})"

if git worktree list --porcelain | grep -qx 'branch refs/heads/main'; then
  echo "sync-main: main is checked out in a worktree; switch it to another branch first" >&2
  exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/sync-main.XXXXXX")"
cleanup() {
  git worktree remove --force "$work" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
git worktree add --quiet --detach "$work" "$source_commit"

python3 "$work/scripts/strip_debug.py" "$work"
git -C "$work" add -A
tree="$(git -C "$work" write-tree)"

short="$(git rev-parse --short "$source_commit")"
if [ "$tree" = "$(git rev-parse "main^{tree}")" ]; then
  echo "main already matches $source_ref ($short)"
  exit 0
fi

# The first sync continues from debug-prototyping itself; later ones join both histories
if git merge-base --is-ancestor "$main_commit" "$source_commit"; then
  parents=(-p "$source_commit")
else
  parents=(-p "$main_commit" -p "$source_commit")
fi

message="Ship debug-prototyping $short without its debug options and demos

main is debug-prototyping at $short with every #if DEBUG block and the debug-only
files stripped (scripts/sync-main.sh, scripts/strip_debug.py): the app as Release
builds it."
if [ -n "${SYNC_MAIN_TRAILER:-}" ]; then
  message="$message

$SYNC_MAIN_TRAILER"
fi

commit="$(git commit-tree "$tree" "${parents[@]}" -m "$message")"
git update-ref -m "sync-main: $source_ref $short" refs/heads/main "$commit" "$main_commit"
echo "main -> $(git rev-parse --short "$commit") (debug-prototyping $short, stripped)"
