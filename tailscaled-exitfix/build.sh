#!/bin/bash
# Builds tailscaled with exitfix.patch (macOS exit-node routes) from the exact tag and commit
# the Homebrew formula uses, runs the patch's tests, then installs it as the system daemon.
# Run it at the keyboard: installing restarts tailscaled, which drops remote sessions briefly.
# Usage: ./build.sh            build, test, install
#        ./build.sh --no-install
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FORMULA="$(brew cat tailscale)"
TAG="$(sed -n 's/.*tag: *"\(v[0-9.]*\)".*/\1/p' <<<"$FORMULA")"
REV="$(sed -n 's/.*revision: *"\([0-9a-f]*\)".*/\1/p' <<<"$FORMULA")"
[ -n "$TAG" ] && [ -n "$REV" ] || { echo "Couldn't read tag/revision from the Homebrew formula" >&2; exit 1; }
WORK="$HOME/Library/Caches/tailscaled-exitfix/build-$TAG"

echo "== Tailscale $TAG ($REV)"
rm -rf "$WORK"
git clone -q --depth 1 --branch "$TAG" https://github.com/tailscale/tailscale.git "$WORK" 2>/dev/null
cd "$WORK"
[ "$(git rev-parse HEAD)" = "$REV" ] || { echo "Tag $TAG is not at Homebrew's revision $REV" >&2; exit 1; }
git apply "$HERE/exitfix.patch"

echo "== Testing the patch"
go test ./wgengine/router/osrouter/ -run 'TestHalves|TestSplit'

echo "== Building tailscaled (Homebrew's ldflags)"
eval "$(./build_dist.sh shellvars)"
go build -trimpath -ldflags "-X tailscale.com/version.longStamp=$VERSION_LONG -X tailscale.com/version.shortStamp=$VERSION_SHORT -X tailscale.com/version.gitCommitStamp=$VERSION_GIT_HASH" \
    -o "$WORK/tailscaled" ./cmd/tailscaled
LC_ALL=C grep -a -q tailscaled-darwin-exitfix-v2 "$WORK/tailscaled" || { echo "Patch marker missing from the build" >&2; exit 1; }
"$WORK/tailscaled" --version | head -1
shasum -a 256 "$WORK/tailscaled"

[ "${1:-}" = "--no-install" ] && { echo "Built $WORK/tailscaled (not installed)"; exit 0; }

echo "== Installing (asks for your password; tailscaled restarts)"
sudo "$WORK/tailscaled" install-system-daemon
brew pin tailscale >/dev/null 2>&1 || true
sleep 3
"$(brew --prefix)/bin/tailscale" status | head -1
echo "Installed. Homebrew's tailscale is pinned so the CLI stays at $TAG; rerun this script after 'brew unpin tailscale && brew upgrade tailscale'."
