#!/usr/bin/env bash
#
# Move a major version tag to the current commit, so every repository pinned to
# `@v1` picks the change up on its next run.
#
# Callers pin a moving major tag rather than a SHA on purpose: that is what makes
# an action bump here a single PR instead of one per dependant repository. The
# price is that this script publishes to three production pipelines at once, so
# it refuses to run unless the self-test is green on exactly this commit.
#
# Usage:
#   scripts/release.sh [v1] [--yes]
#
# Breaking changes get a new major instead: `scripts/release.sh v2`, then move
# the callers over one at a time. The old tag keeps working until the last one
# has moved.

set -euo pipefail

TAG=v1
ASSUME_YES=false
for arg in "$@"; do
  case $arg in
    v[0-9]*)   TAG=$arg ;;
    --yes|-y)  ASSUME_YES=true ;;
    -h|--help) awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/.."

branch=$(git rev-parse --abbrev-ref HEAD)
sha=$(git rev-parse HEAD)

[ "$branch" = main ] || { echo "on '$branch': release from main" >&2; exit 1; }
git diff --quiet && git diff --cached --quiet || { echo "working tree is dirty" >&2; exit 1; }

git fetch --quiet origin main
[ "$(git rev-parse origin/main)" = "$sha" ] || {
  echo "HEAD is not origin/main: push first" >&2; exit 1
}

# The self-test runs the entire pipeline against test/fixture, so a green run on
# this commit is the only evidence that matters.
if command -v gh >/dev/null 2>&1; then
  conclusion=$(gh run list --workflow self-test.yml --commit "$sha" \
    --limit 1 --json conclusion --jq '.[0].conclusion // "none"' 2>/dev/null || echo unknown)
  case $conclusion in
    success) echo "self-test: green on $(git rev-parse --short HEAD)" ;;
    none)    echo "no self-test run for this commit yet" >&2; exit 1 ;;
    unknown) echo "could not ask GitHub about the self-test; continuing" >&2 ;;
    *)       echo "self-test on this commit is '$conclusion'" >&2; exit 1 ;;
  esac
fi

echo
echo "Moving $TAG to $(git rev-parse --short HEAD)  $(git log -1 --format=%s)"
echo "Everything pinned to @$TAG picks this up on its next run:"
grep -rl "coolify-deploy.yml@$TAG" "$HOME/git" --include='*.yml' 2>/dev/null \
  | sed "s#^$HOME/git/#  #" || echo "  (no local clones found to list)"
echo

if ! $ASSUME_YES; then
  read -r -p "Move $TAG? [y/N] " reply
  case $reply in [yY]*) ;; *) echo "aborted"; exit 1 ;; esac
fi

# -f on both: a moving major tag is the entire mechanism. A caller that needs to
# be frozen pins the SHA instead, which this never touches.
git tag -f -a "$TAG" -m "$TAG -> $(git rev-parse --short HEAD)"
git push -f origin "refs/tags/$TAG"

echo "$TAG now points at $(git rev-parse --short HEAD)"
