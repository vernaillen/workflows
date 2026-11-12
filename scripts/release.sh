#!/usr/bin/env bash
#
# Start the release workflow, which moves a major version tag to the current
# commit, so every repository pinned to `@v1` picks the change up on its next
# run. The protect-tags ruleset rejects a tag push from here; the workflow pushes
# with a deploy key once vernaillen approves the run in the browser.
#
# Callers pin a moving major tag rather than a SHA on purpose: that is what makes
# an action bump here a single PR instead of one per dependant repository. The
# price is that a release publishes to every caller's production pipeline at
# once, so this refuses to start unless the self-test is green on exactly this
# commit (the workflow checks that again).
#
# Usage:
#   scripts/release.sh [v1]
#
# Breaking changes get a new major instead: `scripts/release.sh v2`, then move
# the callers over one at a time. The old tag keeps working until the last one
# has moved.

set -euo pipefail

TAG=v1
for arg in "$@"; do
  case $arg in
    v[0-9]*)   TAG=$arg ;;
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

conclusion=$(gh run list --workflow self-test.yml --commit "$sha" \
  --limit 1 --json conclusion --jq '.[0].conclusion // "none"')
case $conclusion in
  success) echo "self-test: green on $(git rev-parse --short HEAD)" ;;
  none)    echo "no self-test run for this commit yet" >&2; exit 1 ;;
  *)       echo "self-test on this commit is '$conclusion'" >&2; exit 1 ;;
esac

echo
echo "Releasing $TAG at $(git rev-parse --short HEAD)  $(git log -1 --format=%s)"
echo "Everything pinned to @$TAG picks this up on its next run:"
grep -rl "coolify-deploy.yml@$TAG" "$HOME/git" --include='*.yml' 2>/dev/null \
  | sed "s#^$HOME/git/#  #" || echo "  (no local clones found to list)"
echo

gh workflow run release.yml --ref main -f tag="$TAG"
echo "Started the release workflow. Approve it as vernaillen to move $TAG:"
echo "  https://github.com/vernaillen/workflows/actions/workflows/release.yml"
